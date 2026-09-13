module mdu #(
  parameter int XLEN = 64
) (
  input  logic              clk,
  input  logic              rst_n,
  input  logic              start,
  input  rtl_core_pkg::mul_op_e op,
  input  logic [XLEN-1:0]   a,
  input  logic [XLEN-1:0]   b,
  output logic [XLEN-1:0]   result,
  output logic              done
);
  import rtl_core_pkg::*;

  typedef enum logic [1:0] { M_IDLE, M_BUSY, M_DONE } mst_e;
  mst_e st;

  logic [127:0] prod;
  logic [63:0] q, r;
  logic [31:0] divw_q, divuw_q, remw_r, remuw_r;
  logic [6:0]  cnt;
  logic [63:0] a_r, b_r;
  mul_op_e op_r;

  assign prod    = $signed($signed(a_r) * $signed(b_r));
  assign done    = (st == M_DONE);
  assign divw_q  = $signed(a_r) / $signed(b_r);
  assign divuw_q = a_r / b_r;
  assign remw_r  = $signed(a_r) % $signed(b_r);
  assign remuw_r = a_r % b_r;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      st <= M_IDLE; cnt <= '0; result <= '0; op_r <= MUL_NONE;
      a_r <= '0; b_r <= '0; q <= '0; r <= '0;
    end else begin
      case (st)
        M_IDLE: begin
          if (start) begin
            a_r  <= a;
            b_r  <= b;
            op_r <= op;
            cnt  <= '0;
            st   <= M_BUSY;
          end
        end
        M_BUSY: begin
          if (cnt == 7'd63) begin
            st <= M_DONE;
            case (op_r)
              MUL_MUL:    result <= prod[63:0];
              MUL_MULH:   result <= prod[127:64];
              MUL_MULHSU: result <= $signed($signed(a_r) * b_r) >> 64;
              MUL_MULHU:  result <= (a_r * b_r) >> 64;
              MUL_DIV:    result <= $signed(a_r) / $signed(b_r);
              MUL_DIVU:   result <= a_r / b_r;
              MUL_REM:    result <= $signed(a_r) % $signed(b_r);
              MUL_REMU:   result <= a_r % b_r;
              MUL_DIVW:   result <= {{32{divw_q[31]}},  divw_q};
              MUL_DIVUW:  result <= {{32{divuw_q[31]}}, divuw_q};
              MUL_REMW:   result <= {{32{remw_r[31]}},  remw_r};
              MUL_REMUW:  result <= {{32{remuw_r[31]}}, remuw_r};
              default:    result <= '0;
            endcase
          end
          cnt <= cnt + 7'd1;
        end
        M_DONE: begin
          st <= M_IDLE;
        end
      endcase
    end
  end

endmodule
