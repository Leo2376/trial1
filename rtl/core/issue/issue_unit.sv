// Dual-issue pairing predicate (Phase 1 backend).
//
// Decides whether two in-order instructions may issue in the same cycle.
// Lane A is the full pipe (ALU/MDU/FPU/LSU/branch/CSR); lane B is ALU-only,
// so both candidates must be simple integer-ALU ops with no memory, CSR,
// system, or control-flow side effects. Lane B can never trap, which keeps
// the existing single-lane trap/redirect logic correct: a lane-A trap or
// taken-branch simply squashes the younger lane-B slot.
//
// Allowed lane-B (and paired lane-A) ops: ADD/SUB/SLL/SLT/SLTU/XOR/SRL/SRA/
// OR/AND (+W variants) + LUI + AUIPC. Everything else issues single on lane A.
module issue_unit (
  input  rtl_core_pkg::ctrl_t c0,
  input  rtl_core_pkg::ctrl_t c1,
  input  logic                valid0,
  input  logic                valid1,
  input  logic                fault0,
  input  logic                fault1,
  output logic                can_dual
);
  import rtl_core_pkg::*;

  function automatic logic is_simple_alu(input ctrl_t c);
    if (c.illegal) return 1'b0;
    if (c.fpu_op != FPU_NONE) return 1'b0;
    if (c.lsu_op != LSU_NONE) return 1'b0;
    if (c.is_branch | c.is_jal | c.is_jalr) return 1'b0;
    if (c.reads_csr | c.writes_csr) return 1'b0;
    if (c.fence_i | c.is_sfence | c.is_ebreak | c.is_ecall) return 1'b0;
    if (c.is_mret | c.is_sret | c.is_wfi) return 1'b0;
    unique case (c.alu_op)
      ALU_ADD, ALU_SUB, ALU_SLL, ALU_SLT, ALU_SLTU,
      ALU_XOR, ALU_SRL, ALU_SRA, ALU_OR, ALU_AND,
      ALU_ADDW, ALU_SUBW, ALU_SLLW, ALU_SRLW, ALU_SRAW,
      ALU_LUI: return 1'b1;
      default: return 1'b0; // NONE, COPYB, MDU family
    endcase
  endfunction

  assign can_dual = valid0 & valid1 & ~fault0 & ~fault1 &
                    is_simple_alu(c0) & is_simple_alu(c1);

endmodule
