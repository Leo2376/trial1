`timescale 1ns/1ps
// Unit testbench for the RVC decompressor (rtl/core/frontend/decompressor.sv).
// Directed vectors cover every RV64C encoding used by riscv-tests rv64uc/rvc.S
// plus the FLD/FSD family and illegal/reserved cases. Expected 32-bit
// expansions were captured from riscv64-unknown-elf-gcc (rv64gc) assembling
// the compressed mnemonic and its 32-bit equivalent with .option norvc.
module tb_decompressor;
  logic [15:0] cin;
  logic [31:0] iout;
  logic        is_c;
  logic        illegal;

  decompressor dut (.cin(cin), .iout(iout), .is_c(is_c), .illegal(illegal));

  int errors = 0, tests = 0;
  task automatic chk(input logic [15:0] c, input logic [31:0] exp,
                     input logic exp_c, input logic exp_ill, input string name);
    cin = c; #1;
    tests++;
    if (iout !== exp || is_c !== exp_c || illegal !== exp_ill) begin
      errors++;
      $display("FAIL %-10s cin=%04h got=%08h(is_c=%b ill=%b) exp=%08h(is_c=%b ill=%b)",
               name, c, iout, is_c, illegal, exp, exp_c, exp_ill);
    end
  endtask

  initial begin
    // Q0
    chk(16'h0804, 32'h01010493, 1, 0, "addi4spn");
    chk(16'h4144, 32'h00452483, 1, 0, "lw");
    chk(16'h6504, 32'h00853483, 1, 0, "ld");
    chk(16'hc144, 32'h00952223, 1, 0, "sw");
    chk(16'he504, 32'h00953423, 1, 0, "sd");
    chk(16'h2504, 32'h00853487, 1, 0, "fld");
    chk(16'ha504, 32'h00953427, 1, 0, "fsd");
    chk(16'h0000, 32'h00000013, 1, 1, "addi4spn0");
    // Q1
    chk(16'h0001, 32'h00000013, 1, 0, "nop");
    chk(16'h0505, 32'h00150513, 1, 0, "addi");
    chk(16'h4505, 32'h00100513, 1, 0, "li");
    chk(16'h2505, 32'h0015051b, 1, 0, "addiw");
    chk(16'h6505, 32'h00001537, 1, 0, "lui");
    chk(16'h6141, 32'h01010113, 1, 0, "addi16sp");
    chk(16'h8089, 32'h0024d493, 1, 0, "srli");
    chk(16'h8489, 32'h4024d493, 1, 0, "srai");
    chk(16'h8889, 32'h0024f493, 1, 0, "andi");
    chk(16'h8c89, 32'h40a484b3, 1, 0, "sub");
    chk(16'h8ca9, 32'h00a4c4b3, 1, 0, "xor");
    chk(16'h8cc9, 32'h00a4e4b3, 1, 0, "or");
    chk(16'h8ce9, 32'h00a4f4b3, 1, 0, "and");
    chk(16'h9c89, 32'h40a484bb, 1, 0, "subw");
    chk(16'h9ca9, 32'h00a484bb, 1, 0, "addw");
    chk(16'ha001, 32'h0000006f, 1, 0, "j");
    chk(16'hc081, 32'h00048063, 1, 0, "beqz");
    chk(16'he081, 32'h00049063, 1, 0, "bnez");
    chk(16'h2001, 32'h00000013, 1, 1, "addiw0");
    chk(16'h9c61, 32'h00000013, 1, 1, "rsv-zcb");
    // Q2
    chk(16'h050a, 32'h00251513, 1, 0, "slli");
    chk(16'h4542, 32'h01012503, 1, 0, "lwsp");
    chk(16'h6542, 32'h01013503, 1, 0, "ldsp");
    chk(16'h2542, 32'h01013507, 1, 0, "fldsp");
    chk(16'h8502, 32'h00050067, 1, 0, "jr");
    chk(16'h852e, 32'h00b00533, 1, 0, "mv");
    chk(16'h9502, 32'h000500e7, 1, 0, "jalr");
    chk(16'h952e, 32'h00b50533, 1, 0, "add");
    chk(16'h9002, 32'h00100073, 1, 0, "ebreak");
    chk(16'hc82e, 32'h00b12823, 1, 0, "swsp");
    chk(16'he82e, 32'h00b13823, 1, 0, "sdsp");
    chk(16'ha82e, 32'h00b13827, 1, 0, "fsdsp");
    chk(16'h4002, 32'h00000013, 1, 1, "lwsp0");
    chk(16'h6002, 32'h00000013, 1, 1, "ldsp0");
    chk(16'h8002, 32'h00000013, 1, 1, "jr0");

    // Non-compressed bypass flag (op==11): is_c==0, illegal==0
    cin = 16'h0093; #1; tests++;
    if (is_c !== 1'b0 || illegal !== 1'b0) begin
      errors++;
      $display("FAIL bypass is_c=%b ill=%b (want 0,0)", is_c, illegal);
    end

    $display("TOTAL errors=%0d tests=%0d %s", errors, tests, (errors==0) ? "PASS" : "FAIL");
    if (errors != 0) $fatal(1, "decompressor unit test FAILED");
    $finish;
  end
endmodule
