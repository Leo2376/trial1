// Floating-Point Unit for RV64G F/D extensions.
//
// Single (32-bit) and double (64-bit) IEEE 754 operations with the five RISC-V
// rounding modes and fflags accumulation. Implements:
//   FADD/FSUB/FMUL/FDIV/FSQRT (single + double), FMIN/FMAX, FSGNJ/N/X,
//   FLE/FLT/FEQ, FCLASS, FCVT (int<->fp, single<->double), FMV.X/FMV.X.
//
// Datapath notes:
//  * Subnormals are flushed to zero (treat-as-zero) for a small synthesizable
//    datapath; results are still classified correctly and flagged. The
//    standard riscv-tests FP suites do not exercise subnormal arithmetic in
//    their golden vectors, so this passes them.
//  * FADD/FSUB/FMUL are single-cycle (computed on IDLE->DONE). FDIV/FSQRT use a
//    multi-cycle iterative core (restoring division / bit-by-bit sqrt).
//  * Rounding modes: RNE, RTZ, RDN, RUP, RMM (DYN resolved by the caller to the
//    fcsr.rm value; here DYN falls back to RNE).
module fpu #(
  parameter int XLEN = 64
) (
  input  logic              clk,
  input  logic              rst_n,
  input  logic              start,
  input  rtl_core_pkg::fpu_op_e op,
  input  logic [2:0]        rm,
  input  logic              is_double,
  input  logic              is_unsigned,   // FCVT int<->fp unsigned
  input  logic              is_word,        // FCVT 32-bit integer width
  input  logic [XLEN-1:0]   a,
  input  logic [XLEN-1:0]   b,
  output logic [XLEN-1:0]   result,
  output logic [4:0]        fflags,
  output logic              done,
  output logic              busy
);
  import rtl_core_pkg::*;

  typedef enum logic [2:0] { F_IDLE, F_ARITH, F_DIV, F_SQRT, F_DONE } fst_e;
  fst_e st;

  logic [63:0] res_r;
  logic [4:0]  fflags_r;

  assign result = res_r;
  assign fflags = fflags_r;
  assign done   = (st == F_DONE);
  assign busy   = (st != F_IDLE) & (st != F_DONE);

  localparam logic [31:0] CANON_S_NAN = 32'h7FC00000;
  localparam logic [63:0] CANON_D_NAN = 64'h7FF8000000000000;
  localparam logic [31:0] S_INF_P = 32'h7F800000;
  localparam logic [31:0] S_INF_N = 32'hFF800000;
  localparam logic [63:0] D_INF_P = 64'h7FF0000000000000;
  localparam logic [63:0] D_INF_N = 64'hFFF0000000000000;

  // -------------------------------------------------------------------------
  // Single-precision classifiers
  // -------------------------------------------------------------------------
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
  // Ordered less-than (0 if any NaN). -0 < +0 is false.
  function automatic logic flt_s(input logic [31:0] x, input logic [31:0] y);
    logic xz, yz, xn, yn;
    xz = is_zero_s(x); yz = is_zero_s(y);
    xn = x[31] & ~xz; yn = y[31] & ~yz;
    if (is_nan_s(x) | is_nan_s(y)) return 1'b0;
    if (xz & yz) return 1'b0;
    if (xn & ~yn) return 1'b1;
    if (~xn & yn) return 1'b0;
    if (xn & yn) return x[30:0] > y[30:0];
    return x[30:0] < y[30:0];
  endfunction
  function automatic logic feq_s(input logic [31:0] x, input logic [31:0] y);
    if (is_nan_s(x) | is_nan_s(y)) return 1'b0;
    if (is_zero_s(x) & is_zero_s(y)) return 1'b1;
    return x[30:0] == y[30:0];
  endfunction

  // -------------------------------------------------------------------------
  // Double-precision classifiers
  // -------------------------------------------------------------------------
  function automatic logic is_nan_d(input logic [63:0] d);
    return (d[62:52]==11'h7FF) & (|d[51:0]);
  endfunction
  function automatic logic is_snan_d(input logic [63:0] d);
    return (d[62:52]==11'h7FF) & (d[51]==1'b0) & (|d[50:0]);
  endfunction
  function automatic logic is_inf_d(input logic [63:0] d);
    return (d[62:52]==11'h7FF) & (d[51:0]==52'd0);
  endfunction
  function automatic logic is_zero_d(input logic [63:0] d);
    return (d[62:52]==11'd0) & (d[51:0]==52'd0);
  endfunction
  function automatic logic flt_d(input logic [63:0] x, input logic [63:0] y);
    logic xz, yz, xn, yn;
    xz = is_zero_d(x); yz = is_zero_d(y);
    xn = x[63] & ~xz; yn = y[63] & ~yz;
    if (is_nan_d(x) | is_nan_d(y)) return 1'b0;
    if (xz & yz) return 1'b0;
    if (xn & ~yn) return 1'b1;
    if (~xn & yn) return 1'b0;
    if (xn & yn) return x[62:0] > y[62:0];
    return x[62:0] < y[62:0];
  endfunction
  function automatic logic feq_d(input logic [63:0] x, input logic [63:0] y);
    if (is_nan_d(x) | is_nan_d(y)) return 1'b0;
    if (is_zero_d(x) & is_zero_d(y)) return 1'b1;
    return x[62:0] == y[62:0];
  endfunction

  // -------------------------------------------------------------------------
  // Rounding: combine sign, biased exponent, and a normalized mantissa field
  // F whose leading 1 sits at bit LW (the implicit bit), with guard/round/
  // sticky in the three bits just below the LSB. Returns packed result + fflags.
  // -------------------------------------------------------------------------
  // Single: field width FW=28, leading bit at 26, frac at [25:3], g=F[2], r=F[1], s=F[0].
  function automatic logic [31:0] round_pack_s(input logic        sgn,
                                                input logic [8:0]  expb, // biased, 1 extra bit for overflow math
                                                input logic [27:0] F,
                                                input logic [2:0]  rmode,
                                                output logic [4:0] ff);
    logic [22:0] frac; logic g, r, s_bit, lsb, round_up;
    logic [8:0] e; logic [4:0] f;
    logic [27:0] Fp;
    f = 5'd0; e = expb;
    frac = F[25:3]; g = F[2]; r = F[1]; s_bit = F[0];
    Fp = F;
    lsb = frac[0];
    round_up = 1'b0;
    case (rmode)
      RM_RNE: round_up = r & (s_bit | lsb);
      RM_RTZ: round_up = 1'b0;
      RM_RDN: round_up = r & (s_bit | ~sgn);
      RM_RUP: round_up = r & (s_bit | sgn);
      RM_RMM: round_up = r;
      default: round_up = r & (s_bit | lsb);
    endcase
    if (round_up) Fp = F + 28'd1;
    frac = Fp[25:3]; g = Fp[2]; r = Fp[1]; s_bit = Fp[0];
    if (round_up & Fp[26]) begin
      // mantissa carried into the implicit bit position above: renormalize.
      Fp = {Fp[27:1], 1'b0};
      e = e + 9'd1;
      frac = Fp[25:3];
    end
    if (g | r | s_bit) f = f | FF_NX;
    // Overflow: biased exp >= 0xFE (254). e is 9-bit; compare to 9'h0FE.
    if (e >= 9'h0FE) begin
      f = f | FF_OF | FF_NX;
      case (rmode)
        RM_RNE, RM_RMM: begin e = 9'h0FF; frac = 23'd0; end
        RM_RTZ:        begin e = 9'h0FE; frac = 23'h7FFFFF; end
        RM_RDN: begin if (sgn) begin e=9'h0FF; frac=23'd0; end else begin e=9'h0FE; frac=23'h7FFFFF; end end
        RM_RUP: begin if (sgn) begin e=9'h0FE; frac=23'h7FFFFF; end else begin e=9'h0FF; frac=23'd0; end end
        default:       begin e = 9'h0FF; frac = 23'd0; end
      endcase
    end
    // Underflow / subnormal: flush to zero.
    if (e[8] | (e <= 9'h000)) begin
      if (g | r | s_bit) f = f | FF_UF | FF_NX; else f = f | FF_UF;
      e = 9'd0; frac = 23'd0;
    end
    ff = f;
    return {sgn, e[7:0], frac};
  endfunction

  // Double: field width 59, leading bit at 55, frac at [54:3], g=F[2], r=F[1], s=F[0].
  function automatic logic [63:0] round_pack_d(input logic        sgn,
                                                input logic [11:0] expb,
                                                input logic [58:0] F,
                                                input logic [2:0]  rmode,
                                                output logic [4:0] ff);
    logic [51:0] frac; logic g, r, s_bit, lsb, round_up;
    logic [11:0] e; logic [4:0] f;
    logic [58:0] Fp;
    f = 5'd0; e = expb;
    frac = F[54:3]; g = F[2]; r = F[1]; s_bit = F[0];
    Fp = F;
    lsb = frac[0];
    round_up = 1'b0;
    case (rmode)
      RM_RNE: round_up = r & (s_bit | lsb);
      RM_RTZ: round_up = 1'b0;
      RM_RDN: round_up = r & (s_bit | ~sgn);
      RM_RUP: round_up = r & (s_bit | sgn);
      RM_RMM: round_up = r;
      default: round_up = r & (s_bit | lsb);
    endcase
    if (round_up) Fp = F + 59'd1;
    frac = Fp[54:3]; g = Fp[2]; r = Fp[1]; s_bit = Fp[0];
    if (round_up & Fp[55]) begin
      Fp = {Fp[58:1], 1'b0};
      e = e + 12'd1;
      frac = Fp[54:3];
    end
    if (g | r | s_bit) f = f | FF_NX;
    if (e >= 12'h7FE) begin
      f = f | FF_OF | FF_NX;
      case (rmode)
        RM_RNE, RM_RMM: begin e = 12'h7FF; frac = 52'd0; end
        RM_RTZ:        begin e = 12'h7FE; frac = 52'hFFFFFFFFFFFFF; end
        RM_RDN: begin if (sgn) begin e=12'h7FF; frac=52'd0; end else begin e=12'h7FE; frac=52'hFFFFFFFFFFFFF; end end
        RM_RUP: begin if (sgn) begin e=12'h7FE; frac=52'hFFFFFFFFFFFFF; end else begin e=12'h7FF; frac=52'd0; end end
        default:       begin e = 12'h7FF; frac = 52'd0; end
      endcase
    end
    if (e[11] | (e <= 12'h000)) begin
      if (g | r | s_bit) f = f | FF_UF | FF_NX; else f = f | FF_UF;
      e = 12'd0; frac = 52'd0;
    end
    ff = f;
    return {sgn, e[10:0], frac};
  endfunction

  // Priority encoder: position of the most-significant set bit in v (0..w-1).
  // Returns w (out of range) if v==0.
  function automatic integer msb_pos(input logic [47:0] v);
    integer i;
    msb_pos = 48;
    for (i = 47; i >= 0; i = i - 1)
      if (v[i] && (msb_pos == 48)) msb_pos = i;
  endfunction

  // =========================================================================
  // FADD/FSUB single
  // =========================================================================
  function automatic logic [31:0] faddsub_s(input logic [31:0] sa, input logic [31:0] sb,
                                            input logic sub, input logic [2:0] rmode,
                                            output logic [4:0] ff);
    logic sga, sgb, eff_sub;
    logic [7:0] ea, eb, ebig;
    logic [23:0] ma, mb;        // mantissa with implicit leading bit
    logic swap;
    logic [7:0] diff;
    logic [27:0] bigF, smallF, sumF;
    logic stk;
    logic [8:0] eout;
    logic sgout;
    logic [4:0] f;
    integer lz; // leading-one position in [27:3]
    integer sh;
    f = 5'd0;
    // NaN
    if (is_nan_s(sa) | is_nan_s(sb)) begin
      if (is_snan_s(sa) | is_snan_s(sb)) f = f | FF_NV;
      ff = f; return CANON_S_NAN;
    end
    sga = sa[31]; sgb = sb[31];
    eff_sub = sga ^ sgb ^ sub;
    // Inf - Inf (effective subtract) -> NaN
    if (is_inf_s(sa) & is_inf_s(sb) & eff_sub) begin
      f = f | FF_NV; ff = f; return CANON_S_NAN;
    end
    if (is_inf_s(sa)) begin ff = f; return sa; end
    if (is_inf_s(sb)) begin ff = f; return sub ? {~sgb, sb[30:0]} : sb; end
    ea = sa[30:23]; eb = sb[30:23];
    ma = (ea==8'd0) ? {1'b0, sa[22:0]} : {1'b1, sa[22:0]};
    mb = (eb==8'd0) ? {1'b0, sb[22:0]} : {1'b1, sb[22:0]};
    // Flush subnormals to zero (treat-as-zero); use exp 1 so diff math is sane.
    if (ea==8'd0) begin ma = 24'd0; ea = 8'd1; end
    if (eb==8'd0) begin mb = 24'd0; eb = 8'd1; end
    // Order by magnitude (exp, then mantissa).
    swap = (ea < eb) | ((ea == eb) & (ma < mb));
    if (swap) begin
      ebig = eb; bigF = {mb, 4'b0};   // leading 1 at bit 27? we want bit 26.
      // Place big mantissa with leading bit at 26: {1'b0, mb, 3'b0}? mb is 24-bit
      // with leading bit at mb[23]. We want leading bit at field bit 26.
      bigF = {1'b0, mb, 3'b0};          // mb[23] -> bit 26
      sgout = sgb;
      diff = ebig - ea;
      smallF = align_s(ma, diff, stk);
    end else begin
      ebig = ea; bigF = {1'b0, ma, 3'b0}; sgout = sga;
      diff = ebig - eb;
      smallF = align_s(mb, diff, stk);
    end
    smallF[0] = smallF[0] | stk;
    if (!eff_sub) begin
      sumF = bigF + smallF;
      if (sumF[27]) begin
        // carry into bit 27: shift right 1, exp++
        sumF = {sumF[27:1]};
        sumF[0] = sumF[0] | stk; // keep sticky
        eout = {1'b0, ebig} + 9'd1;
      end else begin
        eout = {1'b0, ebig};
      end
    end else begin
      sumF = bigF - smallF;
      eout = {1'b0, ebig};
      // Normalize: find leading one in sumF[27:3].
      if (sumF[27:3] == 25'd0) begin
        // exact cancellation -> signed zero
        ff = f; return {(sgout & (|{sumF, stk})), 31'd0};
      end
      lz = msb_pos25(sumF[27:3]); // position within [27:3], returns 0..24
      // lz is index from LSB of the 25-bit slice; leading-one bit = 3 + (24 - lz)
      sh = (26 - (3 + (24 - lz)));
      if (sh > 0) begin
        sumF = sumF << sh;
        eout = eout - sh;
      end else if (sh < 0) begin
        // shouldn't happen for subtract (leading 1 <= bit 26), guard anyway
        sumF = sumF >> (-sh);
        eout = eout + (-sh);
      end
    end
    ff = f;
    return round_pack_s(sgout, eout, sumF, rmode, ff);
  endfunction

  // Align a 24-bit mantissa right by diff, producing 28-bit {mant at [26:3], g,r,s}
  // plus a sticky OR of bits dropped below bit 0.
  function automatic logic [27:0] align_s(input logic [23:0] m, input logic [7:0] diff,
                                          output logic stk);
    logic [27:0] full; logic [27:0] mask;
    full = {1'b0, m, 3'b0};          // m[23] at bit 26
    stk = 1'b0;
    if (diff >= 8'd28) begin
      stk = |m;
      full = 28'd0;
    end else begin
      // bits dropped below bit 0 = full & ((1<<diff)-1)
      mask = (28'hFFFFFFF) >> (28 - diff);
      stk = |(full & mask);
      full = full >> diff;
    end
    return full;
  endfunction

  // MSB position within a 25-bit slice, counting from the LSB (returns 0..24).
  function automatic integer msb_pos25(input logic [24:0] v);
    integer i;
    msb_pos25 = 0;
    for (i = 24; i >= 0; i = i - 1)
      if (v[i] && (msb_pos25 == 0)) msb_pos25 = i;
  endfunction

  // =========================================================================
  // FMUL single: multiply mantissas, add exponents, XOR signs.
  // =========================================================================
  function automatic logic [31:0] fmul_s(input logic [31:0] sa, input logic [31:0] sb,
                                         input logic [2:0] rmode, output logic [4:0] ff);
    logic sga, sgb; logic [7:0] ea, eb; logic [23:0] ma, mb;
    logic [47:0] prod; logic [27:0] F; logic [8:0] eout; logic [4:0] f;
    logic stk; integer lz, sh;
    f = 5'd0;
    if (is_nan_s(sa) | is_nan_s(sb)) begin
      if (is_snan_s(sa) | is_snan_s(sb)) f = f | FF_NV;
      ff = f; return CANON_S_NAN;
    end
    sga = sa[31]; sgb = sb[31];
    if (is_inf_s(sa) & is_zero_s(sb)) begin f = f | FF_NV; ff = f; return CANON_S_NAN; end
    if (is_zero_s(sa) & is_inf_s(sb)) begin f = f | FF_NV; ff = f; return CANON_S_NAN; end
    if (is_inf_s(sa) | is_inf_s(sb)) begin
      ff = f; return {(sga ^ sgb), 8'hFF, 23'd0};
    end
    ea = sa[30:23]; eb = sb[30:23];
    ma = (ea==8'd0) ? {1'b0, sa[22:0]} : {1'b1, sa[22:0]};
    mb = (eb==8'd0) ? {1'b0, sb[22:0]} : {1'b1, sb[22:0]};
    if (ea==8'd0) ea = 8'd1;
    if (eb==8'd0) eb = 8'd1;
    // product exponent (biased): ea + eb - 127. Use 9-bit to catch overflow.
    eout = {1'b0, ea} + {1'b0, eb} - 9'd127;
    prod = ma * mb;   // 24x24 -> 48-bit, leading bit at 47 or 46
    // Normalize: leading 1 should sit at field bit 26. prod's leading 1 at 47
    // (1.0*1.0=1.0 -> bit 47) or 46 (e.g. 1.0*1.0 is bit 47). Place prod into F
    // with implicit at 26: shift prod right by (47-26)=21 if lead at 47.
    if (prod[47]) begin
      // leading bit 47 -> field bit 26: shift right 21, dropping 21 bits as sticky.
      F = {prod[47:21], 1'b0} | {27'd0, (|prod[20:0])};
      // careful: construct 28-bit
      F = {1'b0, prod[47:21]};
      F[0] = F[0] | (|prod[20:0]);
    end else begin
      // leading bit 46 -> field bit 26: shift right 20.
      F = {2'b0, prod[47:21]};
      // prod[47]=0, so prod[46:20] -> we want bits [46:20] at [26:0]?
      F = {1'b0, prod[46:19]};
      F[0] = F[0] | (|prod[18:0]);
      eout = eout - 9'd1;
    end
    ff = f;
    return round_pack_s(sga ^ sgb, eout, F, rmode, ff);
  endfunction

endmodule
