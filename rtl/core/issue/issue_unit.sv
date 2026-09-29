// Dual-issue pairing predicate.
//
// Lane B is always simple integer ALU. Lane A is simple-ALU (dual ALU +
// dual retire, intra-pair bypass covers same-cycle RAW) or a long op
// (MDU/FPU compute). A long pair advances in lockstep behind the long op
// (its busy stalls couple both lanes) and retires the same cycle, so the
// result is always sampled post-done -- no extra bypass needed. Memory,
// CSR, system, and control-flow ops never pair (lane-A single).
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

  assign can_dual = valid0 & valid1 & ~fault0 & ~fault1 &
                    ((is_simple_alu_op(c0) & is_simple_alu_op(c1)) |
                     (is_long_alu_op(c0) & is_simple_alu_op(c1)));

endmodule
