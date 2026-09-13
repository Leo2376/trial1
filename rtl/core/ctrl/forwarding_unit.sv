module forwarding_unit #(
  parameter int XLEN = 64
) (
  input  logic [4:0]      id_rs1,
  input  logic [4:0]      id_rs2,
  input  logic [4:0]      ex_rs1,
  input  logic [4:0]      ex_rs2,
  input  logic [4:0]      mem_rd,
  input  logic            mem_reg_we,
  input  logic            mem_is_load,
  input  logic [4:0]      wb_rd,
  input  logic            wb_reg_we,
  input  logic [4:0]      wb_rd_fp,
  input  logic            wb_fp_we,
  output logic [1:0]      fwd_a,
  output logic [1:0]      fwd_b
);

  localparam logic [1:0] FWD_NONE=2'd0, FWD_MEM=2'd1, FWD_WB=2'd2;

  always_comb begin
    fwd_a = FWD_NONE;
    fwd_b = FWD_NONE;

    if (mem_reg_we && (mem_rd != 5'd0) && (mem_rd == ex_rs1))
      fwd_a = FWD_MEM;
    else if (wb_reg_we && (wb_rd != 5'd0) && (wb_rd == ex_rs1))
      fwd_a = FWD_WB;

    if (mem_reg_we && (mem_rd != 5'd0) && (mem_rd == ex_rs2))
      fwd_b = FWD_MEM;
    else if (wb_reg_we && (wb_rd != 5'd0) && (wb_rd == ex_rs2))
      fwd_b = FWD_WB;
  end

endmodule
