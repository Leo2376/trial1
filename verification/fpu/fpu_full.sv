`timescale 1ns/1ps
// Standalone full single-precision FPU for validation.
package fpuf_pkg;
  localparam logic [2:0] RM_RNE = 3'd0, RM_RTZ = 3'd1, RM_RDN = 3'd2,
                        RM_RUP = 3'd3, RM_RMM = 3'd4;
  localparam logic [4:0] FF_NV = 5'b10000, FF_DZ = 5'b01000, FF_OF = 5'b00100,
                        FF_UF = 5'b00010, FF_NX = 5'b00001;
endpackage

module fpu_full (
  input  logic [31:0] sa, sb,
  input  logic [2:0]  op,     // 0=fadd 1=fsub 2=fmul 3=fdiv 4=fsqrt
  input  logic [2:0]  rmode,
  output logic [31:0] res,
  output logic [4:0]  ff
);
  import fpuf_pkg::*;

  localparam logic [31:0] CANON_S_NAN = 32'h7FC00000;

  function automatic logic is_nan_s(input logic [31:0] s);
    return (s[30:23]==8'hFF) & (|s[22:0]);
  endfunction
  function automatic logic is_snan_s(input logic [31:0] s);
    return (s[30:23]==8'hFF) & (s[22]==1'b0) & (|s[21:0]);
  endfunction
  function automatic logic is_inf_s(input logic [31:0] s);
    return (s[30:23]==8'hFF) & (s[22:0]==23'd0);
  endfunction
  function automatic logic is_zero_s(input logic [31:0] s);
    return (s[30:23]==8'd0) & (s[22:0]==23'd0);
  endfunction

  // round-and-pack single. F is 28-bit: leading 1 at bit 26, frac[25:3],
  // guard=F[2], round=F[1], sticky=F[0]. expb is 9-bit biased exponent.
  function automatic logic [31:0] round_pack_s(input logic        sgn,
                                               input logic [8:0]  expb,
                                               input logic [27:0] F,
                                               input logic [2:0]  rmode,
                                               output logic [4:0] ff);
    logic [22:0] frac; logic g, r, s_bit, lsb, round_up;
    logic [8:0] e; logic [4:0] f; logic [27:0] Fp;
    f = 5'd0; e = expb;
    frac = F[25:3]; g = F[2]; r = F[1]; s_bit = F[0];
    Fp = F;
    lsb = frac[0];
    round_up = 1'b0;
    case (rmode)
      RM_RNE: round_up = g & (r | s_bit | lsb);
      RM_RTZ: round_up = 1'b0;
      RM_RDN: round_up = sgn & (g | r | s_bit);
      RM_RUP: round_up = ~sgn & (g | r | s_bit);
      RM_RMM: round_up = g;
      default: round_up = g & (r | s_bit | lsb);
    endcase
    if (round_up) Fp = F + 28'd8;
    frac = Fp[25:3];
    if (round_up & Fp[27]) begin
      Fp = {Fp[27:1], 1'b0};
      e = e + 9'd1;
      frac = Fp[25:3];
    end
    if (F[2] | F[1] | F[0]) f = f | FF_NX;
    if (e >= 9'h0FF) begin
      f = f | FF_OF | FF_NX;
      case (rmode)
        RM_RNE, RM_RMM: begin e = 9'h0FF; frac = 23'd0; end
        RM_RTZ:        begin e = 9'h0FE; frac = 23'h7FFFFF; end
        RM_RDN: begin if (sgn) begin e=9'h0FF; frac=23'd0; end else begin e=9'h0FE; frac=23'h7FFFFF; end end
        RM_RUP: begin if (sgn) begin e=9'h0FE; frac=23'h7FFFFF; end else begin e=9'h0FF; frac=23'd0; end end
        default:       begin e = 9'h0FF; frac = 23'd0; end
      endcase
    end
    if ((~e[8]) && (e[8:0] < 9'h001)) begin
      if (F[2] | F[1] | F[0]) f = f | FF_UF | FF_NX; else f = f | FF_UF;
      e = 9'd0; frac = 23'd0;
    end
    if (e[8]) begin
      if (F[2] | F[1] | F[0]) f = f | FF_UF | FF_NX; else f = f | FF_UF;
      e = 9'd0; frac = 23'd0;
    end
    ff = f;
    return {sgn, e[7:0], frac};
  endfunction

  function automatic integer msb_pos28(input logic [27:0] v, input integer lo);
    integer i; integer p;
    p = -1;
    for (i = 27; i >= lo; i = i - 1)
      if (v[i] && p < 0) p = i;
    return p;
  endfunction

  // FADD/FSUB single
  function automatic logic [31:0] faddsub_s(input logic [31:0] sxa, input logic [31:0] sxb,
                                           input logic sub, input logic [2:0] rmode,
                                           output logic [4:0] ff);
    logic sga, sgb, eff_sub;
    logic [7:0] ea, eb, ebig, esmall;
    logic [23:0] ma, mb, mbig, msmall;
    logic swap;
    logic [7:0] diff;
    logic [27:0] bigF, smallF, sumF;
    logic stk;
    logic [8:0] eout;
    logic sgout;
    logic [4:0] f;
    integer lead_bit; integer sh;
    logic dropped_bit0;
    f = 5'd0;
    if (is_nan_s(sxa) | is_nan_s(sxb)) begin
      if (is_snan_s(sxa) | is_snan_s(sxb)) f = f | FF_NV;
      ff = f; return CANON_S_NAN;
    end
    sga = sxa[31]; sgb = sxb[31];
    eff_sub = sga ^ sgb ^ sub;
    if (is_inf_s(sxa) & is_inf_s(sxb) & eff_sub) begin
      f = f | FF_NV; ff = f; return CANON_S_NAN;
    end
    if (is_inf_s(sxa)) begin ff = f; return sxa; end
    if (is_inf_s(sxb)) begin ff = f; return sub ? {~sgb, sxb[30:0]} : sxb; end
    ea = sxa[30:23]; eb = sxb[30:23];
    ma = (ea==8'd0) ? {1'b0, sxa[22:0]} : {1'b1, sxa[22:0]};
    mb = (eb==8'd0) ? {1'b0, sxb[22:0]} : {1'b1, sxb[22:0]};
    if (ea==8'd0) begin ma = 24'd0; ea = 8'd1; end
    if (eb==8'd0) begin mb = 24'd0; eb = 8'd1; end
    swap = (ea < eb) | ((ea == eb) & (ma < mb));
    if (swap) begin
      ebig = eb; esmall = ea; mbig = mb; msmall = ma;
      sgout = sgb ^ sub;
    end else begin
      ebig = ea; esmall = eb; mbig = ma; msmall = mb; sgout = sga;
    end
    diff = ebig - esmall;
    bigF = {1'b0, mbig, 3'b0};
    smallF = {1'b0, msmall, 3'b0};
    stk = 1'b0;
    if (diff >= 8'd28) begin
      stk = |msmall;
      smallF = 28'd0;
    end else begin
      stk = |(smallF & ((28'hFFFFFFF) >> (28 - diff)));
      smallF = smallF >> diff;
    end
    if (!eff_sub) begin
      sumF = bigF + smallF;
      eout = {1'b0, ebig};
      if (sumF[27]) begin
        dropped_bit0 = sumF[0];
        sumF = {1'b0, sumF[27:1]};
        sumF[0] = sumF[0] | dropped_bit0 | stk;
        eout = eout + 9'd1;
      end else begin
        sumF[0] = sumF[0] | stk;
      end
    end else begin
      smallF[0] = smallF[0] | stk;
      sumF = bigF - smallF;
      eout = {1'b0, ebig};
      if (sumF[27:3] == 25'd0) begin
        ff = f; return {(sgout & (|{sumF, stk})), 31'd0};
      end
      lead_bit = msb_pos28(sumF, 3);
      sh = 26 - lead_bit;
      if (sh > 0) begin
        sumF = sumF << sh;
        eout = eout - sh;
      end
      sumF[0] = sumF[0] | stk;
    end
    ff = f;
    return round_pack_s(sgout, eout, sumF, rmode, ff);
  endfunction

  // FMUL single
  function automatic logic [31:0] fmul_s(input logic [31:0] sxa, input logic [31:0] sxb,
                                         input logic [2:0] rmode, output logic [4:0] ff);
    logic sga, sgb; logic [7:0] ea, eb; logic [23:0] ma, mb;
    logic [47:0] prod; logic [27:0] F; logic [8:0] eout; logic [4:0] f;
    logic stk;
    f = 5'd0;
    if (is_nan_s(sxa) | is_nan_s(sxb)) begin
      if (is_snan_s(sxa) | is_snan_s(sxb)) f = f | FF_NV;
      ff = f; return CANON_S_NAN;
    end
    sga = sxa[31]; sgb = sxb[31];
    if (is_inf_s(sxa) & is_zero_s(sxb)) begin f = f | FF_NV; ff = f; return CANON_S_NAN; end
    if (is_zero_s(sxa) & is_inf_s(sxb)) begin f = f | FF_NV; ff = f; return CANON_S_NAN; end
    if (is_inf_s(sxa) | is_inf_s(sxb)) begin ff = f; return {(sga ^ sgb), 8'hFF, 23'd0}; end
    ea = sxa[30:23]; eb = sxb[30:23];
    ma = (ea==8'd0) ? {1'b0, sxa[22:0]} : {1'b1, sxa[22:0]};
    mb = (eb==8'd0) ? {1'b0, sxb[22:0]} : {1'b1, sxb[22:0]};
    if (ea==8'd0) ea = 8'd1;
    if (eb==8'd0) eb = 8'd1;
    // Product range [1.0,4.0): ma,mb are 1.x (24-bit, implicit at bit 23), so
    // prod leading bit is 46 (value in [1.0,2.0)) or 47 (value in [2.0,4.0)).
    eout = {1'b0, ea} + {1'b0, eb} - 9'd127;
    prod = ma * mb;   // 48-bit
    if (prod[47]) begin
      // value in [2.0,4.0) = 2 * [1.0,2.0): normalize by shifting right 1 and
      // incrementing the exponent. Place bit 47 at field bit 26 (shift right 21).
      F = (prod >> 21) & 28'h0FFFFFFF;
      stk = |(prod & 28'h1FFFFF);
      F[0] = F[0] | stk;
      eout = eout + 9'd1;
    end else begin
      // value in [1.0,2.0): leading bit 46 -> field bit 26 (shift right 20).
      F = (prod >> 20) & 28'h0FFFFFFF;
      stk = |(prod & 28'hFFFFF);
      F[0] = F[0] | stk;
    end
    ff = f;
    return round_pack_s(sga ^ sgb, eout, F, rmode, ff);
  endfunction

  // FDIV single (iterative restoring division, but here pure-combinational for
  // validation since 24-bit quotient is feasible). Multi-cycle in real HW.
  function automatic logic [31:0] fdiv_s(input logic [31:0] sxa, input logic [31:0] sxb,
                                         input logic [2:0] rmode, output logic [4:0] ff);
    logic sga, sgb; logic [7:0] ea, eb; logic [23:0] ma, mb;
    logic [23:0] q; logic [47:0] rem; integer i;
    logic [27:0] F; logic [8:0] eout; logic [4:0] f;
    logic stk;
    f = 5'd0;
    if (is_nan_s(sxa) | is_nan_s(sxb)) begin
      if (is_snan_s(sxa) | is_snan_s(sxb)) f = f | FF_NV;
      ff = f; return CANON_S_NAN;
    end
    sga = sxa[31]; sgb = sxb[31];
    if (is_inf_s(sxa) & is_inf_s(sxb)) begin f = f | FF_NV; ff=f; return CANON_S_NAN; end
    if (is_zero_s(sxa) & is_zero_s(sxb)) begin f = f | FF_NV; ff=f; return CANON_S_NAN; end
    if (is_inf_s(sxa)) begin ff=f; return {(sga^sgb), 8'hFF, 23'd0}; end
    if (is_inf_s(sxb)) begin ff=f; return {(sga^sgb), 31'd0}; end
    if (is_zero_s(sxb)) begin
      f = f | FF_DZ; ff=f; return {(sga^sgb), 8'hFF, 23'd0};
    end
    ea = sxa[30:23]; eb = sxb[30:23];
    ma = (ea==8'd0) ? {1'b0, sxa[22:0]} : {1'b1, sxa[22:0]};
    mb = (eb==8'd0) ? {1'b0, sxb[22:0]} : {1'b1, sxb[22:0]};
    if (ea==8'd0) ea = 8'd1;
    if (eb==8'd0) eb = 8'd1;
    eout = {1'b0, ea} - {1'b0, eb} + 9'd127;
    // Compute q = (ma << 23) / mb, a 24-bit quotient (value q/2^23 in [0.5,2.0)).
    // For validation we use the direct '/' operator (synthesizable; the
    // integrated FPU uses a multi-cycle restoring divider instead).
    q  = (ma << 23) / mb;
    rem = (ma << 23) - (q * mb);
    $display("DBG FDIV a=%h b=%h ma=%h mb=%h q=%h eout=%0d", sxa, sxb, ma, mb, q, eout);
    // q holds floor(ma/mb * 2^23). If ma>=mb, q[23]=1 (value in [1.0,2.0));
    // else q[23]=0 (value in [0.5,1.0)), shift left 1 and exp--.
    stk = (rem != 48'd0);
    if (q[23]) begin
      F = {1'b0, q, 3'b0};
      F[0] = F[0] | stk;
    end else begin
      F = {1'b0, q, 3'b0} << 1;
      F[0] = F[0] | stk;
      eout = eout - 9'd1;
    end
    ff = f;
    return round_pack_s(sga ^ sgb, eout, F, rmode, ff);
  endfunction

  // FSQRT single (bit-by-bit, 24-bit result + remainder for sticky)
  function automatic logic [31:0] fsqrt_s(input logic [31:0] sxa,
                                          input logic [2:0] rmode, output logic [4:0] ff);
    logic [7:0] ea; logic [23:0] ma;
    logic [47:0] res, rem, term; integer i;
    logic [27:0] F; logic [8:0] eout; logic [4:0] f;
    logic stk; logic odd_exp;
    f = 5'd0;
    if (is_nan_s(sxa)) begin
      if (is_snan_s(sxa)) f = f | FF_NV;
      ff = f; return CANON_S_NAN;
    end
    if (is_inf_s(sxa)) begin ff = f; return sxa; end
    if (sxa[31]) begin
      if (is_zero_s(sxa)) begin ff = f; return 32'h80000000; end
      f = f | FF_NV; ff = f; return CANON_S_NAN;
    end
    if (is_zero_s(sxa)) begin ff = f; return 32'h00000000; end
    ea = sxa[30:23];
    ma = {1'b1, sxa[22:0]};
    // exponent must be even after subtracting bias. If ea odd, shift mantissa
    // left 1 and use ea+1 (even). sqrt(exp) = (ea - 127)/2 + 127.
    odd_exp = ea[0];
    if (odd_exp) begin
      ma = {ma, 1'b0};   // 25-bit, but we treat ma as 24-bit; use {ma[23:0],1'b0}? keep 24+1
      // We'll handle by using a 25-bit working mantissa.
    end
    // Compute sqrt of mantissa (with possible extra bit). res accumulates the
    // 24-bit root. Standard digit-by-digit sqrt for fixed point.
    // Work with rem and res over 48 bits.
    rem = 48'd0; res = 48'd0;
    // Bring in mantissa bits two at a time from MSB.
    // ma is 24-bit (or 25 if odd). We want 24 result bits + remainder for sticky.
    // Use the classic non-restoring sqrt: process 24*2=48 input bits.
    begin : sqrt_loop
      logic [47:0] mwork;
      mwork = (odd_exp) ? {ma[23:0], 25'd0} : {ma, 24'd0};
      for (i = 23; i >= 0; i = i - 1) begin
        rem = {rem[45:0], mwork[47:46]};
        mwork = mwork << 2;
        term = (res << 2) | 48'd1;
        if (rem >= term) begin
          rem = rem - term;
          res = (res << 1) | 48'd1;
        end else begin
          res = res << 1;
        end
      end
      stk = (rem != 48'd0);
    end
    // res[23:0] is the 24-bit root mantissa (1.xxxx). sqrt of 1.x is in [1.0,2.0)
    // so res[23]=1 normally.
    eout = (odd_exp) ? {1'b0, (ea + 8'd1)} - 9'd127 : {1'b0, ea} - 9'd127;
    eout = (eout >> 1) + 9'd127;
    F = {1'b0, res[23:0], 3'b0};
    F[0] = F[0] | stk;
    ff = f;
    return round_pack_s(1'b0, eout, F, rmode, ff);
  endfunction

  logic [4:0] ff_i;
  always_comb begin
    ff_i = 5'd0;
    case (op)
      3'd0: res = faddsub_s(sa, sb, 1'b0, rmode, ff_i);
      3'd1: res = faddsub_s(sa, sb, 1'b1, rmode, ff_i);
      3'd2: res = fmul_s(sa, sb, rmode, ff_i);
      3'd3: res = fdiv_s(sa, sb, rmode, ff_i);
      3'd4: res = fsqrt_s(sa, rmode, ff_i);
      default: begin res = CANON_S_NAN; ff_i = FF_NV; end
    endcase
  end
  assign ff = ff_i;

endmodule
