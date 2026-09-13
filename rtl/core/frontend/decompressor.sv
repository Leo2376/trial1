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

  logic [4:0] rds, rds1, rds2, rdfpr, rs1f, rs2f;
  assign rds1  = {2'b01, cin[4:2]};
  assign rds2  = {2'b01, cin[9:7]};
  assign rdfpr = {2'b01, cin[11:7]};
  assign rs1f  = {2'b01, cin[9:7]};
  assign rs2f  = {2'b01, cin[6:4]};
  assign rds   = cin[11:7];

  function automatic logic [31:0] rvi_lui(logic [19:0] imm20);
    return {imm20, 5'd0, 7'b0110111};
  endfunction
  function automatic logic [31:0] rvi_jal(logic [20:0] imm21);
    return {imm21[20], imm21[10:1], 1'b0, 5'd0, 7'b1101111};
  endfunction
  function automatic logic [31:0] rvi_addi(logic [4:0] rd, logic [4:0] rs1, logic [11:0] imm);
    return {imm, rs1, 3'b000, rd, 7'b0010011};
  endfunction

  logic [31:0] expanded;

  always_comb begin
    expanded = 32'h00000013;
    case (op)
      2'b00: begin
        case (f3)
          3'b000: expanded = {5'b0, cin[12:5], rds2, 2'b00, rds1, 3'b010, rds1, 7'b0000011};
          3'b001: expanded = {5'b0, cin[12:10], cin[6:5], 13'b0, rds2, 3'b010, rds1, 7'b0000011};
          3'b010: expanded = {5'b0, cin[12:5], rds2, 3'b010, rds1, 7'b0000011};
          3'b011: expanded = {5'b0, cin[12:5], cin[6:5], 13'b0, rds2, 3'b010, rds1, 7'b0000011};
          3'b100: begin
            if (!cin[12])
              expanded = {6'b0, cin[10:5], 2'b00, rds2, cin[11:10], rds1, 3'b010, rds1, 7'b0100011};
            else
              expanded = {6'b0, cin[10:5], 2'b00, rds2, cin[6:5], rds1, 3'b010, rds1, 7'b0100011};
          end
          3'b101: expanded = {5'b0, cin[12:5], rds2, 3'b010, rds1, 7'b0000011};
          3'b110: expanded = {5'b0, cin[12:10], cin[6:5], 13'b0, rds2, 3'b010, rds1, 7'b0000011};
          3'b111: expanded = {6'b0, cin[10:5], 2'b00, rds2, cin[6:5], rds1, 3'b010, rds1, 7'b0100011};
        endcase
      end
      2'b01: begin
        case (f3)
          3'b000: begin
            if (cin[12] == 1'b0)
              expanded = {6'b0, cin[10:5], rds2, 5'b0, cin[12], cin[6:5], rds1, 3'b000, rds1, 7'b0010011};
            else
              expanded = {6'b0, cin[10:5], rds2, 5'b0, cin[12], cin[6:5], rds1, 3'b000, rds1, 7'b0111011};
          end
          3'b001: expanded = {5'b0, cin[12], cin[6:2], 13'b0, rds, 3'b001, 5'd2, 7'b1100111};
          3'b010: expanded = {5'b0, cin[12:5], rds, 3'b000, 5'd0, 7'b0010011};
          3'b011: expanded = {15'b0, rds, 3'b001, 5'd0, 7'b0110111};
          3'b100: begin
            case (cin[11:10])
              2'b00, 2'b01: expanded = {2'b0, cin[12:10], cin[6:5], 11'b0, 3'b0, cin[4:2], 3'b000, cin[9:7], 7'b0010011};
              2'b10:          expanded = {2'b0, cin[12:10], cin[6:5], 11'b0, 3'b0, cin[4:2], 3'b000, cin[9:7], 7'b0111011};
              2'b11: begin
                if (!cin[12]) expanded = {7'b0, cin[6:2], 3'b000, cin[11:7], 7'b0010011};
                else          expanded = {7'b0, cin[6:2], 3'b000, cin[11:7], 7'b0111011};
              end
            endcase
          end
          3'b101: begin
            if (cin[12] == 1'b0) begin
              case (cin[11:10])
                2'b00:   expanded = {7'b0, cin[6:2], 3'b000, cin[9:7], 7'b1100011};
                2'b01:   expanded = {7'b0, cin[6:2], 3'b001, cin[9:7], 7'b1100011};
                2'b10:   expanded = {7'b0, cin[6:2], 3'b100, cin[9:7], 7'b1100011};
                2'b11:   expanded = {7'b0, cin[6:2], 3'b101, cin[9:7], 7'b1100011};
              endcase
            end else begin
              if (cin[6:2] == 5'b00000)
                expanded = 32'h00100073;
              else
                expanded = {12'b0, cin[6:2], 3'b000, 5'd0, 7'b1101111};
            end
          end
          3'b110: expanded = {7'b0, cin[12:10], 2'b0, cin[6:5], 6'b0, cin[4:2], 3'b000, cin[9:7], 7'b0010011};
          3'b111: begin
            case ({cin[12], cin[11:10]})
              3'b000:  expanded = {7'b0, cin[6:2], 3'b010, cin[9:7], 7'b1100011};
              3'b001:  expanded = {7'b0, cin[6:2], 3'b011, cin[9:7], 7'b1100011};
              3'b010:  expanded = {7'b0, cin[6:2], 3'b100, cin[9:7], 7'b1100011};
              3'b011:  expanded = {7'b0, cin[6:2], 3'b101, cin[9:7], 7'b1100011};
              3'b100:  expanded = {7'b0, cin[6:2], 3'b110, cin[9:7], 7'b1100011};
              3'b101:  expanded = {7'b0, cin[6:2], 3'b111, cin[9:7], 7'b1100011};
              3'b110:  expanded = {7'b0, cin[6:2], 3'b000, cin[9:7], 7'b1110011};
              3'b111:  expanded = {7'b0, cin[6:2], 3'b000, cin[9:7], 7'b0001111};
            endcase
          end
        endcase
      end
      2'b10: begin
        case (f3)
          3'b000: begin
            if (cin[12] == 1'b0)
              expanded = {6'b0, cin[10:5], rds2, 5'b0, cin[12], cin[6:5], rds, 3'b000, rds, 7'b0010011};
            else
              expanded = {6'b0, cin[10:5], rds2, 5'b0, cin[12], cin[6:5], rds, 3'b000, rds, 7'b0111011};
          end
          3'b001: expanded = {5'b0, cin[12], cin[6:2], 13'b0, rds, 3'b001, 5'd2, 7'b1100111};
          3'b010: expanded = {5'b0, cin[12:5], rds, 3'b000, 5'd0, 7'b0010011};
          3'b011: expanded = {15'b0, rds, 3'b001, 5'd0, 7'b0010111};
          3'b100: begin
            case (cin[11:10])
              2'b00: expanded = {7'b0, cin[12:5], 3'b000, rds, 7'b0010011};
              2'b01: expanded = {7'b0, cin[12:5], 3'b011, rds, 7'b0010011};
              2'b10: expanded = {7'b0, cin[12:5], 3'b110, rds, 7'b0010011};
              2'b11: expanded = {7'b0, cin[12:5], 3'b111, rds, 7'b0010011};
            endcase
          end
          3'b101: begin
            if (cin[12] == 1'b0) begin
              case (cin[11:10])
                2'b00:   expanded = {7'b0, cin[6:2], 3'b000, cin[9:7], 7'b1100011};
                2'b01:   expanded = {7'b0, cin[6:2], 3'b001, cin[9:7], 7'b1100011};
                2'b10:   expanded = {7'b0, cin[6:2], 3'b100, cin[9:7], 7'b1100011};
                2'b11:   expanded = {7'b0, cin[6:2], 3'b101, cin[9:7], 7'b1100011};
              endcase
            end else begin
              if (cin[6:2] == 5'b00000) expanded = 32'h00100073;
              else                      expanded = {12'b0, cin[6:2], 3'b000, 5'd0, 7'b1101111};
            end
          end
          3'b110: begin
            case ({cin[12], cin[11:10]})
              3'b000:  expanded = {7'b0, cin[6:2], 3'b010, cin[9:7], 7'b1100011};
              3'b001:  expanded = {7'b0, cin[6:2], 3'b011, cin[9:7], 7'b1100011};
              3'b010:  expanded = {7'b0, cin[6:2], 3'b100, cin[9:7], 7'b1100011};
              3'b011:  expanded = {7'b0, cin[6:2], 3'b101, cin[9:7], 7'b1100011};
              3'b100:  expanded = {7'b0, cin[6:2], 3'b110, cin[9:7], 7'b1100011};
              3'b101:  expanded = {7'b0, cin[6:2], 3'b111, cin[9:7], 7'b1100011};
              3'b110:  expanded = {7'b0, cin[6:2], 3'b000, cin[9:7], 7'b1110011};
              3'b111:  expanded = {7'b0, cin[6:2], 3'b000, cin[9:7], 7'b0001111};
            endcase
          end
        endcase
      end
      2'b11: expanded = {cin[15:0], 16'h0};
    endcase
  end

  assign iout = expanded;

endmodule
