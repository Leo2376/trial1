module rv64gch_core #(
  parameter int XLEN = 64
) (
  input  logic             clk,
  input  logic             rst_n,
  input  logic [XLEN-1:0]  hartid_i,
  input  logic             timer_irq,
  input  logic             soft_irq,
  input  logic             ext_irq,
  output logic             fetch_req,
  output logic             fetch_we,
  output logic [47:0]      fetch_addr,
  output logic [7:0]       fetch_be,
  output logic [63:0]      fetch_wdata,
  input  logic [63:0]      fetch_rdata,
  input  logic             fetch_ack,
  input  logic             fetch_ready,
  input  logic             fetch_err,
  output logic             mem_req,
  output logic             mem_we,
  output logic [47:0]      mem_addr,
  output logic [7:0]       mem_be,
  output logic [63:0]      mem_wdata,
  output logic             mem_lock,
  input  logic [63:0]      mem_rdata,
  input  logic             mem_ack,
  input  logic             mem_ready,
  input  logic             mem_err,
  output logic [31:0]      dbg_pc,
  // Single-cycle pulse when a FENCE.I retires at WB (for L1I invalidation).
  output logic             fence_i_o,
  // SFENCE.VMA retire pulse (TLB + L1D-drain trigger in the MMU stage).
  output logic             sfence_o,
  // HFENCE.VVMA / HFENCE.GVMA retire pulses (TLB flush + drain like SFENCE).
  output logic             hfence_vvma_o,
  output logic             hfence_gvma_o,
  // Pulse when a SATP write retires at WB (TLB + L1D-drain trigger).
  output logic             satp_we_o,
  // L1D drain sweep in progress (SFENCE/SATP/FENCE.I writeback): stall.
  input  logic             drain_busy_i,
  // Walker memory port (physical; top routes to L2 port C).
  output logic             ptw_req,
  output logic             ptw_we,
  output logic [47:0]      ptw_addr,
  output logic [7:0]       ptw_be,
  output logic [63:0]      ptw_wdata,
  input  logic [63:0]      ptw_rdata,
  input  logic             ptw_ack,
  input  logic             ptw_ready
);
  import rtl_core_pkg::*;
  import rv64gch_memmap_pkg::RESET_PC;

  logic [XLEN-1:0] pc_f, pc_d, pc_x, pc_m;
  logic [31:0]     instr_f, instr_d;
  logic            valid_f, valid_d, valid_x, valid_m, valid_w;
  logic            is_c_f, is_c_d;
  logic            flush_all, flush_id, flush_id_raw, flush_ex;
  logic            stall, stall_raw, frm_stall;
  logic [2:0]      frm;
  logic [2:0]      fpu_rm_eff;
  logic [1:0]      priv;

  ctrl_t           dc, dc1;
  logic [63:0]     imm, imm1;
  logic [4:0]      rs1_d, rs2_d, rs3_d, rs1_x, rs2_x, rd_x, rd_m, rd_w;
  logic [63:0]     rdata1_d, rdata2_d, rdata1_x, rdata2_x, rs1_fwd, rs2_fwd;
  logic [63:0]     alu_a, alu_b, alu_y;
  logic [63:0]     wb_data, wb_data_w, mem_alu_y;
  logic [1:0]      fwd_a, fwd_b;
  logic            reg_we_w, reg_we_m;
  logic            fp_we_w, fp_we_m;
  logic [63:0]     mdu_res, fpu_res;
  logic            mdu_done, fpu_done, mdu_start, fpu_start, mdu_busy, fpu_busy;
  logic            mdu_busy_q, fpu_busy_q;
  logic [63:0]     mem_rdata_aligned;
  logic            mem_is_load_x, mem_is_store_x;
  logic            branch_resolved;
  logic [63:0]     branch_target;
  logic            redirect;
  logic [63:0]     redirect_target;
  logic [63:0]     csr_rdata;
  logic [63:0]     csr_mstatus, csr_satp; // consumed by the MMU stage
  logic [63:0]     csr_sstatus;
  logic            csr_trap_deleg;
  logic            csr_we, trap, mret_x, sret_x;
  logic [4:0]      cause;
  logic [63:0]     epc, tvec;
  logic [1:0]      new_priv;
  logic            irq_pending;
  logic            virt;
  logic            csr_hstatus_spv, csr_hstatus_spvp;

  logic [63:0]     fp_rdata1, fp_rdata2, fp_rdata3;
  logic            fp_rdy;
  logic [4:0]      rd_w_fp;

  logic [63:0]     next_pc;

  typedef struct packed {
    logic        valid;
    logic [63:0] pc;
    logic [31:0] instr;
    ctrl_t       ctrl;
    logic        is_c;
    logic        illegal_c;
    logic        fault_f;   // fetch translation fault bubble
    logic [4:0]  fcause;
    logic [63:0] fva;
    logic [63:0] rs1;
    logic [63:0] rs2;
    logic [63:0] fa;
    logic [63:0] fb;
    logic [63:0] fc;
    logic [63:0] imm;
    logic        pred_taken; // D predicted taken (fetch redirected); EX verifies
    logic [63:0] pred_target; // D's predicted target (jalr: RAS/BTB; else pc+imm)
  } ex_pkt_t;
  ex_pkt_t ex_pkt, ex_pkt_n;

  typedef struct packed {
    logic        valid;
    logic [63:0] pc;
    ctrl_t       ctrl;
    logic [63:0] alu_res;
    logic [63:0] rs2;
    logic [63:0] csr_wdata;
    logic [63:0] mem_addr;
    logic        is_store;
    logic        is_load;
    logic [63:0] store_data;
    logic [7:0]  be;
    logic        lock;
    logic [4:0]  fflags;
    // Dual-issue lane B (ALU-only younger slot) rides the same MEM/WB
    // packets through: no memory access, just an ALU result + dest.
    logic        b_valid;
    logic [4:0]  b_rd;
    logic        b_we;
    logic [63:0] b_alu_res;
    logic [63:0] b_pc;
  } mem_pkt_t;
  mem_pkt_t mem_pkt, mem_pkt_n;

  typedef struct packed {
    logic        valid;
    logic [63:0] pc;
    ctrl_t       ctrl;
    logic [63:0] data;
    logic [63:0] csr_wdata;
    logic [63:0] rs2v; // rs2 value (SFENCE.VMA asid lives here at retire)
    logic [4:0]  rd;
    logic        we;
    logic        fp_we;
    logic [4:0]  fflags;
    // Dual-issue lane B retire slot (integer only, never FP/CSR).
    logic        b_valid;
    logic [4:0]  b_rd;
    logic        b_we;
    logic [63:0] b_data;
    logic [63:0] b_pc;
  } wb_pkt_t;
  wb_pkt_t wb_pkt, wb_pkt_n;

  assign dbg_pc = pc_d;

  // Dual-issue engagement counter (debug only, +define+DUAL_DEBUG).
  `ifdef DUAL_DEBUG
  longint unsigned dual_cnt = 0;
  always @(posedge clk) if (rst_n && issue2 && !stall) dual_cnt <= dual_cnt + 1;
  final $display("[dual] paired-issue cycles = %0d", dual_cnt);
  `endif
  // Dual-issue: lane A (ex_pkt) is the full pipe; lane B (ex_pkt_b) is
  // ALU-only. D0/D1 (dual fetch) issue as a pair when pairable, else the
  // head issues single and D1 shifts up. d_entry/d_entry1 carry
  // issue-time operand values (fresh every cycle, never latched).
  ex_pkt_t ex_pkt_b;
  ex_pkt_t d_entry, d_entry1;
  logic    dualDD;  // D0+D1 pairing decision (issue_unit)
  logic    issue2;  // dual-issue this cycle (D0+D1 pair)

  // Real privilege state (was hardwired M). Switches on the committing
  // edge itself -- trap target, or MPP/SPP on xret redirect -- so no fetch
  // or translation ever uses a stale mode (the old WB-retire lag let
  // post-mret fetches run under the previous priv, fatal for non-identity
  // targets). The same-edge redirect/trap flushes discard in-flight work.
  logic [1:0] xret_priv;
  logic xret_virt;
  logic csr_virt, csr_trap_to_vs;
  logic [63:0] csr_vsatp, csr_hgatp, csr_vsstatus;
  logic [1:0] csr_new_priv;
  logic csr_new_virt;
  assign xret_priv = ex_pkt.ctrl.is_mret ?
                     ((csr_mstatus[12:11] == 2'b10) ? PRIV_U :
                      priv_e'(csr_mstatus[12:11])) :
                     (csr_virt ? (csr_vsstatus[8] ? PRIV_S : PRIV_U) :
                      (csr_hstatus_spv ? (csr_hstatus_spvp ? PRIV_S : PRIV_U) :
                       (csr_sstatus[8] ? PRIV_S : PRIV_U)));
  assign xret_virt = ex_pkt.ctrl.is_mret ? csr_mstatus[39] :
                     (csr_virt ? 1'b1 : csr_hstatus_spv);
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      priv <= PRIV_M;
      virt <= 1'b0;
    end else if (trap) begin
      priv <= csr_new_priv;
      virt <= csr_new_virt;
    end else if (redirect & is_xret) begin
      priv <= xret_priv;
      virt <= xret_virt;
    end
  end

  assign next_pc = (redirect) ? redirect_target : fetch_next_pc;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      pc_f <= RESET_PC;
    end else if (flush_all) begin
      pc_f <= (trap) ? tvec : (redirect ? redirect_target : next_pc);
    end else if (!stall && fetch_done) begin
      pc_f <= next_pc;
    end else if (pred_fire) begin
      pc_f <= pred_target;
    end
  end

  logic [31:0] instr_expanded;
  logic        fetch_is_c;
  logic        fetch_illegal_c;
  logic [31:0] fetch_instr;
  logic [15:0] fetch_low_half;
  logic [63:0] fetch_word_q;   // latched fetch word, held across stalls
  logic [63:0] fetch_pc_q;     // 8B-aligned base of the latched word
  logic        fetch_complete;  // fetch read returned, awaiting consumption
  logic [63:0] fetch_hi_q;     // second word for 32-bit insn straddling 64-bit boundary
  logic        fetch_hi_valid;
  logic        fetch_need_hi;
  logic        fetch_done;
  logic        fetch_busy;
  // A latched fetch result is only usable if it corresponds to the
  // current pc_f. Redirects/flushes change pc_f; a stale result from the
  // previous pc must not be consumed. Comparing the latched pc against
  // pc_f (using the word-aligned address) makes the skid buffer safe
  // across flushes without relying solely on flush_all clearing it.
  logic fetch_res_valid;
  assign fetch_res_valid = fetch_complete & (fetch_pc_q[47:3] == pc_f[47:3]) &
                           (~fetch_need_hi | fetch_hi_valid);
  // Assemble the 32-bit instruction window from the latched fetched
  // 64-bit word(s) based on pc_f[2:1]. A 32-bit (non-compressed) instruction
  // can straddle the 32-bit boundary inside the 64-bit fetch word when it
  // is located at byte offset 2 (pc_f[2:1] == 2'b01), so the lower and
  // upper halves must be stitched together. A 32-bit instruction at byte
  // offset 6 (pc_f[2:1] == 2'b11) straddles the 64-bit word boundary: its
  // low half lives in fetch_word_q[63:48] and its high half in
  // fetch_hi_q[15:0] (fetched with a second AXI transaction). Compressed
  // (16-bit) instructions never straddle, so the half-word selected by
  // pc_f[2:1] is always valid on its own.
  always_comb begin
    unique case (pc_f[2:1])
      2'b00: fetch_instr = fetch_word_q[31:0];
      2'b01: fetch_instr = {fetch_word_q[47:32], fetch_word_q[31:16]};
      2'b10: fetch_instr = fetch_word_q[63:32];
      2'b11: fetch_instr = fetch_need_hi ? {fetch_hi_q[15:0], fetch_word_q[63:48]}
                                          : {16'b0, fetch_word_q[63:48]};
    endcase
  end
  // Low half-word at the current PC determines compressed vs 32-bit and
  // whether a second word is needed (32-bit at offset 6).
  always_comb begin
    unique case (pc_f[2:1])
      2'b00: fetch_low_half = fetch_word_q[15:0];
      2'b01: fetch_low_half = fetch_word_q[31:16];
      2'b10: fetch_low_half = fetch_word_q[47:32];
      2'b11: fetch_low_half = fetch_word_q[63:48];
    endcase
  end
  assign fetch_need_hi = (pc_f[2:1] == 2'b11) & fetch_complete &
                         (fetch_low_half[1:0] == 2'b11) &
                         (fetch_pc_q[47:3] == pc_f[47:3]);
  // The decompressor inspects the lowest 16 bits of the assembled window.
  decompressor u_decomp (.cin(fetch_instr[15:0]), .iout(instr_expanded),
                         .is_c(fetch_is_c), .illegal(fetch_illegal_c));

  logic [31:0] instr_d_use;
  logic        illegal_d_use;
  assign instr_d_use = fetch_is_c ? instr_expanded : fetch_instr;
  assign illegal_d_use = fetch_is_c & fetch_illegal_c;

  // Dual-fetch slot 1: second parcel decoded from the same buffered 8B
  // word (plus the hi word when already present). No extra bus transaction
  // and no new translation: both chunks were translated when fetched, and
  // any fault collapses to single-consume + clear (the existing bubble
  // path), so slot 1 bytes are always known-good here.
  logic [63:0] fetch_pc1;
  logic [3:0]  fetch_len0, fetch_len1;
  logic [3:0]  fetch_off1;
  logic [127:0] fetch_win128;
  logic [31:0] fetch_instr1, instr_expanded1, instr1_d_use;
  logic [15:0] fetch_low_half1;
  logic        fetch_is_c1, fetch_illegal_c1, illegal1_d_use;
  logic        slot1_in_win, slot1_avail, fetch_done1;
  logic [63:0] fetch_next_pc;
  assign fetch_len0 = fetch_is_c ? 4'd2 : 4'd4;
  assign fetch_pc1  = pc_f + {60'd0, fetch_len0};
  // Byte offset of slot 1 within the {hi,word} window (both 2B-aligned).
  assign fetch_off1 = fetch_pc1[3:0] - fetch_pc_q[3:0];
  assign slot1_in_win = (fetch_pc1 >= fetch_pc_q) &
                        (fetch_pc1 < (fetch_pc_q + 64'd16));
  assign fetch_win128 = {fetch_hi_q, fetch_word_q} >> (fetch_off1*8);
  assign fetch_low_half1 = fetch_win128[15:0];
  assign fetch_instr1 = fetch_win128[31:0];
  decompressor u_decomp1 (.cin(fetch_low_half1), .iout(instr_expanded1),
                          .is_c(fetch_is_c1), .illegal(fetch_illegal_c1));
  assign fetch_len1 = fetch_is_c1 ? 4'd2 : 4'd4;
  assign instr1_d_use = fetch_is_c1 ? instr_expanded1 : fetch_instr1;
  assign illegal1_d_use = fetch_is_c1 & fetch_illegal_c1;
  // Slot 1 bytes must be buffered: within the 16B window, and hi bytes
  // (offset >= 8) require the hi word to be present. Offset 14 holds only
  // the low half, so a 32-bit slot 1 there is not servable.
  assign slot1_avail = slot1_in_win &
                       ((fetch_off1 + {1'b0, fetch_len1}) <=
                        (fetch_hi_valid ? 5'd16 : 5'd8));
  assign fetch_done1 = fetch_done & slot1_avail &
                       ~fault_f_q & ~mmu_fault_f & ~dual_suppress;
  assign fetch_next_pc = fetch_done1 ? (fetch_pc1 + {60'd0, fetch_len1}) :
                                       (pc_f + {60'd0, fetch_len0});

  // fetch_done is a latched (level) signal gated by the result being valid
  // for the current pc and the pipeline being able to consume it. This
  // prevents a fetch completion pulse from being lost while the pipeline is
  // stalled (e.g. a load-use hazard or multi-cycle LSU access), which would
  // otherwise deadlock the core, while a stale result from a flushed pc is
  // ignored. For a 32-bit instruction at byte offset 6 the window straddles
  // two 64-bit words, so fetch_res_valid waits for the second word.
  // Static branch prediction (stage a: backward-taken / forward-not-taken)
  // plus stage b: 64-entry direct-mapped BTB with 2-bit counters, an
  // 8-deep return-address stack, and early-JAL redirect -- all predicted
  // in Decode, verified in EX. BTB/RAS are pure predictions (never
  // flushed by fences/traps; a stale entry just mispredicts once and the
  // EX update corrects it). RAS updates at EX-resolve (in-order), so no
  // speculative repair is ever needed.
  localparam int BTB_ENTRIES = 64;
  logic            btb_v [BTB_ENTRIES];
  logic [40:0]     btb_tag [BTB_ENTRIES];
  logic [63:0]     btb_tgt [BTB_ENTRIES];
  logic [1:0]      btb_ctr [BTB_ENTRIES];
  logic [63:0]     ras [8];
  logic [3:0]      ras_count; // 0..8 valid entries
  logic [2:0]      ras_ptr;   // next push slot; top is (ptr-1)&7
  logic [63:0]     ras_top;
  assign ras_top = ras[(ras_ptr - 3'd1) & 3'd7];
  // D0/D1 classification.
  logic d0_branch, d0_jal, d0_jalr, d1_branch, d1_jal, d1_jalr;
  logic [4:0] d0_rs1, d0_rd, d1_rs1, d1_rd;
  assign d0_branch = valid_d & dc.is_branch;
  assign d0_jal    = valid_d & dc.is_jal;
  assign d0_jalr   = valid_d & dc.is_jalr;
  assign d0_rs1 = dc.rs1; assign d0_rd = dc.rd;
  assign d1_branch = has_d1 & dc1.is_branch;
  assign d1_jal    = has_d1 & dc1.is_jal;
  assign d1_jalr   = has_d1 & dc1.is_jalr;
  assign d1_rs1 = dc1.rs1; assign d1_rd = dc1.rd;
  // Link-register call/ret classification (RISC-V convention: x1/x5).
  function automatic logic is_link(input logic [4:0] r);
    return (r == 5'd1) | (r == 5'd5);
  endfunction
  // BTB lookup (index pc[6:1] covers 2B parcels; tag is VA[47:7]).
  logic [5:0] btb_idx0, btb_idx1;
  logic [40:0] btb_tag0, btb_tag1;
  logic btb_hit0, btb_hit1;
  assign btb_idx0 = pc_d[6:1];   assign btb_tag0 = pc_d[47:7];
  assign btb_idx1 = pc_d1[6:1];  assign btb_tag1 = pc_d1[47:7];
  assign btb_hit0 = valid_d & btb_v[btb_idx0] & (btb_tag[btb_idx0] == btb_tag0);
  assign btb_hit1 = has_d1 & btb_v[btb_idx1] & (btb_tag[btb_idx1] == btb_tag1);
  // Slot prediction: RAS ret > BTB (counter for branches, target for
  // jumps) > JAL-always-taken > static BTFN. Younger slot ignored when the
  // older predicts taken (squashed).
  logic d0_pred_t, d1_pred_t;
  logic [63:0] d0_pred_tgt, d1_pred_tgt;
  always_comb begin
    d0_pred_t = 1'b0; d0_pred_tgt = '0;
    if (d0_jalr & is_link(d0_rs1) & ~is_link(d0_rd) & (ras_count != 4'd0)) begin
      d0_pred_t = 1'b1; d0_pred_tgt = ras_top; // return
    end else if ((d0_branch | d0_jalr) & btb_hit0) begin
      if (d0_branch & ~btb_ctr[btb_idx0][1]) begin
        d0_pred_t = 1'b0; // counter says not-taken
      end else begin
        d0_pred_t = 1'b1; d0_pred_tgt = btb_tgt[btb_idx0];
      end
    end else if (d0_jal) begin
      d0_pred_t = 1'b1; d0_pred_tgt = pc_d + imm; // unconditional, exact
    end else if (d0_branch & dc.imm[63] & ~dc.illegal & ~illegal_c_d & ~fault_d) begin
      d0_pred_t = 1'b1; d0_pred_tgt = pc_d + imm; // static BTFN
    end
  end
  always_comb begin
    d1_pred_t = 1'b0; d1_pred_tgt = '0;
    if (!d0_pred_t) begin
      if (d1_jalr & is_link(d1_rs1) & ~is_link(d1_rd) & (ras_count != 4'd0)) begin
        d1_pred_t = 1'b1; d1_pred_tgt = ras_top;
      end else if ((d1_branch | d1_jalr) & btb_hit1) begin
        if (d1_branch & ~btb_ctr[btb_idx1][1]) begin
          d1_pred_t = 1'b0;
        end else begin
          d1_pred_t = 1'b1; d1_pred_tgt = btb_tgt[btb_idx1];
        end
      end else if (d1_jal) begin
        d1_pred_t = 1'b1; d1_pred_tgt = pc_d1 + imm1;
      end else if (d1_branch & dc1.imm[63] & ~dc1.illegal & ~illegal_c_d1 & ~fault_d1) begin
        d1_pred_t = 1'b1; d1_pred_tgt = pc_d1 + imm1;
      end
    end
  end
  logic pred0, pred1, pred_any, pred_fire;
  logic [63:0] pred_target;
  assign pred0 = d0_pred_t;
  assign pred1 = d1_pred_t & ~d0_pred_t;
  assign pred_any = pred0 | pred1;
  assign pred_target = pred0 ? d0_pred_tgt : d1_pred_tgt;
  // Fire only when the frontend can act (no stall/fence/pending fault;
  // real redirects or traps override by priority in each consumer).
  // Firing implies D0 issues this cycle, so the D shift/refill stays
  // consistent. EX latches pred_fire (not raw pred0) so verify matches
  // what fetch actually did.
  assign pred_fire = pred_any & ~stall & ~vm_fence_active & ~fault_f_q;
  assign fetch_done    = fetch_res_valid & ~stall & ~vm_fence_active & ~pred_fire;
  // Fetch virtual address: the straddling second word is translated
  // independently (it can sit on another page).
  logic [63:0] fetch_va;
  logic        fetch_second;
  assign fetch_second = fetch_complete & ~fetch_hi_valid &
                        (fetch_pc_q[47:3] == pc_f[47:3]) &
                        (pc_f[2:1] == 2'b11);
  assign fetch_va = fetch_second ? ({pc_f[63:3], 3'b0} + 64'd8) : pc_f;
  // MMU translate (PIPT: caches see physical addresses only).
  logic        mmu_hit_f, mmu_miss_f, mmu_fault_f;
  logic [47:0] mmu_pa_f;
  logic [4:0]  mmu_cause_f;
  // fetch_req additionally waits on translation: miss holds for the walker,
  // fault takes the bubble path below (never issues a bad address).
  assign fetch_req     = valid_f & fetch_ready & ~stall & ~fetch_busy & ~fetch_res_valid &
                         mmu_hit_f;
  assign fetch_we      = 1'b0;
  assign fetch_addr    = mmu_pa_f;
  assign fetch_be      = 8'hFF;
  assign fetch_wdata   = '0;
  // Fetch translation-fault bubble: latched once per faulting pc_f, then
  // consumed into D like an instruction (pc_f frozen meanwhile). The trap
  // fires from EX; flush_all clears the latch on redirect/trap.
  logic        fault_f_q;
  logic [4:0]  fcause_q;
  logic [63:0] fva_q;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      valid_f        <= 1'b1;
      fetch_busy     <= 1'b0;
      fetch_complete <= 1'b0;
      fetch_word_q   <= '0;
      fetch_pc_q     <= '0;
      fetch_hi_q     <= '0;
      fetch_hi_valid <= 1'b0;
      fault_f_q      <= 1'b0;
      fcause_q       <= '0;
      fva_q          <= '0;
    end else if (flush_all) begin
      fetch_busy     <= 1'b0;
      fetch_complete <= 1'b0;
      fetch_hi_valid <= 1'b0;
      valid_f        <= 1'b1;
      fault_f_q      <= 1'b0;
    end else if (pred_fire) begin
      // Prediction redirected fetch: drop the stale buffered word (its pc
      // no longer matches) so the refill at the target is treated as a
      // fresh word, not a straddle continuation. Decode state is handled
      // in D (D0 issued, D1 squashed); EX/MEM/WB continue undisturbed.
      fetch_busy     <= 1'b0;
      fetch_complete <= 1'b0;
      fetch_hi_valid <= 1'b0;
      valid_f        <= 1'b1;
      fault_f_q      <= 1'b0;
    end else if (vm_fence_active) begin
      // Freeze the skid clear (see above): drop any buffered/in-flight
      // fetch so post-window fetches re-translate fresh. valid_d/pc_d and
      // the rest of the pipe are untouched: nothing is lost.
      fetch_busy     <= 1'b0;
      fetch_complete <= 1'b0;
      fetch_hi_valid <= 1'b0;
    end else begin
      // Grab a translation fault once per faulting pc (bubble path);
      // release it once the F->D stage consumes the bubble. A lingering
      // fault re-arms next cycle, but the first bubble already traps and
      // flushes, so duplicates never survive.
      if (!stall && !fault_f_q && mmu_fault_f) begin
        fault_f_q <= 1'b1;
        fcause_q  <= mmu_cause_f;
        fva_q     <= fetch_va;
      end else if (!stall && fault_f_q && !fetch_done) begin
        fault_f_q <= 1'b0;
      end
      // Latch the returned word on completion so it survives a stall.
      // The first ack fills the low word; if the instruction straddles
      // (32-bit at offset 6) a second ack fills the high word. Busy tracks
      // only the in-flight AXI transaction (set on issue, cleared on ack)
      // so the straddling second word can be issued right after the first
      // returns; complete/hi_valid hold the buffered result across stalls.
      if (fetch_ack & fetch_busy) begin
        fetch_busy <= 1'b0;
        if (!fetch_complete) begin
          fetch_word_q   <= fetch_rdata;
          // Word-aligned base: the bus returns the 8B word containing pc_f;
          // slot-1 offset math ((p1-base) mod 16) needs the aligned base.
          fetch_pc_q     <= {pc_f[63:3], 3'b0};
          fetch_complete <= 1'b1;
        end else begin
          fetch_hi_q     <= fetch_rdata;
          fetch_hi_valid <= 1'b1;
        end
      end else if (fetch_req & fetch_ready) begin
        // A new fetch is issued only when the master is idle and the fetch
        // wins arbitration.
        fetch_busy <= 1'b1;
      end
      // Consume: advance pc_f (done by the caller). The buffered word is
      // retained while it still covers the next pc, so back-to-back
      // instructions in one 8B word serve without bus traffic (8B/cycle
      // fetch). Advancing into the hi chunk promotes it to word; any
      // translation fault drops the buffer so the refill re-faults into
      // the existing bubble path (slot-1 bytes are always known-good).
      if (fetch_done) begin
        fetch_busy <= 1'b0;
        if (fault_f_q | mmu_fault_f) begin
          fetch_complete <= 1'b0;
          fetch_hi_valid <= 1'b0;
        end else if ((fetch_next_pc[47:3] != fetch_pc_q[47:3]) & fetch_hi_valid) begin
          // A hi ack landing this same cycle is fresher than hi_q.
          fetch_word_q   <= (fetch_ack & fetch_busy & fetch_complete) ?
                            fetch_rdata : fetch_hi_q;
          fetch_pc_q     <= fetch_pc_q + 64'd8;
          fetch_hi_valid <= 1'b0;
          fetch_complete <= 1'b1;
        end else if (fetch_next_pc[47:3] == fetch_pc_q[47:3]) begin
          // Still within the buffered word: keep serving it.
        end else begin
          fetch_complete <= 1'b0;
          fetch_hi_valid <= 1'b0;
        end
      end
    end
  end

  assign instr_f = instr_d_use;

  logic illegal_c_d;
  logic fault_d;
  logic [4:0]  fcause_d;
  logic [63:0] fva_d;
  // Dual-fetch slot 1 (younger): valid only when two parcels served together.
  // D0/D1 form a 2-deep in-order queue: issue consumes from the head (one
  // or two per cycle); a single issue shifts D1 to the head. Operands are
  // read combinationally at issue time (always fresh); D holds only
  // instr/pc so a waiting D1 can never go stale behind a retired producer.
  logic        has_d1;
  logic [63:0] pc_d1;
  logic [31:0] instr_d1;
  logic        is_c_d1, illegal_c_d1;
  logic        fault_d1;
  logic [4:0]  fcause_d1;
  logic [63:0] fva_d1;
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      valid_d <= 1'b0; pc_d <= '0; instr_d <= '0; is_c_d <= 1'b0; illegal_c_d <= 1'b0;
      fault_d <= 1'b0; fcause_d <= '0; fva_d <= '0;
      has_d1 <= 1'b0; pc_d1 <= '0; instr_d1 <= '0; is_c_d1 <= 1'b0; illegal_c_d1 <= 1'b0;
      fault_d1 <= 1'b0; fcause_d1 <= '0; fva_d1 <= '0;
    end else if (flush_all) begin
      valid_d <= 1'b0;
      fault_d <= 1'b0;
      has_d1 <= 1'b0;
      fault_d1 <= 1'b0;
    end else if (!stall) begin
      // Under !stall the head (D0) always issues, so overwriting D below
      // never loses an instruction: D0 retires into EX while D shifts.
      if (fetch_done) begin
        if (dualDD) begin
          // Both entries issued as a pair: refill head and tail from fetch.
          valid_d <= valid_f;
          pc_d    <= pc_f;
          is_c_d  <= fetch_is_c;
          instr_d <= instr_d_use;
          illegal_c_d <= illegal_d_use;
          fault_d <= 1'b0;
          has_d1  <= fetch_done1;
          pc_d1   <= fetch_pc1;
          is_c_d1 <= fetch_is_c1;
          instr_d1 <= instr1_d_use;
          illegal_c_d1 <= illegal1_d_use;
          fault_d1 <= 1'b0;
        end else if (has_d1) begin
          // D0 issued single: shift waiting D1 (with fault flags) to the
          // head, new parcel to the tail. (Dual serve is suppressed while
          // D1 waits, so fetch holds exactly one parcel.)
          valid_d <= 1'b1;
          pc_d    <= pc_d1;
          is_c_d  <= is_c_d1;
          instr_d <= instr_d1;
          illegal_c_d <= illegal_c_d1;
          fault_d <= fault_d1;
          fcause_d <= fcause_d1;
          fva_d   <= fva_d1;
          has_d1  <= 1'b1;
          pc_d1   <= pc_f;
          is_c_d1 <= fetch_is_c;
          instr_d1 <= instr_d_use;
          illegal_c_d1 <= illegal_d_use;
          fault_d1 <= 1'b0;
        end else begin
          // D0 issued single (or D was empty): refill from fetch.
          valid_d <= valid_f;
          pc_d    <= pc_f;
          is_c_d  <= fetch_is_c;
          instr_d <= instr_d_use;
          illegal_c_d <= illegal_d_use;
          fault_d <= 1'b0;
          has_d1  <= fetch_done1;
          pc_d1   <= fetch_pc1;
          is_c_d1 <= fetch_is_c1;
          instr_d1 <= instr1_d_use;
          illegal_c_d1 <= illegal1_d_use;
          fault_d1 <= 1'b0;
        end
      end else if (pred_fire) begin
        // Prediction redirected fetch (fetch consume suppressed above):
        // the predicting head issued single, so drain/shift with no fill.
        if (pred0) begin
          // Predicting D0 issued; squash younger D1.
          valid_d <= 1'b0;
          fault_d <= 1'b0;
          has_d1 <= 1'b0;
          fault_d1 <= 1'b0;
        end else begin
          // Predicting D1: D0 issued single; shift predictor to the head.
          valid_d <= 1'b1;
          pc_d    <= pc_d1;
          is_c_d  <= is_c_d1;
          instr_d <= instr_d1;
          illegal_c_d <= illegal_c_d1;
          fault_d <= fault_d1;
          fcause_d <= fcause_d1;
          fva_d   <= fva_d1;
          has_d1  <= 1'b0;
          fault_d1 <= 1'b0;
        end
      end else if (fault_f_q) begin
        // Translation-fault bubble (younger than any waiting D1). Both
        // entries issued under dualDD (bubble to head); else D0 issued
        // single: shift D1 (with fault flags) to the head, bubble to the
        // tail; with no waiter the bubble takes the head.
        // pc carries the faulting VA; instr is a benign NOP.
        if (dualDD) begin
          valid_d <= 1'b1;
          pc_d    <= fva_q;
          is_c_d  <= 1'b1;
          instr_d <= 32'h00000013;
          illegal_c_d <= 1'b0;
          fault_d <= 1'b1;
          fcause_d <= fcause_q;
          fva_d   <= fva_q;
          has_d1 <= 1'b0;
          fault_d1 <= 1'b0;
        end else if (has_d1) begin
          valid_d <= 1'b1;
          pc_d    <= pc_d1;
          is_c_d  <= is_c_d1;
          instr_d <= instr_d1;
          illegal_c_d <= illegal_c_d1;
          fault_d <= fault_d1;
          fcause_d <= fcause_d1;
          fva_d   <= fva_d1;
          has_d1  <= 1'b1;
          pc_d1   <= fva_q;
          is_c_d1 <= 1'b1;
          instr_d1 <= 32'h00000013;
          illegal_c_d1 <= 1'b0;
          fault_d1 <= 1'b1;
          fcause_d1 <= fcause_q;
          fva_d1   <= fva_q;
        end else begin
          valid_d <= 1'b1;
          pc_d    <= fva_q;
          is_c_d  <= 1'b1;
          instr_d <= 32'h00000013;
          illegal_c_d <= 1'b0;
          fault_d <= 1'b1;
          fcause_d <= fcause_q;
          fva_d   <= fva_q;
          has_d1 <= 1'b0;
          fault_d1 <= 1'b0;
        end
      end else begin
        // No fetch (miss/inflight): both issued under dualDD (drain), else
        // D0 issued single: shift any waiting D1 up.
        if (dualDD) begin
          valid_d <= 1'b0;
          fault_d <= 1'b0;
          has_d1 <= 1'b0;
          fault_d1 <= 1'b0;
        end else if (has_d1) begin
          valid_d <= 1'b1;
          pc_d    <= pc_d1;
          is_c_d  <= is_c_d1;
          instr_d <= instr_d1;
          illegal_c_d <= illegal_c_d1;
          fault_d <= fault_d1;
          fcause_d <= fcause_d1;
          fva_d   <= fva_d1;
          has_d1  <= 1'b0;
          fault_d1 <= 1'b0;
        end else begin
          valid_d <= 1'b0;
          fault_d <= 1'b0;
          has_d1 <= 1'b0;
          fault_d1 <= 1'b0;
        end
      end
    end
  end

  function automatic ctrl_t decode(logic [31:0] i);
    ctrl_t c;
    opcode_t op; logic [2:0] f3; logic [6:0] f7;
    c = '0;
    op = i[6:0]; f3 = i[14:12]; f7 = i[31:25];
    c.opcode = op; c.funct3 = f3; c.funct7 = f7;
    c.rd = i[11:7]; c.rs1 = i[19:15]; c.rs2 = i[24:20];
    c.valid = 1'b1;
    case (op)
      OP_LUI:    begin c.alu_op = ALU_LUI;   c.wb_sel = WB_INT; c.a_src = SRC_IMM_U; end
      OP_AUIPC:  begin c.alu_op = ALU_ADD;   c.wb_sel = WB_INT; c.a_src = SRC_PC;    end
      OP_JAL:    begin c.is_jal = 1'b1;      c.wb_sel = WB_INT; c.a_src = SRC_PC; end
      OP_JALR:   begin c.is_jalr = 1'b1;     c.wb_sel = WB_INT; c.alu_op = ALU_ADD; c.a_src = SRC_REG; end
      OP_BRANCH: begin c.is_branch = 1'b1;   end
      OP_LOAD:   begin c.lsu_op = LSU_LW;    c.wb_sel = WB_MEM;
                  case (f3)
                    3'b000: c.lsu_op = LSU_LB;
                    3'b001: c.lsu_op = LSU_LH;
                    3'b010: c.lsu_op = LSU_LW;
                    3'b011: c.lsu_op = LSU_LD;
                    3'b100: c.lsu_op = LSU_LBU;
                    3'b101: c.lsu_op = LSU_LHU;
                    3'b110: c.lsu_op = LSU_LWU;
                  endcase end
      OP_STORE:  begin c.wb_sel = WB_NONE;
                  case (f3)
                    3'b000: c.lsu_op = LSU_SB;
                    3'b001: c.lsu_op = LSU_SH;
                    3'b010: c.lsu_op = LSU_SW;
                    3'b011: c.lsu_op = LSU_SD;
                  endcase end
      OP_OPIMM:  begin c.wb_sel = WB_INT; c.a_src = SRC_REG; c.alu_op = ALU_ADD;
                  case (f3)
                    3'b000: c.alu_op = ALU_ADD;
                    3'b010: c.alu_op = ALU_SLT;
                    3'b011: c.alu_op = ALU_SLTU;
                    3'b100: c.alu_op = ALU_XOR;
                    3'b110: c.alu_op = ALU_OR;
                    3'b111: c.alu_op = ALU_AND;
                    3'b001: c.alu_op = ALU_SLL;
                    3'b101: c.alu_op = (f7[5]) ? ALU_SRA : ALU_SRL;
                  endcase end
      OP_OP:     begin c.wb_sel = WB_INT; c.a_src = SRC_REG;
                  if (f7 == 7'b0000001) begin
                    case (f3)
                      3'b000: c.alu_op = ALU_MUL;
                      3'b001: c.alu_op = ALU_MULH;
                      3'b010: c.alu_op = ALU_MULHSU;
                      3'b011: c.alu_op = ALU_MULHU;
                      3'b100: c.alu_op = ALU_DIV;
                      3'b101: c.alu_op = ALU_DIVU;
                      3'b110: c.alu_op = ALU_REM;
                      3'b111: c.alu_op = ALU_REMU;
                    endcase
                  end else begin
                    case (f3)
                      3'b000: c.alu_op = (f7[5]) ? ALU_SUB : ALU_ADD;
                      3'b001: c.alu_op = ALU_SLL;
                      3'b010: c.alu_op = ALU_SLT;
                      3'b011: c.alu_op = ALU_SLTU;
                      3'b100: c.alu_op = ALU_XOR;
                      3'b101: c.alu_op = (f7[5]) ? ALU_SRA : ALU_SRL;
                      3'b110: c.alu_op = ALU_OR;
                      3'b111: c.alu_op = ALU_AND;
                    endcase
                  end end
      OP_OPIMM32:begin c.wb_sel = WB_INT; c.a_src = SRC_REG;
                  case (f3)
                    3'b000: c.alu_op = ALU_ADDW;
                    3'b001: c.alu_op = ALU_SLLW;
                    3'b101: c.alu_op = (f7[5]) ? ALU_SRAW : ALU_SRLW;
                    default: c.alu_op = ALU_ADDW;
                  endcase end
      OP_OP32:   begin c.wb_sel = WB_INT; c.a_src = SRC_REG;
                  case (f3)
                    3'b000: c.alu_op = (f7[5]) ? ALU_SUBW : ALU_ADDW;
                    3'b001: c.alu_op = ALU_SLLW;
                    3'b101: c.alu_op = (f7[5]) ? ALU_SRAW : ALU_SRLW;
                    default: c.alu_op = ALU_ADDW;
                  endcase
                  if (f7 == 7'b0000001) begin
                    case (f3)
                      3'b000: c.alu_op = ALU_MULW;
                      3'b100: c.alu_op = ALU_DIVW;
                      3'b101: c.alu_op = ALU_DIVUW;
                      3'b110: c.alu_op = ALU_REMW;
                      3'b111: c.alu_op = ALU_REMUW;
                    endcase
                  end end
      OP_SYSTEM: begin c.wb_sel = WB_INT;
                  case (f3)
                    3'b000: begin
                      if (i[31:20] == 12'h000) c.is_ecall = 1'b1;
                      else if (i[31:20] == 12'h001) c.is_ebreak = 1'b1;
                      else if (i[31:20] == 12'h302) c.is_mret = 1'b1;
                      else if (i[31:20] == 12'h102) c.is_sret = 1'b1;
                      else if (i[31:20] == 12'h105) c.is_wfi = 1'b1;
                      // SFENCE.VMA rs1,rs2: funct7=0001001, rd must be x0.
                      else if ((i[31:25] == 7'b0001001) && (i[11:7] == 5'd0))
                        c.is_sfence = 1'b1;
                      // HFENCE.VVMA (0001011) / HFENCE.GVMA (0010111).
                      else if ((i[31:25] == 7'b0001011) && (i[11:7] == 5'd0))
                        c.is_hfence_vvma = 1'b1;
                      else if ((i[31:25] == 7'b0010111) && (i[11:7] == 5'd0))
                        c.is_hfence_gvma = 1'b1;
                    end
                    default: begin
                      // All CSR ops read; all may write. CSRRS/CSRRC only
                      // write when rs1!=0, enforced in the CSR unit. funct3[2]
                      // is the immediate bit (1 => rs1 field is a 5-bit zimm);
                      // the operand value is the same either way. csr_op encodes
                      // CSRRW=001/CSRRS=010/CSRRC=011 via funct3[1:0].
                      c.reads_csr = 1'b1; c.writes_csr = 1'b1;
                      c.csr_addr = i[31:20]; c.csr_op = f3[1:0];
                    end
                  endcase end
      OP_FENCE:  begin
                  if (f3 == 3'b001) c.fence_i = 1'b1;
                end
      OP_AMO:    begin
                  // funct3: 010=W, 011=D (else illegal); funct5 selects
                  // LR/SC vs AMO op; LR requires rs2==0. aq/rl ignored.
                  c.wb_sel = WB_MEM; c.a_src = SRC_REG;
                  c.amo_op = amo_op_e'(i[31:27]);
                  case (amo_op_e'(i[31:27]))
                    AMO_LR: begin
                      c.lsu_op = LSU_LR;
                      if ((f3 != 3'b010 && f3 != 3'b011) || i[24:20] != 5'd0)
                        c.illegal = 1'b1;
                    end
                    AMO_SC: begin
                      c.lsu_op = LSU_SC;
                      if (f3 != 3'b010 && f3 != 3'b011)
                        c.illegal = 1'b1;
                    end
                    AMO_ADD, AMO_SWAP, AMO_XOR, AMO_AND, AMO_OR,
                    AMO_MIN, AMO_MAX, AMO_MINU, AMO_MAXU: begin
                      c.lsu_op = LSU_AMO;
                      if (f3 != 3'b010 && f3 != 3'b011)
                        c.illegal = 1'b1;
                    end
                    default: begin
                      c.lsu_op = LSU_AMO;
                      c.illegal = 1'b1;
                    end
                  endcase end
      OP_FPLOAD: begin
                  // RVV shares 0000111: funct3 e8/e16/e32/e64 (000/101/110/
                  // 111) is vector (FP uses 010/011 only). Skeleton: vle8
                  // unit-stride unmasked only; wider EEW reserved for later.
                  if ((f3 == 3'b000 || f3 == 3'b101 || f3 == 3'b110 ||
                       f3 == 3'b111)) begin
                    c.wb_sel = WB_NONE;
                    c.alu_op = ALU_NONE;
                    if (f3 == 3'b000 && i[27:26] == 2'b00 && i[25] &&
                        i[24:20] == 5'd0) begin
                      c.is_vec_mem = 1'b1;   // vle8.v vd,(rs1)
                      c.vec_is_load = 1'b1;
                    end else begin
                      c.illegal = 1'b1;
                    end
                  end else begin
                    c.is_fp = 1'b1; c.wb_sel = WB_FP;
                    // FLW (funct3=2, 32-bit) / FLD (funct3=3, 64-bit).
                    c.lsu_op = (f3 == 3'b010) ? LSU_LW : LSU_LD;
                  end end
      OP_FPSTORE:begin
                  // RVV shares 0100111 the same way (FP uses 010/011 only).
                  if ((f3 == 3'b000 || f3 == 3'b101 || f3 == 3'b110 ||
                       f3 == 3'b111)) begin
                    c.wb_sel = WB_NONE;
                    c.alu_op = ALU_NONE;
                    if (f3 == 3'b000 && i[27:26] == 2'b00 && i[25] &&
                        i[24:20] == 5'd0) begin
                      c.is_vec_mem = 1'b1;   // vse8.v vs3,(rs1)
                      c.vec_is_load = 1'b0;
                    end else begin
                      c.illegal = 1'b1;
                    end
                  end else begin
                    c.is_fp = 1'b1; c.wb_sel = WB_NONE;
                    // FSW (funct3=2, 32-bit) / FSD (funct3=3, 64-bit).
                    c.lsu_op = (f3 == 3'b010) ? LSU_SW : LSU_SD;
                  end end
      OP_FPOP:   begin c.is_fp = 1'b1; {c.fp_fmt, c.fpu_op, c.wb_sel, c.fp_rm} = decode_fpu_op(i); end
      OP_V:      begin
                  // RVV OPCFG (funct3=111): vsetvli (bits[31:30]!=11, vtype in
                  // bits[31:20]) / vsetivli (bits[31:30]==11 marker, vtype in
                  // bits[29:20], AVL zimm in rs1 field). Supported vtype is
                  // e8m1/ta,ma only; anything else sets vill (vl=0, no trap).
                  // Remaining OP-V (vector ALU, later) is illegal for now.
                  // NOTE: OP-V is 1010111, distinct from OP-FP 1010011.
                  c.wb_sel = WB_NONE;
                  c.alu_op = ALU_NONE;
                  if (f3 == 3'b111 && i[31:30] == 2'b11) begin
                    c.is_vset = 1'b1; c.vset_ivli = 1'b1;
                    c.vtypei = {1'b0, i[29:20]};
                    c.vset_vill = (i[29:20] != VTYPEI_E8M1[9:0]);
                    c.wb_sel = WB_INT;
                  end else if (f3 == 3'b111) begin
                    c.is_vset = 1'b1; c.vset_ivli = 1'b0;
                    c.vtypei = i[31:20];
                    c.vset_vill = (i[31:20] != VTYPEI_E8M1);
                    c.wb_sel = WB_INT;
                  end else begin
                    c.illegal = 1'b1;
                  end end
      OP_FMADD, OP_FMSUB, OP_FNMSUB, OP_FNMADD: begin
                  c.is_fp = 1'b1; c.rs3 = i[31:27]; c.wb_sel = WB_FP;
                  // fmt lives in bits [26:25] (00=S, 01=D): double iff i[25].
                  c.fp_fmt[0] = i[25];
                  c.fp_rm = i[14:12];
                  case (i[6:0])
                    OP_FMADD:  c.fpu_op = FPU_FMADD;
                    OP_FMSUB:  c.fpu_op = FPU_FMSUB;
                    OP_FNMSUB: c.fpu_op = FPU_FNMSUB;
                    OP_FNMADD: c.fpu_op = FPU_FNMADD;
                    default:   c.fpu_op = FPU_NONE;
                  endcase end
      default:   c.illegal = 1'b1;
    endcase
    return c;
  endfunction

  // Decode the OP-FP (opcode 1010011) space. RISC-V encodes the operation in
  // funct7[6:1] and the precision (single/double) in funct7[0] for the
  // arithmetic/sign-injection/min-max/compare ops. Conversion and move ops
  // use the rs2 field to select the source/destination width. Returns a packed
  // triple {fp_fmt[3:0], fpu_op[5:0], wb_sel[1:0], fp_rm[2:0]}; fp_fmt[0] is
  // the double-precision flag used by the FPU, fp_fmt[1] flags integer-
  // destination ops (compare/class/f2i/mv.x) that write the integer regfile.
  function automatic logic [14:0] decode_fpu_op(logic [31:0] i);
    logic [2:0] f3; logic [6:0] f7; logic [4:0] rs2;
    logic [3:0] fmt;  fpu_op_e fop;  wb_sel_e wbs; logic [2:0] rm;
    fmt = '0; fop = FPU_NONE; wbs = WB_FP; rm = i[14:12];
    f3 = i[14:12]; f7 = i[31:25]; rs2 = i[24:20];
    fmt[0] = f7[0]; // single/double precision for arithmetic ops
    case (f7[6:1])
      // FADD/FSUB/FMUL/FDIV: funct7[6:1] = 000000/000010/000100/000110.
      6'b000000: fop = FPU_FADD;
      6'b000010: fop = FPU_FSUB;
      6'b000100: fop = FPU_FMUL;
      6'b000110: fop = FPU_FDIV;
      6'b010110: begin fop = FPU_FSQRT; fmt[0] = f7[0]; end // rs2 must be 0
      6'b001000: begin // FSGNJ/N/X, selected by funct3
                  case (f3)
                    3'b000: fop = FPU_FSGNJ;
                    3'b001: fop = FPU_FSGNJN;
                    3'b010: fop = FPU_FSGNJX;
                    default: fop = FPU_NONE;
                  endcase end
      6'b001010: begin // FMIN/FMAX, selected by funct3
                  case (f3)
                    3'b000: fop = FPU_FMIN;
                    3'b001: fop = FPU_FMAX;
                    default: fop = FPU_NONE;
                  endcase end
      6'b101000: begin // FLE/FLT/FEQ -> integer destination
                  fmt[1] = 1'b1; wbs = WB_INT;
                  case (f3)
                    3'b000: fop = FPU_FLE;
                    3'b001: fop = FPU_FLT;
                    3'b010: fop = FPU_FEQ;
                    default: fop = FPU_NONE;
                  endcase end
      6'b111000: begin
                  // FCLASS (funct3=001) and FMV.X.W/D (funct3=000) share
                  // funct7[6:1]=111000 with rs2=0; funct3 selects the op.
                  if (rs2 == 5'd0 && f3 == 3'b001) begin // FCLASS -> int dest
                    fmt[1] = 1'b1; wbs = WB_INT; fop = FPU_CLASS; fmt[0] = f7[0];
                  end else if (rs2 == 5'd0 && f3 == 3'b000) begin // FMV.X.W/D
                    fmt[1] = 1'b1; wbs = WB_INT; fop = FPU_MV_F2X; fmt[0] = f7[0];
                  end else begin
                    fop = FPU_NONE;
                  end end
      6'b111100: begin // FMV.W.X/D.X -> fp destination, int source
                  if (f3 == 3'b000) begin fop = FPU_MV_X2F; fmt[0] = f7[0]; end
                  else fop = FPU_NONE; end
      6'b110100: begin // FCVT.S.W/D.W (int->fp): funct7=1101000; fp dest
                  fmt[0] = f7[0]; // 0=>fcvt.s.w, 1=>fcvt.d.w (double dest)
                  fmt[2] = rs2[0]; // is_unsigned
                  fmt[3] = rs2[1]; // is_word (1=64-bit, 0=32-bit)
                  case (rs2)
                    5'd0, 5'd2: fop = FPU_I2F; // w / l (signed)
                    5'd1, 5'd3: fop = FPU_I2F; // wu / lu (unsigned)
                    default: fop = FPU_NONE;
                  endcase end
      6'b110000: begin // FCVT.W/L.S (fp->int): funct7=1100000; int dest
                  fmt[0] = f7[0]; fmt[1] = 1'b1; wbs = WB_INT;
                  fmt[2] = rs2[0]; // is_unsigned
                  fmt[3] = rs2[1]; // is_word
                  case (rs2)
                    5'd0, 5'd2: fop = FPU_F2I; // w / l (signed)
                    5'd1, 5'd3: fop = FPU_F2I; // wu / lu (unsigned)
                    default: fop = FPU_NONE;
                  endcase end
      // FCVT.S.D (f7=0100000, double src) and FCVT.D.S (f7=0100001,
      // single src) share funct7[6:1]; f7[0] selects the direction.
      6'b010000: begin
                  if (f7[0]) begin // FCVT.D.S: double dest from single src
                    fmt[0] = 1'b1; fop = FPU_F2D;
                  end else begin    // FCVT.S.D: single dest from double src
                    fmt[0] = 1'b0; fop = FPU_D2F;
                  end end
      default: fop = FPU_NONE;
    endcase
    return {fmt, fop, wbs, rm};
  endfunction

  function automatic logic [63:0] gen_imm(logic [31:0] i);
    opcode_t op = i[6:0];
    logic [2:0] f3 = i[14:12];
    logic [63:0] r;
    case (op)
      OP_LUI, OP_AUIPC: r = {{32{i[31]}}, i[31:12], 12'b0};
      OP_JAL:  r = {{44{i[31]}}, i[19:12], i[20], i[30:21], 1'b0};
      OP_JALR: r = {{52{i[31]}}, i[31:20]};
      // B-type: {imm12=i[31], imm11=i[7], imm10:5=i[30:25],
      // imm4:1=i[11:8], 0} = 13 bits + 51 sign bits = 64. (Was 63 bits:
      // the explicit imm12 copy was missing, so bit 63 read 0 and every
      // backward branch jumped wild. Forward-only suites never caught it.)
      OP_BRANCH:r = {{51{i[31]}}, i[31], i[7], i[30:25], i[11:8], 1'b0};
      OP_LOAD, OP_SYSTEM, OP_FENCE:
               r = {{52{i[31]}}, i[31:20]};
      // Vector ld/st have no immediate (EA = x[rs1]); the funct6/vm/lumop
      // bits alias the I-imm field and must not leak into the address.
      // OP_V (vset) carries no memory address either.
      OP_FPLOAD:
               r = ((f3 == 3'b000 || f3 == 3'b101 || f3 == 3'b110 ||
                     f3 == 3'b111)) ? 64'd0 : {{52{i[31]}}, i[31:20]};
      OP_OPIMM:
               // Shift-immediate (SLLI/SRLI/SRAI) uses a 6-bit shamt in
               // i[25:20]; other OP-IMM use the sign-extended I-type imm.
               if (f3 == 3'b001 || f3 == 3'b101)
                 r = {58'b0, i[25:20]};
               else
                 r = {{52{i[31]}}, i[31:20]};
      OP_OPIMM32:
               // Shift-immediate-32 (SLLIW/SRLIW/SRAIW) uses a 5-bit shamt
               // in i[24:20]; other OP-IMM-32 use the sign-extended I-type imm.
               if (f3 == 3'b001 || f3 == 3'b101)
                 r = {59'b0, i[24:20]};
               else
                 r = {{52{i[31]}}, i[31:20]};
      OP_STORE:
               r = {{52{i[31]}}, i[31:25], i[11:7]};
      OP_FPSTORE:
               r = ((f3 == 3'b000 || f3 == 3'b101 || f3 == 3'b110 ||
                     f3 == 3'b111)) ? 64'd0 : {{52{i[31]}}, i[31:25], i[11:7]};
      OP_V:    r = 64'd0;
      default: r = '0;
    endcase
    return r;
  endfunction

  always_comb begin
    if (valid_d) begin
      dc = decode(instr_d);
      imm = gen_imm(instr_d);
    end else begin
      dc = '0; imm = '0;
    end
    if (has_d1) begin
      dc1 = decode(instr_d1);
      imm1 = gen_imm(instr_d1);
    end else begin
      dc1 = '0; imm1 = '0;
    end
  end

  assign rs1_d = dc.rs1;
  assign rs2_d = dc.rs2;
  assign rs3_d = dc.rs3;
  // Dual-fetch slot 1 register specifiers + read data (extra ports).
  logic [63:0] rdata3_d, rdata4_d, fp_rdata4, fp_rdata5, fp_rdata6;
  logic [4:0]  rs1_d1, rs2_d1, rs3_d1;
  assign rs1_d1 = dc1.rs1;
  assign rs2_d1 = dc1.rs2;
  assign rs3_d1 = dc1.rs3;
  // Slot 1 WB->ID bypass (dual retire: lane B younger wins).
  logic [63:0] rf1_d1, rf2_d1, fp1_d1, fp2_d1, fp3_d1;
  assign rf1_d1 = (wb_int_we_b & (rd_w_b == rs1_d1)) ? wb_data_w_b :
                  (wb_int_we & (rd_w == rs1_d1)) ? wb_data_w : rdata3_d;
  assign rf2_d1 = (wb_int_we_b & (rd_w_b == rs2_d1)) ? wb_data_w_b :
                  (wb_int_we & (rd_w == rs2_d1)) ? wb_data_w : rdata4_d;
  assign fp1_d1 = (wb_fp_we_byp & (rd_w_fp == rs1_d1)) ? wb_data_w : fp_rdata4;
  assign fp2_d1 = (wb_fp_we_byp & (rd_w_fp == rs2_d1)) ? wb_data_w : fp_rdata5;
  assign fp3_d1 = (wb_fp_we_byp & (rd_w_fp == rs3_d1)) ? wb_data_w : fp_rdata6;

  regfile_int u_rfint (
    .clk(clk), .rst_n(rst_n),
    .waddr(rd_w), .we(reg_we_w), .wdata(wb_data_w),
    .waddr_b(rd_w_b), .we_b(reg_we_w_b), .wdata_b(wb_data_w_b),
    .raddr1(rs1_d), .raddr2(rs2_d),
    .rdata1(rdata1_d), .rdata2(rdata2_d),
    .raddr3(rs1_d1), .raddr4(rs2_d1),
    .rdata3(rdata3_d), .rdata4(rdata4_d)
  );

  // WB->ID bypass: the regfile is written at the WB posedge while the ID-stage
  // read is combinational, so an instruction in ID reading a register written
  // by the instruction currently in WB would otherwise capture the stale
  // (pre-write) value. This is the load-use path for the multi-cycle memory:
  // a load retires into WB one cycle before its consumer leaves ID, so the
  // consumer must see the WB write data directly here.
  logic [63:0] rf_rdata1, rf_rdata2;
  logic        wb_int_we, wb_int_we_b;
  assign wb_int_we = reg_we_w & (rd_w != 5'd0);
  assign wb_int_we_b = reg_we_w_b & (rd_w_b != 5'd0);
  // Dual retire: lane B is younger, so it wins the bypass on a WAW match.
  assign rf_rdata1 = (wb_int_we_b & (rd_w_b == rs1_d)) ? wb_data_w_b :
                     (wb_int_we & (rd_w == rs1_d)) ? wb_data_w : rdata1_d;
  assign rf_rdata2 = (wb_int_we_b & (rd_w_b == rs2_d)) ? wb_data_w_b :
                     (wb_int_we & (rd_w == rs2_d)) ? wb_data_w : rdata2_d;

  regfile_fp u_rffp (
    .clk(clk), .rst_n(rst_n),
    .waddr(rd_w_fp), .we(fp_we_w), .wdata(wb_data_w),
    .raddr1(rs1_d), .raddr2(rs2_d), .raddr3(rs3_d),
    .rdata1(fp_rdata1), .rdata2(fp_rdata2), .rdata3(fp_rdata3),
    .raddr4(rs1_d1), .raddr5(rs2_d1), .raddr6(rs3_d1),
    .rdata4(fp_rdata4), .rdata5(fp_rdata5), .rdata6(fp_rdata6)
  );

  // FP WB->ID bypass: same race as the integer regfile (write at the WB
  // posedge vs combinational read in ID). A load or FP op retiring into WB
  // one cycle before its FP consumer leaves ID must forward its WB value.
  logic [63:0] fp_rf1, fp_rf2, fp_rf3;
  logic        wb_fp_we_byp;
  assign wb_fp_we_byp = fp_we_w;
  assign fp_rf1 = (wb_fp_we_byp & (rd_w_fp == rs1_d)) ? wb_data_w : fp_rdata1;
  assign fp_rf2 = (wb_fp_we_byp & (rd_w_fp == rs2_d)) ? wb_data_w : fp_rdata2;
  assign fp_rf3 = (wb_fp_we_byp & (rd_w_fp == rs3_d)) ? wb_data_w : fp_rdata3;

  forwarding_unit u_fwd (
    .id_rs1(rs1_d), .id_rs2(rs2_d),
    .ex_rs1(ex_pkt.ctrl.rs1), .ex_rs2(ex_pkt.ctrl.rs2),
    .mem_rd(rd_m), .mem_reg_we(reg_we_m), .mem_is_load(1'b0),
    .wb_rd(rd_w), .wb_reg_we(reg_we_w),
    .wb_rd_fp(rd_w_fp), .wb_fp_we(fp_we_w),
    .fwd_a(fwd_a), .fwd_b(fwd_b)
  );

  logic load_use_hazard_csr;
  logic lsu_busy;
  assign load_use_hazard_csr = 1'b0;

  // Dynamic rounding (rm=111/DYN): the effective rounding mode comes from
  // fcsr.frm. A DYN op in ID must wait until any older CSR write to FRM/FCSR
  // has retired to WB (fcsr update), otherwise it would sample a stale frm.
  // Later CSR writes cannot overtake: the pipeline stalls on fpu_busy while
  // the DYN op is in EX, so frm is stable for the whole in-flight op.
  function automatic logic writes_frm(input ctrl_t c);
    return c.writes_csr & (c.csr_addr == CSR_FRM || c.csr_addr == CSR_FCSR);
  endfunction
  logic id_needs_frm, frm_pending;
  // Dual-issue pairing: D0+D1 pair when both simple-ALU (the unit excludes
  // faults, CSR/mem/control). Otherwise the head issues single and D1
  // shifts up. D1 waiting suppresses the second fetch parcel (shift needs
  // exactly one free tail slot).
  logic dual_suppress;
  issue_unit u_pairDD (
    .c0(dc), .c1(dc1),
    .valid0(valid_d), .valid1(has_d1),
    .fault0(fault_d), .fault1(fault_d1),
    .can_dual(dualDD)
  );
  assign dual_suppress = has_d1 & ~dualDD;
  assign issue2 = dualDD;
  // Oldest unissued instruction (lane A candidate) + younger lane B candidate.
  logic       chk0_valid, chk1_valid;
  ctrl_t      chk0_ctrl, chk1_ctrl;
  assign chk0_valid = valid_d;
  assign chk0_ctrl  = dc;
  assign chk1_valid = issue2;
  assign chk1_ctrl  = dc1;
  // A DYN (rm=dyn) op stalls at the issue position until older FRM/FCSR
  // writes drain out of EX/MEM (the CSR updates when the write reaches WB,
  // so releasing then reads the new mode). Backend keeps draining (like a
  // load-use hold); freezing it too would livelock on the stale WB term.
  assign id_needs_frm = chk0_valid & (chk0_ctrl.fpu_op != FPU_NONE) &
                        (chk0_ctrl.fp_rm == RM_DYN);
  assign frm_pending = (ex_pkt.valid & writes_frm(ex_pkt.ctrl)) |
                       (mem_pkt.valid & writes_frm(mem_pkt.ctrl));
  assign frm_stall = id_needs_frm & frm_pending;

  hazard_unit u_haz (
    .id_c0(chk0_ctrl), .id_c0_valid(chk0_valid),
    .id_c1(chk1_ctrl), .id_c1_valid(chk1_valid),
    .ex_rd(rd_x), .ex_mem_read(mem_is_load_x),
    .ex_fp_load(ex_fp_load_x),
    .ex_mul_busy(mdu_busy), .ex_fpu_busy(fpu_busy),
    .mem_lsu_busy(lsu_busy),
    .branch_taken(redirect), .trap(trap),
    .is_csr_op(chk0_ctrl.writes_csr), .csr_hazard(load_use_hazard_csr),
    .stall(stall_raw), .load_use(load_use_raw),
    .flush_id(flush_id_raw), .flush_ex(flush_ex)
  );
  // A data-TLB miss stalls the whole pipe for the walker (fetch only
  // waits for its own translation at issue; it needs no stall term).
  logic dtlb_miss;
  assign dtlb_miss = mmu_miss_d;
  // xret (mret/sret) reads mepc/sepc+mstatus in EX, so it must wait in D
  // until older CSR writes drain out of EX/MEM/WB (the CSR updates when
  // the write retires; resolving alongside would read the stale value).
  // Frontend-only hold like load-use/frm (backend drains to resolve).
  logic xret_csr_wait;
  assign xret_csr_wait = chk0_valid &
                         (chk0_ctrl.is_mret | chk0_ctrl.is_sret) &
                         ((ex_pkt.valid & ex_pkt.ctrl.writes_csr) |
                          (mem_pkt.valid & mem_pkt.ctrl.writes_csr) |
                          (wb_pkt.valid & wb_pkt.ctrl.writes_csr));
  // CSR read-after-write: a csrr samples the CSR into its WB packet the
  // same edge an older in-flight csrw applies, so it must wait in D until
  // older CSR writes drain. (Dense dual-fetch delivers the reader
  // back-to-back; single-issue fetch gaps used to mask this.)
  // Frontend-only hold like load-use/frm (backend drains to resolve).
  logic csr_raw_wait;
  assign csr_raw_wait = chk0_valid & chk0_ctrl.reads_csr &
                        ((ex_pkt.valid & ex_pkt.ctrl.writes_csr) |
                         (mem_pkt.valid & mem_pkt.ctrl.writes_csr) |
                         (wb_pkt.valid & wb_pkt.ctrl.writes_csr));
  // RVV: a vector ld/st samples vl/vstart in MEM, so it waits in D until
  // any older vset drains out of EX/MEM/WB (vl/vtype commit at WB retire).
  // Frontend-only hold like xret_csr_wait (backend drains to resolve).
  logic vec_vset_wait;
  assign vec_vset_wait = chk0_valid & chk0_ctrl.is_vec_mem &
                         ((ex_pkt.valid & ex_pkt.ctrl.is_vset) |
                          (mem_pkt.valid & mem_pkt.ctrl.is_vset) |
                          (wb_pkt.valid & wb_pkt.ctrl.is_vset));
  // RVV: a CSR read of vl/vtype/vstart must wait in D until any older
  // vset drains out of EX/MEM/WB (vl/vtype/vstart commit at WB retire;
  // the same-cycle CSR-write bypass covers scalar writes only, not vset).
  // Frontend-only hold like csr_raw_wait (backend drains to resolve).
  logic vec_csr_wait;
  assign vec_csr_wait = chk0_valid & chk0_ctrl.reads_csr &
                        ((chk0_ctrl.csr_addr == CSR_VSTART) |
                         (chk0_ctrl.csr_addr == CSR_VL) |
                         (chk0_ctrl.csr_addr == CSR_VTYPE)) &
                        ((ex_pkt.valid & ex_pkt.ctrl.is_vset) |
                         (mem_pkt.valid & mem_pkt.ctrl.is_vset) |
                         (wb_pkt.valid & wb_pkt.ctrl.is_vset));
  // RVV: while the VLSU sequences elements the whole backend holds (like
  // dtlb_miss); the fault cycle holds too so the faulting op never
  // advances to WB (the trap flush clears MEM instead).
  logic vec_mem_hold;
  assign vec_mem_hold = vec_mem_active & ~vlsu_done;
  assign stall = stall_raw | frm_stall | xret_csr_wait | csr_raw_wait |
                 vec_vset_wait | vec_csr_wait | vec_mem_hold |
                 drain_busy_i | dtlb_miss;
  // Backend drain gate: everything except a load-use / frm hold lets
  // EX/MEM/WB advance. Those holds freeze only the frontend (fetch/D/issue)
  // so the older instruction drains and the hazard resolves; freezing the
  // backend too would livelock (the waiter could never leave while its
  // waiter waits). Dense dual-fetch reaches these states deterministically.
  logic load_use_raw, backend_stall;
  assign backend_stall = (stall_raw & ~load_use_raw) |
                         vec_mem_hold |
                         drain_busy_i | dtlb_miss;
  `ifdef CORE_DEBUG
  // Event-driven fetch tracing (scheduler-safe: fires only on handshakes).
  always @(posedge clk) begin
    if (fetch_req & fetch_ready)
      $display("[core %0t] ISSUE va=%h pa=%h busy=%b hit=%b fault=%b",
               $time, fetch_va, fetch_addr, fetch_busy, mmu_hit_f, mmu_fault_f);
    if (fetch_ack & fetch_busy)
      $display("[core %0t] ACK data=%h complete=%b hi=%b",
               $time, fetch_rdata, fetch_complete, fetch_hi_valid);
    if (valid_f && !stall && !fetch_busy && !fetch_res_valid && !mmu_hit_f)
      $display("[core %0t] WAIT-HIT va=%h fault=%b miss=%b satp=%h priv=%b",
               $time, fetch_va, mmu_fault_f, mmu_miss_f,
               csr_satp, priv);
  end
  `endif

  logic flush_redirect;
  assign flush_redirect = redirect | trap;
  // Fence window: from a FENCE.I/SFENCE/SATP retire until the L1D drain
  // sweep ends. During it: no new fetch consume, no new data issue, and
  // the fetch skid is kept clear (in-flight L1I acks land on busy=0 and
  // are ignored). Retirement itself is untouched, so nothing is lost or
  // duplicated -- the window simply delays. Covers through drain_busy so
  // there is no gap between retire-edge and sweep-start/end.
  logic vm_fence_active;
  assign vm_fence_active = fence_i_o | sfence_o | hfence_vvma_o | hfence_gvma_o |
                           satp_we_o | vsatp_we_o | hgatp_we_o | drain_busy_i;
  // xret redirects like a taken branch: squash F/D and reload pc from
  // epc deterministically (no next_pc race), while the insn itself flows
  // on to retire its CSR effects at WB.
  assign flush_id = flush_id_raw | (ex_pkt.valid & is_xret);
  assign flush_all = flush_id | flush_ex;
  logic flush_all_no_refetch;
  assign flush_all_no_refetch = flush_id_raw | flush_ex;

  // Decode-stage entries, built combinationally (issue-time operand
  // values, always fresh from the regfile + WB bypass).
  always_comb begin
    d_entry = '0;
    d_entry.valid = valid_d;
    d_entry.pc    = pc_d;
    d_entry.instr = instr_d;
    d_entry.ctrl  = dc;
    // Fold decompressor-illegal into the control illegal bit so the
    // EX-stage trap logic catches reserved RVC encodings. The
    // decompressor already substitutes a NOP payload, so no register
    // or memory side-effect can occur before the trap flushes.
    d_entry.ctrl.illegal = dc.illegal | illegal_c_d;
    d_entry.is_c = is_c_d;
    d_entry.illegal_c = illegal_c_d;
    d_entry.fault_f = fault_d;
    d_entry.fcause = fcause_d;
    d_entry.fva = fva_d;
    d_entry.rs1   = rf_rdata1;
    d_entry.rs2   = rf_rdata2;
    // FP operands are latched here (with WB->ID bypass already applied)
    // so the multi-cycle FPU holds stable inputs for its whole run.
    d_entry.fa    = fp_rf1;
    d_entry.fb    = fp_rf2;
    d_entry.fc    = fp_rf3;
    d_entry.imm   = imm;
    // Latch this head's prediction outcome (lane B never holds a branch/
    // jump). pred_fire (not raw pred0): verify must match what fetch did.
    d_entry.pred_taken = pred0 & pred_fire;
    d_entry.pred_target = pred_target;
  end

  // Slot 1 entry (younger), fault flags included like the head.
  always_comb begin
    d_entry1 = '0;
    d_entry1.valid = has_d1;
    d_entry1.pc    = pc_d1;
    d_entry1.instr = instr_d1;
    d_entry1.ctrl  = dc1;
    d_entry1.ctrl.illegal = dc1.illegal | illegal_c_d1;
    d_entry1.is_c = is_c_d1;
    d_entry1.illegal_c = illegal_c_d1;
    d_entry1.fault_f = fault_d1;
    d_entry1.fcause = fcause_d1;
    d_entry1.fva = fva_d1;
    d_entry1.rs1   = rf1_d1;
    d_entry1.rs2   = rf2_d1;
    d_entry1.fa    = fp1_d1;
    d_entry1.fb    = fp2_d1;
    d_entry1.fc    = fp3_d1;
    d_entry1.imm   = imm1;
  end

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      ex_pkt <= '0; ex_pkt_b <= '0;
    end else if (trap) begin
      ex_pkt <= '0; ex_pkt_b <= '0;
    end else if (!backend_stall) begin
      // Any redirect (branch/jump/xret/trap) bubbles EX: the redirecting
      // instruction itself already flowed EX->MEM this same edge (MEM takes
      // the pre-edge EX packet), so it still retires (xret CSR effects
      // happen at WB) while younger wrong-path work never issues. (Issuing
      // D here on xret used to be harmless because single-fetch timing left
      // D empty; dual-fill routinely holds the next sequential.)
      if (flush_redirect) begin
        ex_pkt <= '0; ex_pkt_b <= '0;
      end else if (stall) begin
        // Frontend-only hold (load-use / frm / xret-CSR): the backend
        // drains below while Decode waits. (stall with a free backend
        // implies one of those holds: all backend terms are clear.)
        ex_pkt <= '0; ex_pkt_b <= '0;
      end else if (issue2) begin // D0+D1 pair
        ex_pkt <= d_entry; ex_pkt_b <= d_entry1;
      end else if (valid_d) begin // single from head
        ex_pkt <= d_entry; ex_pkt_b <= '0;
      end else begin
        ex_pkt <= '0; ex_pkt_b <= '0;
      end
    end
  end

  assign rs1_x = ex_pkt.rs1;
  assign rs2_x = ex_pkt.rs2;
  assign rd_x = ex_pkt.ctrl.rd;

  // Forwarding source from the MEM stage: a load's result is its read data
  // (latched in load_data_q once the AXI read completes), a CSR read's
  // result is the CSR read port (the ALU result is meaningless for CSR ops
  // and would corrupt the consumer -- dense dual-fetch hits this window
  // deterministically); any other instruction forwards its ALU/MDU/FPU
  // result. (csr_raw_wait guarantees no older CSR write is still in flight
  // when a CSR read sits in MEM, so csr_rdata is exact here.)
  logic [63:0] mem_fwd_data;
  assign mem_fwd_data = mem_pkt.is_load ? mem_rdata_aligned :
                        (mem_pkt.ctrl.reads_csr ? csr_rdata : mem_alu_y);
  // FP forwarding from MEM: an FLW must forward its NaN-boxed single value;
  // an FP compute forwards the FPU result (alu_res).
  logic [63:0] fp_mem_fwd_data;
  assign fp_mem_fwd_data =
      (mem_pkt.ctrl.opcode == OP_FPLOAD) && (mem_pkt.ctrl.funct3 == 3'b010)
        ? {32'hFFFFFFFF, mem_rdata_aligned[31:0]}
        : mem_fwd_data;

  // FP forwarding: an FP-producing instruction in MEM or WB supplies its
  // result to an FP op reading the same FP register in EX. FP loads forward
  // their read data; FP computes forward their alu_res (the FPU result). The
  // integer fwd_a/fwd_b cannot be reused because they key on the integer
  // write-enable (reg_we), not fp_we.
  logic [63:0] fp_fwd_a, fp_fwd_b, fp_fwd_c;
  logic        fp_fwd_a_mem, fp_fwd_a_wb, fp_fwd_b_mem, fp_fwd_b_wb;
  logic        fp_fwd_c_mem, fp_fwd_c_wb;
  assign fp_fwd_a_mem = mem_pkt.valid & fp_we_m &
                        (rd_m == ex_pkt.ctrl.rs1);
  assign fp_fwd_a_wb  = fp_we_w &
                        (rd_w_fp == ex_pkt.ctrl.rs1);
  assign fp_fwd_b_mem = mem_pkt.valid & fp_we_m &
                        (rd_m == ex_pkt.ctrl.rs2);
  assign fp_fwd_b_wb  = fp_we_w &
                        (rd_w_fp == ex_pkt.ctrl.rs2);
  assign fp_fwd_c_mem = mem_pkt.valid & fp_we_m &
                        (rd_m == ex_pkt.ctrl.rs3);
  assign fp_fwd_c_wb  = fp_we_w &
                        (rd_w_fp == ex_pkt.ctrl.rs3);
  assign fp_fwd_a = fp_fwd_a_mem ? fp_mem_fwd_data :
                    fp_fwd_a_wb  ? wb_data_w : ex_pkt.fa;
  assign fp_fwd_b = fp_fwd_b_mem ? fp_mem_fwd_data :
                    fp_fwd_b_wb  ? wb_data_w : ex_pkt.fb;
  assign fp_fwd_c = fp_fwd_c_mem ? fp_mem_fwd_data :
                    fp_fwd_c_wb  ? wb_data_w : ex_pkt.fc;

  // Dual-issue younger-side forwarding sources: MEM/WB lane B entries are
  // younger than their lane A counterparts, so they win on a WAW match.
  logic mem_b_hit_a, mem_b_hit_b, wb_b_hit_a, wb_b_hit_b;
  assign mem_b_hit_a = mem_pkt.b_valid & mem_pkt.b_we &
                       (mem_pkt.b_rd == ex_pkt.ctrl.rs1);
  assign mem_b_hit_b = mem_pkt.b_valid & mem_pkt.b_we &
                       (mem_pkt.b_rd == ex_pkt.ctrl.rs2);
  assign wb_b_hit_a = wb_pkt.b_valid & wb_pkt.b_we &
                      (wb_pkt.b_rd == ex_pkt.ctrl.rs1);
  assign wb_b_hit_b = wb_pkt.b_valid & wb_pkt.b_we &
                      (wb_pkt.b_rd == ex_pkt.ctrl.rs2);

  always_comb begin
    if (mem_b_hit_a) rs1_fwd = mem_pkt.b_alu_res;
    else case (fwd_a)
      2'd1: rs1_fwd = mem_fwd_data;
      2'd2: rs1_fwd = wb_b_hit_a ? wb_pkt.b_data : wb_data_w;
      default: rs1_fwd = wb_b_hit_a ? wb_pkt.b_data : ex_pkt.rs1;
    endcase
    if (mem_b_hit_b) rs2_fwd = mem_pkt.b_alu_res;
    else case (fwd_b)
      2'd1: rs2_fwd = mem_fwd_data;
      2'd2: rs2_fwd = wb_b_hit_b ? wb_pkt.b_data : wb_data_w;
      default: rs2_fwd = wb_b_hit_b ? wb_pkt.b_data : ex_pkt.rs2;
    endcase
  end

  always_comb begin
    case (ex_pkt.ctrl.a_src)
      SRC_IMM_I, SRC_IMM_S, SRC_IMM_B, SRC_IMM_U, SRC_IMM_J: alu_a = ex_pkt.imm;
      SRC_PC: alu_a = ex_pkt.pc;
      default: alu_a = rs1_fwd;
    endcase
    if (ex_pkt.ctrl.is_jal) begin
      alu_a = ex_pkt.pc;
      alu_b = ex_pkt.imm;
    end else if (ex_pkt.ctrl.is_jalr) begin
      alu_a = rs1_fwd;
      alu_b = ex_pkt.imm;
    end else if (ex_pkt.ctrl.is_branch) begin
      alu_a = rs1_fwd;
      alu_b = rs2_fwd;
    end else begin
      alu_b = (ex_pkt.ctrl.use_imm_b) ? ex_pkt.imm :
             (ex_pkt.ctrl.a_src == SRC_REG) ? rs2_fwd : ex_pkt.imm;
      if (ex_pkt.ctrl.opcode == OP_OPIMM | ex_pkt.ctrl.opcode == OP_OPIMM32 |
          ex_pkt.ctrl.opcode == OP_LOAD | ex_pkt.ctrl.opcode == OP_FPLOAD |
          ex_pkt.ctrl.opcode == OP_STORE | ex_pkt.ctrl.opcode == OP_FPSTORE)
        alu_b = ex_pkt.imm;
    end
  end

  alu u_alu (.op(ex_pkt.ctrl.alu_op), .a(alu_a), .b(alu_b), .y(alu_y));

  // Dual-issue lane B: second integer ALU for a paired simple-ALU op.
  // Operand forwarding is youngest-first: same-cycle lane A result (a pair
  // implies lane A is simple-ALU, so ex_result is its ALU output) > MEM
  // lane B > MEM lane A > WB lane B > WB lane A > latched value.
  logic [63:0] rs1_b_fwd, rs2_b_fwd, alu_a_b, alu_b_b, alu_y_b, ex_result_b;
  logic        intra_b_a, intra_b_b;
  logic        memb_b_a, memb_b_b, mema_b_a, mema_b_b;
  logic        wbb_b_a, wbb_b_b, wba_b_a, wba_b_b;
  // Intra-pair forward carries lane A's same-cycle EX result: valid only
  // when lane A writes the integer file. An FP-to-FP lane A shares only
  // the register NUMBER with lane B's integer source -- forwarding it
  // would corrupt lane B (its operands come from MEM/WB/regfile instead;
  // the result is sampled post-done at the coupled advance edge).
  logic        laneA_writes_int;
  assign laneA_writes_int = ex_pkt.valid &
      (is_simple_alu_op(ex_pkt.ctrl) | is_mdu_op(ex_pkt.ctrl.alu_op) |
       ((ex_pkt.ctrl.fpu_op != FPU_NONE) &
        (ex_pkt.ctrl.wb_sel == WB_INT)));
  assign intra_b_a = ex_pkt.valid & ex_pkt_b.valid & laneA_writes_int & (rd_x != 5'd0) &
                     (rd_x == ex_pkt_b.ctrl.rs1);
  assign intra_b_b = ex_pkt.valid & ex_pkt_b.valid & laneA_writes_int & (rd_x != 5'd0) &
                     (rd_x == ex_pkt_b.ctrl.rs2);
  assign memb_b_a = mem_pkt.b_valid & mem_pkt.b_we &
                    (mem_pkt.b_rd == ex_pkt_b.ctrl.rs1);
  assign memb_b_b = mem_pkt.b_valid & mem_pkt.b_we &
                    (mem_pkt.b_rd == ex_pkt_b.ctrl.rs2);
  assign mema_b_a = reg_we_m & (rd_m != 5'd0) &
                    (rd_m == ex_pkt_b.ctrl.rs1);
  assign mema_b_b = reg_we_m & (rd_m != 5'd0) &
                    (rd_m == ex_pkt_b.ctrl.rs2);
  assign wbb_b_a = wb_pkt.b_valid & wb_pkt.b_we &
                   (wb_pkt.b_rd == ex_pkt_b.ctrl.rs1);
  assign wbb_b_b = wb_pkt.b_valid & wb_pkt.b_we &
                   (wb_pkt.b_rd == ex_pkt_b.ctrl.rs2);
  assign wba_b_a = reg_we_w & (rd_w != 5'd0) &
                   (rd_w == ex_pkt_b.ctrl.rs1);
  assign wba_b_b = reg_we_w & (rd_w != 5'd0) &
                   (rd_w == ex_pkt_b.ctrl.rs2);
  assign rs1_b_fwd = intra_b_a ? ex_result :
                     memb_b_a ? mem_pkt.b_alu_res :
                     mema_b_a ? mem_fwd_data :
                     wbb_b_a ? wb_pkt.b_data :
                     wba_b_a ? wb_data_w : ex_pkt_b.rs1;
  assign rs2_b_fwd = intra_b_b ? ex_result :
                     memb_b_b ? mem_pkt.b_alu_res :
                     mema_b_b ? mem_fwd_data :
                     wbb_b_b ? wb_pkt.b_data :
                     wba_b_b ? wb_data_w : ex_pkt_b.rs2;
  always_comb begin
    case (ex_pkt_b.ctrl.a_src)
      SRC_IMM_I, SRC_IMM_S, SRC_IMM_B, SRC_IMM_U, SRC_IMM_J:
        alu_a_b = ex_pkt_b.imm;
      SRC_PC: alu_a_b = ex_pkt_b.pc;
      default: alu_a_b = rs1_b_fwd;
    endcase
    // Lane B holds only LUI/AUIPC/OP-IMM(-32)/OP(-32): R-type (OP/OP32)
    // takes rs2, everything else (incl. shift-immediates, whose shamt
    // lives in imm, not rs2) takes imm. Mirrors lane A's override list.
    if (ex_pkt_b.ctrl.opcode == OP_OP || ex_pkt_b.ctrl.opcode == OP_OP32)
      alu_b_b = rs2_b_fwd;
    else
      alu_b_b = ex_pkt_b.imm;
  end
  alu u_alu_b (.op(ex_pkt_b.ctrl.alu_op), .a(alu_a_b), .b(alu_b_b), .y(alu_y_b));
  assign ex_result_b = alu_y_b;

  always_comb begin
    case (ex_pkt.ctrl.funct3)
      3'b000: branch_resolved = (rs1_fwd == rs2_fwd);
      3'b001: branch_resolved = (rs1_fwd != rs2_fwd);
      3'b100: branch_resolved = ($signed(rs1_fwd) < $signed(rs2_fwd));
      3'b101: branch_resolved = ($signed(rs1_fwd) >= $signed(rs2_fwd));
      3'b110: branch_resolved = (rs1_fwd < rs2_fwd);
      3'b111: branch_resolved = (rs1_fwd >= rs2_fwd);
      default: branch_resolved = 1'b0;
    endcase
  end

  assign branch_target = (ex_pkt.ctrl.is_jal | ex_pkt.ctrl.is_jalr) ?
                         (alu_a + alu_b) : (ex_pkt.pc + ex_pkt.imm);

  // xRET redirects to epc (mret/sret previously fell through, which only
  // worked when the target happened to be adjacent).
  logic is_xret;
  assign is_xret = ex_pkt.ctrl.is_mret | ex_pkt.ctrl.is_sret;
  // Control-transfer verify against the Decode prediction: branches
  // redirect on mispredict (taken XOR predicted); jumps redirect unless
  // already at the predicted target (JAL early-redirect makes EX a no-op;
  // JALR compares the resolved register target). Mispredicted-taken-
  // not-taken resumes at the fall-through pc.
  logic [63:0] branch_fallthrough;
  logic [63:0] cf_actual_target;
  assign branch_fallthrough = ex_pkt.pc + (ex_pkt.is_c ? 64'd2 : 64'd4);
  assign cf_actual_target = branch_target; // pc+imm, or alu sum for jal/jalr
  assign redirect = ex_pkt.valid &
                    ((ex_pkt.ctrl.is_branch & (branch_resolved ^ ex_pkt.pred_taken)) |
                     (ex_pkt.ctrl.is_jal & ((cf_actual_target != ex_pkt.pred_target) |
                                            ~ex_pkt.pred_taken)) |
                     (ex_pkt.ctrl.is_jalr & ((cf_actual_target != ex_pkt.pred_target) |
                                             ~ex_pkt.pred_taken)) |
                     is_xret);
  assign redirect_target = is_xret ? epc :
                           ((ex_pkt.ctrl.is_branch & ~branch_resolved) ?
                            branch_fallthrough : cf_actual_target);

  // BTB/RAS update at EX-resolve (in-order advance, skipped on traps).
  // Outcomes are final here, so no speculative repair is needed. Branches
  // allocate on taken (weakly-taken) and adapt both ways; JALR records its
  // resolved register target (always taken); JAL needs no entry (decode
  // computes its exact target). RAS pushes calls and pops returns.
  logic ex_advance;
  logic [5:0] btb_upd_idx;
  logic ex_is_call, ex_is_ret;
  assign btb_upd_idx = ex_pkt.pc[6:1];
  assign ex_advance = ex_pkt.valid & ~backend_stall & ~trap;
  function automatic logic [1:0] sat_inc(input logic [1:0] c);
    return (c == 2'b11) ? c : c + 2'd1;
  endfunction
  function automatic logic [1:0] sat_dec(input logic [1:0] c);
    return (c == 2'b00) ? c : c - 2'd1;
  endfunction
  assign ex_is_call = (ex_pkt.ctrl.is_jal | ex_pkt.ctrl.is_jalr) &
                      is_link(ex_pkt.ctrl.rd);
  assign ex_is_ret = ex_pkt.ctrl.is_jalr & is_link(ex_pkt.ctrl.rs1) &
                     ~is_link(ex_pkt.ctrl.rd);
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      for (int i = 0; i < BTB_ENTRIES; i++) begin
        btb_v[i] <= 1'b0;
        btb_tag[i] <= '0;
        btb_tgt[i] <= '0;
        btb_ctr[i] <= 2'b01;
      end
      ras_ptr <= 3'd0;
      ras_count <= 4'd0;
      for (int j = 0; j < 8; j++) ras[j] <= '0;
    end else if (ex_advance) begin
      if (ex_pkt.ctrl.is_branch) begin
        if (branch_resolved) begin
          btb_v[btb_upd_idx] <= 1'b1;
          btb_tag[btb_upd_idx] <= ex_pkt.pc[47:7];
          btb_tgt[btb_upd_idx] <= ex_pkt.pc + ex_pkt.imm;
          btb_ctr[btb_upd_idx] <= (btb_v[btb_upd_idx] &&
                                   (btb_tag[btb_upd_idx] == ex_pkt.pc[47:7])) ?
                                  sat_inc(btb_ctr[btb_upd_idx]) : 2'b10;
        end else if (btb_v[btb_upd_idx] &&
                     (btb_tag[btb_upd_idx] == ex_pkt.pc[47:7])) begin
          btb_ctr[btb_upd_idx] <= sat_dec(btb_ctr[btb_upd_idx]);
        end
      end else if (ex_pkt.ctrl.is_jalr) begin
        btb_v[btb_upd_idx] <= 1'b1;
        btb_tag[btb_upd_idx] <= ex_pkt.pc[47:7];
        btb_tgt[btb_upd_idx] <= branch_target;
        btb_ctr[btb_upd_idx] <= 2'b11;
      end
      if (ex_is_call) begin
        ras[ras_ptr] <= ex_pkt.pc + (ex_pkt.is_c ? 64'd2 : 64'd4);
        ras_ptr <= (ras_ptr + 3'd1) & 3'd7;
        if (ras_count != 4'd8) ras_count <= ras_count + 4'd1;
      end else if (ex_is_ret) begin
        if (ras_count != 4'd0) begin
          ras_ptr <= (ras_ptr - 3'd1) & 3'd7;
          ras_count <= ras_count - 4'd1;
        end
      end
    end
  end

  assign mem_is_load_x = ((ex_pkt.ctrl.lsu_op >= LSU_LB) & (ex_pkt.ctrl.lsu_op <= LSU_LWU)) |
                         (ex_pkt.ctrl.lsu_op == LSU_LR) | (ex_pkt.ctrl.lsu_op == LSU_AMO);
  // EX holds an FP load (FLW/FLD): FP-file load-use handled in hazard_unit.
  logic ex_fp_load_x;
  assign ex_fp_load_x = ex_pkt.valid & mem_is_load_x &
                        (ex_pkt.ctrl.opcode == OP_FPLOAD);
  assign mem_is_store_x = (ex_pkt.ctrl.lsu_op >= LSU_SB) & (ex_pkt.ctrl.lsu_op <= LSU_SD);

  logic mdu_in_ex;
  assign mdu_in_ex = ex_pkt.valid & is_mdu_op(ex_pkt.ctrl.alu_op);

  always_comb begin
    mdu_start = 1'b0; fpu_start = 1'b0;
    if (mdu_in_ex & ~mdu_busy_q & ~mdu_done)
      mdu_start = 1'b1;
    if (fpu_in_ex & ~fpu_busy_q & ~fpu_done)
      fpu_start = 1'b1;
  end

  mdu u_mdu (
    .clk(clk), .rst_n(rst_n),
    .start(mdu_start), .op(alu_to_mul_op(ex_pkt.ctrl.alu_op)),
    .a(rs1_fwd), .b(rs2_fwd),
    .result(mdu_res), .done(mdu_done), .busy(mdu_busy_q)
  );
  assign mdu_busy = mdu_in_ex & ~mdu_done;

  logic fpu_in_ex;
  assign fpu_in_ex = ex_pkt.valid & (ex_pkt.ctrl.fpu_op != FPU_NONE);

  logic [4:0] fpu_fflags;
  // Integer-source FP ops (FCVT.*.X, FMV.X.*) read the integer regfile:
  // forward the integer rs1 value into the FPU's a operand for those.
  logic [63:0] fp_a, fp_b, fp_c;
  logic        fp_op_int_src;
  assign fp_op_int_src = (ex_pkt.ctrl.fpu_op == FPU_I2F) |
                         (ex_pkt.ctrl.fpu_op == FPU_MV_X2F);
  assign fp_a = fp_op_int_src ? rs1_fwd : fp_fwd_a;
  assign fp_b = fp_fwd_b;
  assign fp_c = fp_fwd_c;
  // Spec: rm=111 (DYN) takes the rounding mode from fcsr.frm. Prior FRM/FCSR
  // writes are stalled out above, so frm is stable for the in-flight op.
  assign fpu_rm_eff = (ex_pkt.ctrl.fp_rm == RM_DYN) ? frm : ex_pkt.ctrl.fp_rm;
  fpu u_fpu (
    .clk(clk), .rst_n(rst_n),
    .start(fpu_start), .op(ex_pkt.ctrl.fpu_op), .rm(fpu_rm_eff),
    .is_double(ex_pkt.ctrl.fp_fmt[0]),
    .is_unsigned(ex_pkt.ctrl.fp_fmt[2]),
    .is_word(ex_pkt.ctrl.fp_fmt[3]),
    .a(fp_a), .b(fp_b), .c(fp_c),
    .result(fpu_res), .fflags(fpu_fflags), .done(fpu_done), .busy(fpu_busy_q)
  );
  assign fpu_busy = fpu_in_ex & ~fpu_done;

  logic [63:0] ex_result;
  // RVV vsetvli/vsetivli: AVL is x[rs1] (x0 = VLMAX) or the rs1-field
  // zimm for ivli; vl = min(AVL, VLMAX), vill (decode-flagged) forces 0.
  // The rd writeback (vl) rides the normal WB_INT path; vl/vtype commit
  // to the CSR unit at WB retire (which also resets vstart, sets VS=11).
  logic [63:0] vset_avl;
  logic [7:0]  vset_vl;
  assign vset_avl = ex_pkt.ctrl.vset_ivli ? {59'd0, ex_pkt.ctrl.rs1} :
                    (ex_pkt.ctrl.rs1 == 5'd0 ? 64'(VLMAX) : rs1_fwd);
  assign vset_vl = ex_pkt.ctrl.vset_vill ? 8'd0 :
                   (vset_avl[63:8] != 56'd0 ? 8'(VLMAX) :
                    (vset_avl[7:0] > 8'(VLMAX) ? 8'(VLMAX) : vset_avl[7:0]));
  always_comb begin
    ex_result = alu_y;
    if (is_mdu_op(ex_pkt.ctrl.alu_op))
      ex_result = mdu_res;
    if (ex_pkt.ctrl.fpu_op != FPU_NONE) ex_result = fpu_res;
    if (ex_pkt.ctrl.is_vset) ex_result = {56'd0, vset_vl};
    // JAL/JALR link: return address is the next sequential PC, which is
    // pc+2 for a compressed instruction and pc+4 otherwise.
    if (ex_pkt.ctrl.is_jal | ex_pkt.ctrl.is_jalr)
      ex_result = ex_pkt.pc + (ex_pkt.is_c ? 64'd2 : 64'd4);
  end

  // LR/SC + AMO + AXI transaction engine lives in rtl/core/lsu/lsu.sv;
  // the EX->MEM packet, WB mux, and forwarding stay here.
  logic        lsu_lr_valid;
  logic [47:0] lsu_lr_addr;
  logic        lsu_pending;
  logic        lsu_mem_we;

  // Data-address translation (PIPT: the L1D sees physical only). The VA
  // is full-width; the PA feeds mem_pkt. A TLB miss stalls the pipe for
  // the walker; a fault traps from EX with tval=VA (MEM never issues).
  logic [63:0] ex_va_full;
  assign ex_va_full = rs1_fwd + ex_pkt.imm;
  logic [1:0] eff_priv_d;
  always_comb begin
    eff_priv_d = priv;
    if (priv == PRIV_M && csr_mstatus[17]) begin // MPRV
      if (csr_mstatus[12:11] == 2'b11)      eff_priv_d = PRIV_M;
      else if (csr_mstatus[12:11] == 2'b01) eff_priv_d = PRIV_S;
      else                                 eff_priv_d = PRIV_U;
    end
  end
  logic        ex_mem_valid;
  logic        ex_mem_rd, ex_mem_wr;
  // Vector ld/st translates per element inside MEM (VLSU drives the data
  // port then); EX must not present it as a scalar memory op.
  assign ex_mem_valid = ex_pkt.valid & ~ex_pkt.ctrl.is_vec_mem &
      (mem_is_load_x | mem_is_store_x | ex_is_amo |
       (ex_pkt.ctrl.lsu_op == LSU_SC));
  assign ex_mem_rd = mem_is_load_x;
  assign ex_mem_wr = mem_is_store_x | ex_is_amo |
                     ((ex_pkt.ctrl.lsu_op == LSU_SC) & ex_sc_success);
  logic        mmu_hit_d, mmu_miss_d, mmu_fault_d;
  logic [47:0] mmu_pa_d;
  logic [4:0]  mmu_cause_d;

  // SFENCE.VMA retires with rs1 (VA) in csr_wdata and rs2 (ASID) in
  // rs2v; x0 on either side means "all". HFENCE.VVMA/GVMA flush like
  // SFENCE (conservative full flush for the H v0.1 TLB). SATP/VSATP/HGATP
  // writes flush all. The selective TLB flush fires at retire (ordered
  // with the L1D drain); F/D refetch below re-translates.
  // RVV: while a vector op occupies MEM the data port serves the VLSU's
  // per-element VA (EX is frozen, so no scalar competes for the port).
  mmu #(.ADDR_W(48), .TLB_ENTRIES(32)) u_mmu (
    .clk(clk), .rst_n(rst_n),
    .satp_i(csr_satp), .mstatus_i(csr_mstatus), .priv_i(priv),
    .virt_i(virt), .vsatp_i(csr_vsatp), .hgatp_i(csr_hgatp),
    .vsstatus_i(csr_vsstatus),
    .flush_all_i(satp_we_o | vsatp_we_o | hgatp_we_o |
                 hfence_vvma_o | hfence_gvma_o),
    .flush_sel_i(sfence_o),
    .flush_va_i(wb_pkt.csr_wdata),
    .flush_asid_i(wb_pkt.rs2v[15:0]),
    .flush_has_va_i(wb_pkt.ctrl.rs1 != 5'd0),
    .flush_has_asid_i(wb_pkt.ctrl.rs2 != 5'd0),
    .va_f_i(fetch_va), .priv_f_i(priv),
    .hit_f_o(mmu_hit_f), .pa_f_o(mmu_pa_f), .miss_f_o(mmu_miss_f),
    .fault_f_o(mmu_fault_f), .cause_f_o(mmu_cause_f),
    .va_d_i(vec_mem_active ? vlsu_mmu_va : ex_va_full),
    .priv_d_i(eff_priv_d),
    .rd_d_i(vec_mem_active ? vlsu_mmu_rd : ex_mem_rd),
    .wr_d_i(vec_mem_active ? vlsu_mmu_wr : ex_mem_wr),
    .valid_d_i(vec_mem_active ? vlsu_mmu_valid : ex_mem_valid),
    .hit_d_o(mmu_hit_d), .pa_d_o(mmu_pa_d), .miss_d_o(mmu_miss_d),
    .fault_d_o(mmu_fault_d), .cause_d_o(mmu_cause_d),
    .req_o(ptw_req), .we_o(ptw_we), .addr_o(ptw_addr), .be_o(ptw_be),
    .wdata_o(ptw_wdata), .lock_o(),
    .rdata_i(ptw_rdata), .ack_i(ptw_ack), .ready_i(ptw_ready)
  );

  // SC success checked at EX->MEM entry: reservation must be valid and match.
  // Safe: entry only advances when !stall, i.e. no older LR/AMO still in MEM.
  logic [47:0] ex_mem_addr;
  assign ex_mem_addr = rs1_fwd + ex_pkt.imm;
  logic        ex_sc_success;
  // Reservation compare in PA space (identical to VA in Bare mode).
  assign ex_sc_success = (ex_pkt.ctrl.lsu_op == LSU_SC) &
                         lsu_lr_valid & (lsu_lr_addr == mmu_pa_d);
  logic        ex_is_amo;
  assign ex_is_amo = (ex_pkt.ctrl.lsu_op == LSU_AMO);
  logic        ex_amo_is_d;
  assign ex_amo_is_d = (ex_pkt.ctrl.funct3 == 3'b011);

  always_comb begin
    mem_pkt_n = '0;
    mem_pkt_n.valid = ex_pkt.valid;
    mem_pkt_n.pc    = ex_pkt.pc;
    mem_pkt_n.ctrl  = ex_pkt.ctrl;
    // SC returns 0 on success / 1 on failure in rd (via alu_res + WB mux);
    // all other ops keep the EX result.
    mem_pkt_n.alu_res = (ex_pkt.ctrl.lsu_op == LSU_SC) ?
                        (ex_sc_success ? 64'd0 : 64'd1) : ex_result;
    mem_pkt_n.rs2   = rs2_fwd;
    // CSR write operand is rs1 (forwarded), NOT the ALU result. The prior
    // path set wb_pkt.data = csr_rdata (old value) and fed that back as the
    // write data, making every CSR write a no-op.
    // CSR write operand: rs1 for register forms, the 5-bit zimm
    // zero-extended for CSRRWI/CSRRSI/CSRRCI (funct3[2]).
    mem_pkt_n.csr_wdata = (ex_pkt.ctrl.funct3[2]) ? {59'd0, ex_pkt.ctrl.rs1} : rs1_fwd;
    // Physical address from the MMU (PIPT). In Bare mode this equals the
    // VA low 48 bits, identical to the old direct assignment. Vector ops
    // carry the VA base instead (per-element translation happens in MEM
    // via the VLSU); is_load/is_store stay 0 so the scalar LSU, WB mux
    // and forwarding all ignore the packet.
    mem_pkt_n.mem_addr = ex_pkt.ctrl.is_vec_mem ? ex_mem_addr :
                         {16'd0, mmu_pa_d};
    // SC writes memory only on reservation success; AMO always reads then
    // writes (phased in the MEM FSM below).
    mem_pkt_n.is_store = mem_is_store_x | ex_is_amo |
                         ((ex_pkt.ctrl.lsu_op == LSU_SC) & ex_sc_success);
    mem_pkt_n.is_load  = mem_is_load_x;
    mem_pkt_n.store_data = (ex_pkt.ctrl.is_fp ? fp_b : rs2_fwd) << (mem_pkt_n.mem_addr[2:0]*8);
  mem_pkt_n.fflags = fpu_fflags;
    mem_pkt_n.be = 8'hFF;
    mem_pkt_n.lock = (ex_pkt.ctrl.lsu_op == LSU_LR) | (ex_pkt.ctrl.lsu_op == LSU_SC) |
                     (ex_pkt.ctrl.lsu_op == LSU_AMO);
    // Dual-issue lane B rides through (ALU-only, never traps). A redirect or
    // trap means lane B is wrong-path younger work: squash it while lane A
    // (e.g. a jal link) still flows to MEM.
    mem_pkt_n.b_valid   = ex_pkt_b.valid & ~flush_redirect;
    mem_pkt_n.b_rd      = ex_pkt_b.ctrl.rd;
    mem_pkt_n.b_we      = ex_pkt_b.valid & (ex_pkt_b.ctrl.rd != 5'd0);
    mem_pkt_n.b_alu_res = ex_result_b;
    mem_pkt_n.b_pc      = ex_pkt_b.pc;
    case (ex_pkt.ctrl.lsu_op)
      LSU_LB, LSU_LBU: mem_pkt_n.be = 8'h01 << mem_pkt_n.mem_addr[2:0];
      LSU_LH, LSU_LHU: mem_pkt_n.be = 8'h03 << mem_pkt_n.mem_addr[2:0];
      LSU_LW, LSU_LWU, LSU_SW: mem_pkt_n.be = 8'h0F << mem_pkt_n.mem_addr[2:0];
      LSU_LD, LSU_SD:  mem_pkt_n.be = 8'hFF;
      LSU_SB, LSU_SH:  mem_pkt_n.be = (ex_pkt.ctrl.lsu_op == LSU_SB) ?
                                     (8'h01 << mem_pkt_n.mem_addr[2:0]) :
                                     (8'h03 << mem_pkt_n.mem_addr[2:0]);
      LSU_LR, LSU_SC, LSU_AMO: begin
        // funct3 011=D (8B), 010=W (4B); decode guarantees one of the two.
        mem_pkt_n.be = (ex_pkt.ctrl.funct3 == 3'b011) ? 8'hFF :
                       (8'h0F << mem_pkt_n.mem_addr[2:0]);
      end
    endcase
  end

  // EX->MEM packet advance; the LSU engine (u_lsu below) consumes
  // mem_pkt and drives the data bus + busy/load-data outputs.
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      mem_pkt     <= '0;
    end else if (trap) begin
      mem_pkt     <= '0;
    end else if (!backend_stall) begin
      if (ex_pkt.valid)
        mem_pkt <= mem_pkt_n;
      else
        mem_pkt <= '0;
    end
  end

  logic lsu_mem_req, lsu_mem_we_s;
  logic [47:0] lsu_mem_addr;
  logic [7:0] lsu_mem_be;
  logic [63:0] lsu_mem_wdata;
  logic lsu_mem_lock;
  lsu u_lsu (
    .clk(clk), .rst_n(rst_n),
    .stall_i(backend_stall), .trap_i(trap),
    .req_valid_i(mem_pkt.valid),
    .req_is_load_i(mem_pkt.is_load),
    .req_is_store_i(mem_pkt.is_store),
    .req_addr_i(mem_pkt.mem_addr),
    .req_be_i(mem_pkt.be),
    .req_wdata_i(mem_pkt.store_data),
    .req_lsu_op_i(mem_pkt.ctrl.lsu_op),
    .req_funct3_i(mem_pkt.ctrl.funct3),
    .req_amo_op_i(mem_pkt.ctrl.amo_op),
    .req_rs2_i(mem_pkt.rs2),
    .req_lock_i(mem_pkt.lock),
    .nxt_valid_i(mem_pkt_n.valid),
    .nxt_is_load_i(mem_pkt_n.is_load),
    .nxt_is_store_i(mem_pkt_n.is_store),
    .nxt_is_sc_i(mem_pkt_n.valid &
                 (mem_pkt_n.ctrl.lsu_op == LSU_SC)),
    .fence_hold_i(vm_fence_active),
    .d_rdata_i(mem_rdata),
    .d_ack_i(mem_ack),
    .d_ready_i(mem_ready),
    .mem_req_o(lsu_mem_req),
    .mem_we_o(lsu_mem_we_s),
    .mem_addr_o(lsu_mem_addr),
    .mem_be_o(lsu_mem_be),
    .mem_wdata_o(lsu_mem_wdata),
    .mem_lock_o(lsu_mem_lock),
    .busy_o(lsu_busy),
    .load_data_o(mem_rdata_aligned),
    .lr_valid_o(lsu_lr_valid),
    .lr_addr_o(lsu_lr_addr),
    .pending_o(lsu_pending)
  );
  // NOTE: u_lsu is inherently inert for vector packets (is_load/is_store
  // are 0 for them, so it never enters busy nor issues), but the outputs
  // are still muxed for cleanliness.
  assign lsu_mem_we = lsu_mem_we_s;

  // RVV v0 skeleton: vector regfile + shared-path VLSU. While a vector
  // op occupies MEM the L1D beat serves the VLSU element; the scalar LSU
  // is idle then (see note above), so this mux is arbitration-free.
  logic        vec_mem_active;
  logic        vlsu_busy, vlsu_done, vlsu_fault, vlsu_beat;
  logic [7:0]  vlsu_idx;
  logic [63:0] vlsu_mmu_va;
  logic        vlsu_mmu_rd, vlsu_mmu_wr, vlsu_mmu_valid;
  logic        vlsu_mem_req, vlsu_mem_we;
  logic [47:0] vlsu_mem_addr;
  logic [7:0]  vlsu_mem_be;
  logic [63:0] vlsu_mem_wdata;
  logic [4:0]  vrf_raddr, vrf_waddr;
  logic [4:0]  vrf_ridx, vrf_widx;
  logic [7:0]  vrf_rdata, vrf_wdata;
  logic        vrf_we;
  logic [7:0]  csr_vl, csr_vstart;
  logic [63:0] csr_vtype;
  assign vec_mem_active = mem_pkt.valid & mem_pkt.ctrl.is_vec_mem;
  vregfile u_vregfile (
    .clk(clk), .rst_n(rst_n),
    .raddr_i(vrf_raddr), .ridx_i(vrf_ridx), .rdata_o(vrf_rdata),
    .waddr_i(vrf_waddr), .widx_i(vrf_widx), .wdata_i(vrf_wdata),
    .we_i(vrf_we)
  );
  vlsu u_vlsu (
    .clk(clk), .rst_n(rst_n),
    .active_i(vec_mem_active), .trap_i(trap),
    .is_load_i(mem_pkt.ctrl.vec_is_load),
    .base_va_i(mem_pkt.mem_addr), .vd_i(mem_pkt.ctrl.rd),
    .vl_i(csr_vl), .vstart_i(csr_vstart),
    .vrf_raddr_o(vrf_raddr), .vrf_ridx_o(vrf_ridx),
    .vrf_rdata_i(vrf_rdata),
    .vrf_waddr_o(vrf_waddr), .vrf_widx_o(vrf_widx),
    .vrf_wdata_o(vrf_wdata), .vrf_we_o(vrf_we),
    .mmu_va_o(vlsu_mmu_va), .mmu_rd_o(vlsu_mmu_rd),
    .mmu_wr_o(vlsu_mmu_wr), .mmu_valid_o(vlsu_mmu_valid),
    .mmu_hit_i(mmu_hit_d), .mmu_pa_i(mmu_pa_d),
    .mmu_fault_i(mmu_fault_d),
    .mem_req_o(vlsu_mem_req), .mem_we_o(vlsu_mem_we),
    .mem_addr_o(vlsu_mem_addr), .mem_be_o(vlsu_mem_be),
    .mem_wdata_o(vlsu_mem_wdata),
    .mem_rdata_i(mem_rdata), .mem_ack_i(mem_ack),
    .mem_ready_i(mem_ready),
    .fence_hold_i(vm_fence_active),
    .busy_o(vlsu_busy), .done_o(vlsu_done), .fault_o(vlsu_fault),
    .elem_idx_o(vlsu_idx), .beat_o(vlsu_beat)
  );
  assign mem_req   = vec_mem_active ? vlsu_mem_req   : lsu_mem_req;
  assign mem_we    = vec_mem_active ? vlsu_mem_we    : lsu_mem_we_s;
  assign mem_addr  = vec_mem_active ? vlsu_mem_addr  : lsu_mem_addr;
  assign mem_be    = vec_mem_active ? vlsu_mem_be    : lsu_mem_be;
  assign mem_wdata = vec_mem_active ? vlsu_mem_wdata : lsu_mem_wdata;
  assign mem_lock  = vec_mem_active ? 1'b0           : lsu_mem_lock;

  assign rd_m = mem_pkt.ctrl.rd;
  assign reg_we_m = mem_pkt.valid &
                   ((mem_pkt.ctrl.wb_sel == WB_INT) | (mem_pkt.ctrl.wb_sel == WB_MEM)) &
                   (mem_pkt.ctrl.rd != 5'd0);
  // f0 is a real FP register (only x0 is hardwired zero), so FP writes
  // must not be suppressed for rd==0.
  assign fp_we_m = mem_pkt.valid & (mem_pkt.ctrl.wb_sel == WB_FP);
  assign mem_alu_y = mem_pkt.alu_res;

  always_comb begin
    wb_pkt_n = '0;
    wb_pkt_n.valid = mem_pkt.valid;
    wb_pkt_n.pc    = mem_pkt.pc;
    wb_pkt_n.ctrl  = mem_pkt.ctrl;
    wb_pkt_n.rd    = mem_pkt.ctrl.rd;
    wb_pkt_n.we    = reg_we_m;
    wb_pkt_n.fp_we = fp_we_m;
    wb_pkt_n.fflags = mem_pkt.fflags;
    case (mem_pkt.ctrl.wb_sel)
      WB_INT: wb_pkt_n.data = mem_pkt.alu_res;
      // SC returns its 0/1 status (in alu_res), not memory data.
      WB_MEM: wb_pkt_n.data = (mem_pkt.ctrl.lsu_op == LSU_SC) ? mem_pkt.alu_res :
                              mem_rdata_aligned;
      WB_FP:  wb_pkt_n.data = (mem_pkt.ctrl.opcode == OP_FPLOAD)
                             ? ((mem_pkt.ctrl.funct3 == 3'b010)
                                ? {32'hFFFFFFFF, mem_rdata_aligned[31:0]}  // FLW NaN-box
                                : mem_rdata_aligned)                         // FLD
                             : mem_pkt.alu_res;                             // FPU compute
      default: wb_pkt_n.data = mem_pkt.alu_res;
    endcase
    // CSR read value goes to the integer destination rd; the CSR write
    // operand (rs1) travels separately in csr_wdata so the CSR unit writes
    // the new value, not the old one.
    wb_pkt_n.csr_wdata = mem_pkt.csr_wdata;
    // SFENCE rs1 (VA) rides csr_wdata (funct3[2]==0 gives rs1_fwd) and rs2
    // (ASID) rides a dedicated field, so retire has both operands.
    wb_pkt_n.rs2v = mem_pkt.rs2;
    if (mem_pkt.ctrl.reads_csr) wb_pkt_n.data = csr_rdata;
    // Dual-issue lane B retire slot (integer ALU result only).
    wb_pkt_n.b_valid = mem_pkt.b_valid;
    wb_pkt_n.b_rd    = mem_pkt.b_rd;
    wb_pkt_n.b_we    = mem_pkt.b_we;
    wb_pkt_n.b_data  = mem_pkt.b_alu_res;
    wb_pkt_n.b_pc    = mem_pkt.b_pc;
  end

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) wb_pkt <= '0;
    else if (!backend_stall) wb_pkt <= wb_pkt_n;
  end

  // Commit tracer for lock-step co-simulation with Unicorn (Phase A:
  // offline trace compare). Logs retired instructions (pc, int/fp dest +
  // data, priv), trap events (pc, cause), and completed stores (we-gated
  // so AMO read phases don't log). Off unless +define+COSIM_TRACE.
  `ifdef COSIM_TRACE
  integer cosim_f;
  initial cosim_f = $fopen("cosim_rtl.log", "w");
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
    end else begin
      if (!backend_stall && wb_pkt_n.valid)
        $fwrite(cosim_f, "C %h %0d %h %b %b %0d %h %0d\n",
                wb_pkt_n.pc, wb_pkt_n.rd, wb_pkt_n.data, wb_pkt_n.we,
                wb_pkt_n.fp_we, wb_pkt_n.rd, wb_pkt_n.data, priv);
      // Dual-issue lane B commits in the same cycle, younger (logged second).
      if (!backend_stall && wb_pkt_n.b_valid)
        $fwrite(cosim_f, "C %h %0d %h %b %b %0d %h %0d\n",
                wb_pkt_n.b_pc, wb_pkt_n.b_rd, wb_pkt_n.b_data,
                wb_pkt_n.b_we, 1'b0, wb_pkt_n.b_rd, wb_pkt_n.b_data, priv);
      if (trap)
        $fwrite(cosim_f, "T %h %0d\n", ex_pkt.pc, cause);
      // Completed memory writes only (mem_we excludes AMO read phases
      // and failed SCs, matching what actually reaches memory).
      if (lsu_pending & mem_ack & mem_pkt.valid & lsu_mem_we)
        $fwrite(cosim_f, "M %h %h %h %h\n",
                mem_pkt.pc, mem_pkt.mem_addr[47:0], mem_pkt.be, mem_wdata);
      // Completed vector store beats (element PA/be/data, same semantics).
      if (vlsu_beat & vlsu_mem_we & vec_mem_active)
        $fwrite(cosim_f, "M %h %h %h %h\n",
                mem_pkt.pc, vlsu_mem_addr, vlsu_mem_be, vlsu_mem_wdata);
      $fflush(cosim_f);
    end
  end
  `endif

  // FENCE.I retires in order at WB; the pulse may stretch across a stall
  // (WB holds), which is harmless for the idempotent L1I invalidate.
  assign fence_i_o = wb_pkt.valid & wb_pkt.ctrl.fence_i;
  assign sfence_o = wb_pkt.valid & wb_pkt.ctrl.is_sfence;
  assign hfence_vvma_o = wb_pkt.valid & wb_pkt.ctrl.is_hfence_vvma;
  assign hfence_gvma_o = wb_pkt.valid & wb_pkt.ctrl.is_hfence_gvma;
  logic vsatp_we_o, hgatp_we_o;
  assign vsatp_we_o = wb_pkt.valid & wb_pkt.ctrl.writes_csr &
                      (wb_pkt.ctrl.csr_addr == CSR_VSATP);
  assign hgatp_we_o = wb_pkt.valid & wb_pkt.ctrl.writes_csr &
                      (wb_pkt.ctrl.csr_addr == CSR_HGATP);
  assign satp_we_o = wb_pkt.valid & wb_pkt.ctrl.writes_csr &
                     ((wb_pkt.ctrl.csr_addr == CSR_SATP) ||
                      (wb_pkt.ctrl.csr_addr == CSR_VSATP) ||
                      (wb_pkt.ctrl.csr_addr == CSR_HGATP));
  `ifdef CORE_DEBUG
  always @(posedge clk) begin
    if (fence_i_o | sfence_o | satp_we_o)
      $display("[core %0t] FENCERET fi=%b sf=%b satp=%b pc=%h instr=%h",
               $time, fence_i_o, sfence_o, satp_we_o, wb_pkt.pc, wb_pkt.ctrl);
    if (trap)
      $display("[core %0t] TRAP cause=%0d tval=%h epc=%h priv=%b",
               $time, cause, trap_tval, ex_pkt.pc, priv);
  end
  `endif

  assign rd_w = wb_pkt.rd;
  assign rd_w_fp = wb_pkt.rd;
  assign reg_we_w = wb_pkt.we;
  assign fp_we_w = wb_pkt.fp_we;
  assign wb_data_w = wb_pkt.data;
  // Dual-issue lane B writeback (second integer write port; lane B younger).
  logic [4:0]  rd_w_b;
  logic        reg_we_w_b;
  logic [63:0] wb_data_w_b;
  assign rd_w_b = wb_pkt.b_rd;
  assign reg_we_w_b = wb_pkt.b_valid & wb_pkt.b_we;
  assign wb_data_w_b = wb_pkt.b_data;

  logic [4:0] fcsr_fflags_we;
  logic [4:0] fcsr_fflags;
  assign fcsr_fflags_we = wb_pkt.valid & wb_pkt.ctrl.is_fp & (wb_pkt.ctrl.fpu_op != FPU_NONE);
  logic [63:0] csr_hstatus;
  csr_unit u_csr (
    .clk(clk), .rst_n(rst_n), .flush(flush_all_no_refetch),
    .priv(priv), .hartid(hartid_i),
    .csr_we(wb_pkt.ctrl.writes_csr & wb_pkt.valid),
    .csr_addr(wb_pkt.ctrl.csr_addr),
    .csr_raddr(mem_pkt.ctrl.reads_csr ? mem_pkt.ctrl.csr_addr : wb_pkt.ctrl.csr_addr),
    .csr_wdata(wb_pkt.csr_wdata),
    .csr_op(wb_pkt.ctrl.csr_op),
    .csr_rs1(wb_pkt.ctrl.rs1),
    .csr_rdata(csr_rdata),
    .trap_pc(vec_fault ? mem_pkt.pc : (irq_fire ? pc_d : ex_pkt.pc)),
    .cause(cause), .trap(trap),
    .tval_valid(trap_is_fault & ~irq_fire), .tval(trap_tval),
    .mret(wb_pkt.ctrl.is_mret), .sret(wb_pkt.ctrl.is_sret),
    .ex_mret_i(ex_pkt.valid & ex_pkt.ctrl.is_mret),
    .ex_sret_i(ex_pkt.valid & ex_pkt.ctrl.is_sret),
    .epc(epc), .tvec(tvec),    .new_priv(new_priv),
    .timer_irq(timer_irq), .soft_irq(soft_irq), .ext_irq(ext_irq),
    .irq_pending(irq_pending),
    .irq_take_o(irq_take_o), .irq_cause_o(irq_cause_o),
    .trap_irq_i(irq_fire),
    .fi_we(), .fs_mstatus(),
    .fcsr_fflags_we(fcsr_fflags_we),
    .fcsr_fflags_in(wb_pkt.fflags),
    .fflags(fcsr_fflags),
    .frm(frm),
    .mstatus_o(csr_mstatus),
    .satp_o(csr_satp),
    .sstatus_o(csr_sstatus),
    .trap_deleg_o(csr_trap_deleg),
    .virt_o(csr_virt), .vsatp_o(csr_vsatp), .hgatp_o(csr_hgatp),
    .vsstatus_o(csr_vsstatus),
    .trap_to_vs_o(csr_trap_to_vs),
    .new_virt_priv_o(csr_new_priv), .new_virt_o(csr_new_virt),
    .hstatus_o(csr_hstatus),
    .vset_we_i(wb_pkt.valid & wb_pkt.ctrl.is_vset),
    .vset_vl_i(wb_pkt.data[7:0]),
    .vset_vtype_i(wb_pkt.ctrl.vtypei),
    .vset_vill_i(wb_pkt.ctrl.vset_vill),
    .vec_trap_i(vec_fault),
    .vec_idx_i(vlsu_idx),
    .vl_o(csr_vl), .vtype_o(csr_vtype), .vstart_o(csr_vstart)
  );
  assign csr_hstatus_spv = csr_hstatus[7];
  assign csr_hstatus_spvp = csr_hstatus[8];

  // Fault plumbing for mtval: fetch bubble carries its VA, scalar data
  // faults use the faulting EX virtual address, vector faults use the
  // faulting element VA (vstart carries the index). Interrupts record 0.
  // Scalar data_fault is muted while a vector op occupies MEM (the data
  // port serves the VLSU then; a frozen younger EX op must not alias it).
  logic       trap_is_fault;
  logic [63:0] trap_tval;
  assign trap_is_fault = (ex_pkt.valid & ex_pkt.fault_f) | data_fault |
                         vec_fault;
  assign trap_tval     = vec_fault ? vlsu_mmu_va :
                         ((ex_pkt.valid & ex_pkt.fault_f) ? ex_pkt.fva :
                          ex_va_full);

  logic       data_fault;
  logic [4:0] data_cause;
  assign data_fault = ex_mem_valid & mmu_fault_d & ~vec_mem_active;
  assign data_cause = mmu_cause_d;
  // Vector element fault: precise trap with epc = the vector insn (it
  // restarts at vstart) and tval = the faulting element VA.
  logic       vec_fault;
  assign vec_fault = vec_mem_active & vlsu_fault;

  // Precise interrupt take at an instruction boundary: the backend holds
  // only older instructions, so once it drains the next insn (D head) can
  // trap with mepc pointing at it (mret resumes it). Fires through
  // frontend holds (the waiter re-executes after mret); a pending fetch
  // fault bubble keeps seniority (sync first). Sync traps can't coincide
  // (they need EX valid, but the backend is empty here).
  logic       irq_take_o, irq_fire;
  logic [4:0] irq_cause_o;
  logic       backend_empty;
  assign backend_empty = ~ex_pkt.valid & ~mem_pkt.valid;
  assign irq_fire = irq_take_o & backend_empty & valid_d & ~fault_d;

  logic       sync_trap;
  logic [4:0] sync_cause;
  always_comb begin
    sync_trap = 1'b0; sync_cause = 4'd0;
    if (ex_pkt.valid) begin
      if (ex_pkt.fault_f) begin
        sync_trap = 1'b1; sync_cause = ex_pkt.fcause;
      end else if (ex_pkt.ctrl.illegal) begin
        sync_trap = 1'b1; sync_cause = CAUSE_ILLEGAL_INSN;
      end else if (ex_pkt.ctrl.is_ecall) begin
        sync_trap = 1'b1; sync_cause = (priv == PRIV_M) ? CAUSE_M_ECALL :
                              virt ? ((priv == PRIV_S) ? CAUSE_VS_ECALL : CAUSE_USER_ECALL) :
                              ((priv == PRIV_S) ? CAUSE_SUP_ECALL : CAUSE_USER_ECALL);
      end else if (ex_pkt.ctrl.is_ebreak) begin
        sync_trap = 1'b1; sync_cause = CAUSE_BREAKPOINT;
      end else if (data_fault) begin
        sync_trap = 1'b1; sync_cause = data_cause;
      end
    end
  end
  // A younger EX trap is held off while the VLSU sequences (the older
  // vector op must complete or fault first -- precise-trap order); the
  // vector fault itself traps with the MMU cause (it is the oldest).
  assign trap = (sync_trap & ~vec_mem_hold) | irq_fire | vec_fault;
  assign cause = irq_fire ? irq_cause_o :
                 (vec_fault ? data_cause : sync_cause);

endmodule
