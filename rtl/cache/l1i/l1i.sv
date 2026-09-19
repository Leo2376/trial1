// L1 instruction cache: 32 KiB, direct-mapped, blocking, read-only.
//
// Sits between the core fetch port and the shared AXI arbiter in
// rv64gch_top, speaking the same req/ready/ack 64-bit protocol on both
// sides (single outstanding transaction, single-cycle ack pulse).
//
// Timing contract (matches axi4_master, required by rv64gch_core fetch):
// the ack for a CPU request is NEVER combinational in the accept cycle.
// The core sets fetch_busy on (req & ready) and only honors an ack when
// busy is already set, so every response (hit or fill) is delivered one
// or more cycles after the request is accepted.
//
// Hit latency is 2 cycles (accept -> lookup -> ack). A miss issues
// sequential 8-byte fills (one per cycle the downstream port is ready)
// for the 32-byte line, then re-enters lookup for the (possibly changed)
// CPU address: a redirect during the fill is handled by simply caching
// the old line and serving the new address afterwards.
//
// flush_i (wired to fence.i retire) clears all valid bits. A fill beaten
// in flight when flush arrives is discarded (valid not set) so no
// pre-fence line survives; an in-flight RESP ack is still delivered so
// the core never hangs with fetch_busy set and no ack coming.
//
// NOTE: tag/data/valid live in flops here for bring-up. For synthesis
// they should be mapped to SRAM macros (1R/1W).
module l1i #(
  parameter int ADDR_W     = 48,
  parameter int DATA_W     = 64,
  parameter int LINE_BYTES = 32,
  parameter int SIZE_BYTES = 32 * 1024
) (
  input  logic              clk,
  input  logic              rst_n,

  // CPU side (fetch port of rv64gch_core): read-only.
  input  logic              req_i,
  input  logic [ADDR_W-1:0] addr_i,
  output logic [DATA_W-1:0] rdata_o,
  output logic              ack_o,
  output logic              ready_o,

  // Memory side (toward the shared AXI arbiter): read-only, single beat.
  output logic              req_o,
  output logic [ADDR_W-1:0] addr_o,
  input  logic [DATA_W-1:0] rdata_i,
  input  logic              ack_i,
  input  logic              ready_i,

  // Invalidate all lines (fence.i retire).
  input  logic              flush_i
);

  localparam int OFFSET_BITS     = $clog2(LINE_BYTES);       // 5
  localparam int WORDS_PER_LINE  = LINE_BYTES / 8;           // 4
  localparam int WORD_IDX_BITS   = $clog2(WORDS_PER_LINE);   // 2
  localparam int NUM_LINES       = SIZE_BYTES / LINE_BYTES;  // 1024
  localparam int INDEX_BITS      = $clog2(NUM_LINES);        // 10
  localparam int TAG_BITS        = ADDR_W - INDEX_BITS - OFFSET_BITS; // 33
  // Bit layout of a line address: [TAG | INDEX | WORD_IDX | 3'b000]
  localparam int WORD_LSB        = 3;
  localparam int INDEX_LSB       = WORD_LSB + WORD_IDX_BITS; // 5
  localparam int TAG_LSB         = INDEX_LSB + INDEX_BITS;   // 15

  typedef enum logic [2:0] { S_RESET, S_IDLE, S_LOOKUP, S_RESP, S_FILL } state_e;
  state_e st;

  // Line storage (flops for bring-up; map to SRAM for synthesis).
  logic [TAG_BITS-1:0] tags  [NUM_LINES];
  logic                valid [NUM_LINES];
  logic [DATA_W-1:0]   data  [NUM_LINES][WORDS_PER_LINE];
  // Invalidate epoch: flush_i toggles cur_epoch instead of clearing 1024
  // valid bits (an unsupported array-clear loop). A line hits only when its epoch
  // matches. Stale-epoch lines can only alias after 2 flushes without a
  // refill, and then hold identical instruction bytes (no I-side writes),
  // so the alias is benign.
  logic cur_epoch;
  logic lep   [NUM_LINES];

  logic [ADDR_W-1:0] req_q;    // latched CPU request under lookup
  logic [ADDR_W-1:0] miss_q;   // line being filled
  logic [DATA_W-1:0] resp_q;   // response word for S_RESP
  logic [WORD_IDX_BITS-1:0] fill_cnt;
  logic fill_ok_q;             // fill still valid (no flush arrived mid-fill)

  // Lookup fields for the latched request.
  logic [INDEX_BITS-1:0]    lk_idx;
  logic [TAG_BITS-1:0]      lk_tag;
  logic [WORD_IDX_BITS-1:0] lk_word;
  assign lk_idx  = req_q[INDEX_LSB +: INDEX_BITS];
  assign lk_tag  = req_q[TAG_LSB +: TAG_BITS];
  assign lk_word = req_q[WORD_LSB +: WORD_IDX_BITS];

  logic hit;
  assign hit = valid[lk_idx] & (tags[lk_idx] == lk_tag) & (lep[lk_idx] == cur_epoch);

  logic [INDEX_BITS-1:0] miss_idx;
  assign miss_idx = miss_q[INDEX_LSB +: INDEX_BITS];

  // Moore outputs.
  assign ready_o = (st == S_IDLE);
  assign ack_o   = (st == S_RESP);
  assign rdata_o = resp_q;
  assign req_o   = (st == S_FILL);
  assign addr_o  = {miss_q[ADDR_W-1:INDEX_LSB], fill_cnt, 3'b000};

  // Reset sweep index (one valid bit cleared per cycle; avoids an
  // array-clear loop unsupported by the simulator).
  logic [INDEX_BITS-1:0] rst_idx;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      st        <= S_RESET;
      req_q     <= '0;
      miss_q    <= '0;
      resp_q    <= '0;
      fill_cnt  <= '0;
      fill_ok_q <= 1'b0;
      cur_epoch <= 1'b0;
      rst_idx   <= '0;
    end else begin
      if (flush_i) begin
        cur_epoch <= ~cur_epoch;
        fill_ok_q <= 1'b0;
      end
      case (st)
        S_RESET: begin
          valid[rst_idx] <= 1'b0;
          if (rst_idx == NUM_LINES - 1) st <= S_IDLE;
          else rst_idx <= rst_idx + 1'b1;
        end
        S_IDLE: begin
          if (!flush_i && req_i) begin
            req_q <= addr_i;
            st    <= S_LOOKUP;
            `ifdef L1I_DEBUG
            $display("[l1i %0t] ACCEPT addr=%h", $time, addr_i);
            `endif
          end
        end
        S_LOOKUP: begin
          if (hit) begin
            resp_q <= data[lk_idx][lk_word];
            st     <= S_RESP;
            `ifdef L1I_DEBUG
            $display("[l1i %0t] HIT addr=%h data=%h", $time, req_q, data[lk_idx][lk_word]);
            `endif
          end else begin
            miss_q    <= req_q;
            fill_cnt  <= '0;
            fill_ok_q <= ~flush_i;
            st        <= S_FILL;
            `ifdef L1I_DEBUG
            $display("[l1i %0t] MISS addr=%h", $time, req_q);
            `endif
          end
        end
        S_RESP: begin
          st <= S_IDLE;
          `ifdef L1I_DEBUG
          $display("[l1i %0t] RESP data=%h", $time, resp_q);
          `endif
        end
        S_FILL: begin
          // The CPU request was already accepted (core set fetch_busy), so
          // the fill MUST end in a RESP ack for the latched req_q. A flush
          // only suppresses the valid-set (fill_ok_q); the beats still
          // complete and lookup re-evaluates (refilling post-flush if the
          // line was discarded). Redirects are safe too: the core ignores
          // a stale ack (busy cleared by its flush) and re-requests.
          if (ack_i) begin
            `ifdef L1I_DEBUG
            $display("[l1i %0t] FILLBEAT cnt=%0d addr=%h data=%h", $time, fill_cnt, addr_o, rdata_i);
            `endif
            data[miss_idx][fill_cnt] <= rdata_i;
            if (fill_cnt == WORDS_PER_LINE - 1) begin
              if (fill_ok_q) begin
                tags[miss_idx]  <= miss_q[TAG_LSB +: TAG_BITS];
                valid[miss_idx] <= 1'b1;
                lep[miss_idx]   <= cur_epoch;
              end
              st <= S_LOOKUP;
            end else begin
              fill_cnt <= fill_cnt + 1'b1;
            end
          end
        end
        default: st <= S_RESET;
      endcase
    end
  end

endmodule
