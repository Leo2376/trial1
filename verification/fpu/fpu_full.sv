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
  // guard=F[2], round=F[1], sticky=F[0]. expb is a 10-bit signed biased
  // exponent. The true exponent range needed is [-127, +254] (and overflow
  // products up to +381); a 10-bit signed field [-512,+511] holds this with no
  // sign collision. Overflow = signed(e) >= 255; underflow/denormal = signed(e)
  // <= 0.
  function automatic logic [31:0] round_pack_s(input logic        sgn,
                                               input logic signed [9:0] expb,
                                               input logic [27:0] F,
                                               input logic [2:0]  rmode,
                                               output logic [4:0] ff);
    logic [22:0] frac; logic g, r, s_bit, lsb, round_up;
    logic signed [9:0] e; logic [4:0] f; logic [27:0] Fp;
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
    // Overflow: signed biased exponent >= 255 (true exp >= 128). Round-up may
    // push 254 -> 255. Values >= 256 are genuine overflow, never underflow.
    if (e >= 10'sd255) begin
      f = f | FF_OF | FF_NX;
      case (rmode)
        RM_RNE, RM_RMM: begin e = 10'sd255; frac = 23'd0; end
        RM_RTZ:        begin e = 10'sd254; frac = 23'h7FFFFF; end
        RM_RDN: begin if (sgn) begin e=10'sd255; frac=23'd0; end else begin e=10'sd254; frac=23'h7FFFFF; end end
        RM_RUP: begin if (sgn) begin e=10'sd254; frac=23'h7FFFFF; end else begin e=10'sd255; frac=23'd0; end end
        default:       begin e = 10'sd255; frac = 23'd0; end
      endcase
      ff = f;
      return {sgn, e[7:0], frac};
    end
    // Underflow / denormal: biased exponent <= 0 (true exp <= -127). Denormalize
    // by shifting F right by (1 - e) so the implicit leading 1 lands at the
    // denormal MSB position instead of bit 26, then round.
    if (e <= 10'sd0) begin
      logic [8:0] sh; logic [27:0] Fd; logic inexact_pre;
      logic gd, rd, sd, lsd; logic ru; logic [27:0] Fdd;
      if (e <= -10'sd27) begin
        sh = 9'd28;
      end else begin
        sh = 9'd1 - e;
      end
      Fd = F;
      if (sh >= 9'd28) begin
        inexact_pre = (F[27:0] != 28'd0);
        Fd = 28'd0;
      end else begin
        inexact_pre = (|(Fd & (28'hFFFFFFF >> (28 - sh))));
        Fd = Fd >> sh;
      end
      gd = Fd[2]; rd = Fd[1]; sd = Fd[0] | inexact_pre;
      frac = Fd[25:3]; lsd = frac[0];
      ru = 1'b0;
      case (rmode)
        RM_RNE: ru = gd & (rd | sd | lsd);
        RM_RTZ: ru = 1'b0;
        RM_RDN: ru = sgn & (gd | rd | sd);
        RM_RUP: ru = ~sgn & (gd | rd | sd);
        RM_RMM: ru = gd;
        default: ru = gd & (rd | sd | lsd);
      endcase
      Fdd = Fd;
      if (ru) Fdd = Fd + 28'd8;
      frac = Fdd[25:3];
      if (gd | rd | sd) f = f | FF_UF | FF_NX;
      else f = f | FF_UF;
      // If rounding carried into the implicit bit, it became the smallest
      // normal (exp=1): no longer an underflow result.
      if (Fdd[26]) begin
        e = 10'sd1; f = f & ~FF_UF;
      end else begin
        e = 10'sd0;
      end
      ff = f;
      return {sgn, e[7:0], frac};
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
    logic signed [9:0] eout;
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
      eout = $signed({1'b0, ebig});
      if (sumF[27]) begin
        dropped_bit0 = sumF[0];
        sumF = {1'b0, sumF[27:1]};
        sumF[0] = sumF[0] | dropped_bit0 | stk;
        eout = eout + 10'sd1;
      end else begin
        sumF[0] = sumF[0] | stk;
      end
    end else begin
      smallF[0] = smallF[0] | stk;
      sumF = bigF - smallF;
      eout = $signed({1'b0, ebig});
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
    logic [47:0] prod; logic [27:0] F; logic signed [9:0] eout; logic [4:0] f;
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
    eout = $signed({2'b00, ea} + {2'b00, eb} - 10'd127);
    prod = ma * mb;   // 48-bit
    if (prod[47]) begin
      // value in [2.0,4.0) = 2 * [1.0,2.0): normalize by shifting right 1 and
      // incrementing the exponent. Place bit 47 at field bit 26 (shift right 21).
      F = (prod >> 21) & 28'h0FFFFFFF;
      stk = |(prod & 28'h1FFFFF);
      F[0] = F[0] | stk;
      eout = eout + 10'sd1;
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
    logic [27:0] q; logic [54:0] rem, dividend, qprod; integer i;
    logic [27:0] F; logic signed [9:0] eout; logic [4:0] f;
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
    eout = $signed({2'b00, ea}) - $signed({2'b00, eb}) + 10'sd127;
    // Compute a 28-bit quotient q = (ma << 26) / mb so that the 24-bit
    // mantissa sits in q[26:3] with two guard bits (q[2], q[1]) and a round
    // bit (q[0]); the remainder supplies the sticky. The true quotient
    // ma/mb lies in [0.5, 2.0), so q[27:26] select the [1.0,2.0) vs
    // [0.5,1.0) range. For validation we use the direct '/' operator
    // (synthesizable; the integrated FPU uses a multi-cycle divider).
    dividend = {31'd0, ma} << 26;     // 55-bit
    q        = dividend[54:0] / {4'd0, mb};
    qprod    = {27'd0, q} * {31'd0, mb};
    rem      = dividend - qprod;
    stk      = (rem != 55'd0);
    if (q[27]) begin
      // value in [2.0, ...): impossible for ma<mb*2, but guard against it.
      F    = q[27:0] >> 1;
      F[0] = F[0] | stk;
      eout = eout + 10'sd1;
    end else if (q[26]) begin
      // value in [1.0,2.0): mantissa = q[26:3], guard=q[2], round=q[1],
      // round-bit=q[0].
      F    = q;
      F[0] = F[0] | stk;
    end else begin
      // value in [0.5,1.0): shift left 1, exp--.
      F    = q << 1;
      F[0] = F[0] | stk;
      eout = eout - 10'sd1;
    end
    ff = f;
    return round_pack_s(sga ^ sgb, eout, F, rmode, ff);
  endfunction

  // FSQRT single: digit-by-digit (non-restoring) integer sqrt producing a
  // 26-bit root (24-bit 1.xxx mantissa + 2 guard bits) plus a remainder used as
  // the sticky bit. Denormal inputs are normalized first so the radicand always
  // has its leading 1 in a fixed position. The result exponent is floor(E/2)+127
  // where E is the (possibly negative) unbiased exponent; arithmetic shift
  // handles negative E correctly.
  function automatic logic [31:0] fsqrt_s(input logic [31:0] sxa,
                                          input logic [2:0] rmode, output logic [4:0] ff);
    logic [7:0] ea; logic [24:0] mant; logic [22:0] fracf;
    logic [54:0] res, rem, term; integer i, k; integer L; integer bi;
    logic [51:0] radicand;
    logic [27:0] F; logic signed [10:0] eout; logic [4:0] f;
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
    fracf = sxa[22:0];
    // Normalize denormal inputs (ea==0, fracf!=0): find the leading 1 (L is its
    // bit position in the 23-bit fraction field), shift the fraction so the
    // implicit 1 lands at bit 23, and set the unbiased exponent E = L - 149.
    if (ea == 8'd0) begin
      L = -1;
      for (k = 22; k >= 0; k = k - 1)
        if (fracf[k] && L < 0) L = k;
      mant = {1'b1, fracf << (23 - L)};   // bit 23 set (24-bit 1.frac)
      eout = $signed(11'(L)) - 11'sd149;  // unbiased exponent
    end else begin
      mant = {1'b1, fracf};
      eout = $signed({3'b000, ea}) - 11'sd127;
    end
    // For an odd unbiased exponent, fold the factor of 2 into the mantissa
    // (sqrt(2.frac) in [sqrt(2),2)) and use E (already even after floor div).
    odd_exp = eout[0];
    // radicand = mant * 2^27 (even E) or mant * 2^28 (odd E); both place the
    // radicand leading bit so the 26-bit root has its leading 1 at bit 25.
    if (odd_exp) begin
      radicand = {28'd0, mant} << 28;
    end else begin
      radicand = {28'd0, mant} << 27;
    end
    // Classic non-restoring sqrt: 26 iterations, two radicand bits per step,
    // extracted by absolute index from the MSB down (matches the bit order in
    // which the root is produced).
    rem = 52'd0; res = 52'd0;
    for (i = 25; i >= 0; i = i - 1) begin
      bi = 2*i + 1;
      rem = (rem << 2) | radicand[bi -: 2];
      term = (res << 2) | 52'd1;
      if (rem >= term) begin
        rem = rem - term;
        res = (res << 1) | 52'd1;
      end else begin
        res = res << 1;
      end
    end
    stk = (rem != 52'd0);
    // res is 26-bit: res[25]=leading 1, res[24:2]=23 frac bits, res[1]=guard,
    // res[0]=round. Map into the 28-bit round_pack field (leading 1 at bit 26).
    F = (res << 1) | {27'd0, stk};
    eout = (eout >>> 1) + 11'sd127;
    ff = f;
    return round_pack_s(1'b0, eout[9:0], F, rmode, ff);
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
