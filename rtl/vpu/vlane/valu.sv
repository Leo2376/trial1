// VALU: element-serial integer vector ALU (RVV integer OPIVV/OPMVV/OPIVX/
// OPMVX/OPIVI subset).
//
// Occupies MEM exactly like the VLSU (the whole backend holds while
// sequencing) but touches no memory. Operands come from the VRF read ports
// (vs1 on the data port, vs2 on the index port, v0 mask on the mask port,
// vd old value on the dest port, vs2 gather byte on the gather port -- the
// data/index/mask ports are shared with the VLSU and muxed in the core
// since only one unit is ever active; dest/gather are VALU-only), plus a
// scalar input (x[rs1] for .vx, 5-bit uimm for .vi) carried in the MEM
// packet. Result sunk to vd. Masked-off elements skip (no write, dest
// undisturbed); elements below vstart are never touched. vl/vstart are
// element counts sampled at sequence start (both stable: vset drains
// before vector issue, traps flush); a trap aborts. Cannot fault, so
// there is no fault path and no vstart update. Vector ops stay strictly
// serialized by the hold, hence no VRF forwarding is needed: every op
// sees fully-retired vector state.
//
// Two datapaths, selected per op (packet is frozen while sequencing, so
// the select is stable):
//   fast: SEW=8 classic ALU (add/sub/min/max/and/or/xor/copy/merge,
//     compares, saturating, shifts), VV or VX (scalar low byte). One
//     element per cycle, exactly as the original v0 VALU.
//   wide: everything else -- SEW=16/32/64 classic ALU, integer
//     mul/div/rem (.vv/.vx), slides and gather (any SEW, .vv/.vx/.vi).
//     Per element: an R phase (ew cycles) assembles the vs2/vs1/index
//     element bytes, then a W phase (ew cycles) computes and writes one
//     byte per cycle.
//
// vmerge.vvm (vm=0, internal op MERGE) selects per element on the v0 mask
// bit instead of masking: vd[e] = mask ? vs2[e] : vs1[e] (decode forces
// masked_i=0 for it, so no element skips). Mask-producing compares
// (SEQ/SNE/SLTU/SLT/SLEU/SLE) write bit e of vd (RVV LMUL=1 mask layout)
// via a read-modify-write of the vd byte; masked-off compare elements
// leave vd undisturbed like any other op.
//
// Slides (element index e, offset from scalar, vlmax = 32>>SEW):
//   slideup:   e<off -> undisturbed (skip); else vd[e] = vs2[e-off].
//   slide1up:  vd[0] = scalar (when vstart==0); else vd[e] = vs2[e-1].
//   slidedown: vd[e] = (e+off<vl) ? vs2[e+off] : 0.
//   slide1down: vd[e] = (e+1<vl) ? vs2[e+1] : scalar.
//   gather:    vd[e] = (idx<vlmax) ? vs2[idx] : 0, idx from vs1 (.vv) or
//     scalar (.vx/.vi), SEW-wide. vrgatherei16 is not implemented.
//
// Sequencer (re)start: back-to-back vector ops hand MEM over with no idle
// gap, so the active level alone cannot delimit sequences (the second op
// would inherit the first op's done state and retire empty). The core
// therefore pulses start_i for the cycle a new vector op occupies MEM;
// the unit (re)samples vl/vstart then and holds the pipe for that cycle.
module valu (
  input  logic         clk,
  input  logic         rst_n,
  // Occupancy: vector ALU op held in MEM (level). trap_i aborts.
  input  logic         active_i,
  input  logic         trap_i,
  // Pulse: a new vector op has just entered MEM (re)sample this cycle.
  input  logic         start_i,
  input  logic [5:0]   aluop_i,    // funct6 (or internal MERGE code)
  input  logic [2:0]   funct3_i,   // OP-V funct3: 000/010/100/110/011
  input  logic [1:0]   sew_i,      // SEW code: 0/1/2/3 = 8/16/32/64
  input  logic [63:0]  scalar_i,   // .vx x[rs1] / .vi 5-bit uimm
  input  logic [4:0]   vd_i,
  input  logic [4:0]   vs1_i,      // second operand (rs1 field; COPY source)
  input  logic [4:0]   vs2_i,      // first operand (rs2 field)
  input  logic         masked_i,   // vm=0: skip v0.mask==0 elements
  input  logic [7:0]   vl_i,
  input  logic [7:0]   vstart_i,
  // VRF ports (byte granular; data/index/mask shared with the VLSU).
  output logic [4:0]   vrf_raddr_o,  // vs1
  output logic [4:0]   vrf_ridx_o,
  input  logic [7:0]   vrf_rdata_i,
  output logic [4:0]   vrf_iaddr_o,  // vs2
  output logic [4:0]   vrf_iidx_o,
  input  logic [7:0]   vrf_idata_i,
  output logic [4:0]   vrf_maddr_o,  // v0 mask
  output logic [4:0]   vrf_midx_o,
  input  logic [7:0]   vrf_mdata_i,
  output logic [4:0]   vrf_daddr_o,  // vd old value (compare RMW)
  output logic [4:0]   vrf_didx_o,
  input  logic [7:0]   vrf_ddata_i,
  output logic [4:0]   vrf_gaddr_o,  // gather data (vs2 byte at address)
  output logic [4:0]   vrf_gidx_o,
  input  logic [7:0]   vrf_gdata_i,
  output logic [4:0]   vrf_waddr_o,  // vd
  output logic [4:0]   vrf_widx_o,
  output logic [7:0]   vrf_wdata_o,
  output logic         vrf_we_o,
  output logic         busy_o,
  output logic         done_o
);
  import rtl_core_pkg::*;

  // Fresh-op pulse, gated on occupancy (start_i only ever pulses under
  // active, but the gate keeps the unit self-consistent standalone).
  logic w_start;
  assign w_start = start_i & active_i;

  logic [7:0] vl_q;        // sampled vl (elements)
  logic       started_q;   // sequence latched start values

  // Op classification (packet frozen while sequencing: stable).
  // Scalar source (.vx/.vi) is OPIVX/OPMVX/OPIVI; OPMVV (010) is .vv
  // (both operands vector) despite funct3 != 0.
  logic use_scalar;
  assign use_scalar = (funct3_i == 3'b100) || (funct3_i == 3'b110) ||
                      (funct3_i == 3'b011);
  logic is_gather, is_slide, is_slide1, is_slideup;
  assign is_gather  = (aluop_i == VALU_GATHER);
  assign is_slide   = (aluop_i == VALU_SLIDEUP) || (aluop_i == VALU_SLIDEDN);
  assign is_slide1  = is_slide && (funct3_i == 3'b110);
  assign is_slideup = (aluop_i == VALU_SLIDEUP);
  logic is_muldiv;
  assign is_muldiv = ((funct3_i == 3'b010) || (funct3_i == 3'b110)) &&
                     ((aluop_i == VALU_DIVU) || (aluop_i == VALU_DIV) ||
                      (aluop_i == VALU_REMU) || (aluop_i == VALU_REM) ||
                      (aluop_i == VALU_MULHU) || (aluop_i == VALU_MUL) ||
                      (aluop_i == VALU_MULHSU) || (aluop_i == VALU_MULH));
  // Wide sub-FSM handles mul/div, slides, gather (any SEW) and every op
  // at SEW>8. The e8 classic set keeps the 1-cycle/element fast path.
  logic use_wide;
  assign use_wide = is_muldiv | is_gather | is_slide | (sew_i != 2'd0);

  logic [7:0] ew;          // element width in bytes
  assign ew = 8'd1 << sew_i;
  logic [7:0] vlmax;       // elements per vector register (LMUL=1)
  assign vlmax = 8'd32 >> sew_i;

  // Mask bit e = bit e of v0 (RVV LMUL=1 layout). The mask port is driven
  // by the sequencing element of the active path.
  logic [7:0] seq_e;
  assign seq_e = use_wide ? w_e_q : i_q;
  assign vrf_maddr_o = 5'd0;
  assign vrf_midx_o  = seq_e[4:3];
  logic mask_bit, masked_off;
  assign mask_bit   = (vrf_mdata_i >> seq_e[2:0]) & 1'b1;
  assign masked_off = masked_i & ~mask_bit;

  // Compare destination: bit e of vd (byte e>>3) via RMW.
  logic is_cmp;
  assign is_cmp = (aluop_i == VALU_SEQ) || (aluop_i == VALU_SNE) ||
                  (aluop_i == VALU_SLTU) || (aluop_i == VALU_SLT) ||
                  (aluop_i == VALU_SLEU) || (aluop_i == VALU_SLE);
  assign vrf_daddr_o = vd_i;
  assign vrf_didx_o  = {3'd0, seq_e[7:3]};

  // ================= fast path (e8 classic ALU, VV/VX) =================
  logic [7:0] i_q;         // current element index
  // vd[e] = vs2[e] op vs1[e] (8-bit wrap); COPY moves vs1 (vmv.v.v/.x,
  // scalar low byte for .vx); MERGE selects on the mask bit.
  logic [7:0] f_opa, f_opb, f_res;
  logic       f_cmp;
  assign f_opa = vrf_idata_i;
  assign f_opb = use_scalar ? scalar_i[7:0] : vrf_rdata_i;
  logic [8:0] f_add9;
  logic [7:0] f_sub8;
  logic       f_sadd_ov, f_ssub_ov;
  assign f_add9    = {1'b0, f_opa} + {1'b0, f_opb};
  assign f_sub8    = f_opa - f_opb;
  assign f_sadd_ov = (f_opa[7] == f_opb[7]) && (f_add9[7] != f_opa[7]);
  assign f_ssub_ov = (f_opa[7] != f_opb[7]) && (f_sub8[7] != f_opa[7]);
  logic [2:0] f_shamt;
  assign f_shamt = f_opb[2:0];
  always_comb begin
    f_res = 8'd0;
    f_cmp = 1'b0;
    case (aluop_i)
      VALU_ADD:  f_res = f_opa + f_opb;
      VALU_SUB:  f_res = f_opa - f_opb;
      VALU_MINU: f_res = (f_opa < f_opb) ? f_opa : f_opb;
      VALU_MIN:  f_res = ($signed(f_opa) < $signed(f_opb)) ? f_opa : f_opb;
      VALU_MAXU: f_res = (f_opa < f_opb) ? f_opb : f_opa;
      VALU_MAX:  f_res = ($signed(f_opa) < $signed(f_opb)) ? f_opb : f_opa;
      VALU_AND:  f_res = f_opa & f_opb;
      VALU_OR:   f_res = f_opa | f_opb;
      VALU_XOR:  f_res = f_opa ^ f_opb;
      VALU_COPY: f_res = f_opb;
      VALU_MERGE: f_res = mask_bit ? f_opa : f_opb;
      VALU_SADDU: f_res = f_add9[8] ? 8'hFF : f_add9[7:0];
      VALU_SADD:  f_res = f_sadd_ov ? (f_opa[7] ? 8'h80 : 8'h7F) : f_add9[7:0];
      VALU_SSUBU: f_res = (f_opa < f_opb) ? 8'h00 : f_sub8;
      VALU_SSUB:  f_res = f_ssub_ov ? (f_opa[7] ? 8'h80 : 8'h7F) : f_sub8;
      VALU_SLL:  f_res = f_opa << f_shamt;
      VALU_SRL:  f_res = f_opa >> f_shamt;
      VALU_SRA:  f_res = $signed(f_opa) >>> f_shamt;
      VALU_SEQ:  f_cmp = (f_opa == f_opb);
      VALU_SNE:  f_cmp = (f_opa != f_opb);
      VALU_SLTU: f_cmp = (f_opa < f_opb);
      VALU_SLT:  f_cmp = ($signed(f_opa) < $signed(f_opb));
      VALU_SLEU: f_cmp = (f_opa <= f_opb);
      VALU_SLE:  f_cmp = ($signed(f_opa) <= $signed(f_opb));
      default: begin
        f_res = 8'd0;
        f_cmp = 1'b0;
      end
    endcase
  end
  logic [7:0] f_cmp_byte;
  assign f_cmp_byte = f_cmp ? (vrf_ddata_i | (8'd1 << i_q[2:0])) :
                              (vrf_ddata_i & ~(8'd1 << i_q[2:0]));
  logic f_done;
  assign f_done = (i_q >= vl_q);
  logic f_we;
  assign f_we = ~done_o & ~masked_off;

  // ============ wide path (sub-FSM: R phase then W phase) ============
  logic [7:0] w_e_q;       // current element
  logic [2:0] w_r_q;       // R-phase byte counter
  logic [2:0] w_w_q;       // W-phase byte counter
  logic       w_ph_q;      // 0 = R (assemble), 1 = W (compute/write)
  logic [63:0] w_a_q, w_b_q; // assembled vs2 / vs1-or-scalar elements
  // Element width in bits, masks and shift helpers.
  logic [7:0]  w_ewb;      // 8/16/32/64
  logic [63:0] w_mask;     // ew ones
  logic [5:0]  w_shmask;   // ewb-1 (shift-amount mask)
  assign w_ewb = 8'd8 << sew_i;
  always_comb begin
    case (sew_i)
      2'd0:    begin w_mask = 64'hFF;         w_shmask = 6'd7;  end
      2'd1:    begin w_mask = 64'hFFFF;       w_shmask = 6'd15; end
      2'd2:    begin w_mask = 64'hFFFFFFFF;   w_shmask = 6'd31; end
      default: begin w_mask = 64'hFFFFFFFFFFFFFFFF; w_shmask = 6'd63; end
    endcase
  end
  logic signed [63:0] w_as, w_bs;
  assign w_as = ($signed(w_a_q) << (64 - w_ewb)) >>> (64 - w_ewb);
  assign w_bs = ($signed(w_b_q) << (64 - w_ewb)) >>> (64 - w_ewb);
  // 128-bit products for MULH/MULHU/MULHSU (exact at SEW=64).
  // MULHU needs zero-extended operands (sign extension would corrupt the
  // high word for unsigned values with the top bit set).
  logic signed [127:0] w_pa, w_pb_s, w_prod;
  logic [127:0]        w_pb_u, w_prod_u, w_pa_u;
  assign w_pa     = {{64{w_as[63]}}, w_as};
  assign w_pb_s   = {{64{w_bs[63]}}, w_bs};
  assign w_pb_u   = {64'd0, w_b_q};
  assign w_pa_u   = {64'd0, w_a_q};
  assign w_prod   = w_pa * w_pb_s;
  assign w_prod_u = w_pa_u * w_pb_u;
  logic signed [127:0] w_prod_su;
  assign w_prod_su = w_pa * $signed(w_pb_u);
  // Saturating helpers on ew bits.
  logic [64:0] w_sum65;
  logic        w_sa, w_sb, w_sr, w_carry;
  assign w_sum65 = {1'b0, w_a_q} + {1'b0, w_b_q};
  assign w_sa    = (w_a_q >> (w_ewb - 8'd1)) & 1'b1;
  assign w_sb    = (w_b_q >> (w_ewb - 8'd1)) & 1'b1;
  assign w_sr    = (w_sum65 >> (w_ewb - 8'd1)) & 1'b1;
  assign w_carry = (w_sum65 >> w_ewb) & 1'b1;
  logic        w_sadd_ov, w_ssub_ov;
  logic [63:0] w_diff;
  assign w_diff    = w_a_q - w_b_q;
  assign w_sadd_ov = (w_sa == w_sb) && (w_sr != w_sa);
  assign w_ssub_ov = (w_sa != w_sb) &&
                     (((w_diff >> (w_ewb - 8'd1)) & 1'b1) != w_sa);
  logic [63:0] w_intmin, w_intmax;
  assign w_intmin = 64'd1 << (w_ewb - 8'd1);
  assign w_intmax = w_intmin - 64'd1;
  // Divide/remainder (RISC-V scalar semantics on ew bits: div-by-zero ->
  // -1 (all ones), overflow -> INT_MIN; rem-by-zero -> dividend,
  // rem-overflow -> 0). Ternaries evaluate one side only, so the
  // guarded INT_MIN/-1 divide never executes.
  logic [63:0] w_div_u, w_div_s, w_rem_u, w_rem_s;
  logic        w_div0, w_div_ov;
  assign w_div0   = (w_b_q == 64'd0);
  assign w_div_ov = (w_a_q == w_intmin) && (w_b_q == w_mask);
  assign w_div_u  = w_div0 ? w_mask : (w_a_q / w_b_q);
  assign w_div_s  = w_div0 ? w_mask : (w_div_ov ? w_intmin :
                                       $unsigned(w_as / w_bs));
  assign w_rem_u  = w_div0 ? w_a_q : (w_a_q % w_b_q);
  assign w_rem_s  = w_div0 ? w_a_q : (w_div_ov ? 64'd0 :
                                      $unsigned(w_as % w_bs));
  // Wide ALU result (full element; W writes one byte per cycle).
  logic [63:0] w_res;
  logic        w_cmp;
  logic [5:0]  w_shamt;
  assign w_shamt = w_b_q[5:0] & w_shmask;
  // Shared funct6s disambiguated by funct3 (w_is_div): OPIVV/OPIVX
  // 100000..100011 are saturating add/sub, OPMVV/OPMVX are divide/
  // remainder; 100101 is SLL vs MUL.
  logic w_is_div;
  assign w_is_div = (funct3_i == 3'b010) || (funct3_i == 3'b110);
  always_comb begin
    w_res = 64'd0;
    w_cmp = 1'b0;
    case (aluop_i)
      VALU_ADD:   w_res = w_a_q + w_b_q;
      VALU_SUB:   w_res = w_a_q - w_b_q;
      VALU_MINU:  w_res = (w_a_q < w_b_q) ? w_a_q : w_b_q;
      VALU_MIN:   w_res = (w_as < w_bs) ? w_a_q : w_b_q;
      VALU_MAXU:  w_res = (w_a_q < w_b_q) ? w_b_q : w_a_q;
      VALU_MAX:   w_res = (w_as < w_bs) ? w_b_q : w_a_q;
      VALU_AND:   w_res = w_a_q & w_b_q;
      VALU_OR:    w_res = w_a_q | w_b_q;
      VALU_XOR:   w_res = w_a_q ^ w_b_q;
      VALU_COPY:  w_res = w_b_q;
      VALU_MERGE: w_res = mask_bit ? w_a_q : w_b_q;
      VALU_SADDU: w_res = w_is_div ? w_div_u :
                          (w_carry ? w_mask : w_sum65[63:0]);
      VALU_SADD:  w_res = w_is_div ? w_div_s :
                          (w_sadd_ov ? (w_sa ? w_intmin : w_intmax) :
                                       w_sum65[63:0]);
      VALU_SSUBU: w_res = w_is_div ? w_rem_u :
                          ((w_a_q < w_b_q) ? 64'd0 : w_diff);
      VALU_SSUB:  w_res = w_is_div ? w_rem_s :
                          (w_ssub_ov ? (w_sa ? w_intmin : w_intmax) : w_diff);
      VALU_SLL:   w_res = w_is_div ? (w_a_q * w_b_q) : (w_a_q << w_shamt);
      VALU_SRL:   w_res = w_a_q >> w_shamt;
      VALU_SRA:   w_res = $unsigned(w_as >> w_shamt);
      VALU_MULHU: w_res = w_prod_u[63:0] >> w_ewb;
      VALU_MULHSU: w_res = w_prod_su[63:0] >> w_ewb;
      VALU_MULH:  w_res = w_prod[63:0] >> w_ewb;
      VALU_SEQ:   w_cmp = (w_a_q == w_b_q);
      VALU_SNE:   w_cmp = (w_a_q != w_b_q);
      VALU_SLTU:  w_cmp = (w_a_q < w_b_q);
      VALU_SLT:   w_cmp = (w_as < w_bs);
      VALU_SLEU:  w_cmp = (w_a_q <= w_b_q);
      VALU_SLE:   w_cmp = (w_as <= w_bs);
      default: begin
        w_res = 64'd0;
        w_cmp = 1'b0;
      end
    endcase
  end
  // Slide offset / gather index from the scalar (full 64-bit; huge offsets
  // make every element undisturbed/zero by construction below).
  logic        w_off_hi;
  logic [7:0]  w_off8;
  assign w_off_hi = |scalar_i[63:8];
  assign w_off8   = scalar_i[7:0];
  // Slideup undisturbed region: e < off.
  logic w_up_skip;
  assign w_up_skip = is_slideup && !is_slide1 &&
                     (w_off_hi || (w_e_q < w_off8));
  // Skip conditions evaluated per element (static across its R/W cycles):
  // masked-off, or slideup low region.
  logic w_skip;
  assign w_skip = masked_off | w_up_skip;
  // Slidedown source < vl?
  logic [8:0] w_dn_src9;
  logic       w_dn_ok;
  assign w_dn_src9 = {1'b0, w_e_q} + {1'b0, w_off8};
  assign w_dn_ok   = !w_off_hi && (w_dn_src9 < {1'b0, vl_q});
  // Slide1down fill at the tail?
  logic [8:0] w_s1_src9;
  logic       w_s1_ok;
  assign w_s1_src9 = {1'b0, w_e_q} + 9'd1;
  assign w_s1_ok   = (w_s1_src9 < {1'b0, vl_q});
  // Gather index (SEW-wide from vs1, or scalar) and range check against
  // VLMAX (full-width compare: vlmax=32 needs more than 5 bits).
  logic [63:0] w_idx;
  assign w_idx = use_scalar ? scalar_i : w_b_q;
  logic        w_idx_ok;
  assign w_idx_ok = (w_idx < {56'd0, vlmax});
  // R-phase byte address within vs2/vs1 (e*ew+r <= 31: e<vl<=32/ew).
  logic [7:0] w_rbyte;
  assign w_rbyte = (w_e_q << sew_i) | {5'd0, w_r_q};
  // R-phase scalar byte.
  logic [7:0] w_sbyte;
  assign w_sbyte = (scalar_i >> (w_r_q * 8)) & 8'hFF;
  // W-phase write byte.
  logic [7:0] w_wbyte;
  // Slide source element -> byte address ((src*ew+w) <= 31 when valid).
  logic [7:0] w_src_byte;
  always_comb begin
    w_src_byte = 8'd0;
    if (is_slide) begin
      if (is_slideup) begin
        if (is_slide1)
          // slide1up: vd[0]=fill (vstart==0 only), else vs2[e-1].
          w_src_byte = ((w_e_q - 8'd1) << sew_i) | {5'd0, w_w_q};
        else
          // slideup: vs2[e-off] (skip guarantees e>=off, no wrap).
          w_src_byte = ((w_e_q - w_off8) << sew_i) | {5'd0, w_w_q};
      end else begin
        if (is_slide1)
          // slide1down: vs2[e+1] (validity checked at write).
          w_src_byte = ((w_e_q + 8'd1) << sew_i) | {5'd0, w_w_q};
        else
          // slidedown: vs2[e+off] (validity checked at write).
          w_src_byte = (w_dn_src9[7:0] << sew_i) | {5'd0, w_w_q};
      end
    end
  end
  // Gather data byte address ((idx*ew+w) <= 31 when in range).
  logic [7:0] w_gbyte;
  assign w_gbyte = (w_idx[4:0] << sew_i) | {5'd0, w_w_q};
  // Fill byte (slide1 scalar).
  logic [7:0] w_fbyte;
  assign w_fbyte = (scalar_i >> (w_w_q * 8)) & 8'hFF;
  // Compare RMW byte (idempotent across W cycles).
  logic [7:0] w_cmp_byte;
  assign w_cmp_byte = w_cmp ? (vrf_ddata_i | (8'd1 << w_e_q[2:0])) :
                              (vrf_ddata_i & ~(8'd1 << w_e_q[2:0]));
  always_comb begin
    w_wbyte = 8'd0;
    if (is_slide) begin
      if (is_slideup) begin
        if (is_slide1)
          w_wbyte = (w_e_q == 8'd0) ? w_fbyte : vrf_idata_i;
        else
          w_wbyte = vrf_idata_i;
      end else begin
        if (is_slide1)
          w_wbyte = w_s1_ok ? vrf_idata_i : w_fbyte;
        else
          w_wbyte = w_dn_ok ? vrf_idata_i : 8'd0;
      end
    end else if (is_gather) begin
      w_wbyte = w_idx_ok ? vrf_gdata_i : 8'd0;
    end else if (is_cmp) begin
      w_wbyte = w_cmp_byte;
    end else begin
      // ALU (incl. MERGE, which selects whole elements in w_res).
      w_wbyte = (w_res >> (w_w_q * 8)) & 8'hFF;
    end
  end
  logic w_done;
  assign w_done = (w_e_q >= vl_q);
  logic w_we;
  assign w_we = w_ph_q & ~done_o & ~w_skip;

  // ================= shared sequencer =================
  // During the (re)sample cycle the stale done must not release the hold:
  // the new op has not sequenced anything yet.
  assign done_o = started_q & ~w_start &
                  (use_wide ? w_done : (i_q >= vl_q));
  assign busy_o = active_i & (w_start | (started_q & ~done_o));
  // Write port mux (only one path sequences; idle side is don't-care).
  assign vrf_waddr_o = vd_i;
  assign vrf_widx_o  = use_wide ? (is_cmp ? {3'd0, w_e_q[7:3]} :
                                             ((w_e_q << sew_i) |
                                              {5'd0, w_w_q})) :
                                  (is_cmp ? {3'd0, i_q[7:3]} : i_q[4:0]);
  assign vrf_wdata_o = use_wide ? w_wbyte :
                       (is_cmp ? f_cmp_byte : f_res);
  assign vrf_we_o = active_i & started_q & ~w_start & ~done_o &
                    (use_wide ? w_we : f_we);
  // Read port mux.
  assign vrf_raddr_o = vs1_i;
  assign vrf_ridx_o  = use_wide ? w_rbyte[4:0] : i_q[4:0];
  assign vrf_iaddr_o = vs2_i;
  assign vrf_iidx_o  = use_wide ?
                       (w_ph_q ? w_src_byte[4:0] : w_rbyte[4:0]) :
                       i_q[4:0];
  assign vrf_gaddr_o = vs2_i;
  assign vrf_gidx_o  = w_gbyte[4:0];

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      i_q <= '0; vl_q <= '0; started_q <= 1'b0;
      w_e_q <= '0; w_r_q <= '0; w_w_q <= '0; w_ph_q <= 1'b0;
      w_a_q <= '0; w_b_q <= '0;
    end else if (trap_i || !active_i) begin
      i_q <= '0; started_q <= 1'b0;
      w_e_q <= '0; w_ph_q <= 1'b0;
    end else begin
      if (!started_q || w_start) begin
        // First active cycle, or a new op handed over with no idle gap:
        // (re)sample vl/vstart (both stable, see header).
        i_q <= vstart_i;
        vl_q <= vl_i;
        started_q <= 1'b1;
        w_e_q <= vstart_i;
        w_r_q <= '0; w_w_q <= '0; w_ph_q <= 1'b0;
        w_a_q <= '0; w_b_q <= '0;
      end else if (!done_o) begin
        if (!use_wide) begin
          // Fast: one element per cycle (masked-off keeps the same pace).
          i_q <= i_q + 8'd1;
        end else if (w_skip) begin
          // Masked-off / slideup-low: next element, same pace point.
          w_e_q <= w_e_q + 8'd1;
          w_r_q <= '0; w_w_q <= '0; w_ph_q <= 1'b0;
        end else if (!w_ph_q) begin
          // R phase: assemble element bytes (r==0 assigns, rest ORs).
          if (w_r_q == 8'd0) begin
            w_a_q <= {56'd0, vrf_idata_i};
            w_b_q <= {56'd0, use_scalar ? w_sbyte : vrf_rdata_i};
          end else begin
            w_a_q <= w_a_q | ({56'd0, vrf_idata_i} << (w_r_q * 8));
            w_b_q <= w_b_q | ({56'd0, use_scalar ? w_sbyte : vrf_rdata_i} <<
                              (w_r_q * 8));
          end
          if (w_r_q == (ew - 8'd1)) begin
            w_ph_q <= 1'b1;
            w_w_q <= '0;
          end else begin
            w_r_q <= w_r_q + 3'd1;
          end
        end else begin
          // W phase: one result byte per cycle (write itself is in the
          // wdata/we assigns above, same edge).
          if (w_w_q == (ew - 8'd1)) begin
            w_e_q <= w_e_q + 8'd1;
            w_r_q <= '0; w_w_q <= '0; w_ph_q <= 1'b0;
            w_a_q <= '0; w_b_q <= '0;
          end else begin
            w_w_q <= w_w_q + 3'd1;
          end
        end
      end
    end
  end

endmodule
