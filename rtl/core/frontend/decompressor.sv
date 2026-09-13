// Compressed instruction decompressor (RVC).
// Expands 16-bit compressed instructions to their 32-bit RV64 equivalents.
// Based on the canonical RVC bit mappings (RISC-V ISA Manual, Vol I, Ch 16).
/* verilator lint_off CASEOVERLAP */
module decompressor (
  input  logic [15:0] cin,
  output logic [31:0] iout,
  output logic        is_c
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

  logic [31:0] expanded;
  always_comb begin
    expanded = 32'h00000013;  // default: nop

    case (op)
      // ---------------------------------------------------------------
      // Quadrant 0 (op == 2'b00) - Register-based loads and stores
      // ---------------------------------------------------------------
      2'b00: begin
        case (f3)
          // C.ADDI4SPN: addi rd', x2, nzuimm
          3'b000: begin
            if (cin[12:5] != 8'b0) begin
              expanded = {2'b0, cin[10:7], cin[12:11], cin[5], cin[6], 2'b00,
                          5'd2, 3'b000, rvc_reg(cin[4:2]), 7'b0010011};
            end
          end
          // C.FLD (RV32/64): fld rd', offset(rs1')
          3'b001: begin
            expanded = {4'b0, cin[5], cin[12:10], cin[6], 4'b0, rvc_reg(cin[4:2]),
                        3'b011, rvc_reg(cin[9:7]), 7'b0000111};
          end
          // C.LW: lw rd', offset(rs1')
          3'b010: begin
            expanded = {5'b0, cin[5], cin[12:10], cin[6], 2'b00,
                        rvc_reg(cin[4:2]), 3'b010, rvc_reg(cin[9:7]), 7'b0000011};
          end
          // C.LD (RV64): ld rd', offset(rs1')
          3'b011: begin
            expanded = {4'b0, cin[5], cin[12:10], cin[6], 3'b000,
                        rvc_reg(cin[4:2]), 3'b011, rvc_reg(cin[9:7]), 7'b0000011};
          end
          // C.FSD (RV32/64): fsd rs2', offset(rs1')
          3'b100: begin
            expanded = {4'b0, cin[5], cin[12:10], cin[6], 2'b00,
                        rvc_reg(cin[4:2]), 3'b011, rvc_reg(cin[9:7]), 7'b0100111};
          end
          // C.SW: sw rs2', offset(rs1')
          3'b101: begin
            expanded = {5'b0, cin[5], cin[12], 2'b01, cin[4:2],
                        2'b01, cin[9:7], 3'b010, cin[11:10], cin[6], 2'b00, 7'b0100011};
          end
          // C.SD (RV64): sd rs2', offset(rs1')
          3'b110: begin
            expanded = {4'b0, cin[12], 2'b01, cin[4:2], 2'b01, cin[9:7],
                        3'b011, cin[11:10], cin[6:5], 3'b000, 7'b0100011};
          end
          default: expanded = 32'h00000013;
        endcase
      end

      // ---------------------------------------------------------------
      // Quadrant 1 (op == 2'b01) - Misc arithmetic and control
      // ---------------------------------------------------------------
      2'b01: begin
        case (f3)
          // C.ADDI / C.NOP: addi rd, rd, nzimm6
          3'b000: begin
            expanded = {{6{cin[12]}}, cin[12], cin[6:2], cin[11:7], 3'b000,
                        cin[11:7], 7'b0010011};
          end
          // C.ADDIW (RV64): addiw rd, rd, imm6
          3'b001: begin
            expanded = {{6{cin[12]}}, cin[12], cin[6:2], cin[11:7], 3'b000,
                        cin[11:7], 7'b0011011};
          end
          // C.LI: addi rd, x0, imm6
          3'b010: begin
            expanded = {{6{cin[12]}}, cin[12], cin[6:2], 5'd0, 3'b000,
                        cin[11:7], 7'b0010011};
          end
          // C.ADDI16SP / C.LUI
          3'b011: begin
            if (cin[11:7] == 5'd2) begin
              // C.ADDI16SP: addi x2, x2, nzimm9
              expanded = {{3{cin[12]}}, cin[4:3], cin[5], cin[2], cin[6], 4'b0,
                          5'd2, 3'b000, 5'd2, 7'b0010011};
            end else begin
              // C.LUI: lui rd, nzimm18
              expanded = {{15{cin[12]}}, cin[6:2], cin[11:7], 7'b0110111};
            end
          end
          // C.SRLI / C.SRAI / C.ANDI / C.SUB / C.XOR / C.OR / C.AND / C.SUBW / C.ADDW
          3'b100: begin
            case (cin[11:10])
              // C.SRLI: srli rd', rd', shamt
              2'b00: begin
                expanded = {1'b0, cin[12], cin[6:2], 5'b0, rvc_reg(cin[9:7]),
                            3'b101, rvc_reg(cin[9:7]), 7'b0010011};
              end
              // C.SRAI: srai rd', rd', shamt
              2'b01: begin
                expanded = {1'b1, cin[12], cin[6:2], 5'b0, rvc_reg(cin[9:7]),
                            3'b101, rvc_reg(cin[9:7]), 7'b0010011};
              end
              // C.ANDI: andi rd', rd', imm6
              2'b10: begin
                expanded = {{6{cin[12]}}, cin[12], cin[6:2], rvc_reg(cin[9:7]),
                            3'b111, rvc_reg(cin[9:7]), 7'b0010011};
              end
              // C.SUB / C.XOR / C.OR / C.AND (cin[12]==0) / C.SUBW / C.ADDW (cin[12]==1, RV64)
              2'b11: begin
                if (!cin[12]) begin
                  case (cin[6:5])
                    // C.SUB: sub rd', rd', rs2'
                    2'b00: expanded = {7'b0100000, rvc_reg(cin[4:2]), rvc_reg(cin[9:7]),
                                       3'b000, rvc_reg(cin[9:7]), 7'b0110011};
                    // C.XOR: xor rd', rd', rs2'
                    2'b01: expanded = {7'b0000000, rvc_reg(cin[4:2]), rvc_reg(cin[9:7]),
                                       3'b100, rvc_reg(cin[9:7]), 7'b0110011};
                    // C.OR: or rd', rd', rs2'
                    2'b10: expanded = {7'b0000000, rvc_reg(cin[4:2]), rvc_reg(cin[9:7]),
                                       3'b110, rvc_reg(cin[9:7]), 7'b0110011};
                    // C.AND: and rd', rd', rs2'
                    2'b11: expanded = {7'b0000000, rvc_reg(cin[4:2]), rvc_reg(cin[9:7]),
                                       3'b111, rvc_reg(cin[9:7]), 7'b0110011};
                  endcase
                end else begin
                  case (cin[6:5])
                    // C.SUBW (RV64): subw rd', rd', rs2'
                    2'b00: expanded = {7'b0100000, rvc_reg(cin[4:2]), rvc_reg(cin[9:7]),
                                       3'b000, rvc_reg(cin[9:7]), 7'b0111011};
                    // C.ADDW (RV64): addw rd', rd', rs2'
                    2'b01: expanded = {7'b0000000, rvc_reg(cin[4:2]), rvc_reg(cin[9:7]),
                                       3'b000, rvc_reg(cin[9:7]), 7'b0111011};
                    default: expanded = 32'h00000013;
                  endcase
                end
              end
            endcase
          end
          // C.JAL (RV32) / C.J (RV64): jal x1/x0, offset
          // Note: in RV64, C.JAL is reserved (illegal); C.J is f3=101.
          3'b001: begin
            // C.JAL (RV32 only): jal x1, offset
            expanded = {cin[12], cin[8], cin[10:9], cin[6], cin[7], cin[2],
                        cin[11], cin[5:3], {9{cin[12]}}, 4'b0, 1'b1, 7'b1101111};
          end
          3'b101: begin
            // C.J: jal x0, offset
            expanded = {cin[12], cin[8], cin[10:9], cin[6], cin[7], cin[2],
                        cin[11], cin[5:3], {9{cin[12]}}, 4'b0, 1'b0, 7'b1101111};
          end
          // C.BEQZ: beq rs1', x0, offset
          3'b110: begin
            expanded = {{4{cin[12]}}, cin[10], cin[6:5], cin[3], cin[2], 2'b0,
                        cin[11], cin[5:3], 2'b00, rvc_reg(cin[9:7]), 3'b000,
                        rvc_reg(cin[9:7]), 7'b1100011};
          end
          // C.BNEZ: bne rs1', x0, offset
          3'b111: begin
            expanded = {{4{cin[12]}}, cin[10], cin[6:5], cin[3], cin[2], 2'b0,
                        cin[11], cin[5:3], 2'b00, rvc_reg(cin[9:7]), 3'b001,
                        rvc_reg(cin[9:7]), 7'b1100011};
          end
        endcase
      end

      // ---------------------------------------------------------------
      // Quadrant 2 (op == 2'b10) - SP-relative loads/stores and moves
      // ---------------------------------------------------------------
      2'b10: begin
        case (f3)
          // C.SLLI: slli rd, rd, shamt
          3'b000: begin
            expanded = {1'b0, cin[12], cin[6:2], 5'b0, cin[11:7],
                        3'b001, cin[11:7], 7'b0010011};
          end
          // C.FLDSP (RV32/64): fld rd, offset(sp)
          3'b001: begin
            expanded = {3'b0, cin[5], cin[12:10], cin[6], 3'b000, cin[11:7],
                        3'b011, 5'd2, 7'b0000111};
          end
          // C.LWSP: lw rd, offset(sp)
          3'b010: begin
            expanded = {3'b0, cin[3:2], cin[12], cin[6:4], 2'b00, cin[11:7],
                        3'b010, 5'd2, 7'b0000011};
          end
          // C.LDSP (RV64): ld rd, offset(sp)
          3'b011: begin
            expanded = {3'b0, cin[5:4], cin[12], cin[6:2], 3'b000, cin[11:7],
                        3'b011, 5'd2, 7'b0000011};
          end
          // C.JR / C.MV / C.JALR / C.ADD / C.EBREAK
          3'b100: begin
            if (!cin[12]) begin
              if (cin[6:2] == 5'b0) begin
                // C.JR: jalr x0, 0(rs1)
                expanded = {12'b0, cin[11:7], 3'b000, 5'd0, cin[11:7], 7'b1100111};
              end else begin
                // C.MV: add rd, x0, rs2
                expanded = {7'b0, cin[6:2], 5'd0, 3'b000, cin[11:7], 7'b0110011};
              end
            end else begin
              if (cin[11:7] == 5'd0 && cin[6:2] == 5'b0) begin
                // C.EBREAK
                expanded = 32'h00100073;
              end else if (cin[6:2] == 5'b0) begin
                // C.JALR: jalr x1, 0(rs1)
                expanded = {12'b0, cin[11:7], 3'b000, 5'd1, cin[11:7], 7'b1100111};
              end else begin
                // C.ADD: add rd, rd, rs2
                expanded = {7'b0, cin[6:2], cin[11:7], 3'b000, cin[11:7], 7'b0110011};
              end
            end
          end
          // C.FSDSP (RV32/64): fsd rs2, offset(sp)
          3'b101: begin
            expanded = {3'b0, cin[12:10], cin[6], 2'b00, cin[9:7],
                        3'b011, 5'd2, 7'b0100111};
          end
          // C.SWSP: sw rs2, offset(sp)
          3'b110: begin
            expanded = {4'b0, cin[8:7], cin[12], cin[6:2], 5'd2, 3'b010,
                        cin[11:9], 2'b00, 7'b0100011};
          end
          // C.SDSP (RV64): sd rs2, offset(sp)
          3'b111: begin
            expanded = {3'b0, cin[12:9], cin[8:7], 3'b000, cin[6:2], 5'd2,
                        3'b011, 7'b0100011};
          end
        endcase
      end

      // ---------------------------------------------------------------
      // Quadrant 3 (op == 2'b11): not compressed, pass through
      // The fetch unit supplies the full 32-bit instruction in this case
      // (this branch is never taken because is_c=0 routes around the
      // decompressor, but kept for completeness).
      // ---------------------------------------------------------------
      2'b11: begin
        expanded = {cin, 16'h0};
      end
    endcase
  end

  assign iout = expanded;
endmodule
