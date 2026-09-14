`timescale 1ns/1ps
import fpu_pkg::*;
module tb;
  integer fd, r, errors, tests;
  logic [31:0] sa, sb, res, exp_res;
  logic sub; logic [2:0] rmode; logic [4:0] ff;
  fpu_s dut(.sa(sa), .sb(sb), .sub(sub), .rmode(rmode), .res(res), .ff(ff));
  initial begin
    errors=0; tests=0; rmode=RM_RNE;
    fd = $fopen("vecs.txt","r");
    while ($fscanf(fd, "%h %h %d %h\n", sa, sb, sub, exp_res) == 4) begin
      #1;
      tests = tests + 1;
      if (res !== exp_res) begin
        errors = errors + 1;
        if (errors <= 40) $display("MISMATCH a=%h b=%h sub=%b got=%h exp=%h", sa, sb, sub, res, exp_res);
      end
    end
    $fclose(fd);
    $display("FADD/FSUB-RNE tests=%0d errors=%0d", tests, errors);
    if (errors == 0) $display("PASS"); else $display("FAIL");
    $finish;
  end
endmodule
