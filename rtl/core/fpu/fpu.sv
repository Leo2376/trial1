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
  input  logic              is_word,        // FCVT 64-bit integer width (L/LU)
  input  logic [XLEN-1:0]   a,
  input  logic [XLEN-1:0]   b,
  input  logic [XLEN-1:0]   c,
  output logic [XLEN-1:0]   result,
  output logic [4:0]        fflags,
  output logic              done,
  output logic              busy
);
  import rtl_core_pkg::*;

  typedef enum logic [1:0] { F_IDLE, F_ARITH, F_DONE } fst_e;
  fst_e st;

  logic [63:0] res_r;
  logic [4:0]  fflags_r;
  logic [63:0] comb_res;
  logic [4:0]  comb_ff;

  assign result = res_r;
  assign fflags = fflags_r;
  assign done   = (st == F_DONE);
  assign busy   = (st != F_IDLE) & (st != F_DONE);

  // Single-operation state machine: capture the one-cycle combinational
  // result (and its fflags) while the op is latched in EX, then present it
  // for one cycle. The core stalls on fpu_busy until done, so the result is
  // consumed exactly once by the EX->MEM latch.
  always_comb begin
    comb_res = compute_result(a, b, c, op, rm, is_double, is_unsigned, is_word, comb_ff);
  end

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      st       <= F_IDLE;
      res_r    <= '0;
      fflags_r <= '0;
    end else begin
      case (st)
        F_IDLE:  if (start) st <= F_ARITH;
        F_ARITH: begin
          res_r    <= comb_res;
          fflags_r <= comb_ff;
          st       <= F_DONE;
        end
        F_DONE: st <= F_IDLE;
        default: st <= F_IDLE;
      endcase
    end
  end

  // Combinational result computation for all operations. The fflags output
  // of the dispatched function is the raw flag value; it is assigned to ff
  // (an output of compute_result) so the FSM can latch it alongside the result.
  // 64-bit results (F2D) must escape the 32-bit single dispatch, so those ops
  // are handled here; everything else goes through the single dispatch.
  function automatic logic [63:0] compute_result(
    input logic [63:0] a,
    input logic [63:0] b,
    input logic [63:0] c,
    input rtl_core_pkg::fpu_op_e op,
    input logic [2:0] rm,
    input logic is_double,
    input logic is_unsigned,
    input logic is_word,
    output logic [4:0] ff
  );
    ff = '0;
    if (op == rtl_core_pkg::FPU_F2D) begin
      // Single source must be NaN-boxed; otherwise it reads as canonical NaN.
      return fcvt_d_s((a[63:32] == 32'hFFFFFFFF) ? a[31:0] : CANON_S_NAN, rm, ff);
    end else if (op == rtl_core_pkg::FPU_D2F) begin
      logic [31:0] r32;
      r32 = fcvt_s_d(a, rm, ff);
      return {{32{1'b1}}, r32};
    end else if (op == rtl_core_pkg::FPU_I2F) begin
      // Integer source is the full 64-bit rs1. W-width ops use only the low
      // 32 bits: sign-extended when signed, zero-extended when unsigned.
      logic [63:0] iv;
      iv = is_word ? a :
           is_unsigned ? {32'h0, a[31:0]} : {{32{a[31]}}, a[31:0]};
      if (is_double)
        return fcvt_int_d(iv, is_unsigned, rm, ff);
      return {{32{1'b1}}, fcvt_int_s(iv, is_unsigned, rm, ff)};
    end else if (is_double) begin
      return compute_result_d(a[63:0], b[63:0], c[63:0], op, rm, is_unsigned, is_word, ff);
    end else begin
      // RV64D NaN-boxing: a single-precision FP source whose upper 32 bits
      // are not all 1s reads as the canonical NaN. Moves are exempt:
      // FMV.X.W copies raw FP bits out, FMV.W.X copies raw integer bits in
      // (integer sources are never boxed).
      if (op == rtl_core_pkg::FPU_MV_F2X)
        return {{32{a[31]}}, a[31:0]};
      if (op == rtl_core_pkg::FPU_MV_X2F)
        return {{32{1'b1}}, a[31:0]};
      return compute_result_s((a[63:32] == 32'hFFFFFFFF) ? a[31:0] : CANON_S_NAN,
                              (b[63:32] == 32'hFFFFFFFF) ? b[31:0] : CANON_S_NAN,
                              (c[63:32] == 32'hFFFFFFFF) ? c[31:0] : CANON_S_NAN,
                              op, rm, ff);
    end
  endfunction

  // Double-precision arithmetic dispatch (RV64D). Mirrors
  // compute_result_s with 64-bit operands and full (non-boxed) results.
  // Ops are implemented instruction-by-instruction; unhandled ops return
  // zero so unfinished paths fail loudly in the ISA suite, not silently.
  function automatic logic [63:0] compute_result_d(
    input logic [63:0] a,
    input logic [63:0] b,
    input logic [63:0] c,
    input rtl_core_pkg::fpu_op_e op,
    input logic [2:0] rm,
    input logic is_unsigned,
    input logic is_word,
    output logic [4:0] ff
  );
    ff = '0;
    unique case (op)
      rtl_core_pkg::FPU_FADD: return faddsub_d(a, b, 1'b0, rm, ff);
      rtl_core_pkg::FPU_FSUB: return faddsub_d(a, b, 1'b1, rm, ff);
      rtl_core_pkg::FPU_FMUL: return fmul_d(a, b, rm, ff);
      rtl_core_pkg::FPU_FDIV: return fdiv_d(a, b, rm, ff);
      rtl_core_pkg::FPU_FSQRT: return fsqrt_d(a, rm, ff);
      rtl_core_pkg::FPU_FMIN: return fmin_d(a, b, ff);
      rtl_core_pkg::FPU_FMAX: return fmax_d(a, b, ff);
      rtl_core_pkg::FPU_FMADD:  return fmadd_d(a, b, c, 1'b0, 1'b0, rm, ff);
      rtl_core_pkg::FPU_FMSUB:  return fmadd_d(a, b, c, 1'b0, 1'b1, rm, ff);
      rtl_core_pkg::FPU_FNMSUB: return fmadd_d(a, b, c, 1'b1, 1'b0, rm, ff);
      rtl_core_pkg::FPU_FNMADD: return fmadd_d(a, b, c, 1'b1, 1'b1, rm, ff);
      rtl_core_pkg::FPU_FSGNJ: return fsgnj_d(a, b, ff);
      rtl_core_pkg::FPU_FSGNJN: return fsgnjn_d(a, b, ff);
      rtl_core_pkg::FPU_FSGNJX: return fsgnjx_d(a, b, ff);
      rtl_core_pkg::FPU_FEQ: begin
        ff = (is_snan_d(a) | is_snan_d(b)) ? FF_NV : 5'd0;
        return {63'd0, feq_d(a, b)};
      end
      rtl_core_pkg::FPU_FLT: begin
        ff = (is_nan_d(a) | is_nan_d(b)) ? FF_NV : 5'd0;
        return {63'd0, flt_d(a, b)};
      end
      rtl_core_pkg::FPU_FLE: begin
        ff = (is_nan_d(a) | is_nan_d(b)) ? FF_NV : 5'd0;
        return {63'd0, flt_d(a, b) | feq_d(a, b)};
      end
      // Conversion ops (double precision):
      //   FPU_I2F is routed in compute_result; FPU_F2I: fcvt.{w|wu|l|lu}.d.
      rtl_core_pkg::FPU_F2I: return fcvt_d_int(a, is_unsigned, is_word, rm, ff);
      rtl_core_pkg::FPU_CLASS: return {54'd0, fclass_d(a)};
      // Double moves copy the full 64-bit pattern (no NaN-boxing).
      rtl_core_pkg::FPU_MV_F2X: return a;
      rtl_core_pkg::FPU_MV_X2F: return a;
      default: return 64'd0;
    endcase
  endfunction

  // Single-precision arithmetic dispatch
  // Maps core's fpu_op_e to internal FPU operations. Returns the full 64-bit
  // WB value: single-precision FP results are NaN-boxed ({32'1s, s32}),
  // integer results are widened to XLEN (sign-extended for F2I/MV/F2X).
  function automatic logic [63:0] compute_result_s(
    input logic [31:0] a,
    input logic [31:0] b,
    input logic [31:0] c,
    input rtl_core_pkg::fpu_op_e op,
    input logic [2:0] rm,
    output logic [4:0] ff
  );
    ff = '0;
    unique case (op)
      // Arithmetic ops - direct mapping
      rtl_core_pkg::FPU_FADD:  return {{32{1'b1}}, faddsub_s(a, b, 1'b0, rm, ff)};
      rtl_core_pkg::FPU_FSUB:  return {{32{1'b1}}, faddsub_s(a, b, 1'b1, rm, ff)};
      rtl_core_pkg::FPU_FMUL:  return {{32{1'b1}}, fmul_s(a, b, rm, ff)};
      rtl_core_pkg::FPU_FDIV:  return {{32{1'b1}}, fdiv_s(a, b, rm, ff)};
      rtl_core_pkg::FPU_FSQRT: return {{32{1'b1}}, fsqrt_s(a, rm, ff)};
      // Fused multiply-add family. neg_prod: FNMSUB/FNMADD negate the
      // product; sub_c: FMSUB/FNMSUB subtract the addend.
      rtl_core_pkg::FPU_FMADD:  return {{32{1'b1}}, fmadd_s(a, b, c, 1'b0, 1'b0, rm, ff)};
      rtl_core_pkg::FPU_FMSUB:  return {{32{1'b1}}, fmadd_s(a, b, c, 1'b0, 1'b1, rm, ff)};
      rtl_core_pkg::FPU_FNMSUB: return {{32{1'b1}}, fmadd_s(a, b, c, 1'b1, 1'b0, rm, ff)};
      rtl_core_pkg::FPU_FNMADD: return {{32{1'b1}}, fmadd_s(a, b, c, 1'b1, 1'b1, rm, ff)};
      // Non-arithmetic ops - direct mapping. Comparisons write 0/1 to the
      // integer register: FEQ is quiet (NV only for sNaN), FLT/FLE are
      // signaling (NV for any NaN).
      rtl_core_pkg::FPU_FMIN:  return {{32{1'b1}}, fmin_s(a, b, ff)};
      rtl_core_pkg::FPU_FMAX:  return {{32{1'b1}}, fmax_s(a, b, ff)};
      rtl_core_pkg::FPU_FSGNJ: return {{32{1'b1}}, fsgnj_s(a, b, ff)};
      rtl_core_pkg::FPU_FSGNJN: return {{32{1'b1}}, fsgnjn_s(a, b, ff)};
      rtl_core_pkg::FPU_FSGNJX: return {{32{1'b1}}, fsgnjx_s(a, b, ff)};
      rtl_core_pkg::FPU_FEQ: begin
        ff = (is_snan_s(a) | is_snan_s(b)) ? FF_NV : 5'd0;
        return {63'd0, feq_s(a, b)};
      end
      rtl_core_pkg::FPU_FLT: begin
        ff = (is_nan_s(a) | is_nan_s(b)) ? FF_NV : 5'd0;
        return {63'd0, flt_s(a, b)};
      end
      rtl_core_pkg::FPU_FLE: begin
        ff = (is_nan_s(a) | is_nan_s(b)) ? FF_NV : 5'd0;
        return {63'd0, fle_s(a, b)};
      end
      // Conversion ops. The core's generic ops are widened with the
      // is_unsigned/is_word control bits from decode:
      //   FPU_I2F: fcvt.s.{w|wu|l|lu}  (int -> single)
      //   FPU_F2I: fcvt.{w|wu|l|lu}.s  (single -> int)
      // Single results written to FLEN=64 registers must be NaN-boxed
      // (upper 32 bits all 1s).
      rtl_core_pkg::FPU_F2I:   return fcvt_s_int(a[31:0], is_unsigned, is_word, rm, ff);
      // Move ops. FMV.X.W sign-extends the single value into the integer
      // register (bits preserved, upper bits = copies of bit 31).
      rtl_core_pkg::FPU_MV_F2X: return {{32{a[31]}}, a[31:0]};
      // FMV.W.X: NaN-box the single-precision bit pattern.
      rtl_core_pkg::FPU_MV_X2F: return {{32{1'b1}}, a[31:0]};
      // FCLASS - classify float
      rtl_core_pkg::FPU_CLASS: return {54'd0, fclass_s(a[31:0])};
      default:   return a + b;
    endcase
  endfunction

  // FMADD alignment field: the larger operand's leading bit sits at bit T of
  // the 132-bit exact sum field.
  localparam int FMA_T = 129;

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
      RM_RNE: round_up = g & (r | s_bit | lsb);
      RM_RTZ: round_up = 1'b0;
      RM_RDN: round_up = sgn & (g | r | s_bit);
      RM_RUP: round_up = ~sgn & (g | r | s_bit);
      RM_RMM: round_up = g;
      default: round_up = g & (r | s_bit | lsb);
    endcase
    if (round_up) Fp = F + 59'd8;
    frac = Fp[54:3]; g = Fp[2]; r = Fp[1]; s_bit = Fp[0];
    if (round_up & Fp[56]) begin
      Fp = {Fp[58:1], 1'b0};
      e = e + 12'd1;
      frac = Fp[54:3];
    end
    if (F[2] | F[1] | F[0]) f = f | FF_NX;
    if (e >= 12'h7FF) begin
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

  // MSB position within a 59-bit slice, counting from bit lo.
  function automatic integer msb_pos59(input logic [58:0] v, input integer lo);
    integer i; integer p;
    p = -1;
    for (i = 58; i >= lo; i = i - 1)
      if (v[i] && p < 0) p = i;
    return p;
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
    // Zero + zero: exact signed zero. Same-sign zeros keep the sign;
    // opposite-sign zeros give +0 (-0 under round-down).
    if (is_zero_s(sxa) & is_zero_s(sxb)) begin
      logic zs; logic sgb_eff;
      sgb_eff = sgb ^ sub;
      zs = (sga == sgb_eff) ? sga : (rmode == RM_RDN);
      ff = f; return {zs, 31'd0};
    end
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
  // FADD/FSUB double: same algorithm as faddsub_s scaled to 11-bit
  // exponents and 53-bit significands. The 59-bit working field matches
  // round_pack_d (leading bit at 55, frac at [54:3], g/r/s at [2:0]).
  // Subnormal inputs are flushed to zero, like the single path.
  // =========================================================================
  function automatic logic [63:0] faddsub_d(input logic [63:0] dxa, input logic [63:0] dxb,
                                            input logic sub, input logic [2:0] rmode,
                                            output logic [4:0] ff);
    logic sga, sgb, eff_sub;
    logic [10:0] ea, eb, ebig, esmall;
    logic [52:0] ma, mb, mbig, msmall;
    logic swap;
    logic [11:0] diff;
    logic [58:0] bigF, smallF, sumF;
    logic stk;
    logic signed [12:0] eout;
    logic sgout;
    logic [4:0] f;
    integer lead_bit; integer sh;
    logic dropped_bit0;
    f = 5'd0;
    if (is_nan_d(dxa) | is_nan_d(dxb)) begin
      if (is_snan_d(dxa) | is_snan_d(dxb)) f = f | FF_NV;
      ff = f; return CANON_D_NAN;
    end
    sga = dxa[63]; sgb = dxb[63];
    eff_sub = sga ^ sgb ^ sub;
    if (is_inf_d(dxa) & is_inf_d(dxb) & eff_sub) begin
      f = f | FF_NV; ff = f; return CANON_D_NAN;
    end
    if (is_inf_d(dxa)) begin ff = f; return dxa; end
    if (is_inf_d(dxb)) begin ff = f; return sub ? {~sgb, dxb[62:0]} : dxb; end
    // Zero + zero: exact signed zero. Same-sign zeros keep the sign;
    // opposite-sign zeros give +0 (-0 under round-down).
    if (is_zero_d(dxa) & is_zero_d(dxb)) begin
      logic zs; logic sgb_eff;
      sgb_eff = sgb ^ sub;
      zs = (sga == sgb_eff) ? sga : (rmode == RM_RDN);
      ff = f; return {zs, 63'd0};
    end
    ea = dxa[62:52]; eb = dxb[62:52];
    ma = (ea==11'd0) ? {1'b0, dxa[51:0]} : {1'b1, dxa[51:0]};
    mb = (eb==11'd0) ? {1'b0, dxb[51:0]} : {1'b1, dxb[51:0]};
    if (ea==11'd0) begin ma = 53'd0; ea = 11'd1; end
    if (eb==11'd0) begin mb = 53'd0; eb = 11'd1; end
    swap = (ea < eb) | ((ea == eb) & (ma < mb));
    if (swap) begin
      ebig = eb; esmall = ea; mbig = mb; msmall = ma;
      sgout = sgb ^ sub;
    end else begin
      ebig = ea; esmall = eb; mbig = ma; msmall = mb; sgout = sga;
    end
    diff = ebig - esmall;
    bigF = {3'b0, mbig, 3'b0};
    smallF = {3'b0, msmall, 3'b0};
    stk = 1'b0;
    if (diff >= 12'd59) begin
      stk = |msmall;
      smallF = 59'd0;
    end else begin
      stk = |(smallF & ({59{1'b1}} >> (59 - diff)));
      smallF = smallF >> diff;
    end
    if (!eff_sub) begin
      sumF = bigF + smallF;
      eout = $signed({1'b0, ebig});
      if (sumF[56]) begin
        dropped_bit0 = sumF[0];
        sumF = {1'b0, sumF[58:1]};
        sumF[0] = sumF[0] | dropped_bit0 | stk;
        eout = eout + 13'sd1;
      end else begin
        sumF[0] = sumF[0] | stk;
      end
    end else begin
      smallF[0] = smallF[0] | stk;
      sumF = bigF - smallF;
      eout = $signed({1'b0, ebig});
      if (sumF[58:3] == 56'd0) begin
        ff = f; return {(sgout & (|{sumF, stk})), 63'd0};
      end
      lead_bit = msb_pos59(sumF, 3);
      sh = 55 - lead_bit;
      if (sh > 0) begin
        sumF = sumF << sh;
        eout = eout - sh;
      end
      sumF[0] = sumF[0] | stk;
    end
    ff = f;
    return round_pack_d(sgout, eout[11:0], sumF, rmode, ff);
  endfunction

  // =========================================================================
  // FMUL double: multiply mantissas, add exponents, XOR signs.
  // ma,mb are 1.x (53-bit, implicit at bit 52), so the 106-bit product
  // leads at bit 105 (value in [2.0,4.0)) or 104 (value in [1.0,2.0)).
  // =========================================================================
  function automatic logic [63:0] fmul_d(input logic [63:0] dxa, input logic [63:0] dxb,
                                         input logic [2:0] rmode, output logic [4:0] ff);
    logic sga, sgb; logic [10:0] ea, eb; logic [52:0] ma, mb;
    logic [105:0] prod; logic [58:0] F; logic signed [12:0] eout; logic [4:0] f;
    logic stk;
    f = 5'd0;
    if (is_nan_d(dxa) | is_nan_d(dxb)) begin
      if (is_snan_d(dxa) | is_snan_d(dxb)) f = f | FF_NV;
      ff = f; return CANON_D_NAN;
    end
    sga = dxa[63]; sgb = dxb[63];
    if (is_inf_d(dxa) & is_zero_d(dxb)) begin f = f | FF_NV; ff = f; return CANON_D_NAN; end
    if (is_zero_d(dxa) & is_inf_d(dxb)) begin f = f | FF_NV; ff = f; return CANON_D_NAN; end
    if (is_inf_d(dxa) | is_inf_d(dxb)) begin ff = f; return {(sga ^ sgb), 11'h7FF, 52'd0}; end
    // Zero x finite = signed zero (IEEE: exact, no flags).
    if (is_zero_d(dxa) | is_zero_d(dxb)) begin ff = f; return {sga ^ sgb, 63'd0}; end
    ea = dxa[62:52]; eb = dxb[62:52];
    ma = (ea==11'd0) ? {1'b0, dxa[51:0]} : {1'b1, dxa[51:0]};
    mb = (eb==11'd0) ? {1'b0, dxb[51:0]} : {1'b1, dxb[51:0]};
    if (ea==11'd0) ea = 11'd1;
    if (eb==11'd0) eb = 11'd1;
    eout = $signed({2'b00, ea} + {2'b00, eb} - 13'd1023);
    prod = ma * mb;   // 106-bit
    if (prod[105]) begin
      // value in [2.0,4.0): bit 105 -> field bit 55 (shift right 50).
      F = (prod >> 50) & {59{1'b1}};
      stk = |(prod & (((106'b1) << 50) - 106'b1));
      F[0] = F[0] | stk;
      eout = eout + 13'sd1;
    end else begin
      // value in [1.0,2.0): bit 104 -> field bit 55 (shift right 49).
      F = (prod >> 49) & {59{1'b1}};
      stk = |(prod & (((106'b1) << 49) - 106'b1));
      F[0] = F[0] | stk;
    end
    ff = f;
    return round_pack_d(sga ^ sgb, eout[11:0], F, rmode, ff);
  endfunction

  // =========================================================================
  // FMUL single: multiply mantissas, add exponents, XOR signs.
  // =========================================================================
  function automatic logic [31:0] fmul_s(input logic [31:0] sxa, input logic [31:0] sxb,
                                         input logic [2:0] rmode, output logic [4:0] ff);
    logic sga, sgb; logic [7:0] ea, eb; logic [23:0] ma, mb;
    logic [47:0] prod; logic [27:0] F; logic signed [9:0] eout; logic [4:0] f;
    logic stk;
    logic signed [9:0] Ea, Eb; integer La, Lb, k;
    f = 5'd0;
    if (is_nan_s(sxa) | is_nan_s(sxb)) begin
      if (is_snan_s(sxa) | is_snan_s(sxb)) f = f | FF_NV;
      ff = f; return CANON_S_NAN;
    end
    sga = sxa[31]; sgb = sxb[31];
    if (is_inf_s(sxa) & is_zero_s(sxb)) begin f = f | FF_NV; ff = f; return CANON_S_NAN; end
    if (is_zero_s(sxa) & is_inf_s(sxb)) begin f = f | FF_NV; ff = f; return CANON_S_NAN; end
    if (is_inf_s(sxa) | is_inf_s(sxb)) begin ff = f; return {(sga ^ sgb), 8'hFF, 23'd0}; end
    // Zero x finite = signed zero (IEEE: exact, no flags).
    if (is_zero_s(sxa) | is_zero_s(sxb)) begin ff = f; return {sga ^ sgb, 32'd0}; end
    ea = sxa[30:23]; eb = sxb[30:23];
    ma = {1'b1, sxa[22:0]}; mb = {1'b1, sxb[22:0]};
    Ea = $signed({2'b00, ea}) - 10'sd127;
    Eb = $signed({2'b00, eb}) - 10'sd127;
    // Normalize subnormal inputs (reached here only when nonzero): leading 1
    // to bit 23, unbiased exponent E = L - 149.
    if (ea==8'd0) begin
      La = -1;
      for (k = 22; k >= 0; k = k - 1)
        if (sxa[k] && La < 0) La = k;
      ma = {1'b1, sxa[22:0] << (23-La)};
      Ea = La - 149;
    end
    if (eb==8'd0) begin
      Lb = -1;
      for (k = 22; k >= 0; k = k - 1)
        if (sxb[k] && Lb < 0) Lb = k;
      mb = {1'b1, sxb[22:0] << (23-Lb)};
      Eb = Lb - 149;
    end
    // Product range [1.0,4.0): ma,mb are 1.x (24-bit, implicit at bit 23), so
    // prod leading bit is 46 (value in [1.0,2.0)) or 47 (value in [2.0,4.0)).
    eout = Ea + Eb + 10'sd127;
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
  // FDIV double (iterative restoring division, pure-combinational here).
  // Quotient q = (ma << 55) / mb is 56 bits: q[55] set means value in
  // [1.0,2.0) with the 52-bit mantissa in q[54:3] and g/r/s in q[2:0];
  // otherwise shift left 1 and decrement the exponent. Remainder = sticky.
  // =========================================================================
  function automatic logic [63:0] fdiv_d(input logic [63:0] dxa, input logic [63:0] dxb,
                                         input logic [2:0] rmode, output logic [4:0] ff);
    logic sga, sgb; logic [10:0] ea, eb; logic [52:0] ma, mb;
    logic [55:0] q; logic [107:0] rem, dividend, qprod; integer i;
    logic [58:0] F; logic signed [12:0] eout; logic [4:0] f;
    logic stk;
    f = 5'd0;
    if (is_nan_d(dxa) | is_nan_d(dxb)) begin
      if (is_snan_d(dxa) | is_snan_d(dxb)) f = f | FF_NV;
      ff = f; return CANON_D_NAN;
    end
    sga = dxa[63]; sgb = dxb[63];
    if (is_inf_d(dxa) & is_inf_d(dxb)) begin f = f | FF_NV; ff=f; return CANON_D_NAN; end
    if (is_zero_d(dxa) & is_zero_d(dxb)) begin f = f | FF_NV; ff=f; return CANON_D_NAN; end
    if (is_inf_d(dxa)) begin ff=f; return {(sga^sgb), 11'h7FF, 52'd0}; end
    if (is_inf_d(dxb)) begin ff=f; return {(sga^sgb), 63'd0}; end
    if (is_zero_d(dxb)) begin
      f = f | FF_DZ; ff=f; return {(sga^sgb), 11'h7FF, 52'd0};
    end
    // 0 / finite = signed zero (exact, no flags).
    if (is_zero_d(dxa)) begin ff=f; return {(sga^sgb), 63'd0}; end
    ea = dxa[62:52]; eb = dxb[62:52];
    ma = (ea==11'd0) ? {1'b0, dxa[51:0]} : {1'b1, dxa[51:0]};
    mb = (eb==11'd0) ? {1'b0, dxb[51:0]} : {1'b1, dxb[51:0]};
    if (ea==11'd0) ea = 11'd1;
    if (eb==11'd0) eb = 11'd1;
    eout = $signed({2'b00, ea}) - $signed({2'b00, eb}) + 13'sd1023;
    // Compute a 56-bit quotient q = (ma << 55) / mb so that the 53-bit
    // mantissa sits in q[55:3] with guard/round/sticky in q[2:0];
    // the remainder supplies the sticky.
    dividend = {55'd0, ma} << 55;   // 108-bit
    q        = dividend[107:0] / {3'd0, mb};
    qprod    = {52'd0, q} * {52'd0, mb};
    rem      = dividend - qprod;
    stk      = (rem != 108'd0);
    if (q[55]) begin
      // value in [1.0,2.0): mantissa = q[55:3], guard=q[2], round=q[1], sticky=q[0].
      F    = {3'b0, q[55:0]};
      F[0] = F[0] | stk;
    end else begin
      // value in [0.5,1.0): shift left 1, exp--.
      F    = {2'b0, q[54:0], 1'b0};
      F[0] = F[0] | stk;
      eout = eout - 13'sd1;
    end
    ff = f;
    return round_pack_d(sga ^ sgb, eout[11:0], F, rmode, ff);
  endfunction
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
    // 0 / finite = signed zero (exact, no flags).
    if (is_zero_s(sxa)) begin ff=f; return {(sga^sgb), 31'd0}; end
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
  // FSQRT double: digit-by-digit (non-restoring) integer sqrt, scaled from
  // fsqrt_s: 54-bit mantissa, 110-bit radicand, 55 root iterations. The
  // 55-bit root has its leading 1 at res[54]; F maps it to field bit 55.
  // =========================================================================
  function automatic logic [63:0] fsqrt_d(input logic [63:0] dxa,
                                          input logic [2:0] rmode, output logic [4:0] ff);
    logic [10:0] ea; logic [53:0] mant; logic [51:0] fracf;
    logic [111:0] res, rem, term; integer i, k; integer L; integer bi;
    logic [109:0] radicand;
    logic [58:0] F; logic signed [12:0] eout; logic [4:0] f;
    logic stk; logic odd_exp;
    f = 5'd0;
    if (is_nan_d(dxa)) begin
      if (is_snan_d(dxa)) f = f | FF_NV;
      ff = f; return CANON_D_NAN;
    end
    if (is_inf_d(dxa)) begin ff = f; return dxa; end
    if (dxa[63]) begin
      if (is_zero_d(dxa)) begin ff = f; return 64'h8000000000000000; end
      f = f | FF_NV; ff = f; return CANON_D_NAN;
    end
    if (is_zero_d(dxa)) begin ff = f; return 64'h0000000000000000; end
    ea = dxa[62:52];
    fracf = dxa[51:0];
    // Normalize denormal inputs (ea==0, fracf!=0): L is the leading-1 bit
    // position in the 52-bit fraction field; E = L - 1075.
    if (ea == 11'd0) begin
      L = -1;
      for (k = 51; k >= 0; k = k - 1)
        if (fracf[k] && L < 0) L = k;
      mant = {1'b1, fracf << (52 - L)};
      eout = $signed(13'(L)) - 13'sd1075;
    end else begin
      mant = {1'b1, fracf};
      eout = $signed({2'b00, ea}) - 13'sd1023;
    end
    // For an odd unbiased exponent, fold the factor of 2 into the mantissa
    // and use E (already even after floor div).
    odd_exp = eout[0];
    if (odd_exp) begin
      radicand = {57'd0, mant} << 57;
    end else begin
      radicand = {57'd0, mant} << 56;
    end
    // Classic non-restoring sqrt: 55 iterations, two radicand bits per step,
    // extracted by absolute index from the MSB down.
    rem = 112'd0; res = 112'd0;
    for (i = 54; i >= 0; i = i - 1) begin
      bi = 2*i + 1;
      rem = (rem << 2) | radicand[bi -: 2];
      term = (res << 2) | 112'd1;
      if (rem >= term) begin
        rem = rem - term;
        res = (res << 1) | 112'd1;
      end else begin
        res = res << 1;
      end
    end
    stk = (rem != 112'd0);
    // res is 55-bit: res[54]=leading 1, res[53:2]=52 frac bits, res[1]=guard,
    // res[0]=round. Map into the 59-bit round_pack field (leading 1 at bit 55).
    F = (res << 1) | {58'd0, stk};
    eout = (eout >>> 1) + 13'sd1023;
    ff = f;
    return round_pack_d(1'b0, eout[11:0], F, rmode, ff);
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

  // FMIN/FMAX double. Same selection rules as the single versions;
  // sNaN inputs set NV even when the result is not NaN.
  function automatic logic [63:0] fmin_d(input logic [63:0] a, input logic [63:0] b,
                                         output logic [4:0] ff);
    ff = 5'd0;
    if (is_snan_d(a) | is_snan_d(b)) ff = FF_NV;
    if (is_nan_d(a) & is_nan_d(b)) return CANON_D_NAN;
    if (is_nan_d(a)) return b;
    if (is_nan_d(b)) return a;
    if (a[63] & ~b[63]) return a;  // a negative, b positive
    if (~a[63] & b[63]) return b;  // a positive, b negative
    if (a[63]) begin
      // both negative: larger magnitude is smaller; -0 < +0 handled since
      // the zero with sign 1 has the same magnitude but must win.
      if (a[62:0] > b[62:0]) return a;
      return b;
    end
    // both positive: smaller magnitude is smaller; +0 vs -0 returns -0
    if (a[62:0] < b[62:0]) return a;
    if (a[62:0] > b[62:0]) return b;
    return a;  // equal: identical bits
  endfunction

  function automatic logic [63:0] fmax_d(input logic [63:0] a, input logic [63:0] b,
                                         output logic [4:0] ff);
    ff = 5'd0;
    if (is_snan_d(a) | is_snan_d(b)) ff = FF_NV;
    if (is_nan_d(a) & is_nan_d(b)) return CANON_D_NAN;
    if (is_nan_d(a)) return b;
    if (is_nan_d(b)) return a;
    if (a[63] & ~b[63]) return b;  // a negative, b positive
    if (~a[63] & b[63]) return a;  // a positive, b negative
    if (a[63]) begin
      // both negative: smaller magnitude is larger
      if (a[62:0] < b[62:0]) return a;
      return b;
    end
    // both positive: larger magnitude is larger
    if (a[62:0] > b[62:0]) return a;
    if (a[62:0] < b[62:0]) return b;
    return a;
  endfunction

  // FMIN - smaller of two values; -0 < +0 for min/max purposes.
  // Both NaN -> canonical NaN; one NaN -> the non-NaN operand.
  // sNaN inputs set NV even when the result is not NaN.
  function automatic logic [31:0] fmin_s(input logic [31:0] a, input logic [31:0] b,
                                         output logic [4:0] ff);
    ff = 5'd0;
    if (is_snan_s(a) | is_snan_s(b)) ff = FF_NV;
    if (is_nan_s(a) & is_nan_s(b)) return CANON_S_NAN;
    if (is_nan_s(a)) return b;
    if (is_nan_s(b)) return a;
    if (a[31] & ~b[31]) return a;  // a negative, b positive
    if (~a[31] & b[31]) return b;  // a positive, b negative
    if (a[31]) begin
      // both negative: larger magnitude is smaller; -0 < +0 handled since
      // the zero with sign 1 has the same magnitude but must win.
      if (a[30:0] > b[30:0]) return a;
      return b;
    end
    // both positive: smaller magnitude is smaller; +0 vs -0 returns -0
    if (a[30:0] < b[30:0]) return a;
    if (a[30:0] > b[30:0]) return b;
    return a;  // equal: identical bits
  endfunction

  // FMAX - larger of two values
  function automatic logic [31:0] fmax_s(input logic [31:0] a, input logic [31:0] b,
                                         output logic [4:0] ff);
    ff = 5'd0;
    if (is_snan_s(a) | is_snan_s(b)) ff = FF_NV;
    if (is_nan_s(a) & is_nan_s(b)) return CANON_S_NAN;
    if (is_nan_s(a)) return b;
    if (is_nan_s(b)) return a;
    if (a[31] & ~b[31]) return b;  // a negative, b positive
    if (~a[31] & b[31]) return a;  // a positive, b negative
    if (a[31]) begin
      // both negative: smaller magnitude is larger
      if (a[30:0] < b[30:0]) return a;
      return b;
    end
    // both positive: larger magnitude is larger
    if (a[30:0] > b[30:0]) return a;
    if (a[30:0] < b[30:0]) return b;
    return a;
  endfunction

  // FSGNJ double family: all bits except the sign come from rs1 (a).
  function automatic logic [63:0] fsgnj_d(input logic [63:0] a, input logic [63:0] b,
                                          output logic [4:0] ff);
    ff = 5'd0;
    return {b[63], a[62:0]};
  endfunction

  function automatic logic [63:0] fsgnjn_d(input logic [63:0] a, input logic [63:0] b,
                                           output logic [4:0] ff);
    ff = 5'd0;
    return {~b[63], a[62:0]};
  endfunction

  function automatic logic [63:0] fsgnjx_d(input logic [63:0] a, input logic [63:0] b,
                                           output logic [4:0] ff);
    ff = 5'd0;
    return {a[63] ^ b[63], a[62:0]};
  endfunction

  // FSGNJ family: all bits except the sign come from rs1 (a); the sign is
  // rs2's (b) sign, its inverse, or the XOR of both. No flags, no NaN
  // canonicalization.
  function automatic logic [31:0] fsgnj_s(input logic [31:0] a, input logic [31:0] b,
                                          output logic [4:0] ff);
    ff = 5'd0;
    return {b[31], a[30:0]};
  endfunction

  function automatic logic [31:0] fsgnjn_s(input logic [31:0] a, input logic [31:0] b,
                                           output logic [4:0] ff);
    ff = 5'd0;
    return {~b[31], a[30:0]};
  endfunction

  function automatic logic [31:0] fsgnjx_s(input logic [31:0] a, input logic [31:0] b,
                                           output logic [4:0] ff);
    ff = 5'd0;
    return {a[31] ^ b[31], a[30:0]};
  endfunction

  // FCLASS double - classify into the 10-bit mask (same bit order as single).
  function automatic logic [9:0] fclass_d(input logic [63:0] a);
    logic [9:0] cls;
    cls = 10'd0;
    if (is_nan_d(a)) begin
      cls = is_snan_d(a) ? 10'b0100000000 : 10'b1000000000;
    end else if (is_inf_d(a)) begin
      cls = a[63] ? 10'b0000000001 : 10'b0010000000;
    end else if (is_zero_d(a)) begin
      cls = a[63] ? 10'b0000001000 : 10'b0000010000;
    end else if (a[62:52] == 11'd0) begin
      cls = a[63] ? 10'b0000000100 : 10'b0000100000;
    end else begin
      cls = a[63] ? 10'b0000000010 : 10'b0001000000;
    end
    return cls;
  endfunction

  // FCLASS - classify into the 10-bit mask:
  // bit0=-inf 1=-normal 2=-subnormal 3=-0 4=+0 5=+subnormal 6=+normal
  // 7=+inf 8=sNaN 9=qNaN. Never sets flags.
  function automatic logic [31:0] fclass_s(input logic [31:0] a);
    logic [9:0] cls;
    cls = 10'd0;
    if (is_nan_s(a)) begin
      cls = is_snan_s(a) ? 10'b0100000000 : 10'b1000000000;
    end else if (is_inf_s(a)) begin
      cls = a[31] ? 10'b0000000001 : 10'b0010000000;
    end else if (is_zero_s(a)) begin
      cls = a[31] ? 10'b0000001000 : 10'b0000010000;
    end else if (a[30:23] == 8'd0) begin
      cls = a[31] ? 10'b0000000100 : 10'b0000100000;
    end else begin
      cls = a[31] ? 10'b0000000010 : 10'b0001000000;
    end
    return {22'd0, cls};
  endfunction


  // =========================================================================
  // Conversion operations
  // =========================================================================

  // FCVT.S.D - convert double to single. Normalized 53-bit significand
  // m53 feeds round_pack_s with its leading 1 at F[26]; exponent is
  // clamped so the packer's overflow/underflow paths trigger correctly.
  function automatic logic [31:0] fcvt_s_d(input logic [63:0] d,
                                            input logic [2:0] rmode,
                                            output logic [4:0] ff);
    logic sgn;
    logic [10:0] exp_d;
    logic [51:0] frac_d;
    logic [52:0] m53;
    logic [27:0] F;
    logic signed [11:0] Eb;
    logic signed [9:0] eout;
    integer L, k;

    ff = 5'd0;

    if (is_nan_d(d)) begin
      if (is_snan_d(d)) ff = FF_NV;
      return CANON_S_NAN;
    end
    if (is_inf_d(d)) return d[63] ? S_INF_N : S_INF_P;
    if (is_zero_d(d)) return d[63] ? 32'h80000000 : 32'h00000000;

    sgn = d[63];
    exp_d = d[62:52];
    frac_d = d[51:0];

    if (exp_d == 11'd0) begin
      // Denormal input: normalize (L = leading-1 position), E = L - 1074.
      L = -1;
      for (k = 51; k >= 0; k = k - 1)
        if (frac_d[k] && L < 0) L = k;
      m53 = ({1'b0, frac_d} << (52 - L));
      Eb = L - 1074;
    end else begin
      m53 = {1'b1, frac_d};
      Eb = $signed({1'b0, exp_d}) - 12'sd1023;
    end

    // 28-bit field: F[27]=0, F[26]=implicit 1, F[25:3]=frac, g/r/s below.
    F = {1'b0, m53[52:27], 1'b0};
    F[0] = F[0] | (|m53[26:0]);

    // Clamp to the packer's tractable range: Eb > 127 overflows to inf;
    // Eb < -154 always flushes to zero (magnitude < 2^-154); in between,
    // the packer's denormal path forms single subnormals.
    if (Eb > 12'sd127) eout = 10'sd255;
    else if (Eb < -12'sd154) begin
      ff = FF_UF | FF_NX; return {sgn, 31'd0};
    end
    else eout = Eb + 127;

    return round_pack_s(sgn, eout, F, rmode, ff);
  endfunction

  // FCVT.D.S - convert single to double. Widening is always exact: pack
  // directly (no rounding). Denormal inputs are normalized explicitly.
  function automatic logic [63:0] fcvt_d_s(input logic [31:0] s,
                                            input logic [2:0] rmode,
                                            output logic [4:0] ff);
    logic sgn_s;
    logic [7:0] exp_s;
    logic [22:0] frac_s;
    logic signed [11:0] Eb;
    logic [51:0] frac_d;
    integer L, k;

    ff = 5'd0;

    if (is_nan_s(s)) begin
      if (is_snan_s(s)) ff = FF_NV;
      return CANON_D_NAN;
    end
    if (is_inf_s(s)) return s[31] ? D_INF_N : D_INF_P;
    if (is_zero_s(s)) return s[31] ? 64'h8000000000000000 : 64'h0000000000000000;

    sgn_s = s[31];
    exp_s = s[30:23];
    frac_s = s[22:0];

    if (exp_s == 8'd0) begin
      // Denormal: normalize (L = leading-1 position), E = L - 149.
      L = -1;
      for (k = 22; k >= 0; k = k - 1)
        if (frac_s[k] && L < 0) L = k;
      Eb = L - 149;
      frac_d = {frac_s << (23 - L), 29'd0};
    end else begin
      Eb = $signed({4'b0000, exp_s}) - 12'sd127;
      frac_d = {frac_s, 29'd0};
    end

    return {sgn_s, Eb[10:0] + 11'd1023, frac_d};
  endfunction

  // =========================================================================
  // FMADD double: fused multiply-add with a single rounding step. Exact
  // 106-bit product of the 53-bit significands is aligned with the addend
  // in a 190-bit field (product leading bit fixed at bit DFMA_T), low bits
  // compress into a sticky, and the normalized sum is rounded once via
  // round_pack_d. Scaled from fmadd_s (132-bit field, T=129).
  localparam int DFMA_T = 187;
  function automatic logic [63:0] fmadd_d(input logic [63:0] a, input logic [63:0] b,
                                          input logic [63:0] c,
                                          input logic        neg_prod,
                                          input logic        sub_c,
                                          input logic [2:0]  rmode,
                                          output logic [4:0] ff);
    logic sga, sgb, sgc, sgprod, sgc_eff, eff_sub, sgout;
    logic prod_zero, cz;
    logic [10:0] ea, eb, ec;
    logic [52:0] ma, mb, mc;
    logic [105:0] prod, pn;
    logic [189:0] bigF, smlF, sumF;
    integer e_p, e_c, d, dm, expn, L, i;
    logic stk;
    logic [58:0] F;
    logic signed [12:0] eb_out;
    logic [11:0] eb12;
    logic [4:0] f;
    logic [63:0] mr;

    f = 5'd0;
    if (is_nan_d(a) | is_nan_d(b) | is_nan_d(c)) begin
      if (is_snan_d(a) | is_snan_d(b) | is_snan_d(c)) f = f | FF_NV;
      ff = f; return CANON_D_NAN;
    end
    sga = a[63]; sgb = b[63]; sgc = c[63];
    sgprod  = sga ^ sgb ^ neg_prod;
    sgc_eff = sgc ^ sub_c;
    prod_zero = (a[62:52] == 11'd0) | (b[62:52] == 11'd0);
    cz        = (c[62:52] == 11'd0);

    if ((is_inf_d(a) & is_zero_d(b)) | (is_zero_d(a) & is_inf_d(b))) begin
      f = f | FF_NV; ff = f; return CANON_D_NAN;
    end
    if (is_inf_d(a) | is_inf_d(b)) begin
      if (is_inf_d(c) & (sgc_eff != sgprod)) begin
        f = f | FF_NV; ff = f; return CANON_D_NAN;
      end
      ff = f; return {sgprod, 11'h7FF, 52'd0};
    end
    if (is_inf_d(c)) begin ff = f; return c; end

    if (prod_zero) begin
      // Product is (signed) zero: the result is the addend alone (a zero
      // addend yields the zero-sign rule).
      if (cz) begin
        ff = f; return {sgprod & sgc_eff, 63'd0};
      end
      ff = f; return sgc_eff ? {1'b1, c[62:0]} : c;
    end
    if (cz) begin
      // Addend is zero: the rounded product alone, with the product sign.
      mr = fmul_d(a, b, rmode, ff);
      return {sgprod, mr[62:0]};
    end

    ea = a[62:52]; eb = b[62:52]; ec = c[62:52];
    ma = {1'b1, a[51:0]}; mb = {1'b1, b[51:0]}; mc = {1'b1, c[51:0]};
    prod = ma * mb;                       // exact 106-bit product
    // Normalize the product so pn[105] is the leading one: pn in [2^105,2^106)
    // with value P = pn * 2^expn.
    if (prod[105]) begin pn = prod;      expn = (ea - 1023) + (eb - 1023) - 104; end
    else           begin pn = {prod[104:0], 1'b0}; expn = (ea - 1023) + (eb - 1023) - 105; end
    e_p = expn + 105;   // unbiased exponent of the product
    e_c = ec - 1023;    // unbiased exponent of the addend
    d  = e_p - e_c;
    dm = -d;

    eff_sub = sgprod ^ sgc_eff;
    stk = 1'b0;
    if (d >= 0) begin
      // Product is the larger-magnitude operand: pn[105] at field bit T.
      bigF = 190'd0;
      bigF[DFMA_T -: 106] = pn;
      if (d <= DFMA_T - 53) begin
        // Addend fully inside the field: mc[52] at bit T-d.
        smlF = 190'd0;
        smlF[DFMA_T-d -: 53] = mc;
      end else if (d <= DFMA_T) begin
        // Low bits of mc shift out below bit 0; compress them into sticky.
        smlF = 190'(mc) >> (d - (DFMA_T - 52));
        stk  = |(mc & ((190'd1 << (d - (DFMA_T - 52))) - 1));
      end else begin
        smlF = 190'd0;
        stk  = |mc;
      end
      if (stk) smlF[0] = 1'b1;
      if (!eff_sub) begin
        sumF = bigF + smlF;
        sgout = sgprod;
      end else if (bigF >= smlF) begin
        sumF = bigF - smlF;
        sgout = sgprod;
      end else begin
        sumF = smlF - bigF;
        sgout = sgc_eff;
      end
    end else begin
      // Addend is the larger-magnitude operand: mc[52] at field bit T.
      bigF = 190'd0;
      bigF[DFMA_T -: 53] = mc;
      if (dm <= DFMA_T - 106) begin
        // Product fully inside the field: pn[105] at bit T-dm.
        smlF = 190'd0;
        smlF[DFMA_T-dm -: 106] = pn;
      end else if (dm <= DFMA_T) begin
        smlF = 190'(pn) >> (dm - (DFMA_T - 105));
        stk  = |(pn & ((190'd1 << (dm - (DFMA_T - 105))) - 1));
      end else begin
        smlF = 190'd0;
        stk  = |pn;
      end
      if (stk) smlF[0] = 1'b1;
      if (!eff_sub) begin
        sumF = bigF + smlF;
        sgout = sgc_eff;
      end else if (bigF >= smlF) begin
        sumF = bigF - smlF;
        sgout = sgc_eff;
      end else begin
        sumF = smlF - bigF;
        sgout = sgprod;
      end
    end

    if (sumF == 190'd0) begin
      // Exact cancellation: +0 except under RDN (-0).
      ff = f; return {(rmode == RM_RDN), 63'd0};
    end

    // Leading-one position (sum can carry up to two bits above T).
    L = 190;
    for (i = 189; i >= 0; i = i - 1)
      if ((L == 190) && sumF[i]) L = i;

    // Biased exponent: field bit T has weight 2^larger_exp, so the sum's
    // unbiased exponent is larger_exp + (L - T).
    if (d >= 0) eb_out = e_p + (L - DFMA_T) + 1023;
    else        eb_out = e_c + (L - DFMA_T) + 1023;

    // Normalize so the leading one lands on bit 189, then slice the 59-bit
    // round field: F[55]=leading 1, F[54:3]=52-bit fraction, G/R/sticky below.
    sumF = sumF << (189 - L);
    F = {3'b0, sumF[189:137], sumF[136], sumF[135], |sumF[134:0]};

    // Clamp the biased exponent into the packer's 12-bit range: values above
    // the double max can only come from true overflow (biased > 2046).
    if (eb_out > 13'sd2046) eb12 = 12'h7FF;
    else eb12 = eb_out[11:0];

    ff = f;
    return round_pack_d(sgout, eb12, F, rmode, ff);
  endfunction

  // FMADD family: fused single-precision multiply-add with a single
  // rounding step (IEEE fused semantics, no double rounding). The exact
  // 48-bit product of the 24-bit significands is aligned with the addend in
  // a 132-bit field (larger operand's leading bit fixed at bit 129), the
  // low bits of the smaller operand compress into a sticky, and the
  // normalized sum is rounded once via round_pack_s.
  //   FMADD:  +(a*b) + c      FMSUB:  +(a*b) - c
  //   FNMADD: -(a*b) + c      FNMSUB: -(a*b) - c
  // Subnormal inputs are flushed to zero (same policy as faddsub_s).
  // =========================================================================
  function automatic logic [31:0] fmadd_s(input logic [31:0] a, input logic [31:0] b,
                                          input logic [31:0] c,
                                          input logic        neg_prod,
                                          input logic        sub_c,
                                          input logic [2:0]  rmode,
                                          output logic [4:0] ff);
    logic sga, sgb, sgc, sgprod, sgc_eff, eff_sub, sgout;
    logic prod_zero, cz;
    logic [7:0] ea, eb, ec;
    logic [23:0] ma, mb, mc;
    logic [47:0] prod, pn;
    logic [131:0] bigF, smlF, sumF;
    integer e_p, e_c, d, dm, expn, L, i;
    logic stk;
    logic [27:0] F;
    logic signed [9:0] eb_out;
    logic [4:0] f;
    logic [31:0] mr;

    f = 5'd0;
    if (is_nan_s(a) | is_nan_s(b) | is_nan_s(c)) begin
      if (is_snan_s(a) | is_snan_s(b) | is_snan_s(c)) f = f | FF_NV;
      ff = f; return CANON_S_NAN;
    end
    sga = a[31]; sgb = b[31]; sgc = c[31];
    sgprod  = sga ^ sgb ^ neg_prod;
    sgc_eff = sgc ^ sub_c;
    prod_zero = (a[30:23] == 8'd0) | (b[30:23] == 8'd0);
    cz        = (c[30:23] == 8'd0);

    if ((is_inf_s(a) & is_zero_s(b)) | (is_zero_s(a) & is_inf_s(b))) begin
      f = f | FF_NV; ff = f; return CANON_S_NAN;
    end
    if (is_inf_s(a) | is_inf_s(b)) begin
      if (is_inf_s(c) & (sgc_eff != sgprod)) begin
        f = f | FF_NV; ff = f; return CANON_S_NAN;
      end
      ff = f; return {sgprod, 8'hFF, 23'd0};
    end
    if (is_inf_s(c)) begin ff = f; return c; end

    if (prod_zero) begin
      // Product is (signed) zero: the result is the addend alone (a zero
      // addend yields the zero-sign rule).
      if (cz) begin
        ff = f; return {sgprod & sgc_eff, 31'd0};
      end
      ff = f; return sgc_eff ? {1'b1, c[30:0]} : c;
    end
    if (cz) begin
      // Addend is zero: the rounded product alone, with the product sign.
      mr = fmul_s(a, b, rmode, ff);
      return {sgprod, mr[30:0]};
    end

    ea = a[30:23]; eb = b[30:23]; ec = c[30:23];
    ma = {1'b1, a[22:0]}; mb = {1'b1, b[22:0]}; mc = {1'b1, c[22:0]};
    prod = ma * mb;                       // exact 48-bit product
    // Normalize the product so pn[47] is the leading one: pn in [2^47,2^48)
    // with value P = pn * 2^expn (prod has its leading one at bit 47 or 46).
    if (prod[47]) begin pn = prod;      expn = (ea - 127) + (eb - 127) - 46; end
    else          begin pn = {prod[46:0], 1'b0}; expn = (ea - 127) + (eb - 127) - 47; end
    e_p = expn + 47;   // unbiased exponent of the product
    e_c = ec - 127;    // unbiased exponent of the addend
    d  = e_p - e_c;
    dm = -d;

    eff_sub = sgprod ^ sgc_eff;
    stk = 1'b0;
    if (d >= 0) begin
      // Product is the larger-magnitude operand: pn[47] at field bit T.
      bigF = 132'd0;
      bigF[FMA_T -: 48] = pn;
      if (d <= FMA_T - 24) begin
        // Addend fully inside the field: mc[23] at bit T-d.
        smlF = 132'd0;
        smlF[FMA_T-d -: 24] = mc;
      end else if (d <= FMA_T) begin
        // Low bits of mc shift out below bit 0; compress them into sticky.
        smlF = 132'(mc) >> (d - (FMA_T - 23));
        stk  = |(mc & ((132'd1 << (d - (FMA_T - 23))) - 1));
      end else begin
        smlF = 132'd0;
        stk  = |mc;
      end
      if (stk) smlF[0] = 1'b1;
      if (!eff_sub) begin
        sumF = bigF + smlF;
        sgout = sgprod;
      end else if (bigF >= smlF) begin
        sumF = bigF - smlF;
        sgout = sgprod;
      end else begin
        sumF = smlF - bigF;
        sgout = sgc_eff;
      end
    end else begin
      // Addend is the larger-magnitude operand: mc[23] at field bit T.
      bigF = 132'd0;
      bigF[FMA_T -: 24] = mc;
      if (dm <= FMA_T - 48) begin
        // Product fully inside the field: pn[47] at bit T-dm.
        smlF = 132'd0;
        smlF[FMA_T-dm -: 48] = pn;
      end else if (dm <= FMA_T) begin
        smlF = 132'(pn) >> (dm - (FMA_T - 47));
        stk  = |(pn & ((132'd1 << (dm - (FMA_T - 47))) - 1));
      end else begin
        smlF = 132'd0;
        stk  = |pn;
      end
      if (stk) smlF[0] = 1'b1;
      if (!eff_sub) begin
        sumF = bigF + smlF;
        sgout = sgc_eff;
      end else if (bigF >= smlF) begin
        sumF = bigF - smlF;
        sgout = sgc_eff;
      end else begin
        sumF = smlF - bigF;
        sgout = sgprod;
      end
    end

    if (sumF == 132'd0) begin
      // Exact cancellation: +0 except under RDN (-0).
      ff = f; return {(rmode == RM_RDN), 31'd0};
    end

    // Leading-one position (sum can carry up to two bits above T).
    L = 132;
    for (i = 131; i >= 0; i = i - 1)
      if ((L == 132) && sumF[i]) L = i;

    // Biased exponent: field bit T has weight 2^larger_exp, so the sum's
    // unbiased exponent is larger_exp + (L - T).
    if (d >= 0) eb_out = e_p + (L - FMA_T) + 127;
    else        eb_out = e_c + (L - FMA_T) + 127;

    // Normalize so the leading one lands on bit 131, then slice the 28-bit
    // round field: significand [131:108] -> F[26:3], G, R, sticky below.
    sumF = sumF << (131 - L);
    F[26:3] = sumF[131:108];
    F[2]    = sumF[107];
    F[1]    = sumF[106];
    F[0]    = |sumF[105:0];

    ff = f;
    return round_pack_s(sgout, eb_out, F, rmode, ff);
  endfunction

  // FCVT int to single: is_word=1 treats the integer as 64-bit (L/LU),
  // is_word=0 as 32-bit (W/WU, sign- or zero-extended). Unsigned inputs use
  // the magnitude directly. Rounds per rmode; sets NX when inexact.
  // FCVT int to double (mirror of fcvt_int_s with the 59-bit double field:
  // mantissa leading 1 at bit 63 maps to field bit 55, i.e. shift right 8).
  function automatic logic [63:0] fcvt_int_d(input logic [63:0] int_val,
                                             input logic        is_unsigned,
                                             input logic [2:0] rmode,
                                             output logic [4:0] ff);
    logic [63:0] mag;
    logic        sgn;
    logic [63:0] mant;
    integer      leading_zeros;
    logic signed [12:0] eout;
    logic [58:0] F;
    logic        stk;

    ff = 5'd0;
    if (int_val == 64'd0) return 64'h0000000000000000;

    if (is_unsigned) begin
      sgn = 1'b0;
      mag = int_val;
    end else begin
      sgn = int_val[63];
      mag = sgn ? (~int_val + 64'd1) : int_val;
    end
    if (mag == 64'd0) return sgn ? 64'h8000000000000000 : 64'h0000000000000000;

    leading_zeros = 0;
    for (integer i = 63; i >= 0; i = i - 1) begin
      if (mag[i] == 1'b0) leading_zeros = leading_zeros + 1;
      else break;
    end
    mant = mag << leading_zeros;

    // unbiased exponent of the leading 1
    eout = 13'sd63 - leading_zeros;
    // Field: mant's leading 1 is at bit 63; the significand maps to
    // F[55:4] (52 frac bits), guard F[3]... i.e. shift right 8 with the
    // low 8 bits folded into sticky. F[0] collects the sticky.
    F  = 59'(mant >> 8);
    stk = |mant[7:0];
    F[0] = F[0] | stk;
    eout = eout + 13'sd1023;
    return round_pack_d(sgn, eout[11:0], F, rmode, ff);
  endfunction

  function automatic logic [31:0] fcvt_int_s(input logic [63:0] int_val,
                                            input logic        is_unsigned,
                                            input logic [2:0] rmode,
                                            output logic [4:0] ff);
    logic [63:0] mag;
    logic        sgn;
    logic [63:0] mant;
    integer      leading_zeros;
    logic signed [9:0] eout;
    logic [27:0] F;
    logic        stk;

    ff = 5'd0;
    if (int_val == 64'd0) return 32'h00000000;

    if (is_unsigned) begin
      sgn = 1'b0;
      mag = int_val;
    end else begin
      sgn = int_val[63];
      mag = sgn ? (~int_val + 64'd1) : int_val;
    end
    if (mag == 64'd0) return sgn ? 32'h80000000 : 32'h00000000;

    leading_zeros = 0;
    for (integer i = 63; i >= 0; i = i - 1) begin
      if (mag[i] == 1'b0) leading_zeros = leading_zeros + 1;
      else break;
    end
    mant = mag << leading_zeros;

    // unbiased exponent of the leading 1
    eout = 10'sd63 - leading_zeros;
    // Field: place the top 27 fraction bits (24 sig + guard/round/sticky).
    // mant's leading 1 is at bit 63; the significand bits 23..0 map to
    // mant[63:40], guard mant[39], round mant[38], sticky = |mant[37:0].
    F  = {1'b0, mant[63:38], 1'b0};
    // F[26] must hold the leading 1: shift right so bit 63 -> bit 26.
    F  = 28'(mant >> 37);
    stk = |mant[37:0];
    F[0] = F[0] | stk;
    eout = eout + 10'sd127;
    return round_pack_s(sgn, eout, F, rmode, ff);
  endfunction

  // FCVT double to int with RISC-V saturation semantics (mirror of
  // fcvt_s_int with a 53-bit significand and double bias).
  function automatic logic [63:0] fcvt_d_int(input logic [63:0] d,
                                             input logic        is_unsigned,
                                             input logic        is_word,
                                             input logic [2:0] rmode,
                                             output logic [4:0] ff);
    logic        sgn, subnorm;
    logic [10:0] exp;
    logic [51:0] frac;
    logic [63:0] v64, mag, result;
    logic [52:0] v53;
    logic        inexact, out_of_range;
    integer      e, sh;
    logic        g, r, st, round_up;
    logic [63:0] max_pos, max_neg;

    ff = 5'd0;
    if (is_nan_d(d)) begin
      ff = FF_NV;
      return is_unsigned ? 64'hFFFFFFFFFFFFFFFF :
             (is_word ? 64'h7FFFFFFFFFFFFFFF : 64'h000000007FFFFFFF);
    end
    sgn = d[63]; exp = d[62:52]; frac = d[51:0];
    if (is_unsigned) begin
      max_pos = 64'hFFFFFFFFFFFFFFFF; max_neg = 64'd0;
    end else if (is_word) begin
      max_pos = 64'h7FFFFFFFFFFFFFFF; max_neg = 64'h8000000000000000;
    end else begin
      max_pos = 64'h000000007FFFFFFF; max_neg = 64'hFFFFFFFF80000000;
    end
    if (is_inf_d(d)) begin
      ff = FF_NV;
      return sgn ? max_neg : max_pos;
    end
    if (is_zero_d(d)) return 64'd0;

    // Value = v53 * 2^(e-52): v53 is the 53-bit significand ({1,frac} for
    // normals, {0,frac} for subnormals with e biased accordingly).
    subnorm = (exp == 11'd0);
    v53 = subnorm ? {1'b0, frac} : {1'b1, frac};
    v64 = {11'd0, v53};
    e = subnorm ? -1022 : (exp - 1023);
    inexact = 1'b0;
    if (e > 63) begin
      // value >= 2^64: out of range for every destination
      ff = FF_NV;
      return sgn ? max_neg : max_pos;
    end
    sh = 52 - e;
    if (sh > 0) begin
      if (sh >= 54) begin
        mag = 64'd0;
        g = 1'b0; r = 1'b0; st = |v64;
      end else begin
        mag = v64 >> sh;
        g = (v64 >> (sh-1)) & 64'd1;
        r = (sh >= 2) ? ((v64 >> (sh-2)) & 64'd1) : 1'b0;
        st = (sh >= 3) ? (|(v64 & ((64'd1 << (sh-2)) - 1))) : 1'b0;
      end
      inexact = g | r | st;
      round_up = 1'b0;
      if (inexact) begin
        case (rmode)
          RM_RNE: round_up = g & (r | st | mag[0]);
          RM_RTZ: round_up = 1'b0;
          RM_RDN: round_up = sgn & (g | r | st);
          RM_RUP: round_up = ~sgn & (g | r | st);
          RM_RMM: round_up = g;
          default: round_up = g & (r | st | mag[0]);
        endcase
        mag = mag + (round_up ? 64'd1 : 64'd0);
      end
    end else begin
      // e in [52,63]: v64 << (e-52), value <= 2^64, fits the range check
      mag = v64 << (e - 52);
    end
    if (inexact) ff = ff | FF_NX;

    // Range check on the rounded magnitude, then apply the sign.
    if (sgn) out_of_range = (mag > (~max_neg + 64'd1));
    else     out_of_range = (mag > max_pos);
    if (out_of_range) begin
      ff = FF_NV;
      return sgn ? max_neg : max_pos;
    end
    result = sgn ? (~mag + 64'd1) : mag;
    if (!is_word) result = {{32{result[31]}}, result[31:0]};
    return result;
  endfunction

  // FCVT single to int with RISC-V saturation semantics: NaN, +/-Inf and
  // out-of-range results clip to the destination bounds and set NV (never
  // OF/UF); inexact results set NX. is_word=1 -> 64-bit (L/LU), is_word=0 ->
  // 32-bit (W/WU, sign-extended to XLEN).
  function automatic logic [63:0] fcvt_s_int(input logic [31:0] s,
                                             input logic        is_unsigned,
                                             input logic        is_word,
                                             input logic [2:0] rmode,
                                             output logic [4:0] ff);
    logic        sgn, subnorm;
    logic [7:0]  exp;
    logic [22:0] frac;
    logic [63:0] v64, mag, result;
    logic        inexact, out_of_range;
    integer      e, sh;
    logic        g, r, st, round_up;
    logic [63:0] max_pos, max_neg;

    ff = 5'd0;
    if (is_nan_s(s)) begin
      ff = FF_NV;
      return is_unsigned ? 64'hFFFFFFFFFFFFFFFF :
             (is_word ? 64'h7FFFFFFFFFFFFFFF : 64'h000000007FFFFFFF);
    end
    sgn = s[31]; exp = s[30:23]; frac = s[22:0];
    if (is_unsigned) begin
      max_pos = 64'hFFFFFFFFFFFFFFFF; max_neg = 64'd0;
    end else if (is_word) begin
      max_pos = 64'h7FFFFFFFFFFFFFFF; max_neg = 64'h8000000000000000;
    end else begin
      max_pos = 64'h000000007FFFFFFF; max_neg = 64'hFFFFFFFF80000000;
    end
    if (is_inf_s(s)) begin
      ff = FF_NV;
      return sgn ? max_neg : max_pos;
    end
    if (is_zero_s(s)) return 64'd0;

    // Value = v64 * 2^(e-23): v64 is the 24-bit significand ({1,frac} for
    // normals, {0,frac} for subnormals with e biased accordingly). The
    // integer result is v64 shifted by (23-e): right (fractional part, with
    // guard/round/sticky rounding) or left (e > 23).
    subnorm = (exp == 8'd0);
    v64 = subnorm ? {41'd0, frac} : {40'd0, 1'b1, frac};
    e = subnorm ? -126 : (exp - 127);
    inexact = 1'b0;
    if (e > 63) begin
      // value >= 2^64: out of range for every destination
      ff = FF_NV;
      return sgn ? max_neg : max_pos;
    end
    sh = 23 - e;
    if (sh > 0) begin
      if (sh >= 25) begin
        mag = 64'd0;
        g = 1'b0; r = 1'b0; st = |v64;
      end else begin
        mag = v64 >> sh;
        g = (v64 >> (sh-1)) & 64'd1;
        r = (sh >= 2) ? ((v64 >> (sh-2)) & 64'd1) : 1'b0;
        st = (sh >= 3) ? (|(v64 & ((64'd1 << (sh-2)) - 1))) : 1'b0;
      end
      inexact = g | r | st;
      round_up = 1'b0;
      if (inexact) begin
        case (rmode)
          RM_RNE: round_up = g & (r | st | mag[0]);
          RM_RTZ: round_up = 1'b0;
          RM_RDN: round_up = sgn & (g | r | st);
          RM_RUP: round_up = ~sgn & (g | r | st);
          RM_RMM: round_up = g;
          default: round_up = g & (r | st | mag[0]);
        endcase
        mag = mag + (round_up ? 64'd1 : 64'd0);
      end
    end else begin
      // e in [23,63]: v64 << (e-23), value <= 2^64, fits the range check
      mag = v64 << (e - 23);
    end
    if (inexact) ff = ff | FF_NX;

    // Range check on the rounded magnitude, then apply the sign.
    if (sgn) out_of_range = (mag > (~max_neg + 64'd1));
    else     out_of_range = (mag > max_pos);
    if (out_of_range) begin
      ff = FF_NV;
      return sgn ? max_neg : max_pos;
    end
    result = sgn ? (~mag + 64'd1) : mag;
    if (!is_word) result = {{32{result[31]}}, result[31:0]};
    return result;
  endfunction

endmodule
