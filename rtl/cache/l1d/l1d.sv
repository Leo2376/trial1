// L1 data cache: 32 KiB, 4-way set-associative, blocking, write-back
// with write-allocate.
//
// 256 sets x 4 ways x 32-byte lines, tree-PLRU replacement. Sits on the
// core data-memory port (between rv64gch_core mem_* and the shared AXI
// arbiter in rv64gch_top), speaking the same req/ready/ack 64-bit protocol
// on both sides (single outstanding transaction, single-cycle ack pulse).
//
// The inline LSU is untouched: it still issues single 8-byte reads/writes
// with byte-enables and sequences AMO as read-then-write. The cache honors
// the same contract the AXI path did:
//
// - Reads: hit -> word in 2 cycles (accept -> lookup -> ack). Miss ->
//   fill the 32-byte line (evicting a tree-PLRU victim, writing it back
//   first if dirty), then serve.
// - Writes: hit -> byte-merge per be_i, set dirty, ack. Miss ->
//   write-allocate (fill first, then merge). Ack carries no data.
// - AMO/LR/SC: the core sequences these as ordinary reads/writes, which
//   is atomic here by construction (in-order core + blocking cache: the
//   line cannot move between the AMO read and write phases). Reservation
//   tracking stays in the core; single-hart semantics unchanged.
// - FENCE (normal): naturally satisfied — the blocking cache retires every
//   access in order and the core stalls on lsu_busy, so all prior accesses
//   complete before a FENCE retires. flush_i is provided for future
//   coherence use (global invalidate); top ties it off (no DMA yet).
//
// Timing contract (required by the core LSU): the ack for an accepted CPU
// request is NEVER combinational in the accept cycle. Responses always
// come one or more cycles after acceptance.
//
// NOTE: tag/data/valid/dirty/plru live in flops here for bring-up. For
// synthesis they should be mapped to SRAM macros.
module l1d #(
  parameter int ADDR_W     = 48,
  parameter int DATA_W     = 64,
  parameter int LINE_BYTES = 32,
  parameter int SIZE_BYTES = 32 * 1024,
  parameter int NUM_WAYS   = 4
) (
  input  logic              clk,
  input  logic              rst_n,

  // CPU side (data port of rv64gch_core).
  input  logic              req_i,
  input  logic              we_i,
  input  logic [ADDR_W-1:0] addr_i,
  input  logic [7:0]        be_i,
  input  logic [DATA_W-1:0] wdata_i,
  input  logic              lock_i,
  output logic [DATA_W-1:0] rdata_o,
  output logic              ack_o,
  output logic              ready_o,

  // Memory side (toward the shared AXI arbiter): single beat.
  output logic              req_o,
  output logic              we_o,
  output logic [ADDR_W-1:0] addr_o,
  output logic [7:0]        be_o,
  output logic [DATA_W-1:0] wdata_o,
  output logic              lock_o,
  input  logic [DATA_W-1:0] rdata_i,
  input  logic              ack_i,
  input  logic              ready_i,

  // Invalidate all lines (reserved for future coherence use; tie off).
  input  logic              flush_i,

  // Drain: write back all dirty lines and invalidate (PTE/code visibility
  // on SFENCE.VMA / SATP write / FENCE.I retire). Level; edge-triggered
  // internally. drain_busy_o stalls the core while pending or running.
  input  logic              drain_i,
  output logic              drain_busy_o
);

  localparam int OFFSET_BITS     = $clog2(LINE_BYTES);                // 5
  localparam int WORDS_PER_LINE  = LINE_BYTES / 8;                    // 4
  localparam int WORD_IDX_BITS   = $clog2(WORDS_PER_LINE);            // 2
  localparam int NUM_SETS        = SIZE_BYTES / LINE_BYTES / NUM_WAYS; // 256
  localparam int INDEX_BITS      = $clog2(NUM_SETS);                  // 8
  localparam int WAY_BITS        = $clog2(NUM_WAYS);                  // 2
  localparam int TAG_BITS        = ADDR_W - INDEX_BITS - OFFSET_BITS; // 35
  // Bit layout of a line address: [TAG | INDEX | WORD_IDX | 3'b000]
  localparam int WORD_LSB        = 3;
  localparam int INDEX_LSB       = WORD_LSB + WORD_IDX_BITS;          // 5
  localparam int TAG_LSB         = INDEX_LSB + INDEX_BITS;            // 13

  import rv64gch_memmap_pkg::*;

  // Physical memory attribute: everything at/above MMIO_BASE (hostif,
  // future CLINT/PLIC) is uncacheable MMIO and bypasses the lines.
  function automatic logic uncacheable(input logic [ADDR_W-1:0] a);
    return a >= MMIO_BASE;
  endfunction

  typedef enum logic [3:0] {
    S_RESET, S_IDLE, S_LOOKUP, S_RESP, S_WRITEBACK, S_FILL,
    S_UNCACHED, S_DRAIN, S_DRAINWB
  } state_e;
  state_e st;

  // Line storage (flops for bring-up; map to SRAM for synthesis).
  logic [TAG_BITS-1:0] tags  [NUM_SETS][NUM_WAYS];
  logic [NUM_WAYS-1:0] valid [NUM_SETS];
  logic [NUM_WAYS-1:0] dirty [NUM_SETS];
  logic [NUM_WAYS-1:0] lep   [NUM_SETS];   // per-way invalidate epoch
  logic [DATA_W-1:0]   data  [NUM_SETS][NUM_WAYS][WORDS_PER_LINE];
  // Tree-PLRU per set: [2]=root (0=left{0,1} LRU, 1=right{2,3} LRU),
  // [1]=left (0=way0 LRU, 1=way1 LRU), [0]=right (0=way2 LRU, 1=way3 LRU).
  // Bits point TOWARD the LRU way; touching way w sets them AWAY from w.
  logic [2:0]          plru  [NUM_SETS];

  // Latched CPU request under service.
  logic [ADDR_W-1:0] req_addr_q;
  logic              req_we_q;
  logic [7:0]        req_be_q;
  logic [DATA_W-1:0] req_wdata_q;
  logic              req_lock_q;
  logic [ADDR_W-1:0] miss_q;     // line being filled
  logic [TAG_BITS-1:0] wb_tag_q; // victim tag being written back
  logic [DATA_W-1:0] resp_q;
  logic [WAY_BITS-1:0] way_q;    // hit way, or victim way under fill
  logic [WORD_IDX_BITS-1:0] cnt_q; // beat counter for fill/writeback
  logic fill_ok_q;               // fill still valid (no flush mid-fill)
  logic cur_epoch;

  // Lookup fields for the latched request.
  logic [INDEX_BITS-1:0]    lk_set;
  logic [TAG_BITS-1:0]      lk_tag;
  logic [WORD_IDX_BITS-1:0] lk_word;
  assign lk_set  = req_addr_q[INDEX_LSB +: INDEX_BITS];
  assign lk_tag  = req_addr_q[TAG_LSB +: TAG_BITS];
  assign lk_word = req_addr_q[WORD_LSB +: WORD_IDX_BITS];

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

  // Byte-merge for write hits (blocking; avoids a delayed-assignment loop).
  logic [DATA_W-1:0] merged_word;
  always_comb begin
    merged_word = data[lk_set][hit_way][lk_word];
    for (int b = 0; b < 8; b++)
      if (req_be_q[b]) merged_word[8*b +: 8] = req_wdata_q[8*b +: 8];
  end

  // Drain sweep position (set/way under visit).
  logic [INDEX_BITS-1:0] drain_set_q;
  logic [WAY_BITS-1:0]   drain_way_q;
  logic                  drain_pend_q, drain_i_d;

  // Moore outputs. Uncached (MMIO) passes the latched request straight
  // through as a single beat; fills/writebacks walk miss_q's line; drain
  // writebacks walk the swept line (tag rebuilt like a victim writeback).
  assign ready_o = (st == S_IDLE) & ~drain_pend_q;
  assign ack_o   = (st == S_RESP);
  assign rdata_o = resp_q;
  assign drain_busy_o = drain_pend_q | (st == S_DRAIN) | (st == S_DRAINWB);
  assign req_o   = (st == S_WRITEBACK) | (st == S_FILL) | (st == S_UNCACHED) |
                   (st == S_DRAINWB);
  assign we_o    = (st == S_WRITEBACK) | (st == S_DRAINWB) |
                   ((st == S_UNCACHED) & req_we_q);
  assign be_o    = (st == S_UNCACHED) ? req_be_q : 8'hFF;
  assign addr_o  = (st == S_UNCACHED) ? req_addr_q :
                   (st == S_DRAINWB) ? {wb_tag_q, drain_set_q, cnt_q, 3'b000} :
                   (st == S_WRITEBACK) ? {wb_tag_q, miss_set, cnt_q, 3'b000} :
                                         {miss_q[ADDR_W-1:INDEX_LSB], cnt_q, 3'b000};
  assign wdata_o = (st == S_UNCACHED) ? req_wdata_q :
                   (st == S_DRAINWB) ? data[drain_set_q][drain_way_q][cnt_q] :
                                       data[miss_set][way_q][cnt_q];
  assign lock_o  = req_lock_q & ((st == S_FILL) | (st == S_WRITEBACK) | (st == S_UNCACHED));

  // PLRU touch helper (inline): point away from the given way.
  // Reset sweep index (one set cleared per cycle; avoids an array-clear
  // loop unsupported by the simulator).
  logic [INDEX_BITS-1:0] rst_idx;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      st          <= S_RESET;
      req_addr_q  <= '0;
      req_we_q    <= 1'b0;
      req_be_q    <= '0;
      req_wdata_q <= '0;
      req_lock_q  <= 1'b0;
      miss_q      <= '0;
      resp_q      <= '0;
      way_q       <= '0;
      cnt_q       <= '0;
      fill_ok_q   <= 1'b0;
      cur_epoch   <= 1'b0;
      rst_idx     <= '0;
      drain_set_q <= '0;
      drain_way_q <= '0;
      drain_pend_q <= 1'b0;
      drain_i_d   <= 1'b0;
    end else begin
      if (flush_i) begin
        cur_epoch <= ~cur_epoch;
        fill_ok_q <= 1'b0;
      end
      // Drain trigger is edge-detected: the retire pulse stretches across
      // the drain stall (WB holds the fencing insn), which must not retrig.
      drain_i_d <= drain_i;
      if (drain_i & ~drain_i_d) begin
        drain_pend_q <= 1'b1;
        `ifdef L1D_DEBUG
        $display("[l1d %0t] DRAIN-REQ", $time);
        `endif
      end
      case (st)
        S_RESET: begin
          valid[rst_idx] <= '0;
          dirty[rst_idx] <= '0;
          plru[rst_idx]  <= '0;
          if (rst_idx == NUM_SETS - 1) st <= S_IDLE;
          else rst_idx <= rst_idx + 1'b1;
        end
        S_IDLE: begin
          if (drain_pend_q) begin
            // Drain wins over a held request; the core is stalled anyway.
            drain_set_q <= '0;
            drain_way_q <= '0;
            cnt_q       <= '0;
            st          <= S_DRAIN;
            `ifdef L1D_DEBUG
            $display("[l1d %0t] DRAIN-START", $time);
            `endif
          // NOTE: no flush gate on accept (same reason as L1I: the core
          // commits on req&ready and a refusal would strand it with no
          // ack). The toggled epoch forces a post-flush miss + refill.
          end else if (req_i) begin
            req_addr_q  <= addr_i;
            req_we_q    <= we_i;
            req_be_q    <= be_i;
            req_wdata_q <= wdata_i;
            req_lock_q  <= lock_i;
            st          <= S_LOOKUP;
            `ifdef L1D_DEBUG
            $display("[l1d %0t] ACCEPT we=%b addr=%h be=%h", $time, we_i, addr_i, be_i);
            `endif
          end
        end
        S_DRAIN: begin
          // Visit every line: dirty ones are written back (next state),
          // all are invalidated so post-fence accesses refill.
          if (valid[drain_set_q][drain_way_q] &
              dirty[drain_set_q][drain_way_q] &
              (lep[drain_set_q][drain_way_q] == cur_epoch)) begin
            wb_tag_q <= tags[drain_set_q][drain_way_q];
            cnt_q    <= '0;
            st       <= S_DRAINWB;
          end else begin
            valid[drain_set_q][drain_way_q] <= 1'b0;
            if (drain_way_q == NUM_WAYS - 1) begin
              drain_way_q <= '0;
              if (drain_set_q == NUM_SETS - 1) begin
                drain_pend_q <= 1'b0;
                st <= S_IDLE;
                `ifdef L1D_DEBUG
                $display("[l1d %0t] DRAIN-DONE", $time);
                `endif
              end else begin
                drain_set_q <= drain_set_q + 1'b1;
              end
            end else begin
              drain_way_q <= drain_way_q + 1'b1;
            end
          end
        end
        S_DRAINWB: begin
          if (ack_i) begin
            if (cnt_q == WORDS_PER_LINE - 1) begin
              valid[drain_set_q][drain_way_q] <= 1'b0;
              dirty[drain_set_q][drain_way_q] <= 1'b0;
              st <= S_DRAIN;
              // Advance past the written line (shared with the S_DRAIN
              // stepper below to keep one traversal).
              if (drain_way_q == NUM_WAYS - 1) begin
                drain_way_q <= '0;
                if (drain_set_q == NUM_SETS - 1) begin
                  drain_pend_q <= 1'b0;
                  st <= S_IDLE;
                  `ifdef L1D_DEBUG
                  $display("[l1d %0t] DRAIN-DONE", $time);
                  `endif
                end else begin
                  drain_set_q <= drain_set_q + 1'b1;
                end
              end else begin
                drain_way_q <= drain_way_q + 1'b1;
              end
            end else begin
              cnt_q <= cnt_q + 1'b1;
            end
          end
        end
        S_LOOKUP: begin
          if (uncacheable(req_addr_q)) begin
            // MMIO (tohost/hostif, future CLINT/PLIC): never allocate,
            // never match lines; single-beat pass-through.
            st <= S_UNCACHED;
            `ifdef L1D_DEBUG
            $display("[l1d %0t] UNCACHED we=%b addr=%h", $time, req_we_q, req_addr_q);
            `endif
          end else if (hit && !req_we_q) begin
            resp_q <= data[lk_set][hit_way][lk_word];
            plru[lk_set][2] <= (hit_way < 2);
            if (hit_way < 2) plru[lk_set][1] <= (hit_way == 0);
            else             plru[lk_set][0] <= (hit_way == 2);
            st <= S_RESP;
            `ifdef L1D_DEBUG
            $display("[l1d %0t] RDHIT addr=%h way=%0d data=%h", $time, req_addr_q,
                     hit_way, data[lk_set][hit_way][lk_word]);
            `endif
          end else if (hit) begin
            data[lk_set][hit_way][lk_word] <= merged_word;
            dirty[lk_set][hit_way] <= 1'b1;
            plru[lk_set][2] <= (hit_way < 2);
            if (hit_way < 2) plru[lk_set][1] <= (hit_way == 0);
            else             plru[lk_set][0] <= (hit_way == 2);
            st <= S_RESP;
            `ifdef L1D_DEBUG
            $display("[l1d %0t] WRHIT addr=%h way=%0d", $time, req_addr_q, hit_way);
            `endif
          end else begin
            miss_q    <= req_addr_q;
            way_q     <= victim;
            wb_tag_q  <= tags[lk_set][victim];
            cnt_q     <= '0;
            fill_ok_q <= ~flush_i;
            // A dirty victim must be written back before the fill reuses
            // the way; a clean/invalid victim goes straight to fill.
            if (valid[lk_set][victim] & dirty[lk_set][victim] &
                (lep[lk_set][victim] == cur_epoch)) begin
              st <= S_WRITEBACK;
              `ifdef L1D_DEBUG
              $display("[l1d %0t] MISS-DIRTY addr=%h victim=%0d", $time, req_addr_q, victim);
              `endif
            end else begin
              st <= S_FILL;
              `ifdef L1D_DEBUG
              $display("[l1d %0t] MISS addr=%h victim=%0d", $time, req_addr_q, victim);
              `endif
            end
          end
        end
        S_RESP: begin
          st <= S_IDLE;
          `ifdef L1D_DEBUG
          $display("[l1d %0t] RESP data=%h", $time, resp_q);
          `endif
        end
        S_UNCACHED: begin
          // Single pass-through beat; the line arrays are untouched.
          // (A flush cannot strand us: no fill is pending and RESP still
          // acks the accepted request.)
          if (ack_i) begin
            if (!req_we_q) resp_q <= rdata_i;
            st <= S_RESP;
          end
        end
        S_WRITEBACK: begin
          if (ack_i) begin
            `ifdef L1D_DEBUG
            $display("[l1d %0t] WBDATA cnt=%0d addr=%h data=%h", $time,
                     cnt_q, addr_o, wdata_o);
            `endif
            if (cnt_q == WORDS_PER_LINE - 1) begin
              dirty[miss_set][way_q] <= 1'b0;
              cnt_q <= '0; // fill restarts its own beat walk
              st <= S_FILL;
            end else begin
              cnt_q <= cnt_q + 1'b1;
            end
          end
        end
        S_FILL: begin
          // The CPU request was already accepted, so the fill MUST end in
          // a lookup of the latched request (which applies a pending write
          // for write-allocate). A flush only suppresses the valid-set.
          if (ack_i) begin
            `ifdef L1D_DEBUG
            $display("[l1d %0t] FILLBEAT cnt=%0d way=%0d addr=%h data=%h", $time,
                     cnt_q, way_q, addr_o, rdata_i);
            `endif
            data[miss_set][way_q][cnt_q] <= rdata_i;
            if (cnt_q == WORDS_PER_LINE - 1) begin
              if (fill_ok_q) begin
                tags[miss_set][way_q]  <= miss_q[TAG_LSB +: TAG_BITS];
                valid[miss_set][way_q] <= 1'b1;
                dirty[miss_set][way_q] <= 1'b0;
                lep[miss_set][way_q]   <= cur_epoch;
                plru[miss_set][2] <= (way_q >= 2);
                if (way_q < 2) plru[miss_set][1] <= (way_q == 1);
                else           plru[miss_set][0] <= (way_q == 3);
              end
              st <= S_LOOKUP;
            end else begin
              cnt_q <= cnt_q + 1'b1;
            end
          end
        end
        default: st <= S_RESET;
      endcase
    end
  end

endmodule
