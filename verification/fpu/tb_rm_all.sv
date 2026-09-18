`timescale 1ns/1ps
import fpuf_pkg::*;
module tb;
  integer fd, errors, tests;
  integer e_rm[0:4]; integer t_rm[0:4];
  logic [31:0] sa, sb, res, exp_res;
  logic [2:0] op; logic [2:0] rmode; logic [4:0] ff;
  integer rm_i;
  fpu_full dut(.sa(sa), .sb(sb), .op(op), .rmode(rmode), .res(res), .ff(ff));
  initial begin
    errors=0; tests=0;
    for (integer j=0;j<5;j=j+1) begin e_rm[j]=0; t_rm[j]=0; end
    fd = $fopen("vecs_rm_all.txt","r");
    while ($fscanf(fd, "%h %h %d %d %h\n", sa, sb, op, rm_i, exp_res) == 5) begin
      rmode = rm_i[2:0];
      #1;
      tests = tests + 1;
      t_rm[rm_i] = t_rm[rm_i] + 1;
      if (res !== exp_res) begin
        errors = errors + 1;
        e_rm[rm_i] = e_rm[rm_i] + 1;
        if (errors <= 60) $display("MISMATCH a=%h b=%h op=%d rm=%d got=%h exp=%h", sa, sb, op, rm_i, res, exp_res);
      end
    end
    $fclose(fd);
    $display("RNE   errors=%0d/%0d", e_rm[0], t_rm[0]);
    $display("RTZ   errors=%0d/%0d", e_rm[1], t_rm[1]);
    $display("RDN   errors=%0d/%0d", e_rm[2], t_rm[2]);
    $display("RUP   errors=%0d/%0d", e_rm[3], t_rm[3]);
    $display("RMM   errors=%0d/%0d", e_rm[4], t_rm[4]);
    $display("TOTAL errors=%0d tests=%0d", errors, tests);
    if (errors==0) $display("PASS"); else $display("FAIL");
    $finish;
  end
endmodule
