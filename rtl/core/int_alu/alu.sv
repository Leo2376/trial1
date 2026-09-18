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

  assign a32 = a[31:0];
  assign b32 = b[31:0];

  always_comb begin
    y = '0;
    y32 = '0;
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
      ALU_ADDW:   begin y32 = a32 + b32; y = {{32{y32[31]}}, y32}; end
      ALU_SUBW:   begin y32 = a32 - b32; y = {{32{y32[31]}}, y32}; end
      ALU_SLLW:   begin y32 = a32 << b[4:0]; y = {{32{y32[31]}}, y32}; end
      ALU_SRLW:   begin y32 = a32 >> b[4:0]; y = {{32{y32[31]}}, y32}; end
      ALU_SRAW:   begin y32 = $signed(a32) >>> b[4:0]; y = {{32{y32[31]}}, y32}; end
      ALU_LUI:    y = b;
      ALU_COPYB:  y = b;
      default:    y = '0;
    endcase
  end
endmodule
