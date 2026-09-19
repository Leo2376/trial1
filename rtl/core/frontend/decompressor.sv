// Compressed instruction decompressor (RVC) for RV64GC.
// Expands 16-bit compressed instructions to their 32-bit RV64 equivalents.
// Reference: RISC-V ISA Manual Vol I Ch 16 + CVA6 compressed_decoder (RV64, F present).
// Supports RV64C + F (FLD/FSD/FLDSP/FSDSP). Zcb/Zcmp not supported (illegal).
/* verilator lint_off CASEOVERLAP */
module decompressor (
  input  logic [15:0] cin,
  output logic [31:0] iout,
  output logic        is_c,
  output logic        illegal
);

  logic [1:0] op;
  logic [2:0] f3;
  assign op = cin[1:0];
  assign f3 = cin[15:13];
  assign is_c = (op != 2'b11);

  // 3-bit compressed register indices map to x8..x15
  function automatic logic [4:0] rvc_reg (logic [2:0] i);
    return {2'b01, i};
  endfunction

  localparam logic [6:0] OP_LOAD    = 7'b0000011;
  localparam logic [6:0] OP_LOADFP  = 7'b0000111;
  localparam logic [6:0] OP_OPIMM   = 7'b0010011;
  localparam logic [6:0] OP_STORE   = 7'b0100011;
  localparam logic [6:0] OP_STOREFP = 7'b0100111;
  localparam logic [6:0] OP_OP      = 7'b0110011;
  localparam logic [6:0] OP_LUI     = 7'b0110111;
  localparam logic [6:0] OP_BRANCH  = 7'b1100011;
  localparam logic [6:0] OP_JALR    = 7'b1100111;
  localparam logic [6:0] OP_JAL     = 7'b1101111;
  localparam logic [6:0] OP_OPIMM32 = 7'b0011011;
  localparam logic [6:0] OP_OP32    = 7'b0111011;

  logic [31:0] expanded;
  logic        ill;
  always_comb begin
    expanded = 32'h00000013;  // default: nop
    ill = 1'b0;

    case (op)
      // ---------------------------------------------------------------
      // Quadrant 0 (op == 2'b00)
      // ---------------------------------------------------------------
      2'b00: begin
        case (f3)
          // C.ADDI4SPN -> addi rd', x2, nzuimm
          3'b000: begin
            expanded = {2'b0, cin[10:7], cin[12:11], cin[5], cin[6], 2'b00,
                        5'd2, 3'b000, rvc_reg(cin[4:2]), OP_OPIMM};
            if (cin[12:5] == 8'b0) ill = 1'b1;
          end
          // C.FLD (RV64, F) -> fld rd', offset(rs1')
          3'b001: begin
            expanded = {4'b0, cin[6:5], cin[12:10], 3'b000,
                        rvc_reg(cin[9:7]), 3'b011, rvc_reg(cin[4:2]), OP_LOADFP};
          end
          // C.LW -> lw rd', offset(rs1')
          3'b010: begin
            expanded = {5'b0, cin[5], cin[12:10], cin[6], 2'b00,
                        rvc_reg(cin[9:7]), 3'b010, rvc_reg(cin[4:2]), OP_LOAD};
          end
          // C.LD (RV64) -> ld rd', offset(rs1')
          3'b011: begin
            expanded = {4'b0, cin[6:5], cin[12:10], 3'b000,
                        rvc_reg(cin[9:7]), 3'b011, rvc_reg(cin[4:2]), OP_LOAD};
          end
          // 3'b100: reserved (Zcb LBU/LH/SB/SH slot) -> illegal
          // C.FSD (RV64, F) -> fsd rs2', offset(rs1')
          3'b101: begin
            expanded = {4'b0, cin[6:5], cin[12],
                        rvc_reg(cin[4:2]), rvc_reg(cin[9:7]),
                        3'b011, cin[11:10], 3'b000, OP_STOREFP};
          end
          // C.SW -> sw rs2', offset(rs1')
          3'b110: begin
            expanded = {5'b0, cin[5], cin[12],
                        rvc_reg(cin[4:2]), rvc_reg(cin[9:7]),
                        3'b010, cin[11:10], cin[6], 2'b00, OP_STORE};
          end
          // C.SD (RV64) -> sd rs2', offset(rs1')
          3'b111: begin
            expanded = {4'b0, cin[6:5], cin[12],
                        rvc_reg(cin[4:2]), rvc_reg(cin[9:7]),
                        3'b011, cin[11:10], 3'b000, OP_STORE};
          end
          default: ill = 1'b1;
        endcase
      end

      // ---------------------------------------------------------------
      // Quadrant 1 (op == 2'b01)
      // ---------------------------------------------------------------
      2'b01: begin
        case (f3)
          // C.ADDI / C.NOP -> addi rd, rd, nzimm
          3'b000: begin
            expanded = {{6{cin[12]}}, cin[12], cin[6:2],
                        cin[11:7], 3'b000, cin[11:7], OP_OPIMM};
          end
          // C.ADDIW (RV64) -> addiw rd, rd, imm (rd==0 illegal)
          3'b001: begin
            if (cin[11:7] != 5'd0) begin
              expanded = {{6{cin[12]}}, cin[12], cin[6:2],
                          cin[11:7], 3'b000, cin[11:7], OP_OPIMM32};
            end else begin
              ill = 1'b1;
            end
          end
          // C.LI -> addi rd, x0, imm
          3'b010: begin
            expanded = {{6{cin[12]}}, cin[12], cin[6:2],
                        5'd0, 3'b000, cin[11:7], OP_OPIMM};
          end
          // C.ADDI16SP / C.LUI
          3'b011: begin
            if (cin[11:7] == 5'd2) begin
              // C.ADDI16SP -> addi x2, x2, nzimm
              expanded = {{3{cin[12]}}, cin[4:3], cin[5], cin[2], cin[6], 4'b0,
                          5'd2, 3'b000, 5'd2, OP_OPIMM};
              if ({cin[12], cin[6:2]} == 6'b0) ill = 1'b1;
            end else if (cin[11:7] != 5'd0) begin
              // C.LUI -> lui rd, nzimm
              expanded = {{15{cin[12]}}, cin[6:2], cin[11:7], OP_LUI};
              if ({cin[12], cin[6:2]} == 6'b0) ill = 1'b1;
            end else begin
              ill = 1'b1;
            end
          end
          // C.SRLI / C.SRAI / C.ANDI / C.SUB / C.XOR / C.OR / C.AND / C.SUBW / C.ADDW
          3'b100: begin
            case (cin[11:10])
              // C.SRLI -> srli rd', rd', shamt
              // C.SRAI -> srai rd', rd', shamt
              2'b00, 2'b01: begin
                expanded = {1'b0, cin[10], 4'b0, cin[12], cin[6:2],
                            rvc_reg(cin[9:7]), 3'b101,
                            rvc_reg(cin[9:7]), OP_OPIMM};
              end
              // C.ANDI -> andi rd', rd', imm
              2'b10: begin
                expanded = {{6{cin[12]}}, cin[12], cin[6:2],
                            rvc_reg(cin[9:7]), 3'b111,
                            rvc_reg(cin[9:7]), OP_OPIMM};
              end
              2'b11: begin
                case ({cin[12], cin[6:5]})
                  // C.SUB -> sub rd', rd', rs2'
                  3'b000: expanded = {2'b01, 5'b0, rvc_reg(cin[4:2]),
                                      rvc_reg(cin[9:7]), 3'b000,
                                      rvc_reg(cin[9:7]), OP_OP};
                  // C.XOR -> xor rd', rd', rs2'
                  3'b001: expanded = {7'b0, rvc_reg(cin[4:2]),
                                      rvc_reg(cin[9:7]), 3'b100,
                                      rvc_reg(cin[9:7]), OP_OP};
                  // C.OR -> or rd', rd', rs2'
                  3'b010: expanded = {7'b0, rvc_reg(cin[4:2]),
                                      rvc_reg(cin[9:7]), 3'b110,
                                      rvc_reg(cin[9:7]), OP_OP};
                  // C.AND -> and rd', rd', rs2'
                  3'b011: expanded = {7'b0, rvc_reg(cin[4:2]),
                                      rvc_reg(cin[9:7]), 3'b111,
                                      rvc_reg(cin[9:7]), OP_OP};
                  // C.SUBW (RV64) -> subw rd', rd', rs2'
                  3'b100: expanded = {2'b01, 5'b0, rvc_reg(cin[4:2]),
                                      rvc_reg(cin[9:7]), 3'b000,
                                      rvc_reg(cin[9:7]), OP_OP32};
                  // C.ADDW (RV64) -> addw rd', rd', rs2'
                  3'b101: expanded = {2'b00, 5'b0, rvc_reg(cin[4:2]),
                                      rvc_reg(cin[9:7]), 3'b000,
                                      rvc_reg(cin[9:7]), OP_OP32};
                  default: ill = 1'b1;
                endcase
              end
            endcase
          end
          // C.J -> jal x0, offset
          3'b101: begin
            expanded = {cin[12], cin[8], cin[10:9], cin[6], cin[7], cin[2],
                        cin[11], cin[5:3], {9{cin[12]}}, 5'd0, OP_JAL};
          end
          // C.BEQZ -> beq rs1', x0, offset
          3'b110: begin
            expanded = {{4{cin[12]}}, cin[6:5], cin[2], 5'b0,
                        rvc_reg(cin[9:7]), 2'b00, 1'b0,
                        cin[11:10], cin[4:3], cin[12], OP_BRANCH};
          end
          // C.BNEZ -> bne rs1', x0, offset
          3'b111: begin
            expanded = {{4{cin[12]}}, cin[6:5], cin[2], 5'b0,
                        rvc_reg(cin[9:7]), 2'b00, 1'b1,
                        cin[11:10], cin[4:3], cin[12], OP_BRANCH};
          end
          default: ill = 1'b1;
        endcase
      end

      // ---------------------------------------------------------------
      // Quadrant 2 (op == 2'b10)
      // ---------------------------------------------------------------
      2'b10: begin
        case (f3)
          // C.SLLI -> slli rd, rd, shamt
          3'b000: begin
            expanded = {6'b0, cin[12], cin[6:2],
                        cin[11:7], 3'b001, cin[11:7], OP_OPIMM};
          end
          // C.FLDSP -> fld rd, offset(sp)
          3'b001: begin
            expanded = {3'b0, cin[4:2], cin[12], cin[6:5], 3'b000,
                        5'd2, 3'b011, cin[11:7], OP_LOADFP};
          end
          // C.LWSP -> lw rd, offset(sp) (rd==0 illegal)
          3'b010: begin
            if (cin[11:7] != 5'd0) begin
              expanded = {4'b0, cin[3:2], cin[12], cin[6:4], 2'b00,
                          5'd2, 3'b010, cin[11:7], OP_LOAD};
            end else begin
              ill = 1'b1;
            end
          end
          // C.LDSP (RV64) -> ld rd, offset(sp) (rd==0 illegal)
          3'b011: begin
            if (cin[11:7] != 5'd0) begin
              expanded = {3'b0, cin[4:2], cin[12], cin[6:5], 3'b000,
                          5'd2, 3'b011, cin[11:7], OP_LOAD};
            end else begin
              ill = 1'b1;
            end
          end
          // C.JR / C.MV / C.JALR / C.ADD / C.EBREAK
          3'b100: begin
            if (!cin[12]) begin
              if (cin[6:2] == 5'b0) begin
                // C.JR -> jalr x0, 0(rs1) (rs1==0 illegal)
                expanded = {12'b0, cin[11:7], 3'b000, 5'd0, OP_JALR};
                if (cin[11:7] == 5'd0) ill = 1'b1;
              end else begin
                // C.MV -> add rd, x0, rs2
                expanded = {7'b0, cin[6:2], 5'd0, 3'b000, cin[11:7], OP_OP};
              end
            end else begin
              if (cin[6:2] == 5'b0) begin
                if (cin[11:7] == 5'd0) begin
                  // C.EBREAK
                  expanded = 32'h00100073;
                end else begin
                  // C.JALR -> jalr x1, 0(rs1)
                  expanded = {12'b0, cin[11:7], 3'b000, 5'd1, OP_JALR};
                end
              end else begin
                // C.ADD -> add rd, rd, rs2
                expanded = {7'b0, cin[6:2], cin[11:7], 3'b000, cin[11:7], OP_OP};
              end
            end
          end
          // C.FSDSP -> fsd rs2, offset(sp)
          3'b101: begin
            expanded = {3'b0, cin[9:7], cin[12], cin[6:2],
                        5'd2, 3'b011, cin[11:10], 3'b000, OP_STOREFP};
          end
          // C.SWSP -> sw rs2, offset(sp)
          3'b110: begin
            expanded = {4'b0, cin[8:7], cin[12], cin[6:2],
                        5'd2, 3'b010, cin[11:9], 2'b00, OP_STORE};
          end
          // C.SDSP (RV64) -> sd rs2, offset(sp)
          3'b111: begin
            expanded = {3'b0, cin[9:7], cin[12], cin[6:2],
                        5'd2, 3'b011, cin[11:10], 3'b000, OP_STORE};
          end
          default: ill = 1'b1;
        endcase
      end

      // ---------------------------------------------------------------
      // op == 2'b11: not compressed (handled by bypass in core)
      // ---------------------------------------------------------------
      2'b11: begin
        expanded = {cin, 16'h0};
        ill = 1'b0;
      end
    endcase
  end

  assign iout = ill ? 32'h00000013 : expanded;
  assign illegal = ill & is_c;
endmodule
