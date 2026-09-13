module alu #(
  parameter int XLEN = 64
) (
  input  rtl_core_pkg::alu_op_e op,
  input  logic [XLEN-1:0]       a,
  input  logic [XLEN-1:0]       b,
  output logic [XLEN-1:0]       y
);
  import rtl_core_pkg::*;

  logic [31:0] a32, b32, y32;
  logic [63:0] mul_full;
  logic [63:0] as_ext, bs_ext;
  logic [127:0] mull, mulh_s, mulh_su, mulh_u;
  logic [63:0] div_q, div_r;
  logic div_by_zero;

  assign a32 = a[31:0];
  assign b32 = b[31:0];
  assign as_ext = $signed(a32);
  assign bs_ext = $signed(b32);
  assign mull   = a * b;
  assign mulh_s  = $signed($signed(a) * $signed(b));
  assign mulh_su = $signed($signed(a) * b);
  assign mulh_u  = a * b;
  assign mul_full = mull;

  always_comb begin
    y = '0;
    div_q = '0; div_r = '0; div_by_zero = 1'b0;
    case (op)
      ALU_ADD:    y = a + b;
      ALU_SUB:    y = a - b;
      ALU_SLL:    y = a << b[5:0];
      ALU_SLT:    y = ($signed(a) < $signed(b)) ? 64'd1 : 64'd0;
      ALU_SLTU:   y = (a < b) ? 64'd1 : 64'd0;
      ALU_XOR:    y = a ^ b;
      ALU_SRL:    y = a >> b[5:0];
      ALU_SRA:    y = $signed(a) >>> b[5:0];
      ALU_OR:     y = a | b;
      ALU_AND:    y = a & b;
      ALU_ADDW:   y = {{32{a32[31]}}, a32 + b32};
      ALU_SUBW:   y = {{32{a32[31]}}, a32 - b32};
      ALU_SLLW:   y = {{32{a32[31]}}, a32 << b[4:0]};
      ALU_SRLW:   y = {{32{a32[31]}}, a32 >> b[4:0]};
      ALU_SRAW:   y = {{32{a32[31]}}, $signed(a32) >>> b[4:0]};
      ALU_LUI:    y = b;
      ALU_COPYB:  y = b;
      ALU_MUL:    y = mull;
      ALU_MULH:   y = mulh_s;
      ALU_MULHSU: y = mulh_su;
      ALU_MULHU:  y = mulh_u;
      ALU_DIV:    y = $signed(a) / $signed(b);
      ALU_DIVU:   y = a / b;
      ALU_REM:    y = $signed(a) % $signed(b);
      ALU_REMU:   y = a % b;
      ALU_DIVW:   y = {{32{div_q[31]}}, $signed(a32) / $signed(b32)};
      ALU_DIVUW:  y = {{32{div_q[31]}}, a32 / b32};
      ALU_REMW:   y = {{32{div_r[31]}}, $signed(a32) % $signed(b32)};
      ALU_REMUW:  y = {{32{div_r[31]}}, a32 % b32};
      default:    y = '0;
    endcase
  end

endmodule
