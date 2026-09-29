// PLIC: Platform-Level Interrupt Controller (SiFive-style map).
//
//   priority[1..N]  @ +0x4*i       (32-bit, values 0..7; 0 = never)
//   pending         @ +0x1000      (3 words for N=64, RO; bit i = src i)
//   enable M (ctx0) @ +0x2000      (3 words, RW)
//   enable S (ctx1) @ +0x2080      (3 words, RW)
//   threshold M     @ +0x200000    (RW), claim/complete M @ +0x200004
//   threshold S     @ +0x201000    (RW), claim/complete S @ +0x201004
//
// Claim (read) returns the highest-priority pending+enabled source above
// threshold (lowest ID breaks ties) and marks it claimed; 0 if none.
// Complete (write ID) clears the claim. Sources are level-sensitive.
// Single-beat AXI slave: the bus carries 8B beats (base-aligned), regs
// are 4B (selected half by addr[2]); writes are byte-masked via wstrb.
module plic #(
  parameter int NUM_SOURCES = 64,
  parameter logic [47:0] BASE = 48'h0001_0020_0000
) (
  input  logic             clk,
  input  logic             rst_n,
  axi4_if.s                bus,
  input  logic [NUM_SOURCES:1] sources_i,
  output logic             eip_o,
  output logic             seip_o
);

  // Bit i (1..N) lives in word i/32 (bit 0 reserved); N=64 needs 3 words.
  localparam int NWORDS = (NUM_SOURCES + 32) / 32;

  logic [31:0] prio [NUM_SOURCES+1];
  logic [31:0] en_m [NWORDS];
  logic [31:0] en_s [NWORDS];
  logic [2:0]  thresh_m, thresh_s;
  logic [NUM_SOURCES:1] claimed_m, claimed_s;
  // Latched claim IDs (returned on the R beat after the AR accept that
  // claimed them).
  logic [6:0] claim_id_m_q, claim_id_s_q;

  wire [NUM_SOURCES:1] pending = sources_i;

  // Standard bit mapping: source i lives in bit i (word i/32).
  // Source 0 does not exist (bit 0 reads 0).
  function automatic logic en_bit(input logic [31:0] arr [NWORDS],
                                  input int id);
    return arr[id / 32][id % 32];
  endfunction

  // Winner select per context: enabled, unclaimed, priority > threshold;
  // highest priority wins, lowest ID breaks ties (upward scan, strict >).
  function automatic logic [6:0] pick_id(
      input logic [31:0] en [NWORDS],
      input logic [NUM_SOURCES:1] claimed,
      input logic [2:0] thresh);
    logic [2:0] best_p;
    logic [6:0] best_id;
    best_p = 3'd0;
    best_id = 7'd0;
    for (int i = 1; i <= NUM_SOURCES; i++) begin
      if (pending[i] && en_bit(en, i) && !claimed[i] &&
          (prio[i][2:0] > thresh) &&
          ((prio[i][2:0] > best_p) || (best_id == 7'd0))) begin
        best_p  = prio[i][2:0];
        best_id = 7'(unsigned'(i));
      end
    end
    return best_id;
  endfunction

  wire [6:0] claim_m = pick_id(en_m, claimed_m, thresh_m);
  wire [6:0] claim_s = pick_id(en_s, claimed_s, thresh_s);
  assign eip_o  = (claim_m != 7'd0);
  assign seip_o = (claim_s != 7'd0);

  typedef enum logic [1:0] {W_IDLE, W_DATA, W_RESP} wst_e;
  typedef enum logic [1:0] {R_IDLE, R_DATA} rst_e;
  wst_e wst;
  rst_e rst;

  logic [47:0] w_off, r_off;
  logic [3:0]  w_id, r_id;

  function automatic logic [31:0] lane_mask(input logic [3:0] be);
    logic [31:0] m;
    m = '0;
    for (int i = 0; i < 4; i++)
      if (be[i]) m[i*8 +: 8] = 8'hFF;
    return m;
  endfunction

  function automatic logic is_prio(input logic [47:0] off);
    return (off >= 48'h4) &&
           (off <= 48'h4 * 48'(unsigned'(NUM_SOURCES)));
  endfunction
  function automatic int prio_id(input logic [47:0] off);
    return int'(off / 4);
  endfunction
  function automatic logic [31:0] pend_word(input int w);
    logic [31:0] v;
    v = '0;
    for (int i = 0; i < 32; i++) begin
      int id;
      id = w * 32 + i;
      if ((id >= 1) && (id <= NUM_SOURCES) && pending[id])
        v[i] = 1'b1;
    end
    return v;
  endfunction

  function automatic logic is_enm(input logic [47:0] off);
    return (off == 48'h2000) || (off == 48'h2004) || (off == 48'h2008);
  endfunction
  function automatic logic is_ens(input logic [47:0] off);
    return (off == 48'h2080) || (off == 48'h2084) || (off == 48'h2088);
  endfunction
  function automatic int enm_idx(input logic [47:0] off);
    return int'((off - 48'h2000) / 4);
  endfunction
  function automatic int ens_idx(input logic [47:0] off);
    return int'((off - 48'h2080) / 4);
  endfunction
  function automatic logic is_pend(input logic [47:0] off);
    return (off == 48'h1000) || (off == 48'h1004) || (off == 48'h1008);
  endfunction
  function automatic int pend_idx(input logic [47:0] off);
    return int'((off - 48'h1000) / 4);
  endfunction

  // 32-bit reg selected by a 4B offset; out-of-map reads 0, writes drop.
  function automatic logic [31:0] read_reg(input logic [47:0] off);
    if (is_prio(off))            return prio[prio_id(off)];
    if (is_pend(off))            return pend_word(pend_idx(off));
    if (is_enm(off))             return en_m[enm_idx(off)];
    if (is_ens(off))             return en_s[ens_idx(off)];
    if (off == 48'h200000)        return {29'd0, thresh_m};
    if (off == 48'h201000)        return {29'd0, thresh_s};
    return 32'd0;
  endfunction

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      wst <= W_IDLE; rst <= R_IDLE;
      bus.awready <= 1'b0; bus.wready <= 1'b0;
      bus.bvalid  <= 1'b0; bus.bresp  <= 2'b00; bus.bid <= '0;
      bus.arready <= 1'b0;
      bus.rvalid  <= 1'b0; bus.rresp  <= 2'b00; bus.rid <= '0;
      bus.rdata   <= '0;   bus.rlast  <= 1'b0;
      for (int i = 0; i <= NUM_SOURCES; i++) prio[i] = 32'd0;
      for (int w = 0; w < NWORDS; w++) begin
        en_m[w] = 32'd0;
        en_s[w] = 32'd0;
      end
      thresh_m <= 3'd0; thresh_s <= 3'd0;
      claimed_m <= '0; claimed_s <= '0;
      claim_id_m_q <= 7'd0; claim_id_s_q <= 7'd0;
      w_off <= '0; r_off <= '0; w_id <= '0; r_id <= '0;
    end else begin
      case (wst)
        W_IDLE: begin
          bus.bvalid <= 1'b0;
          bus.awready <= 1'b1;
          if (bus.awvalid && bus.awready) begin
            w_off <= bus.awaddr - BASE;
            w_id  <= bus.awid;
            bus.awready <= 1'b0;
            wst <= W_DATA;
          end
        end
        W_DATA: begin
          bus.wready <= 1'b1;
          if (bus.wvalid && bus.wready) begin
            logic hi;
            logic [31:0] wd;
            logic [3:0]  be;
            bus.wready <= 1'b0;
            wst <= W_RESP;
            hi = w_off[2];
            wd = hi ? bus.wdata[63:32] : bus.wdata[31:0];
            be = hi ? bus.wstrb[7:4] : bus.wstrb[3:0];
            if (is_prio(w_off)) begin
              // Priorities are 3-bit (mask the rest on write).
              prio[prio_id(w_off)] <=
                (((prio[prio_id(w_off)] & ~lane_mask(be)) |
                  (wd & lane_mask(be))) & 32'h0000_0007);
            end else if (is_enm(w_off)) begin
              en_m[enm_idx(w_off)] <= (en_m[enm_idx(w_off)] & ~lane_mask(be)) |
                                     (wd & lane_mask(be));
            end else if (is_ens(w_off)) begin
              en_s[ens_idx(w_off)] <= (en_s[ens_idx(w_off)] & ~lane_mask(be)) |
                                     (wd & lane_mask(be));
            end else if (w_off == 48'h200000) begin
              if (|be) thresh_m <= wd[2:0];
            end else if (w_off == 48'h201000) begin
              if (|be) thresh_s <= wd[2:0];
            end else if (w_off == 48'h200004) begin
              // Complete M: clear claim by ID.
              if (wd[6:0] != 7'd0 && wd[6:0] <= 7'(unsigned'(NUM_SOURCES)))
                claimed_m[wd[6:0]] <= 1'b0;
            end else if (w_off == 48'h201004) begin
              if (wd[6:0] != 7'd0 && wd[6:0] <= 7'(unsigned'(NUM_SOURCES)))
                claimed_s[wd[6:0]] <= 1'b0;
            end
          end
        end
        W_RESP: begin
          bus.bvalid <= 1'b1;
          bus.bresp  <= 2'b00;
          bus.bid    <= w_id;
          if (bus.bvalid && bus.bready) begin
            bus.bvalid <= 1'b0;
            wst <= W_IDLE;
          end
        end
        default: wst <= W_IDLE;
      endcase
      case (rst)
        R_IDLE: begin
          bus.rvalid <= 1'b0;
          bus.arready <= 1'b1;
          if (bus.arvalid && bus.arready) begin
            r_off <= bus.araddr - BASE;
            r_id  <= bus.arid;
            bus.arready <= 1'b0;
            rst <= R_DATA;
            // Claim side effect: latch the winner now; the R beat below
            // reports it. Single-beat reads only.
            if ((bus.araddr - BASE) == 48'h200004) begin
              claim_id_m_q <= claim_m;
              if (claim_m != 7'd0) claimed_m[claim_m] <= 1'b1;
            end else if ((bus.araddr - BASE) == 48'h201004) begin
              claim_id_s_q <= claim_s;
              if (claim_s != 7'd0) claimed_s[claim_s] <= 1'b1;
            end
          end
        end
        R_DATA: begin
          bus.rvalid <= 1'b1;
          bus.rresp  <= 2'b00;
          bus.rid    <= r_id;
          bus.rlast  <= 1'b1;
          // Full 8B beat at the 8B-aligned base (thresh low, claim high).
          if ((r_off & ~48'h7) == 48'h200000)
            bus.rdata <= {{25'd0, claim_id_m_q}, {29'd0, thresh_m}};
          else if ((r_off & ~48'h7) == 48'h201000)
            bus.rdata <= {{25'd0, claim_id_s_q}, {29'd0, thresh_s}};
          else
            bus.rdata <= {read_reg((r_off & ~48'h7) + 48'h4),
                          read_reg(r_off & ~48'h7)};
          if (bus.rvalid && bus.rready) begin
            bus.rvalid <= 1'b0;
            bus.rlast  <= 1'b0;
            rst <= R_IDLE;
          end
        end
        default: rst <= R_IDLE;
      endcase
    end
  end

endmodule
