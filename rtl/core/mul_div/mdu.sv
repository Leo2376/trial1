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
  output logic              done,
  output logic              busy
);
  import rtl_core_pkg::*;
  typedef enum logic [1:0] { M_IDLE, M_BUSY, M_DONE } mst_e;
  mst_e st;
  logic [127:0] prod_ss, prod_su, prod_uu;
  logic [6:0]   cnt;
  logic [63:0]  a_r, b_r;
  logic [31:0]  a32, b32;
  logic [63:0]  div_res, rem_res;
  mul_op_e op_r;

  // 128-bit products from latched operands.
  // prod_ss : signed   * signed   (MULH)
  // prod_su : signed a * unsigned b (MULHSU) - a sign-extended, b zero-extended,
  //           multiplied as a signed 128x128 product. b is positive so the
  //           zero-extension equals its sign-extension, giving the correct
  //           signed-by-unsigned high word.
  // prod_uu : unsigned * unsigned (MULHU)
  assign prod_ss = $signed($signed({{64{a_r[63]}}, a_r}) * $signed({{64{b_r[63]}}, b_r}));
  assign prod_su = $signed($signed({{64{a_r[63]}}, a_r}) * $signed({64'b0, b_r}));
  assign prod_uu = {64'd0, a_r} * {64'd0, b_r};

  assign a32 = a_r[31:0];
  assign b32 = b_r[31:0];
  logic [31:0] divw_q, remw_q, divuw_q, remuw_q;
  assign divw_q  = $signed(a32) / $signed(b32);
  assign remw_q  = $signed(a32) % $signed(b32);
  assign divuw_q = a32 / b32;
  assign remuw_q = a32 % b32;
  logic [63:0] div_s, div_u, rem_s, rem_u;
  assign div_s = $signed(a_r) / $signed(b_r);
  assign div_u = a_r / b_r;
  assign rem_s = $signed(a_r) % $signed(b_r);
  assign rem_u = a_r % b_r;

  // W-variant division/remainder operate on the lower 32 bits with sign-
  // extension of the 32-bit result to 64 bits. Overflow (INT_MIN / -1) and
  // divide-by-zero follow the RISC-V specification.
  assign div_res = (b32 == 32'd0) ? 64'hFFFF_FFFF_FFFF_FFFF :
                   (a32 == 32'h8000_0000 && b32 == 32'hFFFF_FFFF) ?
                   64'hFFFF_FFFF_8000_0000 :
                   {{32{divw_q[31]}}, divw_q};
  assign rem_res = (b32 == 32'd0) ? {{32{a32[31]}}, a32} :
                   (a32 == 32'h8000_0000 && b32 == 32'hFFFF_FFFF) ?
                   64'd0 :
                   {{32{remw_q[31]}}, remw_q};

  assign done = (st == M_DONE);
  assign busy = (st != M_IDLE);

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      st <= M_IDLE; cnt <= '0; result <= '0; op_r <= MUL_NONE;
      a_r <= '0; b_r <= '0;
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
            unique case (op_r)
              MUL_MUL:    result <= prod_ss[63:0];
              MUL_MULW:   result <= {{32{prod_ss[31]}}, prod_ss[31:0]};
              MUL_MULH:   result <= prod_ss[127:64];
              MUL_MULHSU: result <= prod_su[127:64];
              MUL_MULHU:  result <= prod_uu[127:64];
              MUL_DIV:    result <= (b_r == '0) ? 64'hFFFF_FFFF_FFFF_FFFF :
                                   (a_r == 64'h8000_0000_0000_0000 &&
                                    b_r == 64'hFFFF_FFFF_FFFF_FFFF) ?
                                   64'h8000_0000_0000_0000 : div_s;
              MUL_DIVU:   result <= (b_r == '0) ? 64'hFFFF_FFFF_FFFF_FFFF :
                                   div_u;
              MUL_REM:    result <= (b_r == '0) ? a_r :
                                   (a_r == 64'h8000_0000_0000_0000 &&
                                    b_r == 64'hFFFF_FFFF_FFFF_FFFF) ?
                                   64'd0 : rem_s;
              MUL_REMU:   result <= (b_r == '0) ? a_r : rem_u;
              MUL_DIVW:   result <= div_res;
              MUL_DIVUW:  result <= (b32 == 32'd0) ? 64'hFFFF_FFFF_FFFF_FFFF :
                                    {{32{divuw_q[31]}}, divuw_q};
              MUL_REMW:   result <= rem_res;
              MUL_REMUW:  result <= (b32 == 32'd0) ? {{32{a32[31]}}, a32} :
                                    {{32{remuw_q[31]}}, remuw_q};
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
