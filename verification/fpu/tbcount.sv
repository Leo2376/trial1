import fpuf_pkg::*;
module tb;
  integer fd, errors, tests, e0,e1,e2,e3,e4, t0,t1,t2,t3,t4;
  logic [31:0] sa, sb, res, exp_res;
  logic [2:0] op; logic [2:0] rmode; logic [4:0] ff;
  fpu_full dut(.sa(sa), .sb(sb), .op(op), .rmode(rmode), .res(res), .ff(ff));
  initial begin
    errors=0; tests=0; e0=0;e1=0;e2=0;e3=0;e4=0;t0=0;t1=0;t2=0;t3=0;t4=0;
    rmode=RM_RNE;
    fd = $fopen("vecs_all.txt","r");
    while ($fscanf(fd, "%h %h %d %h\n", sa, sb, op, exp_res) == 4) begin
      #1; tests=tests+1;
      case(op)
        0:t0=t0+1; 1:t1=t1+1; 2:t2=t2+1; 3:t3=t3+1; 4:t4=t4+1;
      endcase
      if (res !== exp_res) begin
        errors=errors+1;
        case(op)
          0:e0=e0+1; 1:e1=e1+1; 2:e2=e2+1; 3:e3=e3+1; 4:e4=e4+1;
        endcase
      end
    end
    $fclose(fd);
    $display("op0 fadd: %0d/%0d", e0,t0);
    $display("op1 fsub: %0d/%0d", e1,t1);
    $display("op2 fmul: %0d/%0d", e2,t2);
    $display("op3 fdiv: %0d/%0d", e3,t3);
    $display("op4 fsqrt: %0d/%0d", e4,t4);
    $display("TOTAL errors=%0d tests=%0d", errors, tests);
    if (errors==0) $display("PASS"); else $display("FAIL");
    $finish;
  end
endmodule
