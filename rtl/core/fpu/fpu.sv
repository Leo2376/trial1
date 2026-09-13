module fpu #(
  parameter int XLEN = 64
) (
  input  logic              clk,
  input  logic              rst_n,
  input  logic              start,
  input  rtl_core_pkg::fpu_op_e op,
  input  logic [2:0]        rm,
  input  logic [XLEN-1:0]   a,
  input  logic [XLEN-1:0]   b,
  output logic [XLEN-1:0]   result,
  output logic [4:0]        fflags,
  output logic              done,
  output logic              busy
);
  import rtl_core_pkg::*;

  typedef enum logic [1:0] { F_IDLE, F_BUSY, F_DONE } fst_e;
  fst_e st;

  logic [63:0] res_r;
  logic [4:0]  fflags_r;

  assign result = res_r;
  assign fflags = fflags_r;
  assign done   = (st == F_DONE);
  assign busy   = (st == F_BUSY);

  logic is_dbl_a, is_dbl_b;
  logic [31:0] as_single, bs_single;
  logic [63:0] as_dbl, bs_dbl;
  logic [31:0] a_single_res;

  assign a_single_res = dbl2single(a);

  function automatic logic [31:0] dbl2single(input logic [63:0] d);
    logic [1:0]  sgn; logic [10:0] exp; logic [51:0] man;
    logic [31:0] s;
    sgn = d[63]; exp = d[62:52]; man = d[51:0];
    s[31] = sgn[0];
    s[30:23] = (exp == 0) ? 8'd0 : (exp - 11'd1023 + 11'd127);
    s[22:0] = man[51:29];
    return s;
  endfunction

  function automatic logic [63:0] single2dbl(input logic [31:0] s);
    logic [63:0] d;
    d[63]    = s[31];
    d[62:52] = (s[30:23] == 8'd0) ? 11'd0 : (s[30:23] - 8'd127 + 11'd1023);
    d[51:29] = s[22:0];
    d[28:0]  = 29'd0;
    return d;
  endfunction

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      st <= F_IDLE; res_r <= '0; fflags_r <= '0;
    end else begin
      case (st)
        F_IDLE: begin
          if (start) begin
            st <= F_BUSY;
            fflags_r <= '0;
          end
        end
        F_BUSY: begin
          st <= F_DONE;
          res_r <= '0;
          case (op)
            FPU_F2D:   res_r <= single2dbl(a[31:0]);
            FPU_D2F:   res_r <= {{32{a_single_res[31]}}, a_single_res};
            FPU_I2F:   res_r <= single2dbl({1'b0, a[31], 8'd0, a[30:0]});
            FPU_F2I:   res_r <= {a[63], a[62:0]};
            FPU_MV_X2F:res_r <= a;
            FPU_MV_F2X:res_r <= a;
            FPU_FSGNJ: res_r <= {b[63], a[62:0]};
            FPU_FSGNJN:res_r <= {~b[63], a[62:0]};
            FPU_FSGNJX:res_r <= {a[63]^b[63], a[62:0]};
            FPU_FMIN:  res_r <= (a < b) ? a : b;
            FPU_FMAX:  res_r <= (a > b) ? a : b;
            FPU_FEQ:   res_r <= (a == b) ? 64'd1 : 64'd0;
            FPU_FLT:   res_r <= (a <  b) ? 64'd1 : 64'd0;
            FPU_FLE:   res_r <= (a <= b) ? 64'd1 : 64'd0;
            default:   res_r <= a + b;
          endcase
        end
        F_DONE: st <= F_IDLE;
      endcase
    end
  end

endmodule
