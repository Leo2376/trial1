// L1 instruction cache: 32 KiB, 4-way set-associative, blocking, read-only.
//
// 256 sets x 4 ways x 32-byte lines, tree-PLRU replacement. Sits between
// the core fetch port and the shared AXI arbiter in rv64gch_top, speaking
// the same req/ready/ack 64-bit protocol on both sides (single outstanding
// transaction, single-cycle ack pulse).
//
// Timing contract (matches axi4_master, required by rv64gch_core fetch):
// the ack for a CPU request is NEVER combinational in the accept cycle.
// The core sets fetch_busy on (req & ready) and only honors an ack when
// busy is already set, so every response (hit or fill) is delivered one
// or more cycles after the request is accepted.
//
// Hit latency is 2 cycles (accept -> lookup -> ack). A miss selects a
// tree-PLRU victim way and issues sequential 8-byte fills for the 32-byte
// line, then re-enters lookup for the latched request: a redirect during
// the fill is handled by serving the old line (the core ignores the stale
// ack after its flush) and caching the new address on re-request.
//
// flush_i (wired to fence.i retire) toggles an invalidate epoch instead of
// clearing 1024 valid bits. A line hits only when its epoch matches; a
// stale-epoch alias can only occur after 2 flushes without a refill and
// then holds identical instruction bytes (no I-side writes), so it is
// benign.
//
// NOTE: tag/data/valid/plru live in flops here for bring-up. For synthesis
// they should be mapped to SRAM macros (tag banks + data banks).
module l1i #(
  parameter int ADDR_W     = 48,
  parameter int DATA_W     = 64,
  parameter int LINE_BYTES = 32,
  parameter int SIZE_BYTES = 32 * 1024,
  parameter int NUM_WAYS   = 4
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

  localparam int OFFSET_BITS    = $clog2(LINE_BYTES);              // 5
  localparam int WORDS_PER_LINE = LINE_BYTES / 8;                  // 4
  localparam int WORD_IDX_BITS  = $clog2(WORDS_PER_LINE);          // 2
  localparam int NUM_SETS       = SIZE_BYTES / LINE_BYTES / NUM_WAYS; // 256
  localparam int INDEX_BITS     = $clog2(NUM_SETS);                // 8
  localparam int WAY_BITS       = $clog2(NUM_WAYS);                // 2
  localparam int TAG_BITS       = ADDR_W - INDEX_BITS - OFFSET_BITS;  // 35
  // Bit layout of a line address: [TAG | INDEX | WORD_IDX | 3'b000]
  localparam int WORD_LSB       = 3;
  localparam int INDEX_LSB      = WORD_LSB + WORD_IDX_BITS;        // 5
  localparam int TAG_LSB        = INDEX_LSB + INDEX_BITS;          // 13

  typedef enum logic [2:0] { S_RESET, S_IDLE, S_LOOKUP, S_RESP, S_FILL } state_e;
  state_e st;

  // Line storage (flops for bring-up; map to SRAM for synthesis).
  logic [TAG_BITS-1:0] tags  [NUM_SETS][NUM_WAYS];
  logic [NUM_WAYS-1:0] valid [NUM_SETS];
  logic [NUM_WAYS-1:0] lep   [NUM_SETS];   // per-way invalidate epoch
  logic [DATA_W-1:0]   data  [NUM_SETS][NUM_WAYS][WORDS_PER_LINE];
  // Tree-PLRU per set: [2]=root (0=left{0,1} LRU, 1=right{2,3} LRU),
  // [1]=left (0=way0 LRU, 1=way1 LRU), [0]=right (0=way2 LRU, 1=way3 LRU).
  // Bits point TOWARD the least-recently-used way; touching way w sets
  // them AWAY from w (root <= (w<2), mid <= (w==edge0)).
  logic [2:0]          plru  [NUM_SETS];

  logic [ADDR_W-1:0] req_q;    // latched CPU request under lookup
  logic [ADDR_W-1:0] miss_q;   // line being filled
  logic [DATA_W-1:0] resp_q;   // response word for S_RESP
  logic [WAY_BITS-1:0] victim_q; // latched victim way for the fill
  logic [WORD_IDX_BITS-1:0] fill_cnt;
  logic fill_ok_q;             // fill still valid (no flush arrived mid-fill)
  logic cur_epoch;

  // Lookup fields for the latched request.
  logic [INDEX_BITS-1:0]    lk_set;
  logic [TAG_BITS-1:0]      lk_tag;
  logic [WORD_IDX_BITS-1:0] lk_word;
  assign lk_set  = req_q[INDEX_LSB +: INDEX_BITS];
  assign lk_tag  = req_q[TAG_LSB +: TAG_BITS];
  assign lk_word = req_q[WORD_LSB +: WORD_IDX_BITS];

  // 4-way tag compare (blocking combinational; simulator-friendly).
  logic [NUM_WAYS-1:0] way_match;
  always_comb begin
    way_match = '0;
    for (int w = 0; w < NUM_WAYS; w++)
      way_match[w] = valid[lk_set][w] & (tags[lk_set][w] == lk_tag) &
                     (lep[lk_set][w] == cur_epoch);
  end

  logic hit;
  logic [WAY_BITS-1:0] hit_way;
  always_comb begin
    hit = 1'b0;
    hit_way = '0;
    for (int w = 0; w < NUM_WAYS; w++)
      if (way_match[w]) begin
        hit = 1'b1;
        hit_way = w[WAY_BITS-1:0];
      end
  end

  // Tree-PLRU victim for the latched request's set.
  logic [WAY_BITS-1:0] victim;
  always_comb begin
    if (!plru[lk_set][2]) victim = plru[lk_set][1] ? 2'd1 : 2'd0;
    else                  victim = plru[lk_set][0] ? 2'd3 : 2'd2;
  end

  logic [INDEX_BITS-1:0] miss_set;
  assign miss_set = miss_q[INDEX_LSB +: INDEX_BITS];

  // Moore outputs.
  assign ready_o = (st == S_IDLE);
  assign ack_o   = (st == S_RESP);
  assign rdata_o = resp_q;
  assign req_o   = (st == S_FILL);
  assign addr_o  = {miss_q[ADDR_W-1:INDEX_LSB], fill_cnt, 3'b000};

  // Reset sweep index (one set cleared per cycle; avoids an array-clear
  // loop unsupported by the simulator).
  logic [INDEX_BITS-1:0] rst_idx;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      st        <= S_RESET;
      req_q     <= '0;
      miss_q    <= '0;
      resp_q    <= '0;
      victim_q  <= '0;
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
          valid[rst_idx] <= '0;
          plru[rst_idx]  <= '0;
          if (rst_idx == NUM_SETS - 1) st <= S_IDLE;
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
            resp_q <= data[lk_set][hit_way][lk_word];
            // PLRU update: point away from the accessed way (toward LRU).
            plru[lk_set][2] <= (hit_way < 2);
            if (hit_way < 2) plru[lk_set][1] <= (hit_way == 0);
            else             plru[lk_set][0] <= (hit_way == 2);
            st <= S_RESP;
            `ifdef L1I_DEBUG
            $display("[l1i %0t] HIT addr=%h way=%0d data=%h", $time, req_q,
                     hit_way, data[lk_set][hit_way][lk_word]);
            `endif
          end else begin
            miss_q    <= req_q;
            victim_q  <= victim;
            fill_cnt  <= '0;
            fill_ok_q <= ~flush_i;
            st        <= S_FILL;
            `ifdef L1I_DEBUG
            $display("[l1i %0t] MISS addr=%h victim=%0d", $time, req_q, victim);
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
            $display("[l1i %0t] FILLBEAT cnt=%0d way=%0d addr=%h data=%h", $time,
                     fill_cnt, victim_q, addr_o, rdata_i);
            `endif
            data[miss_set][victim_q][fill_cnt] <= rdata_i;
            if (fill_cnt == WORDS_PER_LINE - 1) begin
              if (fill_ok_q) begin
                tags[miss_set][victim_q]  <= miss_q[TAG_LSB +: TAG_BITS];
                valid[miss_set][victim_q] <= 1'b1;
                lep[miss_set][victim_q]   <= cur_epoch;
                // Filled way is now MRU: point away from it.
                plru[miss_set][2] <= (victim_q < 2);
                if (victim_q < 2) plru[miss_set][1] <= (victim_q == 0);
                else              plru[miss_set][0] <= (victim_q == 2);
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
