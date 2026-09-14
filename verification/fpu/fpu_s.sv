`timescale 1ns/1ps
// Standalone FPU single-precision arithmetic for validation against $realtobits.
package fpu_pkg;
  localparam logic [2:0] RM_RNE = 3'd0, RM_RTZ = 3'd1, RM_RDN = 3'd2,
                        RM_RUP = 3'd3, RM_RMM = 3'd4;
  localparam logic [4:0] FF_NV = 5'b10000, FF_DZ = 5'b01000, FF_OF = 5'b00100,
                        FF_UF = 5'b00010, FF_NX = 5'b00001;
endpackage

module fpu_s (
  input  logic [31:0] sa, sb,
  input  logic        sub,
  input  logic [2:0]  rmode,
  output logic [31:0] res,
  output logic [4:0]  ff
);
  import fpu_pkg::*;

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

  localparam logic [31:0] CANON_S_NAN = 32'h7FC00000;

  // round-and-pack single. mant is a 28-bit field where the leading 1 sits at
  // bit 26, the 23-bit fraction at [25:3], guard=F[2], round=F[1], sticky=F[0].
  // expb is the biased exponent (9 bits to detect overflow).
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
    // Round up adds 1 at the fraction LSB (bit 3), not bit 0 (sticky).
    if (round_up) Fp = F + 28'd8;
    frac = Fp[25:3];
    // Rounding can carry the all-ones fraction into the implicit bit (bit 26)
    // and beyond into bit 27 (e.g. 1.111..1 -> 10.000). Detect carry into bit 27
    // and renormalize by shifting right one, incrementing the exponent.
    if (round_up & Fp[27]) begin
      Fp = {Fp[27:1], 1'b0};
      e = e + 9'd1;
      frac = Fp[25:3];
    end
    // recompute dropped bits after increment for inexact
    g = (round_up) ? 1'b0 : F[2]; // approximation; use original for NX flag
    if (F[2] | F[1] | F[0]) f = f | FF_NX;
    // Overflow: exponent 0xFF (255) is inf/nan; max normal is 0xFE.
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
    // Underflow / subnormal flush-to-zero
    if (e[8] | (e <= 9'h001) & (F[26]==1'b0)) begin
      // leading bit gone below normal: treat as zero if e<=0
    end
    if ((~e[8]) && (e[8:0] < 9'h001) ) begin
      if (F[2] | F[1] | F[0]) f = f | FF_UF | FF_NX; else f = f | FF_UF;
      e = 9'd0; frac = 23'd0;
    end
    if (e[8]) begin
      // exponent went negative via subtraction: flush to zero
      if (F[2] | F[1] | F[0]) f = f | FF_UF | FF_NX; else f = f | FF_UF;
      e = 9'd0; frac = 23'd0;
    end
    ff = f;
    return {sgn, e[7:0], frac};
  endfunction

  // faddsub single
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
    // order by magnitude
    swap = (ea < eb) | ((ea == eb) & (ma < mb));
    if (swap) begin
      ebig = eb; esmall = ea; mbig = mb; msmall = ma;
      // a - b with |b|>|a|: result = -(b - a), sign = sgb ^ sub.
      sgout = sgb ^ sub;
    end else begin
      ebig = ea; esmall = eb; mbig = ma; msmall = mb; sgout = sga;
    end
    diff = ebig - esmall;
    // Place big mantissa: leading 1 (mbig[23]) at field bit 26.
    bigF = {1'b0, mbig, 3'b0};        // bit 26 = mbig[23]
    // Align small mantissa right by diff, capturing sticky.
    smallF = {1'b0, msmall, 3'b0};    // bit 26 = msmall[23]
    stk = 1'b0;
    if (diff >= 8'd28) begin
      stk = |msmall;
      smallF = 28'd0;
    end else begin
      // bits dropped below bit 0 of smallF = low 'diff' bits of smallF
      stk = |(smallF & ((28'hFFFFFFF) >> (28 - diff)));
      smallF = smallF >> diff;
    end
    // For effective subtraction, the guard/round bits of the aligned small
    // operand (positions [2:1]) are real mantissa bits and must participate
    // in the subtract so that borrows propagate correctly. The sticky bit
    // (OR of bits dropped below position 0) must ALSO be included in the
    // subtract — ORed into smallF[0] before the subtract — so that the
    // dropped fraction causes the correct borrow from the guard/round bits.
    //   This is required even when smallF is entirely shifted out (== 0): the
    // remaining sticky then represents a value 0 < f < 1 (in bit-0 units),
    // and bigF - f (with bigF[2:0] == 0) borrows through bits[2:0] producing
    // guard=1, round=1, sticky=1 — the mathematically correct truncated
    // result. Omitting the borrow would leave guard=0, round=0 (1 ULP high).
    //   After normalization the original sticky is ORed into sumF[0] to mark
    // inexactness. This is a no-op when there is no left shift (the consumed
    // sticky already set bit 0 via the 0->1 borrow) and restores the inexact
    // flag when a left shift zeroed bit 0.
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
      lead_bit = -1;
      for (sh = 27; sh >= 3; sh = sh - 1)
        if (sumF[sh] && lead_bit < 0) lead_bit = sh;
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

  logic [4:0] ff_i;
  assign res = faddsub_s(sa, sb, sub, rmode, ff_i);
  assign ff  = ff_i;

endmodule
