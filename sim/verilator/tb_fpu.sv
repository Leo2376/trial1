`timescale 1ns/1ps
// Testbench for the integrated FPU module (rtl/core/fpu/fpu.sv).
// Vectors are taken from the riscv-tests rv64uf suite (fmadd.S, fadd.S,
// fdiv.S, fmin.S, fcmp.S, fclass.S, fcvt.S, fcvt_w.S, move.S) so the unit
// FPU is validated against the same expectations the core-level ISA tests
// enforce (result bits + exact fflags).
module tb_fpu;
  import rtl_core_pkg::*;

  logic clk = 0, rst_n = 0;
  logic start = 0;
  fpu_op_e op = FPU_NONE;
  logic [2:0] rm = RM_RNE;
  logic is_double = 0, is_unsigned = 0, is_word = 0;
  logic [63:0] a = 0, b = 0, c = 0;
  logic [63:0] result;
  logic [4:0] fflags;
  logic done, busy;

  always #5 clk = ~clk;

  fpu dut (
    .clk(clk), .rst_n(rst_n), .start(start), .op(op), .rm(rm),
    .is_double(is_double), .is_unsigned(is_unsigned), .is_word(is_word),
    .a(a), .b(b), .c(c),
    .result(result), .fflags(fflags), .done(done), .busy(busy)
  );

  task automatic do_op3(input fpu_op_e o, input logic [63:0] sa, input logic [63:0] sb,
                       input logic [63:0] sc, input logic [2:0] mode,
                       output logic [63:0] res, output logic [4:0] rff);
    @(negedge clk);
    // RV64D NaN-boxing: single-precision FP sources must be boxed, mirroring
    // what the core guarantees (double values and integer sources
    // I2F/MV_X2F stay raw).
    if (!is_double && o != FPU_I2F && o != FPU_MV_X2F) begin
      if (sa[63:32] != 32'hFFFFFFFF) sa = {32'hFFFFFFFF, sa[31:0]};
      if (sb[63:32] != 32'hFFFFFFFF) sb = {32'hFFFFFFFF, sb[31:0]};
      if (sc[63:32] != 32'hFFFFFFFF) sc = {32'hFFFFFFFF, sc[31:0]};
    end
    op = o; rm = mode; a = sa; b = sb; c = sc; start = 1;
    @(negedge clk);
    start = 0;
    while (!done) @(negedge clk);
    res = result; rff = fflags;
  endtask

  task automatic do_op(input fpu_op_e o, input logic [63:0] sa, input logic [63:0] sb,
                      input logic [2:0] mode, output logic [63:0] res,
                      output logic [4:0] rff);
    do_op3(o, sa, sb, 64'd0, mode, res, rff);
  endtask

  int errors = 0, tests = 0;
  logic [63:0] got;
  logic [4:0]  gff;

  task automatic chk64(input logic [63:0] exp, input logic [4:0] expff);
    tests++;
    if (got !== exp || gff !== expff) begin
      errors++;
      $display("FAIL op=%0s got=%h ff=%h exp=%h expff=%h", op.name(), got, gff, exp, expff);
    end
  endtask

  task automatic chk32(input logic [31:0] exp, input logic [4:0] expff);
    tests++;
    if (got[31:0] !== exp || gff !== expff) begin
      errors++;
      $display("FAIL op=%0s got=%h ff=%h exp=%h expff=%h", op.name(), got[31:0], gff, exp, expff);
    end
  endtask

  // IEEE single bit patterns used by the rv64uf vectors
  localparam logic [31:0] F_1_0    = 32'h3F800000;
  localparam logic [31:0] F_2_0    = 32'h40000000;
  localparam logic [31:0] F_2_5    = 32'h40200000;
  localparam logic [31:0] F_3_5    = 32'h40600000;
  localparam logic [31:0] F_5_0    = 32'h40A00000;
  localparam logic [31:0] F_M1_0   = 32'hBF800000;
  localparam logic [31:0] F_M2_0   = 32'hC0000000;
  localparam logic [31:0] F_M12    = 32'hC1400000;
  localparam logic [31:0] F_M1235_1= 32'hC49A6333;  // -1235.1
  localparam logic [31:0] F_11_10  = 32'h3F8CCCCD;  // 1.1
  localparam logic [31:0] F_M11_10 = 32'hBF8CCCCD;  // -1.1
  localparam logic [31:0] F_1236_2 = 32'h449A8666;  // 1236.2
  localparam logic [31:0] F_M1236_2= 32'hC49A8666;
  localparam logic [31:0] F_15     = 32'h3FC00000;  // 1.5
  localparam logic [31:0] F_M15    = 32'hBFC00000;  // -1.5
  localparam logic [31:0] F_8      = 32'h41000000;  // 8.0
  localparam logic [31:0] F_1234   = 32'h449A4000;  // 1234
  localparam logic [31:0] QNANF    = 32'h7FC00000;
  localparam logic [31:0] SNANF    = 32'h7F800001;
  localparam logic [31:0] INFF     = 32'h7F800000;
  localparam logic [31:0] NINFF    = 32'hFF800000;

  initial begin
    rst_n = 0;
    repeat (3) @(negedge clk);
    rst_n = 1;

    // ---------------- FADD/FSUB (riscv-tests fadd.S) ----------------
    do_op(FPU_FADD, F_2_5, F_1_0, RM_RNE, got, gff);  // 2.5+1.0 = 3.5
    chk32(F_3_5, 5'd0);
    do_op(FPU_FSUB, F_2_5, F_1_0, RM_RNE, got, gff);  // 2.5-1.0 = 1.5
    chk32(F_15, 5'd0);
    do_op(FPU_FSUB, F_M1235_1, F_11_10, RM_RNE, got, gff);  // -1235.1+1.1
    chk32(F_M1236_2, 5'd1);  // -1236.2, inexact
    do_op(FPU_FSUB, INFF, INFF, RM_RNE, got, gff);     // Inf-Inf
    chk32(QNANF, FF_NV);

    // ---------------- FMUL (fadd.S 8-10) ----------------
    do_op(FPU_FMUL, F_2_5, F_1_0, RM_RNE, got, gff);  // 2.5*1.0
    chk32(F_2_5, 5'd0);
    do_op(FPU_FMUL, F_M1235_1, F_M11_10, RM_RNE, got, gff); // (-1235.1)*(-1.1)
    chk32(32'h44A9D385, 5'd1);

    // ---------------- FDIV/FSQRT (fdiv.S) ----------------
    do_op(FPU_FDIV, F_M2_0, F_2_0, RM_RNE, got, gff);  // -2/2 = -1
    chk32(F_M1_0, 5'd0);
    do_op(FPU_FSQRT, 32'h42C80000, 64'd0, RM_RNE, got, gff);  // sqrt(100)=10
    chk32(32'h41200000, 5'd0);
    do_op(FPU_FSQRT, F_M1_0, 64'd0, RM_RNE, got, gff);        // sqrt(-1)
    chk32(QNANF, FF_NV);

    // ---------------- FMADD family (fmadd.S) ----------------
    // FMADD 1.0*2.5+1.0 = 3.5
    do_op3(FPU_FMADD, F_1_0, F_2_5, F_1_0, RM_RNE, got, gff);
    chk32(F_3_5, 5'd0);
    // FMADD (-1.0)*(-1235.1)+1.1 = 1236.2 (inexact)
    do_op3(FPU_FMADD, F_M1_0, F_M1235_1, F_11_10, RM_RNE, got, gff);
    chk32(F_1236_2, 5'd1);
    // FMADD 2.0*(-5.0)+(-2.0) = -12
    do_op3(FPU_FMADD, F_2_0, 32'hC0A00000, 32'hC0000000, RM_RNE, got, gff);
    chk32(F_M12, 5'd0);
    // FNMADD 1.0*2.5+1.0 -> -(3.5)
    do_op3(FPU_FNMADD, F_1_0, F_2_5, F_1_0, RM_RNE, got, gff);
    chk32(32'hC0600000, 5'd0);
    // FNMADD (-1.0)*(-1235.1)+1.1 -> -(1236.2)
    do_op3(FPU_FNMADD, F_M1_0, F_M1235_1, F_11_10, RM_RNE, got, gff);
    chk32(F_M1236_2, 5'd1);
    // FMSUB 1.0*2.5-1.0 = 1.5
    do_op3(FPU_FMSUB, F_1_0, F_2_5, F_1_0, RM_RNE, got, gff);
    chk32(F_15, 5'd0);
    // FMSUB (-1.0)*(-1235.1)-1.1 = 1234
    do_op3(FPU_FMSUB, F_M1_0, F_M1235_1, F_11_10, RM_RNE, got, gff);
    chk32(F_1234, 5'd1);
    // FNMSUB 1.0*2.5-1.0 -> -(1.5)
    do_op3(FPU_FNMSUB, F_1_0, F_2_5, F_1_0, RM_RNE, got, gff);
    chk32(F_M15, 5'd0);
    // FNMSUB 2.0*(-5.0)-(-2.0) = 8 per fmadd.S vector 13
    do_op3(FPU_FNMSUB, F_2_0, 32'hC0A00000, 32'hC0000000, RM_RNE, got, gff);
    chk32(F_8, 5'd0);
    // FMADD with zero addend: product of 1.0*2.5 stays
    do_op3(FPU_FMADD, F_1_0, F_2_5, 32'h00000000, RM_RNE, got, gff);
    chk32(F_2_5, 5'd0);

    // ---------------- FMIN/FMAX (fmin.S) ----------------
    do_op(FPU_FMIN, F_2_5, F_1_0, RM_RNE, got, gff);
    chk32(F_1_0, 5'd0);
    do_op(FPU_FMAX, F_2_5, F_1_0, RM_RNE, got, gff);
    chk32(F_2_5, 5'd0);
    do_op(FPU_FMIN, F_M1235_1, F_11_10, RM_RNE, got, gff);
    chk32(F_M1235_1, 5'd0);
    // FMIN(+0,-0) = -0
    do_op(FPU_FMIN, 32'h00000000, 32'h80000000, RM_RNE, got, gff);
    chk32(32'h80000000, 5'd0);
    // FMAX(sNaN, 1.0) = 1.0, NV
    do_op(FPU_FMAX, SNANF, F_1_0, RM_RNE, got, gff);
    chk32(F_1_0, FF_NV);

    // ---------------- FCMP (fcmp.S) ----------------
    do_op(FPU_FEQ, 32'hBFAE147B, 32'hBFAE147B, RM_RNE, got, gff); // -1.36
    chk32(32'd1, 5'd0);
    do_op(FPU_FLT, 32'hBFAE147B, 32'hBFAE147B, RM_RNE, got, gff);
    chk32(32'd0, 5'd0);
    do_op(FPU_FLE, 32'hBFAE147B, 32'hBFAE147B, RM_RNE, got, gff);
    chk32(32'd1, 5'd0);
    do_op(FPU_FLT, QNANF, F_1_0, RM_RNE, got, gff);
    chk32(32'd0, FF_NV);

    // ---------------- FSGNJ family ----------------
    do_op(FPU_FSGNJ, 32'h3F800000, 32'hBF800000, RM_RNE, got, gff);
    chk32(32'hBF800000, 5'd0);
    do_op(FPU_FSGNJN, 32'h3F800000, 32'hBF800000, RM_RNE, got, gff);
    chk32(32'h3F800000, 5'd0);
    do_op(FPU_FSGNJX, 32'hBF800000, 32'hBF800000, RM_RNE, got, gff);
    chk32(32'h3F800000, 5'd0);

    // ---------------- FCLASS (fclass.S) ----------------
    do_op(FPU_CLASS, NINFF, 64'd0, RM_RNE, got, gff);  chk32(32'd1<<0, 5'd0);
    do_op(FPU_CLASS, 32'hBF800000, 64'd0, RM_RNE, got, gff); chk32(32'd1<<1, 5'd0);
    do_op(FPU_CLASS, 32'h807FFFFF, 64'd0, RM_RNE, got, gff); chk32(32'd1<<2, 5'd0);
    do_op(FPU_CLASS, 32'h80000000, 64'd0, RM_RNE, got, gff); chk32(32'd1<<3, 5'd0);
    do_op(FPU_CLASS, 32'h00000000, 64'd0, RM_RNE, got, gff); chk32(32'd1<<4, 5'd0);
    do_op(FPU_CLASS, 32'h007FFFFF, 64'd0, RM_RNE, got, gff); chk32(32'd1<<5, 5'd0);
    do_op(FPU_CLASS, F_1_0, 64'd0, RM_RNE, got, gff);  chk32(32'd1<<6, 5'd0);
    do_op(FPU_CLASS, INFF, 64'd0, RM_RNE, got, gff);   chk32(32'd1<<7, 5'd0);
    do_op(FPU_CLASS, SNANF, 64'd0, RM_RNE, got, gff);  chk32(32'd1<<8, 5'd0);
    do_op(FPU_CLASS, QNANF, 64'd0, RM_RNE, got, gff);  chk32(32'd1<<9, 5'd0);

    // ---------------- FCVT int->fp (fcvt.S) ----------------
    is_unsigned = 0; is_word = 0;
    do_op(FPU_I2F, 64'd2, 64'd0, RM_RNE, got, gff);       // fcvt.s.w 2 -> 2.0
    chk32(F_2_0, 5'd0);
    do_op(FPU_I2F, -64'd2, 64'd0, RM_RNE, got, gff);      // fcvt.s.w -2 -> -2.0
    chk32(32'hC0000000, 5'd0);
    is_unsigned = 1;
    do_op(FPU_I2F, -64'd2, 64'd0, RM_RNE, got, gff);      // fcvt.s.wu 0xFFFFFFFE
    chk32(32'h4F800000, 5'd1);
    is_unsigned = 0; is_word = 1;
    do_op(FPU_I2F, -64'd2, 64'd0, RM_RNE, got, gff);      // fcvt.s.l -2 -> -2.0
    chk32(32'hC0000000, 5'd0);
    is_unsigned = 1;
    do_op(FPU_I2F, -64'd2, 64'd0, RM_RNE, got, gff);      // fcvt.s.lu 2^64-2
    chk32(32'h5F800000, 5'd1);
    is_unsigned = 0; is_word = 0;

    // ---------------- FCVT fp->int (fcvt_w.S) ----------------
    // fcvt.w.s(-1.1, rtz) = -1, NX
    do_op(FPU_F2I, 32'hBF8CCCCD, 64'd0, RM_RTZ, got, gff);
    chk32(32'hFFFFFFFF, FF_NX);
    // fcvt.w.s(-1.0) = -1 exact
    do_op(FPU_F2I, F_M1_0, 64'd0, RM_RNE, got, gff);
    chk32(32'hFFFFFFFF, 5'd0);
    // fcvt.w.s(1.1, rtz) = 1, NX
    do_op(FPU_F2I, F_11_10, 64'd0, RM_RTZ, got, gff);
    chk32(32'd1, FF_NX);
    // fcvt.w.s(3e9, rtz) saturates to 2^31-1, NV
    do_op(FPU_F2I, 32'h4F32D05E, 64'd0, RM_RTZ, got, gff);
    chk32(32'h000000007FFFFFFF, FF_NV);
    is_unsigned = 1;
    // fcvt.wu.s(3e9, rtz) = 3000000000
    do_op(FPU_F2I, 32'h4F32D05E, 64'd0, RM_RTZ, got, gff);
    chk64(64'hFFFFFFFFB2D05E00, 5'd0);  // W result sign-extended to XLEN
    // fcvt.wu.s(-3.0, rtz) saturates to 0, NV
    do_op(FPU_F2I, 32'hC0400000, 64'd0, RM_RTZ, got, gff);
    chk32(32'd0, FF_NV);
    // fcvt.wu.s(-1.0) -> 0, NV
    do_op(FPU_F2I, F_M1_0, 64'd0, RM_RNE, got, gff);
    chk32(32'd0, FF_NV);
    is_unsigned = 0;
    // fcvt.l.s(-1.0) = -1
    is_word = 1;
    do_op(FPU_F2I, F_M1_0, 64'd0, RM_RNE, got, gff);
    chk64(64'hFFFFFFFFFFFFFFFF, 5'd0);
    // fcvt.l.s(3e9, rtz) = 3000000000
    do_op(FPU_F2I, 32'h4F32D05E, 64'd0, RM_RTZ, got, gff);
    chk64(64'd3000000000, 5'd0);
    // fcvt.l.s(NaN) = 2^63-1, NV
    do_op(FPU_F2I, QNANF, 64'd0, RM_RNE, got, gff);
    chk64(64'h7FFFFFFFFFFFFFFF, FF_NV);
    // fcvt.l.s(-Inf) = -2^63, NV
    do_op(FPU_F2I, NINFF, 64'd0, RM_RNE, got, gff);
    chk64(64'h8000000000000000, FF_NV);
    // fcvt.lu.s(3e9, rtz) = 3000000000
    is_unsigned = 1;
    do_op(FPU_F2I, 32'h4F32D05E, 64'd0, RM_RTZ, got, gff);
    chk64(64'd3000000000, 5'd0);
    // fcvt.lu.s(-3.0) = 0, NV
    do_op(FPU_F2I, 32'hC0400000, 64'd0, RM_RTZ, got, gff);
    chk64(64'd0, FF_NV);
    is_unsigned = 0; is_word = 0;

    // ---------------- FMV ----------------
    // FMV.W.X is a full XLEN-bit copy (never NaN-boxes): unboxed patterns
    // round-trip exactly (Unicorn lock-step caught the old boxing here).
    do_op(FPU_MV_X2F, 32'hDEADBEEF, 64'd0, RM_RNE, got, gff);
    chk64(64'h00000000DEADBEEF, 5'd0);
    do_op(FPU_MV_X2F, 64'hFFFFFFFFDEADBEEF, 64'd0, RM_RNE, got, gff);
    chk64(64'hFFFFFFFFDEADBEEF, 5'd0);
    do_op(FPU_MV_F2X, 32'hCAFEBABE, 64'd0, RM_RNE, got, gff);
    chk64({32'hFFFFFFFF, 32'hCAFEBABE}, 5'd0);

    // ---------------- Double-precision (rv64ud mirror) ----------------
    is_double = 1; is_unsigned = 0; is_word = 0;
    // FADD.D 2.5+1.0=3.5 / FSUB.D 2.5-1.0=1.5
    do_op(FPU_FADD, 64'h4004000000000000, 64'h3FF0000000000000, RM_RNE, got, gff);
    chk64(64'h400C000000000000, 5'd0);
    do_op(FPU_FSUB, 64'h4004000000000000, 64'h3FF0000000000000, RM_RNE, got, gff);
    chk64(64'h3FF8000000000000, 5'd0);
    // FADD.D -1235.1+1.1=-1234.0 inexact
    do_op(FPU_FADD, 64'hC0934C6666666666, 64'h3FF199999999999A, RM_RNE, got, gff);
    chk64(64'hC093480000000000, 5'd1);
    // FMUL.D 2.5*2.0=5.0 / FDIV.D 1.0/2.0=0.5 / FSQRT.D(4.0)=2.0
    do_op(FPU_FMUL, 64'h4004000000000000, 64'h4000000000000000, RM_RNE, got, gff);
    chk64(64'h4014000000000000, 5'd0);
    do_op(FPU_FDIV, 64'h3FF0000000000000, 64'h4000000000000000, RM_RNE, got, gff);
    chk64(64'h3FE0000000000000, 5'd0);
    do_op(FPU_FSQRT, 64'h4010000000000000, 64'd0, RM_RNE, got, gff);
    chk64(64'h4000000000000000, 5'd0);
    // FMADD.D 1.0*2.5+1.0=3.5
    do_op3(FPU_FMADD, 64'h3FF0000000000000, 64'h4004000000000000,
           64'h3FF0000000000000, RM_RNE, got, gff);
    chk64(64'h400C000000000000, 5'd0);
    // FMIN.D/FMAX.D/FEQ.D/FLT.D/FCLASS.D
    do_op(FPU_FMIN, 64'h4004000000000000, 64'h3FF0000000000000, RM_RNE, got, gff);
    chk64(64'h3FF0000000000000, 5'd0);
    do_op(FPU_FMAX, 64'h4004000000000000, 64'h3FF0000000000000, RM_RNE, got, gff);
    chk64(64'h4004000000000000, 5'd0);
    do_op(FPU_FEQ, 64'h3FF0000000000000, 64'h3FF0000000000000, RM_RNE, got, gff);
    chk64(64'd1, 5'd0);
    do_op(FPU_FLT, 64'h3FF0000000000000, 64'h4000000000000000, RM_RNE, got, gff);
    chk64(64'd1, 5'd0);
    do_op(FPU_CLASS, 64'h3FF0000000000000, 64'd0, RM_RNE, got, gff);
    chk64(64'd1<<6, 5'd0);
    // FCVT.D.W(2)=2.0 / FCVT.W.D(1.5,rtz)=1,NX / FCVT.S.D/FCVT.D.S roundtrip
    do_op(FPU_I2F, 64'd2, 64'd0, RM_RNE, got, gff);
    chk64(64'h4000000000000000, 5'd0);
    do_op(FPU_F2I, 64'h3FF8000000000000, 64'd0, RM_RTZ, got, gff);
    chk64(64'd1, FF_NX);
    do_op(FPU_D2F, 64'hC0934C6666666666, 64'd0, RM_RNE, got, gff);
    chk64({32'hFFFFFFFF, 32'hC49A6333}, 5'd1);
    do_op(FPU_F2D, 64'hFFFFFFFFBFC00000, 64'd0, RM_RNE, got, gff);
    chk64(64'hBFF8000000000000, 5'd0);
    // FMV.D.X / FMV.X.D full-width copies
    do_op(FPU_MV_X2F, 64'hDEADBEEFCAFEBABE, 64'd0, RM_RNE, got, gff);
    chk64(64'hDEADBEEFCAFEBABE, 5'd0);
    do_op(FPU_MV_F2X, 64'hCAFEBABEDEADBEEF, 64'd0, RM_RNE, got, gff);
    chk64(64'hCAFEBABEDEADBEEF, 5'd0);
    is_double = 0;

    $display("TOTAL errors=%0d tests=%0d %s", errors, tests, (errors==0) ? "PASS" : "FAIL");
    if (errors != 0) $fatal(1, "FPU unit test FAILED");
    $finish;
  end
endmodule
