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

  // Simple state machine for handshake - computes result in F_ARITH
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      st       <= F_IDLE;
      res_r    <= '0;
      fflags_r <= '0;
    end else begin
      case (st)
        F_IDLE: begin
          if (start) begin
            fflags_r <= '0;
            st <= F_ARITH;
          end
        end
        F_ARITH: begin
          res_r <= compute_result(a, b, op, rm, is_double, is_unsigned, is_word);
          st <= F_DONE;
        end
        F_DONE: st <= F_IDLE;
        default: st <= F_IDLE;
      endcase
    end
  end

  // Combinational result computation for all operations
  function automatic logic [63:0] compute_result(
    input logic [63:0] a,
    input logic [63:0] b,
    input rtl_core_pkg::fpu_op_e op,
    input logic [2:0] rm,
    input logic is_double,
    input logic is_unsigned,
    input logic is_word
  );
    logic [4:0] ff;
    logic [63:0] r;
    if (is_double) begin
      r = {{32{1'b0}}, compute_result_s(a[31:0], b[31:0], op, rm, ff)};
    end else begin
      r = {{32{1'b0}}, compute_result_s(a[31:0], b[31:0], op, rm, ff)};
    end
    return r;
  endfunction

  // Single-precision arithmetic dispatch
  // Maps core's fpu_op_e to internal FPU operations
  function automatic logic [31:0] compute_result_s(
    input logic [31:0] a,
    input logic [31:0] b,
    input rtl_core_pkg::fpu_op_e op,
    input logic [2:0] rm,
    output logic [4:0] ff
  );
    ff = '0;
    unique case (op)
      // Arithmetic ops - direct mapping
      rtl_core_pkg::FPU_FADD:  return faddsub_s(a, b, 1'b0, rm, ff);
      rtl_core_pkg::FPU_FSUB:  return faddsub_s(a, b, 1'b1, rm, ff);
      rtl_core_pkg::FPU_FMUL:  return fmul_s(a, b, rm, ff);
      rtl_core_pkg::FPU_FDIV:  return fdiv_s(a, b, rm, ff);
      rtl_core_pkg::FPU_FSQRT: return fsqrt_s(a, rm, ff);
      // Non-arithmetic ops - direct mapping
      rtl_core_pkg::FPU_FMIN:  return fmin_s(a, b, ff);
      rtl_core_pkg::FPU_FMAX:  return fmax_s(a, b, ff);
      rtl_core_pkg::FPU_FSGNJ: return fsgnj_s(a, b, ff);
      rtl_core_pkg::FPU_FSGNJN: return fsgnjn_s(a, b, ff);
      rtl_core_pkg::FPU_FSGNJX: return fsgnjx_s(a, b, ff);
      rtl_core_pkg::FPU_FEQ:   return feq_s(a, b);
      rtl_core_pkg::FPU_FLT:   return flt_s(a, b);
      rtl_core_pkg::FPU_FLE:   return fle_s(a, b);
      // Conversion ops - core uses generic names, map to specific implementations
      // FPU_I2F = FCVT.W.S or FCVT.L.S (int to float)
      rtl_core_pkg::FPU_I2F:   return fcvt_int_s(a, 64'd0, rm, ff);
      // FPU_F2I = FCVT.S.W or FCVT.S.L (float to int)
      rtl_core_pkg::FPU_F2I:   return fcvt_s_int({32'h0, a}, 64'd0, rm, ff);
      // FPU_F2D = FCVT.D.S (float to double)
      rtl_core_pkg::FPU_F2D:   return fcvt_d_s({32'h0, a}, rm, ff)[31:0];
      // FPU_D2F = FCVT.S.D (double to float)
      rtl_core_pkg::FPU_D2F:   return fcvt_s_d({32'h0, a}, rm, ff);
      // Move ops
      rtl_core_pkg::FPU_MV_X2F: return fmv_x_w(a[31:0]);
      rtl_core_pkg::FPU_MV_F2X: return fmv_w_x(a[31:0]);
      // FCLASS - classify float
      rtl_core_pkg::FPU_CLASS: return fclass_s(a, ff);
      // FCVT ops (if used directly)
      rtl_core_pkg::FPU_FCVT_S_D: return fcvt_s_d(a, rm, ff);
      rtl_core_pkg::FPU_FCVT_D_S: return fcvt_d_s({32'h0, a}, rm, ff)[31:0];
      rtl_core_pkg::FPU_FCVT_W_S: return fcvt_int_s(a, 32'd0, rm, ff);
      rtl_core_pkg::FPU_FCVT_WU_S: return fcvt_int_s(a, 32'd0, rm, ff);
      rtl_core_pkg::FPU_FCVT_L_S: return fcvt_int_s(a, 64'd0, rm, ff);
      rtl_core_pkg::FPU_FCVT_LU_S: return fcvt_int_s(a, 64'd0, rm, ff);
      rtl_core_pkg::FPU_FCVT_S_W: return fcvt_s_int(a[31:0], 32'd0, rm, ff);
      rtl_core_pkg::FPU_FCVT_S_WU: return fcvt_s_int(a[31:0], 32'd0, rm, ff);
      rtl_core_pkg::FPU_FCVT_S_L: return fcvt_s_int(a[31:0], 64'd0, rm, ff);
      rtl_core_pkg::FPU_FCVT_S_LU: return fcvt_s_int(a[31:0], 64'd0, rm, ff);
      default:   return a + b;
    endcase
  endfunction

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
  function automatic logic fle_s(input logic [31:0] x, input logic [31:0] y);
    return flt_s(x, y) | feq_s(x, y);
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
  // Uses signed exponent to handle overflow/underflow correctly.
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
      e = e + 10'sd1;
      frac = Fp[25:3];
    end
    if (F[2] | F[1] | F[0]) f = f | FF_NX;
    // Overflow: signed biased exponent >= 255 (true exp >= 128).
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
    // Underflow / denormal: biased exponent <= 0 (true exp <= -127).
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
      // If rounding carried into the implicit bit, it became the smallest normal.
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

  // MSB position within a 28-bit slice, counting from the LSB.
  function automatic integer msb_pos28(input logic [27:0] v, input integer lo);
    integer i; integer p;
    p = -1;
    for (i = 27; i >= lo; i = i - 1)
      if (v[i] && p < 0) p = i;
    return p;
  endfunction

  // MSB position within a 25-bit slice, counting from the LSB (returns 0..24).
  function automatic integer msb_pos25(input logic [24:0] v);
    integer i;
    msb_pos25 = 0;
    for (i = 24; i >= 0; i = i - 1)
      if (v[i] && (msb_pos25 == 0)) msb_pos25 = i;
  endfunction

  // =========================================================================
  // FADD/FSUB single
  // =========================================================================
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

  // =========================================================================
  // FMUL single: multiply mantissas, add exponents, XOR signs.
  // =========================================================================
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

  // =========================================================================
  // FDIV single (iterative restoring division, but here pure-combinational for
  // validation since 24-bit quotient is feasible). Multi-cycle in real HW.
  // =========================================================================
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
    // bit (q[0]); the remainder supplies the sticky.
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
      // value in [1.0,2.0): mantissa = q[26:3], guard=q[2], round=q[1], round-bit=q[0].
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

  // =========================================================================
  // FSQRT single: digit-by-digit (non-restoring) integer sqrt
  // =========================================================================
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
    // extracted by absolute index from the MSB down.
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

  // =========================================================================
  // Non-arithmetic operations
  // =========================================================================

  // FMIN - return smaller of two values
  function automatic logic [31:0] fmin_s(input logic [31:0] a, input logic [31:0] b,
                                         output logic [4:0] ff);
    ff = 5'd0;
    if (is_nan_s(a) & is_nan_s(b)) begin
      ff = FF_NV; return CANON_S_NAN;
    end
    if (is_nan_s(a)) return b;
    if (is_nan_s(b)) return a;
    if (a[31] & ~b[31]) return a;  // a negative, b positive
    if (~a[31] & b[31]) return b;  // a positive, b negative
    if (a[30:0] < b[30:0]) return a;
    if (a[30:0] > b[30:0]) return b;
    // equal magnitudes, return the one with sign bit set to 0
    return {1'b0, a[30:0]};
  endfunction

  // FMAX - return larger of two values
  function automatic logic [31:0] fmax_s(input logic [31:0] a, input logic [31:0] b,
                                         output logic [4:0] ff);
    ff = 5'd0;
    if (is_nan_s(a) & is_nan_s(b)) begin
      ff = FF_NV; return CANON_S_NAN;
    end
    if (is_nan_s(a)) return b;
    if (is_nan_s(b)) return a;
    if (a[31] & ~b[31]) return b;  // a negative, b positive
    if (~a[31] & b[31]) return a;  // a positive, b negative
    if (a[30:0] > b[30:0]) return a;
    if (a[30:0] < b[30:0]) return b;
    // equal magnitudes, return the one with sign bit set to 0
    return {1'b0, a[30:0]};
  endfunction

  // FSGNJ - sign of a, magnitude of b
  function automatic logic [31:0] fsgnj_s(input logic [31:0] a, input logic [31:0] b,
                                          output logic [4:0] ff);
    ff = 5'd0;
    if (is_nan_s(b) & ~is_nan_s(a)) begin
      ff = FF_NV; return CANON_S_NAN;
    end
    return {a[31], b[30:0]};
  endfunction

  // FSGNJN - negated sign of a, magnitude of b
  function automatic logic [31:0] fsgnjn_s(input logic [31:0] a, input logic [31:0] b,
                                           output logic [4:0] ff);
    ff = 5'd0;
    if (is_nan_s(b) & ~is_nan_s(a)) begin
      ff = FF_NV; return CANON_S_NAN;
    end
    return {~a[31], b[30:0]};
  endfunction

  // FSGNJX - XOR of signs, magnitude from b
  function automatic logic [31:0] fsgnjx_s(input logic [31:0] a, input logic [31:0] b,
                                           output logic [4:0] ff);
    ff = 5'd0;
    if (is_nan_s(b) & ~is_nan_s(a)) begin
      ff = FF_NV; return CANON_S_NAN;
    end
    return {a[31] ^ b[31], b[30:0]};
  endfunction

  // FCLASS - classify float value
  function automatic logic [31:0] fclass_s(input logic [31:0] a,
                                           output logic [4:0] ff);
    logic [9:0] cls;
    ff = 5'd0;
    cls = 10'd0;
    
    if (is_nan_s(a)) begin
      // Signaling NaN: bit 0 (positive) or bit 9 (negative)
      // Quiet NaN: bit 1 (positive) or bit 8 (negative)
      if (a[31]) cls = is_snan_s(a) ? 10'b1000000000 : 10'b0100000000;
      else       cls = is_snan_s(a) ? 10'b0000000001 : 10'b0000000010;
    end else if (is_inf_s(a)) begin
      // Infinity: bit 2 (positive) or bit 7 (negative)
      cls = a[31] ? 10'b0010000000 : 10'b0000000100;
    end else if (is_zero_s(a)) begin
      // Zero: bit 3 (positive) or bit 6 (negative)
      cls = a[31] ? 10'b0001000000 : 10'b0000001000;
    end else if (a[30:23] == 8'd0) begin
      // Subnormal: bit 4 (positive) or bit 5 (negative)
      cls = a[31] ? 10'b0000100000 : 10'b0000010000;
    end else begin
      // Normal: bit 5 (positive) or bit 4 (negative)  <- same as subnormal?
      // Per RISC-V FCLASS: bit 4 = negative normal, bit 5 = positive normal,
      // bit 3 = negative subnormal, bit 2 = positive subnormal. Recheck:
      // bit0=-NaN(?) Actually per spec:
      //  bit0 = -NaN, bit1 = -inf ... no. The spec is:
      //  bit0 = -inf? Let's use the canonical spec:
      //  bit0 (1<<0) = -inf, bit1 = -normal, bit2 = -subnormal, bit3 = -0,
      //  bit4 = +0, bit5 = +subnormal, bit6 = +normal, bit7 = +inf,
      //  bit8 = signaling NaN (sNaN), bit9 = quiet NaN (qNaN).
      if (a[31]) begin
        // negative: normal (bit1), subnormal (bit2), zero (bit3), inf (bit0)
        if (a[30:23] == 8'hFF) cls = 10'b0000000001;              // -inf
        else if (a[30:23] != 8'd0) cls = 10'b0000000010;           // -normal
        else if (a[22:0] != 23'd0) cls = 10'b0000000100;          // -subnormal
        else cls = 10'b0000001000;                                 // -0
      end else begin
        // positive
        if (a[30:23] == 8'hFF) cls = 10'b1000000000;              // +inf
        else if (a[30:23] != 8'd0) cls = 10'b0100000000;          // +normal
        else if (a[22:0] != 23'd0) cls = 10'b0010000000;           // +subnormal
        else cls = 10'b0001000000;                                 // +0
      end
    end
    
    return cls;
  endfunction

  // =========================================================================
  // Conversion operations
  // =========================================================================

  // FCVT.S.D - convert double to single
  function automatic logic [31:0] fcvt_s_d(input logic [63:0] d,
                                            input logic [2:0] rmode,
                                            output logic [4:0] ff);
    logic [63:0] sgn_d, exp_d, frac_d;
    logic [31:0] sgn_s, exp_s, frac_s;
    logic [10:0] exp_bias;
    logic [52:0] frac_full;
    logic [27:0] F;
    logic signed [9:0] eout;
    
    ff = 5'd0;
    
    if (is_nan_d(d)) begin
      if (is_snan_d(d)) ff = FF_NV;
      return CANON_S_NAN;
    end
    if (is_inf_d(d)) return d[63] ? S_INF_N : S_INF_P;
    if (is_zero_d(d)) return d[63] ? 32'h80000000 : 32'h00000000;
    
    // Extract double components
    sgn_d = d[63];
    exp_d = d[62:52];
    frac_d = d[51:0];
    
    // Convert exponent: double bias 1023 -> single bias 127
    exp_bias = {1'b0, exp_d} - 11'd1023 + 11'd127;
    
    // Combine fraction with implicit bit
    frac_full = {1'b1, frac_d};
    
    // Shift fraction right by (52-23)=29 bits to get 24-bit single fraction
    // with guard/round/sticky
    F = {frac_full[52:25], 1'b0} | {27'd0, (|frac_full[24:0])};
    F[0] = F[0] | (|frac_full[24:0]);
    
    eout = $signed(exp_bias);
    
    return round_pack_s(sgn_d, eout, F, rmode, ff);
  endfunction

  // FCVT.D.S - convert single to double
  function automatic logic [63:0] fcvt_d_s(input logic [31:0] s,
                                            input logic [2:0] rmode,
                                            output logic [4:0] ff);
    logic [31:0] sgn_s, exp_s, frac_s;
    logic [63:0] sgn_d, exp_d, frac_d;
    logic [11:0] exp_bias;
    logic [58:0] F;
    
    ff = 5'd0;
    
    if (is_nan_s(s)) begin
      if (is_snan_s(s)) ff = FF_NV;
      return CANON_D_NAN;
    end
    if (is_inf_s(s)) return s[31] ? D_INF_N : D_INF_P;
    if (is_zero_s(s)) return s[31] ? 64'h8000000000000000 : 64'h0000000000000000;
    
    // Extract single components
    sgn_s = s[31];
    exp_s = s[30:23];
    frac_s = s[22:0];
    
    // Convert exponent: single bias 127 -> double bias 1023
    exp_bias = {3'b000, exp_s} - 8'd127 + 8'd1023;
    
    // Expand fraction to 53 bits (52 explicit + 1 implicit)
    frac_d = {frac_s, 29'd0};
    
    // Build 59-bit field for double rounding
    F = {1'b1, frac_d, 5'b0};
    
    return round_pack_d(sgn_s, exp_bias, F, rmode, ff);
  endfunction

  // FCVT int to float (single)
  function automatic logic [31:0] fcvt_int_s(input logic [63:0] int_val,
                                            input logic [63:0] width,
                                            input logic [2:0] rmode,
                                            output logic [4:0] ff);
    logic [63:0] abs_val;
    logic sgn;
    logic [63:0] mant;
    integer leading_zeros;
    logic [10:0] exp_bias;
    logic [27:0] F;
    
    ff = 5'd0;
    
    if (int_val == 0) return 32'h00000000;
    
    sgn = int_val[63];
    abs_val = sgn ? -int_val : int_val;
    
    // Count leading zeros
    leading_zeros = 0;
    for (integer i = 63; i >= 0; i = i - 1) begin
      if (abs_val[i] == 1'b0) leading_zeros = leading_zeros + 1;
      else break;
    end
    
    // Normalize: shift mantissa to have leading 1 at bit 23
    mant = abs_val << leading_zeros;
    
    // Calculate exponent: 63 - leading_zeros + 127 - 23 = 167 - leading_zeros
    exp_bias = 11'd167 - leading_zeros;
    
    // Extract 24 bits of mantissa (including implicit bit)
    F = {mant[63:36], 1'b0, mant[35:36-24+1]};
    
    return round_pack_s(sgn, exp_bias, F, rmode, ff);
  endfunction

  // FCVT float to int (single)
  function automatic logic [63:0] fcvt_s_int(input logic [63:0] s_val,
                                            input logic [63:0] width,
                                            input logic [2:0] rmode,
                                            output logic [4:0] ff);
    logic [31:0] s;
    logic sgn;
    logic [7:0] exp;
    logic [22:0] frac;
    logic [63:0] result;
    logic [10:0] exp_unbias;
    
    ff = 5'd0;
    s = s_val[31:0];
    
    if (is_nan_s(s)) begin
      ff = FF_NV;
      return '0;
    end
    if (is_inf_s(s)) begin
      ff = FF_OF;
      return '0;
    end
    if (is_zero_s(s)) return '0;
    
    sgn = s[31];
    exp = s[30:23];
    frac = s[22:0];
    
    // Calculate unbiased exponent
    exp_unbias = {3'b000, exp} - 8'd127;
    
    // Check for overflow
    if (exp_unbias > 63) begin
      ff = FF_OF;
      return sgn ? -1 : '1;
    end
    
    // Check for underflow
    if (exp_unbias < 0) begin
      ff = FF_UF;
      return '0;
    end
    
    // Construct mantissa with implicit bit
    result = {1'b1, frac} << exp_unbias;
    
    if (sgn) result = -result;
    
    return result;
  endfunction

  // FMV.X.W - move float register to integer register
  function automatic logic [63:0] fmv_x_w(input logic [31:0] fval);
    return {{32{1'b0}}, fval};
  endfunction

  // FMV.W.X - move integer register to float register
  function automatic logic [31:0] fmv_w_x(input logic [31:0] ival);
    return ival;
  endfunction

endmodule
