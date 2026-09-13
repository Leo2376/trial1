module hazard_unit #(
  parameter int XLEN = 64
) (
  input  logic [4:0]      id_rs1,
  input  logic [4:0]      id_rs2,
  input  logic [4:0]      ex_rd,
  input  logic            ex_mem_read,
  input  logic            ex_mul_busy,
  input  logic            ex_fpu_busy,
  input  logic            mem_lsu_busy,
  input  logic            branch_taken,
  input  logic            trap,
  input  logic            is_csr_op,
  input  logic            csr_hazard,
  output logic            stall,
  output logic            flush_id,
  output logic            flush_ex
);

  logic load_use_hazard;

  assign load_use_hazard = ex_mem_read && (ex_rd != 5'd0) &&
                           ((ex_rd == id_rs1) || (ex_rd == id_rs2));

  assign stall = load_use_hazard | ex_mul_busy | ex_fpu_busy | mem_lsu_busy |
                 (is_csr_op & csr_hazard);

  assign flush_id = branch_taken | trap;
  assign flush_ex = branch_taken | trap;

endmodule
