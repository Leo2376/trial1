module hazard_unit #(
  parameter int XLEN = 64
) (
  // Oldest issue candidate (lane A) + younger dual slot (lane B).
  input  rtl_core_pkg::ctrl_t id_c0,
  input  logic                id_c0_valid,
  input  rtl_core_pkg::ctrl_t id_c1,
  input  logic                id_c1_valid,
  input  logic [4:0]      ex_rd,
  input  logic            ex_mem_read,
  // EX holds an FP load (FLW/FLD): its FP rd feeds FP-file readers.
  input  logic            ex_fp_load,
  input  logic            ex_mul_busy,
  input  logic            ex_fpu_busy,
  input  logic            mem_lsu_busy,
  input  logic            branch_taken,
  input  logic            trap,
  input  logic            is_csr_op,
  input  logic            csr_hazard,
  output logic            stall,
  output logic            load_use,
  output logic            flush_id,
  output logic            flush_ex
);
  import rtl_core_pkg::*;

  // Integer rs1 readers: R/RW-imm ALU, loads/stores (addr), branches,
  // jalr, AMO/LR/SC, register-form CSR ops, and int-source FP ops
  // (FCVT.W/D.X, FMV.W.X/D.X). LUI/AUIPC/JAL and imm-CSR read no int reg.
  function automatic logic reads_rs1(input ctrl_t c);
    // RVV: vector ld/st read the base (rs1); vsetvli reads AVL (rs1)
    // while vsetivli takes its uimm from the rs1 field (no reg read).
    if (c.is_vec_mem)
      return 1'b1;
    if (c.is_vset)
      return ~c.vset_ivli;
    if (c.is_fp)
      return (c.fpu_op == FPU_I2F) | (c.fpu_op == FPU_MV_X2F);
    if (c.opcode == OP_OP || c.opcode == OP_OPIMM ||
        c.opcode == OP_OP32 || c.opcode == OP_OPIMM32)
      return 1'b1;
    if (c.is_branch || c.is_jalr)
      return 1'b1;
    if (c.lsu_op != LSU_NONE)
      return 1'b1; // loads/stores addr, LR/SC/AMO addr (+data via rs2)
    if (c.reads_csr && !c.funct3[2])
      return 1'b1; // register-form CSR; zimm forms read no reg
    return 1'b0;
  endfunction

  // Integer rs2 readers: R-type ALU, store/AMO data, branches.
  // I-type immediates reuse the rs2 field for imm bits (never a reg).
  function automatic logic reads_rs2(input ctrl_t c);
    // RVV: strided vector ld/st read the stride from x[rs2]; unit-stride
    // reads no int rs2 (the field is lumop/vm), vector data lives in VRF.
    if (c.is_vec_mem)
      return c.vec_strided;
    if (c.is_fp)
      return 1'b0;
    if (c.opcode == OP_OP || c.opcode == OP_OP32)
      return 1'b1;
    if (c.is_branch)
      return 1'b1;
    if (c.lsu_op == LSU_SB || c.lsu_op == LSU_SH ||
        c.lsu_op == LSU_SW || c.lsu_op == LSU_SD ||
        c.lsu_op == LSU_SC || c.lsu_op == LSU_AMO)
      return 1'b1;
    return 1'b0;
  endfunction

  logic load_use_hazard;
  // NOTE on the integer side below: rs3 is intentionally absent (FP-only
  // field, different file), and rs2 is masked to true readers so I-type
  // immediates (c.li etc.) never cause spurious stalls. A spurious stall
  // used to resolve by fetch-gap timing luck; a dense dual frontend turns
  // it into a permanent livelock (EX load frozen while its false consumer
  // waits in Decode forever).
  // FP-file readers of an in-flight FP load (f0 is a real register: no
  // x0 exclusion on this side). Int-src FP ops (I2F/MV_X2F) read the int
  // file (covered above); FP loads/stores use int rs1 for the address
  // (covered above); everything else reads FP rs1/rs2 (+rs3 for FMADD).
  function automatic logic fp_int_src(input ctrl_t c);
    return (c.fpu_op == FPU_I2F) | (c.fpu_op == FPU_MV_X2F);
  endfunction
  function automatic logic fp_is_fmadd(input ctrl_t c);
    return (c.opcode == OP_FMADD) | (c.opcode == OP_FMSUB) |
           (c.opcode == OP_FNMSUB) | (c.opcode == OP_FNMADD);
  endfunction
  function automatic logic fp_reads_rs1(input ctrl_t c);
    return c.is_fp & ~fp_int_src(c) &
           (c.opcode != OP_FPLOAD) & (c.opcode != OP_FPSTORE);
  endfunction
  function automatic logic fp_reads_rs2(input ctrl_t c);
    return c.is_fp & ~fp_int_src(c) &
           ((c.opcode == OP_FPOP) | fp_is_fmadd(c) |
            (c.opcode == OP_FPSTORE));
  endfunction
  function automatic logic fp_reads_rs3(input ctrl_t c);
    return c.is_fp & fp_is_fmadd(c);
  endfunction
  function automatic logic fp_match(input ctrl_t c, input logic [4:0] rd);
    return ((fp_reads_rs1(c)) && (rd == c.rs1)) ||
           ((fp_reads_rs2(c)) && (rd == c.rs2)) ||
           ((fp_reads_rs3(c)) && (rd == c.rs3));
  endfunction
  logic fp_load_use_hazard;
  assign fp_load_use_hazard = ex_fp_load && id_c0_valid &&
                              (fp_match(id_c0, ex_rd) ||
                               (id_c1_valid && fp_match(id_c1, ex_rd)));
  assign load_use_hazard = (ex_mem_read && (ex_rd != 5'd0) && id_c0_valid &&
                           (((reads_rs1(id_c0)) && (ex_rd == id_c0.rs1)) ||
                            ((reads_rs2(id_c0)) && (ex_rd == id_c0.rs2)) ||
                            (id_c1_valid &&
                             (((reads_rs1(id_c1)) && (ex_rd == id_c1.rs1)) ||
                              ((reads_rs2(id_c1)) && (ex_rd == id_c1.rs2)))))) ||
                           fp_load_use_hazard;

  assign stall = load_use_hazard | ex_mul_busy | ex_fpu_busy | mem_lsu_busy |
                 (is_csr_op & csr_hazard);
  assign load_use = load_use_hazard;

  // A control-flow redirect (branch/jal/jalr) squashes only the younger
  // wrong-path instruction in ID; the redirecting instruction in EX must
  // continue to MEM/WB to retire (jal/jalr write a link register). A trap
  // aborts the EX instruction itself, so it also bubbles EX.
  assign flush_id = branch_taken | trap;
  assign flush_ex = trap;

endmodule
