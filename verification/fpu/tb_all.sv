`timescale 1ns/1ps
import fpuf_pkg::*;
module tb;
  integer fd, errors, tests;
  logic [31:0] sa, sb, res, exp_res;
  logic [2:0] op; logic [2:0] rmode; logic [4:0] ff;
  fpu_full dut(.sa(sa), .sb(sb), .op(op), .rmode(rmode), .res(res), .ff(ff));
  initial begin
    errors=0; tests=0; rmode=RM_RNE;
    fd = $fopen("vecs_all.txt","r");
    while ($fscanf(fd, "%h %h %d %h\n", sa, sb, op, exp_res) == 4) begin
      #1;
      tests = tests + 1;
      if (res !== exp_res) begin
        errors = errors + 1;
        if (errors <= 200) $display("MISMATCH a=%h b=%h op=%d got=%h exp=%h", sa, sb, op, res, exp_res);
      end
    end
    $fclose(fd);
    $display("FPU-all tests=%0d errors=%0d", tests, errors);
    if (errors == 0) $display("PASS"); else $display("FAIL");
    $finish;
  end
endmodule
