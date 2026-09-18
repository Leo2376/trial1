`timescale 1ns/1ps
import fpu_pkg::*;
module tb;
  integer fd, errors, tests;
  logic [31:0] sa, sb, res, exp_res;
  logic sub; logic [2:0] rmode; logic [4:0] ff;
  integer rm_i;
  fpu_s dut(.sa(sa), .sb(sb), .sub(sub), .rmode(rmode), .res(res), .ff(ff));
  initial begin
    errors=0; tests=0;
    fd = $fopen("vecs_rm.txt","r");
    while ($fscanf(fd, "%h %h %d %d %h\n", sa, sb, sub, rm_i, exp_res) == 5) begin
      rmode = rm_i[2:0];
      #1;
      tests = tests + 1;
      if (res !== exp_res) begin
        errors = errors + 1;
        if (errors <= 40) $display("MISMATCH a=%h b=%h sub=%b rm=%d got=%h exp=%h", sa, sb, sub, rm_i, res, exp_res);
      end
    end
    $fclose(fd);
    $display("FADD/FSUB all-RM tests=%0d errors=%0d", tests, errors);
    if (errors == 0) $display("PASS"); else $display("FAIL");
    $finish;
  end
endmodule
