// L2 unified cache: 256 KiB, 8-way set-associative, blocking, write-back
// with write-allocate. Shared victim of the L1I (fill) and L1D (fill +
// writeback) ports.
//
// 1024 sets x 8 ways x 32-byte lines, tree-PLRU replacement. Single
// memory-side port toward the AXI master. The two request ports arbitrate
// internally with data-side (B) priority, matching the old shared-bus
// scheme; the L2 is blocking so at most one transaction is in flight and
// no AXI-side owner tracking is needed downstream.
//
// Protocol on all ports is the same req/ready/ack 64-bit single-beat
// discipline used by both L1s: acks never come combinationally in the
// accept cycle. Port A is read-only (L1I fills; we_i/be_i ignored).
// Addresses at/above MMIO_BASE bypass as uncacheable single beats on
// either port (defense in depth; L1D already filters MMIO).
//
// NOTE: tag/data/valid/dirty/plru live in flops here for bring-up. For
// synthesis they should be mapped to SRAM macros.
module l2 #(
  parameter int ADDR_W     = 48,
  parameter int DATA_W     = 64,
  parameter int LINE_BYTES = 32,
  parameter int SIZE_BYTES = 256 * 1024,
  parameter int NUM_WAYS   = 8
) (
  input  logic              clk,
  input  logic              rst_n,

  // Port A (L1I fill side): read-only.
  input  logic              req_a_i,
  input  logic [ADDR_W-1:0] addr_a_i,
  output logic [DATA_W-1:0] rdata_a_o,
  output logic              ack_a_o,
  output logic              ready_a_o,

  // Port B (L1D memory side): read + write.
  input  logic              req_b_i,
  input  logic              we_b_i,
  input  logic [ADDR_W-1:0] addr_b_i,
  input  logic [7:0]        be_b_i,
  input  logic [DATA_W-1:0] wdata_b_i,
  input  logic              lock_b_i,
  output logic [DATA_W-1:0] rdata_b_o,
  output logic              ack_b_o,
  output logic              ready_b_o,

  // Port C (page-table walker): read + write (A/D updates). Highest
  // priority: the pipeline is stalled on a TLB miss while it is active.
  input  logic              req_c_i,
  input  logic              we_c_i,
  input  logic [ADDR_W-1:0] addr_c_i,
  input  logic [7:0]        be_c_i,
  input  logic [DATA_W-1:0] wdata_c_i,
  input  logic              lock_c_i,
  output logic [DATA_W-1:0] rdata_c_o,
  output logic              ack_c_o,
  output logic              ready_c_o,

  // Memory side (toward the AXI master): single beat.
  output logic              req_o,
  output logic              we_o,
  output logic [ADDR_W-1:0] addr_o,
  output logic [7:0]        be_o,
  output logic [DATA_W-1:0] wdata_o,
  output logic              lock_o,
  input  logic [DATA_W-1:0] rdata_i,
  input  logic              ack_i,
  input  logic              ready_i
);

  import rv64gch_memmap_pkg::*;

  function automatic logic uncacheable(input logic [ADDR_W-1:0] a);
    return a >= MMIO_BASE;
  endfunction

  localparam int OFFSET_BITS     = $clog2(LINE_BYTES);                 // 5
  localparam int WORDS_PER_LINE  = LINE_BYTES / 8;                     // 4
  localparam int WORD_IDX_BITS   = $clog2(WORDS_PER_LINE);             // 2
  localparam int NUM_SETS        = SIZE_BYTES / LINE_BYTES / NUM_WAYS; // 1024
  localparam int INDEX_BITS      = $clog2(NUM_SETS);                   // 10
  localparam int WAY_BITS        = $clog2(NUM_WAYS);                   // 3
  localparam int TAG_BITS        = ADDR_W - INDEX_BITS - OFFSET_BITS;  // 33
  // Bit layout of a line address: [TAG | INDEX | WORD_IDX | 3'b000]
  localparam int WORD_LSB        = 3;
  localparam int INDEX_LSB       = WORD_LSB + WORD_IDX_BITS;           // 5
  localparam int TAG_LSB         = INDEX_LSB + INDEX_BITS;             // 15

  typedef enum logic [2:0] {
    S_RESET, S_IDLE, S_LOOKUP, S_RESP, S_WRITEBACK, S_FILL, S_UNCACHED
  } state_e;
  state_e st;

  // Line storage (flops for bring-up; map to SRAM for synthesis).
  logic [TAG_BITS-1:0] tags  [NUM_SETS][NUM_WAYS];
  logic [NUM_WAYS-1:0] valid [NUM_SETS];
  logic [NUM_WAYS-1:0] dirty [NUM_SETS];
  logic [DATA_W-1:0]   data  [NUM_SETS][NUM_WAYS][WORDS_PER_LINE];
  // Tree-PLRU per set (7 bits for 8 ways): [6]=root,
  // [5:4]=next level, [3:0]=leaves. Bits point TOWARD the LRU way;
  // touching way w sets them AWAY from w (bit <= ~w[bitpos]).
  logic [6:0]          plru  [NUM_SETS];

  // Latched request under service (port selected in IDLE; C > B > A).
  logic [1:0]          sel_q; // 0 = port A, 1 = port B, 2 = port C
  logic [ADDR_W-1:0] req_addr_q;
  logic              req_we_q;
  logic [7:0]        req_be_q;
  logic [DATA_W-1:0] req_wdata_q;
  logic              req_lock_q;
  logic [ADDR_W-1:0] miss_q;
  logic [TAG_BITS-1:0] wb_tag_q;
  logic [DATA_W-1:0] resp_q;
  logic [WAY_BITS-1:0] way_q;
  logic [WORD_IDX_BITS-1:0] cnt_q;

  // Lookup fields for the latched request.
  logic [INDEX_BITS-1:0]    lk_set;
  logic [TAG_BITS-1:0]      lk_tag;
  logic [WORD_IDX_BITS-1:0] lk_word;
  assign lk_set  = req_addr_q[INDEX_LSB +: INDEX_BITS];
  assign lk_tag  = req_addr_q[TAG_LSB +: TAG_BITS];
  assign lk_word = req_addr_q[WORD_LSB +: WORD_IDX_BITS];

  // 8-way tag compare (blocking combinational; simulator-friendly).
  logic [NUM_WAYS-1:0] way_match;
  always_comb begin
    way_match = '0;
    for (int w = 0; w < NUM_WAYS; w++)
      way_match[w] = valid[lk_set][w] & (tags[lk_set][w] == lk_tag);
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

  // Tree-PLRU victim for the latched request's set: walk root->leaf.
  logic [WAY_BITS-1:0] victim;
  always_comb begin
    if (!plru[lk_set][6]) begin
      if (!plru[lk_set][5]) victim = plru[lk_set][3] ? 3'd1 : 3'd0;
      else                  victim = plru[lk_set][2] ? 3'd3 : 3'd2;
    end else begin
      if (!plru[lk_set][4]) victim = plru[lk_set][1] ? 3'd5 : 3'd4;
      else                  victim = plru[lk_set][0] ? 3'd7 : 3'd6;
    end
  end

  logic [INDEX_BITS-1:0] miss_set;
  assign miss_set = miss_q[INDEX_LSB +: INDEX_BITS];

  // Byte-merge for port-B write hits (blocking; no delayed-assignment loop).
  logic [DATA_W-1:0] merged_word;
  always_comb begin
    merged_word = data[lk_set][hit_way][lk_word];
    for (int b = 0; b < 8; b++)
      if (req_be_q[b]) merged_word[8*b +: 8] = req_wdata_q[8*b +: 8];
  end

  // Port readiness: only IDLE accepts, C > B > A priority.
  assign ready_a_o = (st == S_IDLE) & ~req_b_i & ~req_c_i;
  assign ready_b_o = (st == S_IDLE) & ~req_c_i;
  assign ready_c_o = (st == S_IDLE);
  assign ack_a_o   = (st == S_RESP) & (sel_q == 2'd0);
  assign ack_b_o   = (st == S_RESP) & (sel_q == 2'd1);
  assign ack_c_o   = (st == S_RESP) & (sel_q == 2'd2);
  assign rdata_a_o = resp_q;
  assign rdata_b_o = resp_q;
  assign rdata_c_o = resp_q;

  // Memory side. Uncached passes the latched beat through; fills and
  // writebacks walk the 4 beats of their line in order.
  assign req_o   = (st == S_WRITEBACK) | (st == S_FILL) | (st == S_UNCACHED);
  assign we_o    = (st == S_WRITEBACK) | ((st == S_UNCACHED) & req_we_q);
  assign be_o    = (st == S_UNCACHED) ? req_be_q : 8'hFF;
  assign addr_o  = (st == S_UNCACHED) ? req_addr_q :
                   (st == S_WRITEBACK) ? {wb_tag_q, miss_set, cnt_q, 3'b000} :
                                         {miss_q[ADDR_W-1:INDEX_LSB], cnt_q, 3'b000};
  assign wdata_o = (st == S_UNCACHED) ? req_wdata_q : data[miss_set][way_q][cnt_q];
  assign lock_o  = req_lock_q & ((st == S_FILL) | (st == S_WRITEBACK) | (st == S_UNCACHED));

  // Reset sweep index (one set cleared per cycle).
  logic [INDEX_BITS-1:0] rst_idx;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      st          <= S_RESET;
      sel_q       <= 2'd0;
      req_addr_q  <= '0;
      req_we_q    <= 1'b0;
      req_be_q    <= '0;
      req_wdata_q <= '0;
      req_lock_q  <= 1'b0;
      miss_q      <= '0;
      wb_tag_q    <= '0;
      resp_q      <= '0;
      way_q       <= '0;
      cnt_q       <= '0;
      rst_idx     <= '0;
    end else begin
      case (st)
        S_RESET: begin
          valid[rst_idx] <= '0;
          dirty[rst_idx] <= '0;
          plru[rst_idx]  <= '0;
          if (rst_idx == NUM_SETS - 1) st <= S_IDLE;
          else rst_idx <= rst_idx + 1'b1;
        end
        S_IDLE: begin
          if (req_c_i) begin
            sel_q       <= 2'd2;
            req_addr_q  <= addr_c_i;
            req_we_q    <= we_c_i;
            req_be_q    <= be_c_i;
            req_wdata_q <= wdata_c_i;
            req_lock_q  <= lock_c_i;
            st          <= S_LOOKUP;
            `ifdef L2_DEBUG
            $display("[l2 %0t] ACCEPT-C we=%b addr=%h", $time, we_c_i, addr_c_i);
            `endif
          end else if (req_b_i) begin
            sel_q       <= 2'd1;
            req_addr_q  <= addr_b_i;
            req_we_q    <= we_b_i;
            req_be_q    <= be_b_i;
            req_wdata_q <= wdata_b_i;
            req_lock_q  <= lock_b_i;
            st          <= S_LOOKUP;
            `ifdef L2_DEBUG
            $display("[l2 %0t] ACCEPT-B we=%b addr=%h", $time, we_b_i, addr_b_i);
            `endif
          end else if (req_a_i) begin
            sel_q       <= 2'd0;
            req_addr_q  <= addr_a_i;
            req_we_q    <= 1'b0;
            req_be_q    <= 8'hFF;
            req_wdata_q <= '0;
            req_lock_q  <= 1'b0;
            st          <= S_LOOKUP;
            `ifdef L2_DEBUG
            $display("[l2 %0t] ACCEPT-A addr=%h", $time, addr_a_i);
            `endif
          end
        end
        S_LOOKUP: begin
          if (uncacheable(req_addr_q)) begin
            st <= S_UNCACHED;
            `ifdef L2_DEBUG
            $display("[l2 %0t] UNCACHED we=%b addr=%h", $time, req_we_q, req_addr_q);
            `endif
          end else if (hit && !req_we_q) begin
            resp_q <= data[lk_set][hit_way][lk_word];
            // PLRU touch: only the nodes on hit_way's path point away.
            plru[lk_set][6] <= ~hit_way[2];
            if (!hit_way[2]) begin
              plru[lk_set][5] <= ~hit_way[1];
              if (!hit_way[1]) plru[lk_set][3] <= ~hit_way[0];
              else             plru[lk_set][2] <= ~hit_way[0];
            end else begin
              plru[lk_set][4] <= ~hit_way[1];
              if (!hit_way[1]) plru[lk_set][1] <= ~hit_way[0];
              else             plru[lk_set][0] <= ~hit_way[0];
            end
            st <= S_RESP;
            `ifdef L2_DEBUG
            $display("[l2 %0t] RDHIT addr=%h way=%0d", $time, req_addr_q, hit_way);
            `endif
          end else if (hit) begin
            data[lk_set][hit_way][lk_word] <= merged_word;
            dirty[lk_set][hit_way] <= 1'b1;
            plru[lk_set][6] <= ~hit_way[2];
            if (!hit_way[2]) begin
              plru[lk_set][5] <= ~hit_way[1];
              if (!hit_way[1]) plru[lk_set][3] <= ~hit_way[0];
              else             plru[lk_set][2] <= ~hit_way[0];
            end else begin
              plru[lk_set][4] <= ~hit_way[1];
              if (!hit_way[1]) plru[lk_set][1] <= ~hit_way[0];
              else             plru[lk_set][0] <= ~hit_way[0];
            end
            st <= S_RESP;
            `ifdef L2_DEBUG
            $display("[l2 %0t] WRHIT addr=%h way=%0d", $time, req_addr_q, hit_way);
            `endif
          end else begin
            miss_q   <= req_addr_q;
            way_q    <= victim;
            wb_tag_q <= tags[lk_set][victim];
            cnt_q    <= '0;
            if (valid[lk_set][victim] & dirty[lk_set][victim]) begin
              st <= S_WRITEBACK;
              `ifdef L2_DEBUG
              $display("[l2 %0t] MISS-DIRTY addr=%h victim=%0d", $time, req_addr_q, victim);
              `endif
            end else begin
              st <= S_FILL;
              `ifdef L2_DEBUG
              $display("[l2 %0t] MISS addr=%h victim=%0d", $time, req_addr_q, victim);
              `endif
            end
          end
        end
        S_RESP: begin
          st <= S_IDLE;
        end
        S_WRITEBACK: begin
          if (ack_i) begin
            `ifdef L2_DEBUG
            $display("[l2 %0t] WBDATA cnt=%0d addr=%h", $time, cnt_q, addr_o);
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
          // The request was already accepted, so the fill MUST end in a
          // lookup of the latched request (applying a pending port-B write
          // for write-allocate).
          if (ack_i) begin
            `ifdef L2_DEBUG
            $display("[l2 %0t] FILLBEAT cnt=%0d way=%0d addr=%h data=%h", $time,
                     cnt_q, way_q, addr_o, rdata_i);
            `endif
            data[miss_set][way_q][cnt_q] <= rdata_i;
            if (cnt_q == WORDS_PER_LINE - 1) begin
              tags[miss_set][way_q]  <= miss_q[TAG_LSB +: TAG_BITS];
              valid[miss_set][way_q] <= 1'b1;
              dirty[miss_set][way_q] <= 1'b0;
              plru[miss_set][6] <= ~way_q[2];
              if (!way_q[2]) begin
                plru[miss_set][5] <= ~way_q[1];
                if (!way_q[1]) plru[miss_set][3] <= ~way_q[0];
                else           plru[miss_set][2] <= ~way_q[0];
              end else begin
                plru[miss_set][4] <= ~way_q[1];
                if (!way_q[1]) plru[miss_set][1] <= ~way_q[0];
                else           plru[miss_set][0] <= ~way_q[0];
              end
              st <= S_LOOKUP;
            end else begin
              cnt_q <= cnt_q + 1'b1;
            end
          end
        end
        S_UNCACHED: begin
          if (ack_i) begin
            if (!req_we_q) resp_q <= rdata_i;
            st <= S_RESP;
          end
        end
        default: st <= S_RESET;
      endcase
    end
  end

endmodule
