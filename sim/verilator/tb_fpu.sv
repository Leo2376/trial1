`timescale 1ns/1ps
// Testbench for the integrated FPU module (rtl/core/fpu/fpu.sv).
// Smoke test of the single-precision datapath and the core<->FPU op mapping
// (compute_result_s) used by the rv64uf ISA tests.
module tb_fpu;
  import rtl_core_pkg::*;

  logic clk = 0, rst_n = 0;
  logic start = 0;
  fpu_op_e op = FPU_NONE;
  logic [2:0] rm = RM_RNE;
  logic is_double = 0, is_unsigned = 0, is_word = 0;
  logic [63:0] a = 0, b = 0;
  logic [63:0] result;
  logic [4:0] fflags;
  logic done, busy;

  always #5 clk = ~clk;

  fpu dut (
    .clk(clk), .rst_n(rst_n), .start(start), .op(op), .rm(rm),
    .is_double(is_double), .is_unsigned(is_unsigned), .is_word(is_word),
    .a(a), .b(b), .result(result), .fflags(fflags), .done(done), .busy(busy)
  );

  task automatic do_op(input fpu_op_e o, input logic [31:0] sa, input logic [31:0] sb,
                       input logic [2:0] mode, output logic [31:0] res);
    @(negedge clk);
    op = o; rm = mode; a = {32'h0, sa}; b = {32'h0, sb}; start = 1;
    @(negedge clk);
    start = 0;
    while (!done) @(negedge clk);
    res = result[31:0];
  endtask

  int errors = 0, tests = 0;
  logic [31:0] got, exp;

  // Reference using real arithmetic: convert single bits to real via $bitstoreal
  // on the raw bit pattern (Verilator supports $bitstoreal on 64-bit patterns;
  // single-precision bit patterns must be widened with the exponent rebiased).
  // Simpler approach: use shorts. Here we use $realtobits/$bitstoreal on the
  // double that equals the single value: the single bits are a valid double
  // only after conversion, so we re-derive via a real-typed conversion helper.
  function automatic real bits_to_real(input logic [31:0] s);
    // Decode single-precision manually into a real.
    real frac, val;
    int e;
    frac = 0.0;
    for (int k = 22; k >= 0; k--) if (s[k]) frac = frac + ($rtoi(2)**(-(23-k))) * 1.0;
    // value = (-1)^sign * 2^(e-127) * (1 + frac_field/2^23)
    val = 1.0 + (s[22:0] * 1.0) / (2.0**23);
    e = s[30:23];
    if (e == 0) begin
      val = (s[22:0] * 1.0) / (2.0**23);
      e = 1;
    end
    val = val * (2.0**(e - 127));
    if (s[31]) val = -val;
    return val;
  endfunction

  function automatic logic [31:0] real_to_bits(input real r);
    // Encode a real to single precision (RNE), only valid for the normal range.
    int e;
    real frac;
    logic [31:0] s;
    logic [7:0] eb;
    logic [22:0] fr;
    logic sg;
    sg = (r < 0.0);
    if (r < 0.0) r = -r;
    if (r == 0.0) return sg ? 32'h80000000 : 32'h00000000;
    e = $rtoi($floor($log2(r)));
    frac = r / (2.0**e) - 1.0;
    fr = $rtoi(frac * (2.0**23));
    eb = e + 127;
    return {sg, eb[7:0], fr};
  endfunction

  function automatic logic [31:0] ref_s(input logic [31:0] sa, input logic [31:0] sb,
                                        input fpu_op_e o);
    real ra, rb, rr;
    ra = bits_to_real(sa); rb = bits_to_real(sb);
    case (o)
      FPU_FADD:  rr = ra + rb;
      FPU_FSUB:  rr = ra - rb;
      FPU_FMUL:  rr = ra * rb;
      FPU_FDIV:  rr = ra / rb;
      default:   rr = 0.0;
    endcase
    return real_to_bits(rr);
  endfunction

  logic [31:0] vec_a [0:5];
  logic [31:0] vec_b [0:5];
  int i;

  initial begin
    vec_a[0] = 32'h3F800000; vec_b[0] = 32'h40000000; // 1.0 + 2.0 = 3.0
    vec_a[1] = 32'hBF800000; vec_b[1] = 32'h3F000000; // -1.0 + 0.5 = -0.5
    vec_a[2] = 32'h40490FDB; vec_b[2] = 32'h402DF854; // pi * e
    vec_a[3] = 32'h41200000; vec_b[3] = 32'hC0A00000; // 10.0 / -5.0 = -2.0
    vec_a[4] = 32'h3F000000; vec_b[4] = 32'h40400000; // 0.5 * 3.0 = 1.5
    vec_a[5] = 32'h40490FDB; vec_b[5] = 32'h40490FDB; // pi / pi = 1.0

    rst_n = 0;
    repeat (3) @(negedge clk);
    rst_n = 1;

    for (i = 0; i < 6; i++) begin
      do_op(FPU_FADD, vec_a[i], vec_b[i], RM_RNE, got);
      exp = ref_s(vec_a[i], vec_b[i], FPU_FADD);
      tests++;
      if (got !== exp) begin errors++; $display("FADD fail a=%h b=%h got=%h exp=%h", vec_a[i], vec_b[i], got, exp); end
    end
    for (i = 0; i < 6; i++) begin
      do_op(FPU_FSUB, vec_a[i], vec_b[i], RM_RNE, got);
      exp = ref_s(vec_a[i], vec_b[i], FPU_FSUB);
      tests++;
      if (got !== exp) begin errors++; $display("FSUB fail a=%h b=%h got=%h exp=%h", vec_a[i], vec_b[i], got, exp); end
    end
    for (i = 0; i < 6; i++) begin
      do_op(FPU_FMUL, vec_a[i], vec_b[i], RM_RNE, got);
      exp = ref_s(vec_a[i], vec_b[i], FPU_FMUL);
      tests++;
      if (got !== exp) begin errors++; $display("FMUL fail a=%h b=%h got=%h exp=%h", vec_a[i], vec_b[i], got, exp); end
    end
    for (i = 0; i < 6; i++) begin
      do_op(FPU_FDIV, vec_a[i], vec_b[i], RM_RNE, got);
      exp = ref_s(vec_a[i], vec_b[i], FPU_FDIV);
      tests++;
      if (got !== exp) begin errors++; $display("FDIV fail a=%h b=%h got=%h exp=%h", vec_a[i], vec_b[i], got, exp); end
    end

    // FSQRT(4.0) = 2.0
    do_op(FPU_FSQRT, 32'h40800000, 32'h0, RM_RNE, got);
    tests++;
    if (got !== 32'h40000000) begin errors++; $display("FSQRT fail got=%h", got); end

    // FSQRT(2.0) = 1.4142135...
    do_op(FPU_FSQRT, 32'h40000000, 32'h0, RM_RNE, got);
    tests++;
    if (got !== 32'h3FB504F3) begin errors++; $display("FSQRT2 fail got=%h", got); end

    // FMIN/FMAX
    do_op(FPU_FMIN, 32'hBF800000, 32'h3F800000, RM_RNE, got);
    tests++;
    if (got !== 32'hBF800000) begin errors++; $display("FMIN fail got=%h", got); end
    do_op(FPU_FMAX, 32'hBF800000, 32'h3F800000, RM_RNE, got);
    tests++;
    if (got !== 32'h3F800000) begin errors++; $display("FMAX fail got=%h", got); end

    // FSGNJ family
    do_op(FPU_FSGNJ, 32'h3F800000, 32'hBF800000, RM_RNE, got);
    tests++;
    if (got !== 32'hBF800000) begin errors++; $display("FSGNJ fail got=%h", got); end
    do_op(FPU_FSGNJN, 32'h3F800000, 32'hBF800000, RM_RNE, got);
    tests++;
    if (got !== 32'h3F800000) begin errors++; $display("FSGNJN fail got=%h", got); end
    do_op(FPU_FSGNJX, 32'hBF800000, 32'hBF800000, RM_RNE, got);
    tests++;
    if (got !== 32'h3F800000) begin errors++; $display("FSGNJX fail got=%h", got); end

    // FEQ/FLT/FLE (compare results come back as 0/1 in bit 0)
    do_op(FPU_FEQ, 32'h3F800000, 32'h3F800000, RM_RNE, got);
    tests++;
    if (got[0] !== 1'b1) begin errors++; $display("FEQ fail got=%h", got); end
    do_op(FPU_FLT, 32'hBF800000, 32'h3F800000, RM_RNE, got);
    tests++;
    if (got[0] !== 1'b1) begin errors++; $display("FLT fail got=%h", got); end
    do_op(FPU_FLE, 32'h3F800000, 32'h3F800000, RM_RNE, got);
    tests++;
    if (got[0] !== 1'b1) begin errors++; $display("FLE fail got=%h", got); end

    // FMV ops (core mapping)
    do_op(FPU_MV_X2F, 32'hDEADBEEF, 32'h0, RM_RNE, got);
    tests++;
    if (got !== 32'hDEADBEEF) begin errors++; $display("MV_X2F fail got=%h", got); end
    do_op(FPU_MV_F2X, 32'hCAFEBABE, 32'h0, RM_RNE, got);
    tests++;
    if (got !== 32'hCAFEBABE) begin errors++; $display("MV_F2X fail got=%h", got); end

    // F2I: 1.0 -> 1
    do_op(FPU_F2I, 32'h3F800000, 32'h0, RM_RNE, got);
    tests++;
    if (got !== 32'h1) begin errors++; $display("F2I fail got=%h", got); end

    // I2F: 2 -> 2.0
    do_op(FPU_I2F, 32'h2, 32'h0, RM_RNE, got);
    tests++;
    if (got !== 32'h40000000) begin errors++; $display("I2F fail got=%h", got); end

    // FCLASS of +1.0 -> bit 6 (positive normal)
    do_op(FPU_CLASS, 32'h3F800000, 32'h0, RM_RNE, got);
    tests++;
    if (got !== 32'h40) begin errors++; $display("FCLASS fail got=%h", got); end

    $display("TOTAL errors=%0d tests=%0d %s", errors, tests, (errors==0) ? "PASS" : "FAIL");
    $finish;
  end
endmodule
