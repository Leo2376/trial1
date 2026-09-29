// Load-Store Unit: MEM-stage transaction engine (extracted from
// rv64gch_core.sv; behavior identical). Handles single-beat loads/stores,
// LR/SC reservations (single hart), and AMO read-modify-write (two beats)
// over one AXI-ish data port, plus the aligned load-data latch.
//
// The pipeline packet itself (EX->MEM regs, WB mux, forwarding) stays in
// the core; this engine consumes one request per MEM occupancy and reports
// busy until the final beat's own ack returns.
module lsu (
  input  logic             clk,
  input  logic             rst_n,
  // Backend stall: 0 = take the incoming request, 1 = hold the current
  // transaction and make AXI progress.
  input  logic             stall_i,
  input  logic             trap_i,
  // Request side (core MEM packet fields, held stable while busy_o).
  // cur_* is the current MEM occupancy; nxt_* is the incoming packet the
  // core takes this same edge (entry must key on the incoming packet --
  // keying on cur_* misses the window by a cycle and wedges).
  input  logic             req_valid_i,
  input  logic             req_is_load_i,
  input  logic             req_is_store_i,
  input  logic [63:0]      req_addr_i,
  input  logic [7:0]       req_be_i,
  input  logic [63:0]      req_wdata_i,
  input  rtl_core_pkg::lsu_op_e req_lsu_op_i,
  input  logic [2:0]       req_funct3_i,
  input  rtl_core_pkg::amo_op_e req_amo_op_i,
  input  logic [63:0]      req_rs2_i,
  input  logic             req_lock_i,
  input  logic             nxt_valid_i,
  input  logic             nxt_is_load_i,
  input  logic             nxt_is_store_i,
  input  logic             nxt_is_sc_i,
  // No new data issue inside the fence window (drain in progress).
  input  logic             fence_hold_i,
  // Data bus side (to L1D).
  input  logic [63:0]      d_rdata_i,
  input  logic             d_ack_i,
  input  logic             d_ready_i,
  output logic             mem_req_o,
  output logic             mem_we_o,
  output logic [47:0]      mem_addr_o,
  output logic [7:0]       mem_be_o,
  output logic [63:0]      mem_wdata_o,
  output logic             mem_lock_o,
  // Status.
  output logic             busy_o,
  output logic [63:0]      load_data_o,
  // LR reservation for the core's EX-stage SC check.
  output logic             lr_valid_o,
  output logic [47:0]      lr_addr_o,
  // In-flight transaction marker (for the core's commit tracer).
  output logic             pending_o
);
  import rtl_core_pkg::*;

  // LR/SC reservation (single hart): set by LR, checked+cleared by SC,
  // cleared on trap. Compared on full byte address.
  logic        lr_valid_q;
  logic [47:0] lr_addr_q;

  // AMO ALU: old = aligned memory value, op2 = rs2. W operates on low 32b.
  function automatic logic [63:0] amo_compute(logic [63:0] old, logic [63:0] op2,
                                              amo_op_e op, logic is_d);
    logic [31:0] o32, p32, r32;
    logic [63:0] r64;
    if (!is_d) begin
      o32 = old[31:0]; p32 = op2[31:0];
      unique case (op)
        AMO_ADD:  r32 = o32 + p32;
        AMO_SWAP: r32 = p32;
        AMO_XOR:  r32 = o32 ^ p32;
        AMO_AND:  r32 = o32 & p32;
        AMO_OR:   r32 = o32 | p32;
        AMO_MIN:  r32 = ($signed(o32) < $signed(p32)) ? o32 : p32;
        AMO_MAX:  r32 = ($signed(o32) >= $signed(p32)) ? o32 : p32;
        AMO_MINU: r32 = (o32 < p32) ? o32 : p32;
        AMO_MAXU: r32 = (o32 >= p32) ? o32 : p32;
        default:  r32 = o32;
      endcase
      return {{32{r32[31]}}, r32};
    end
    unique case (op)
      AMO_ADD:  r64 = old + op2;
      AMO_SWAP: r64 = op2;
      AMO_XOR:  r64 = old ^ op2;
      AMO_AND:  r64 = old & op2;
      AMO_OR:   r64 = old | op2;
      AMO_MIN:  r64 = ($signed(old) < $signed(op2)) ? old : op2;
      AMO_MAX:  r64 = ($signed(old) >= $signed(op2)) ? old : op2;
      AMO_MINU: r64 = (old < op2) ? old : op2;
      AMO_MAXU: r64 = (old >= op2) ? old : op2;
      default:  r64 = old;
    endcase
    return r64;
  endfunction

  function automatic logic [63:0] align_load(logic [63:0] d, logic [2:0] off, lsu_op_e op);
    logic [63:0] r;
    r = d >> (off*8);
    case (op)
      LSU_LB:  r = {{56{r[7]}},  r[7:0]};
      LSU_LH:  r = {{48{r[15]}}, r[15:0]};
      LSU_LW:  r = {{32{r[31]}}, r[31:0]};
      LSU_LD:  r = r;
      LSU_LBU: r = {56'd0, r[7:0]};
      LSU_LHU: r = {48'd0, r[15:0]};
      LSU_LWU: r = {32'd0, r[31:0]};
      default: r = r;
    endcase
    return r;
  endfunction

  logic        lsu_busy;
  logic        axi_issued;
  logic        axi_pending;
  logic        amo_wr_q;
  logic [63:0] load_data_q;
  logic        amo_read_ack;

  // axi_pending marks the in-flight transaction of the current request so
  // that only its own completion (d_ack_i) is interpreted as this load's/
  // store's response. axi_issued suppresses a re-issue of the same
  // transaction: once the data port has accepted a load/store request it
  // stays asserted until the load/store leaves (the request advances), so
  // a completed transaction cannot be re-driven. busy_o is raised when a
  // load/store/atomic enters and drops when its final transaction's own
  // ack returns, unstalling the pipeline so it drains to WB.
  // AMO is two transactions (read old, write new): amo_wr_q tracks the phase.
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      lsu_busy    <= 1'b0;
      axi_issued  <= 1'b0;
      axi_pending <= 1'b0;
      lr_valid_q  <= 1'b0;
      lr_addr_q   <= '0;
      amo_wr_q    <= 1'b0;
    end else if (trap_i) begin
      lsu_busy    <= 1'b0;
      axi_issued  <= 1'b0;
      axi_pending <= 1'b0;
      lr_valid_q  <= 1'b0;
      amo_wr_q    <= 1'b0;
    end else if (!stall_i) begin
      if (nxt_valid_i & (nxt_is_store_i | nxt_is_load_i)) begin
        lsu_busy    <= 1'b1;
        axi_issued  <= 1'b0;
        axi_pending <= 1'b0;
        amo_wr_q    <= 1'b0;
      end else begin
        lsu_busy    <= 1'b0;
        axi_issued  <= 1'b0;
        axi_pending <= 1'b0;
        amo_wr_q    <= 1'b0;
        // SC (fail or success) consumes the reservation as it drains.
        if (nxt_valid_i & nxt_is_sc_i)
          lr_valid_q <= 1'b0;
      end
    end else begin
      // Pipeline stalled (busy_o holds it). Issue the AXI request once and
      // keep it issued until the load/store leaves; clear busy_o only on
      // the final transaction's own completion so the pipeline can then drain.
      if (mem_req_o & d_ready_i) begin
        axi_issued  <= 1'b1;
        axi_pending <= 1'b1;
      end
      if (axi_pending & d_ack_i) begin
        // LR sets the reservation when its read returns.
        if (req_valid_i & (req_lsu_op_i == LSU_LR)) begin
          lr_valid_q  <= 1'b1;
          lr_addr_q   <= req_addr_i[47:0];
          lsu_busy    <= 1'b0;
          axi_pending <= 1'b0;
        // AMO read phase: advance to write phase, re-arm issue, stay busy.
        end else if (req_valid_i & (req_lsu_op_i == LSU_AMO) & ~amo_wr_q) begin
          amo_wr_q    <= 1'b1;
          axi_issued  <= 1'b0;
          axi_pending <= 1'b0;
        end else begin
          lsu_busy    <= 1'b0;
          axi_pending <= 1'b0;
        end
      end
      // SC (success or fail) consumes the reservation once it leaves;
      // the drain happens via the entry path clearing busy above, but flag
      // the clear here too for the success path that just acked.
      if (axi_pending & d_ack_i & req_valid_i &
          (req_lsu_op_i == LSU_SC))
        lr_valid_q <= 1'b0;
    end
  end

  // mem_req is asserted only until the data port accepts the load/store
  // request (axi_issued). Staying asserted past acceptance would let the
  // shared port re-issue the same transaction after it completes (e.g. a
  // duplicate store write whose response later arrives as a stale ack and
  // corrupts a following load's busy_o). axi_issued clears when the
  // transaction's ack returns, readying for the next load/store.
  // AMO is read-then-write: we=0 in the read phase (amo_wr_q==0), we=1 with
  // the computed new value in the write phase.
  logic mem_is_amo_w;
  assign mem_is_amo_w = req_valid_i & (req_lsu_op_i == LSU_AMO) & amo_wr_q;
  logic [63:0] amo_old_aligned;
  assign amo_old_aligned = align_load(load_data_q, 3'b0, (req_funct3_i == 3'b011) ? LSU_LD : LSU_LW);
  logic [63:0] amo_new;
  assign amo_new = amo_compute(amo_old_aligned, req_rs2_i, req_amo_op_i,
                               (req_funct3_i == 3'b011));
  // No new data issue inside the fence window (a younger op waits;
  // busy_o already stalls the pipe, and the drain needs no competition).
  assign mem_req_o   = req_valid_i & (req_is_store_i | req_is_load_i) & ~axi_issued &
                       ~fence_hold_i;
  // AMO read phase must issue with we=0 (the entry is_store bit is 1, so it
  // cannot be used directly); write phase uses the computed amo_new.
  assign mem_we_o    = (req_lsu_op_i == LSU_AMO) ? amo_wr_q : req_is_store_i;
  assign mem_addr_o  = req_addr_i[47:0];
  assign mem_be_o    = req_be_i;
  assign mem_wdata_o = mem_is_amo_w ? (amo_new << (req_addr_i[2:0]*8)) : req_wdata_i;
  assign mem_lock_o  = req_lock_i;

  // The load read data is latched when THIS load's own transaction
  // completes (axi_pending drop), not on any dmem ack. The shared data port
  // can deliver a stale ack (e.g. a prior store's response) while a load is
  // in flight with the bus read data still holding a fetch word; latching on a
  // bare ack would capture the wrong value. axi_pending is asserted for
  // the current request's transaction and cleared only by its own ack.
  // LR/AMO widths come from funct3 (010=W, 011=D); AMO latches only in its
  // read phase (write ack must not overwrite the old value in load_data_q).
  assign amo_read_ack = req_valid_i & (req_lsu_op_i == LSU_AMO) & ~amo_wr_q;
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) load_data_q <= '0;
    else if (axi_pending & d_ack_i & req_valid_i & req_is_load_i &
             (req_lsu_op_i != LSU_AMO | amo_read_ack))
      load_data_q <= align_load(d_rdata_i, req_addr_i[2:0],
        ((req_lsu_op_i == LSU_LR) | (req_lsu_op_i == LSU_AMO)) ?
          ((req_funct3_i == 3'b011) ? LSU_LD : LSU_LW) :
          req_lsu_op_i);
  end

  assign busy_o      = lsu_busy;
  assign load_data_o = load_data_q;
  assign lr_valid_o  = lr_valid_q;
  assign lr_addr_o   = lr_addr_q;
  assign pending_o   = axi_pending;

endmodule
