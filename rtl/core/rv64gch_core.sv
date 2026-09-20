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

  ctrl_t           dc;
  logic [63:0]     imm;
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
  logic            branch_taken, branch_resolved;
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
  } wb_pkt_t;
  wb_pkt_t wb_pkt, wb_pkt_n;

  assign dbg_pc = pc_d;

  // Real privilege state (was hardwired M). Switches on the committing
  // edge itself -- trap target, or MPP/SPP on xret redirect -- so no fetch
  // or translation ever uses a stale mode (the old WB-retire lag let
  // post-mret fetches run under the previous priv, fatal for non-identity
  // targets). The same-edge redirect/trap flushes discard in-flight work.
  logic [1:0] xret_priv;
  assign xret_priv = ex_pkt.ctrl.is_mret ?
                     ((csr_mstatus[12:11] == 2'b10) ? PRIV_U :
                      priv_e'(csr_mstatus[12:11])) :
                     (csr_sstatus[8] ? PRIV_S : PRIV_U);
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      priv <= PRIV_M;
    end else if (trap) begin
      priv <= csr_trap_deleg ? PRIV_S : PRIV_M;
    end else if (redirect & is_xret) begin
      priv <= xret_priv;
    end
  end

  assign next_pc = (redirect) ? redirect_target :
                  (fetch_is_c) ? (pc_f + 16'd2) : (pc_f + 64'd4);

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      pc_f <= RESET_PC;
    end else if (flush_all) begin
      pc_f <= (trap) ? tvec : (redirect ? redirect_target : next_pc);
    end else if (!stall && fetch_done) begin
      pc_f <= next_pc;
    end
  end

  logic [31:0] instr_expanded;
  logic        fetch_is_c;
  logic        fetch_illegal_c;
  logic [31:0] fetch_instr;
  logic [15:0] fetch_low_half;
  logic [63:0] fetch_word_q;   // latched fetch word, held across stalls
  logic [63:0] fetch_pc_q;     // pc the latched word was fetched for
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

  // fetch_done is a latched (level) signal gated by the result being valid
  // for the current pc and the pipeline being able to consume it. This
  // prevents a fetch completion pulse from being lost while the pipeline is
  // stalled (e.g. a load-use hazard or multi-cycle LSU access), which would
  // otherwise deadlock the core, while a stale result from a flushed pc is
  // ignored. For a 32-bit instruction at byte offset 6 the window straddles
  // two 64-bit words, so fetch_res_valid waits for the second word.
  assign fetch_done    = fetch_res_valid & ~stall & ~vm_fence_active;
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
          fetch_pc_q     <= pc_f;
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
      if (fetch_done) begin
        fetch_busy     <= 1'b0;
        fetch_complete <= 1'b0;
        fetch_hi_valid <= 1'b0;
      end
    end
  end

  assign instr_f = instr_d_use;

  logic illegal_c_d;
  logic fault_d;
  logic [4:0]  fcause_d;
  logic [63:0] fva_d;
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      valid_d <= 1'b0; pc_d <= '0; instr_d <= '0; is_c_d <= 1'b0; illegal_c_d <= 1'b0;
      fault_d <= 1'b0; fcause_d <= '0; fva_d <= '0;
    end else if (flush_all) begin
      valid_d <= 1'b0;
      fault_d <= 1'b0;
    end else if (!stall) begin
      if (fetch_done) begin
        valid_d <= valid_f;
        pc_d    <= pc_f;
        is_c_d  <= fetch_is_c;
        instr_d <= instr_d_use;
        illegal_c_d <= illegal_d_use;
        fault_d <= 1'b0;
      end else if (fault_f_q) begin
        // Translation-fault bubble: flows like an insn, traps from EX.
        // pc_d carries the faulting VA; instr is a benign NOP.
        valid_d <= 1'b1;
        pc_d    <= fva_q;
        is_c_d  <= 1'b1;
        instr_d <= 32'h00000013;
        illegal_c_d <= 1'b0;
        fault_d <= 1'b1;
        fcause_d <= fcause_q;
        fva_d   <= fva_q;
      end else begin
        valid_d <= 1'b0;
        fault_d <= 1'b0;
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
      OP_FPLOAD: begin c.is_fp = 1'b1; c.wb_sel = WB_FP;
                  // FLW (funct3=2, 32-bit) / FLD (funct3=3, 64-bit).
                  c.lsu_op = (f3 == 3'b010) ? LSU_LW : LSU_LD; end
      OP_FPSTORE:begin c.is_fp = 1'b1; c.wb_sel = WB_NONE;
                  // FSW (funct3=2, 32-bit) / FSD (funct3=3, 64-bit).
                  c.lsu_op = (f3 == 3'b010) ? LSU_SW : LSU_SD; end
      OP_FPOP:   begin c.is_fp = 1'b1; {c.fp_fmt, c.fpu_op, c.wb_sel, c.fp_rm} = decode_fpu_op(i); end
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
      OP_LOAD, OP_SYSTEM, OP_FPLOAD, OP_FENCE:
               r = {{52{i[31]}}, i[31:20]};
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
      OP_STORE, OP_FPSTORE:
               r = {{52{i[31]}}, i[31:25], i[11:7]};
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
  end

  assign rs1_d = dc.rs1;
  assign rs2_d = dc.rs2;
  assign rs3_d = dc.rs3;

  regfile_int u_rfint (
    .clk(clk), .rst_n(rst_n),
    .waddr(rd_w), .we(reg_we_w), .wdata(wb_data_w),
    .raddr1(rs1_d), .raddr2(rs2_d),
    .rdata1(rdata1_d), .rdata2(rdata2_d)
  );

  // WB->ID bypass: the regfile is written at the WB posedge while the ID-stage
  // read is combinational, so an instruction in ID reading a register written
  // by the instruction currently in WB would otherwise capture the stale
  // (pre-write) value. This is the load-use path for the multi-cycle memory:
  // a load retires into WB one cycle before its consumer leaves ID, so the
  // consumer must see the WB write data directly here.
  logic [63:0] rf_rdata1, rf_rdata2;
  logic        wb_int_we;
  assign wb_int_we = reg_we_w & (rd_w != 5'd0);
  assign rf_rdata1 = (wb_int_we & (rd_w == rs1_d)) ? wb_data_w : rdata1_d;
  assign rf_rdata2 = (wb_int_we & (rd_w == rs2_d)) ? wb_data_w : rdata2_d;

  regfile_fp u_rffp (
    .clk(clk), .rst_n(rst_n),
    .waddr(rd_w_fp), .we(fp_we_w), .wdata(wb_data_w),
    .raddr1(rs1_d), .raddr2(rs2_d), .raddr3(rs3_d),
    .rdata1(fp_rdata1), .rdata2(fp_rdata2), .rdata3(fp_rdata3)
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
  assign id_needs_frm = valid_d & (dc.fpu_op != FPU_NONE) & (dc.fp_rm == RM_DYN);
  assign frm_pending = (ex_pkt.valid & writes_frm(ex_pkt.ctrl)) |
                       (mem_pkt.valid & writes_frm(mem_pkt.ctrl)) |
                       (wb_pkt.valid & writes_frm(wb_pkt.ctrl));
  assign frm_stall = id_needs_frm & frm_pending;

  hazard_unit u_haz (
    .id_rs1(rs1_d), .id_rs2(rs2_d), .id_rs3(rs3_d),
    .ex_rd(rd_x), .ex_mem_read(mem_is_load_x),
    .ex_mul_busy(mdu_busy), .ex_fpu_busy(fpu_busy),
    .mem_lsu_busy(lsu_busy),
    .branch_taken(redirect), .trap(trap),
    .is_csr_op(dc.writes_csr), .csr_hazard(load_use_hazard_csr),
    .stall(stall_raw), .flush_id(flush_id_raw), .flush_ex(flush_ex)
  );
  // A data-TLB miss stalls the whole pipe for the walker (fetch only
  // waits for its own translation at issue; it needs no stall term).
  logic dtlb_miss;
  assign dtlb_miss = mmu_miss_d;
  assign stall = stall_raw | frm_stall | drain_busy_i | dtlb_miss;
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
  assign vm_fence_active = fence_i_o | sfence_o | satp_we_o | drain_busy_i;
  // xret redirects like a taken branch: squash F/D and reload pc from
  // epc deterministically (no next_pc race), while the insn itself flows
  // on to retire its CSR effects at WB.
  assign flush_id = flush_id_raw | (ex_pkt.valid & is_xret);
  assign flush_all = flush_id | flush_ex;
  logic flush_all_no_refetch;
  assign flush_all_no_refetch = flush_id_raw | flush_ex;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      ex_pkt <= '0;
    end else if (trap) begin
      ex_pkt <= '0;
    end else if (!stall) begin
      // xret is NOT killed here (unlike branches/jumps): it must retire at
      // WB for its CSR effects (MPIE/MPP/SPIE/SPP). It is harmless downstream
      // (no mem op, rd=x0) while pc/F/D already redirected around it.
      if (flush_redirect & ~(redirect & is_xret)) begin
        ex_pkt <= '0;
      end else begin
        ex_pkt.valid <= valid_d;
        ex_pkt.pc    <= pc_d;
        ex_pkt.instr <= instr_d;
        ex_pkt.ctrl  <= dc;
        // Fold decompressor-illegal into the control illegal bit so the
        // EX-stage trap logic catches reserved RVC encodings. The
        // decompressor already substitutes a NOP payload, so no register
        // or memory side-effect can occur before the trap flushes.
        ex_pkt.ctrl.illegal <= dc.illegal | illegal_c_d;
        ex_pkt.is_c <= is_c_d;
        ex_pkt.illegal_c <= illegal_c_d;
        ex_pkt.fault_f <= fault_d;
        ex_pkt.fcause <= fcause_d;
        ex_pkt.fva <= fva_d;
        ex_pkt.rs1   <= rf_rdata1;
        ex_pkt.rs2   <= rf_rdata2;
        // FP operands are latched here (with WB->ID bypass already applied)
        // so the multi-cycle FPU holds stable inputs for its whole run.
        ex_pkt.fa    <= fp_rf1;
        ex_pkt.fb    <= fp_rf2;
        ex_pkt.fc    <= fp_rf3;
        ex_pkt.imm   <= imm;
      end
    end
  end

  assign rs1_x = ex_pkt.rs1;
  assign rs2_x = ex_pkt.rs2;
  assign rd_x = ex_pkt.ctrl.rd;

  // Forwarding source from the MEM stage: a load's result is its read data
  // (latched in load_data_q once the AXI read completes), not its ALU address;
  // any other instruction forwards its ALU/MDU/FPU result.
  logic [63:0] mem_fwd_data;
  assign mem_fwd_data = mem_pkt.is_load ? mem_rdata_aligned : mem_alu_y;
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

  always_comb begin
    case (fwd_a)
      2'd1: rs1_fwd = mem_fwd_data;
      2'd2: rs1_fwd = wb_data_w;
      default: rs1_fwd = ex_pkt.rs1;
    endcase
    case (fwd_b)
      2'd1: rs2_fwd = mem_fwd_data;
      2'd2: rs2_fwd = wb_data_w;
      default: rs2_fwd = ex_pkt.rs2;
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

  assign branch_taken = ex_pkt.valid & ex_pkt.ctrl.is_branch & branch_resolved;
  assign branch_target = (ex_pkt.ctrl.is_jal | ex_pkt.ctrl.is_jalr) ?
                         (alu_a + alu_b) : (ex_pkt.pc + ex_pkt.imm);

  // xRET redirects to epc (mret/sret previously fell through, which only
  // worked when the target happened to be adjacent).
  logic is_xret;
  assign is_xret = ex_pkt.ctrl.is_mret | ex_pkt.ctrl.is_sret;
  assign redirect = ex_pkt.valid & (ex_pkt.ctrl.is_branch & branch_resolved |
                                    ex_pkt.ctrl.is_jal | ex_pkt.ctrl.is_jalr |
                                    is_xret);
  assign redirect_target = is_xret ? epc : branch_target;

  assign mem_is_load_x = ((ex_pkt.ctrl.lsu_op >= LSU_LB) & (ex_pkt.ctrl.lsu_op <= LSU_LWU)) |
                         (ex_pkt.ctrl.lsu_op == LSU_LR) | (ex_pkt.ctrl.lsu_op == LSU_AMO);
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
  always_comb begin
    ex_result = alu_y;
    if (is_mdu_op(ex_pkt.ctrl.alu_op))
      ex_result = mdu_res;
    if (ex_pkt.ctrl.fpu_op != FPU_NONE) ex_result = fpu_res;
    // JAL/JALR link: return address is the next sequential PC, which is
    // pc+2 for a compressed instruction and pc+4 otherwise.
    if (ex_pkt.ctrl.is_jal | ex_pkt.ctrl.is_jalr)
      ex_result = ex_pkt.pc + (ex_pkt.is_c ? 64'd2 : 64'd4);
  end

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
  assign ex_mem_valid = ex_pkt.valid &
      (mem_is_load_x | mem_is_store_x | ex_is_amo |
       (ex_pkt.ctrl.lsu_op == LSU_SC));
  assign ex_mem_rd = mem_is_load_x;
  assign ex_mem_wr = mem_is_store_x | ex_is_amo |
                     ((ex_pkt.ctrl.lsu_op == LSU_SC) & ex_sc_success);
  logic        mmu_hit_d, mmu_miss_d, mmu_fault_d;
  logic [47:0] mmu_pa_d;
  logic [4:0]  mmu_cause_d;

  // SFENCE.VMA retires with rs1 (VA) in csr_wdata and rs2 (ASID) in
  // rs2v; x0 on either side means "all". The selective TLB flush fires at
  // retire (ordered with the L1D drain); F/D refetch below re-translates.
  mmu #(.ADDR_W(48), .TLB_ENTRIES(32)) u_mmu (
    .clk(clk), .rst_n(rst_n),
    .satp_i(csr_satp), .mstatus_i(csr_mstatus), .priv_i(priv),
    .flush_all_i(satp_we_o),
    .flush_sel_i(sfence_o),
    .flush_va_i(wb_pkt.csr_wdata),
    .flush_asid_i(wb_pkt.rs2v[15:0]),
    .flush_has_va_i(wb_pkt.ctrl.rs1 != 5'd0),
    .flush_has_asid_i(wb_pkt.ctrl.rs2 != 5'd0),
    .va_f_i(fetch_va), .priv_f_i(priv),
    .hit_f_o(mmu_hit_f), .pa_f_o(mmu_pa_f), .miss_f_o(mmu_miss_f),
    .fault_f_o(mmu_fault_f), .cause_f_o(mmu_cause_f),
    .va_d_i(ex_va_full), .priv_d_i(eff_priv_d),
    .rd_d_i(ex_mem_rd), .wr_d_i(ex_mem_wr),
    .valid_d_i(ex_mem_valid),
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
                         lr_valid_q & (lr_addr_q == mmu_pa_d);
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
    // VA low 48 bits, identical to the old direct assignment.
    mem_pkt_n.mem_addr = {16'd0, mmu_pa_d};
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

  // axi_pending marks the in-flight transaction of the current mem_pkt so
  // that only its own completion (mem_ack) is interpreted as this load's/
  // store's response. axi_issued suppresses a re-issue of the same
  // transaction: once the AXI master has accepted a load/store request it
  // stays asserted until the load/store leaves the MEM stage (the pipeline
  // advances mem_pkt), so a completed transaction cannot be re-driven. lsu_busy
  // is raised when a load/store/atomic enters MEM and drops when its final
  // transaction's own ack returns, unstalling the pipeline so it drains to WB.
  // AMO is two transactions (read old, write new): amo_wr_q tracks the phase.
  logic amo_wr_q;
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      mem_pkt     <= '0;
      lsu_busy    <= 1'b0;
      axi_issued  <= 1'b0;
      axi_pending <= 1'b0;
      lr_valid_q  <= 1'b0;
      lr_addr_q   <= '0;
      amo_wr_q    <= 1'b0;
    end else if (trap) begin
      mem_pkt     <= '0;
      lsu_busy    <= 1'b0;
      axi_issued  <= 1'b0;
      axi_pending <= 1'b0;
      lr_valid_q  <= 1'b0;
      amo_wr_q    <= 1'b0;
    end else if (!stall) begin
      if (ex_pkt.valid)
        mem_pkt <= mem_pkt_n;
      else
        mem_pkt <= '0;
      if (mem_pkt_n.valid & (mem_pkt_n.is_store | mem_pkt_n.is_load)) begin
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
        if (mem_pkt_n.valid & (mem_pkt_n.ctrl.lsu_op == LSU_SC))
          lr_valid_q <= 1'b0;
      end
    end else begin
      // Pipeline stalled (lsu_busy holds it). Issue the AXI request once and
      // keep it issued until the load/store leaves MEM; clear lsu_busy only on
      // the final transaction's own completion so the pipeline can then drain.
      if (mem_req & mem_ready) begin
        axi_issued  <= 1'b1;
        axi_pending <= 1'b1;
      end
      if (axi_pending & mem_ack) begin
        // LR sets the reservation when its read returns.
        if (mem_pkt.valid & (mem_pkt.ctrl.lsu_op == LSU_LR)) begin
          lr_valid_q  <= 1'b1;
          lr_addr_q   <= mem_pkt.mem_addr;
          lsu_busy    <= 1'b0;
          axi_pending <= 1'b0;
        // AMO read phase: advance to write phase, re-arm issue, stay busy.
        end else if (mem_pkt.valid & (mem_pkt.ctrl.lsu_op == LSU_AMO) & ~amo_wr_q) begin
          amo_wr_q    <= 1'b1;
          axi_issued  <= 1'b0;
          axi_pending <= 1'b0;
        end else begin
          lsu_busy    <= 1'b0;
          axi_pending <= 1'b0;
        end
      end
      // SC (success or fail) consumes the reservation once it leaves MEM;
      // the drain happens via fetch_done path clearing busy above, but flag
      // the clear here too for the success path that just acked.
      if (axi_pending & mem_ack & mem_pkt.valid &
          (mem_pkt.ctrl.lsu_op == LSU_SC))
        lr_valid_q <= 1'b0;
    end
  end

  assign rd_m = mem_pkt.ctrl.rd;
  assign reg_we_m = mem_pkt.valid &
                   ((mem_pkt.ctrl.wb_sel == WB_INT) | (mem_pkt.ctrl.wb_sel == WB_MEM)) &
                   (mem_pkt.ctrl.rd != 5'd0);
  // f0 is a real FP register (only x0 is hardwired zero), so FP writes
  // must not be suppressed for rd==0.
  assign fp_we_m = mem_pkt.valid & (mem_pkt.ctrl.wb_sel == WB_FP);
  assign mem_alu_y = mem_pkt.alu_res;

  // mem_req is asserted only until the AXI master accepts the load/store
  // request (axi_issued). Staying asserted past acceptance would let the
  // shared master re-issue the same transaction after it completes (e.g. a
  // duplicate store write whose B response later arrives as a stale ack and
  // corrupts a following load's lsu_busy). axi_issued clears when the
  // transaction's ack returns, readying for the next load/store.
  // AMO is read-then-write: we=0 in the read phase (amo_wr_q==0), we=1 with
  // the computed new value in the write phase.
  logic axi_issued;
  logic mem_is_amo_w;
  assign mem_is_amo_w = mem_pkt.valid & (mem_pkt.ctrl.lsu_op == LSU_AMO) & amo_wr_q;
  logic [63:0] amo_old_aligned;
  assign amo_old_aligned = align_load(load_data_q, 3'b0, (mem_pkt.ctrl.funct3 == 3'b011) ? LSU_LD : LSU_LW);
  logic [63:0] amo_new;
  assign amo_new = amo_compute(amo_old_aligned, mem_pkt.rs2, mem_pkt.ctrl.amo_op,
                               (mem_pkt.ctrl.funct3 == 3'b011));
  // No new data issue inside the fence window (a younger MEM op waits;
  // lsu_busy already stalls the pipe, and the drain needs no competition).
  assign mem_req   = mem_pkt.valid & (mem_pkt.is_store | mem_pkt.is_load) & ~axi_issued &
                     ~vm_fence_active;
  // AMO read phase must issue with we=0 (the entry is_store bit is 1, so it
  // cannot be used directly); write phase uses the computed amo_new.
  assign mem_we    = (mem_pkt.ctrl.lsu_op == LSU_AMO) ? amo_wr_q : mem_pkt.is_store;
  assign mem_addr  = mem_pkt.mem_addr;
  assign mem_be    = mem_pkt.be;
  assign mem_wdata = mem_is_amo_w ? (amo_new << (mem_pkt.mem_addr[2:0]*8)) : mem_pkt.store_data;
  assign mem_lock  = mem_pkt.lock;

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

  // The load read data is latched when THIS load's own AXI transaction
  // completes (axi_pending drop), not on any dmem ack. The shared AXI port
  // can deliver a stale ack (e.g. a prior store's B response) while a load is
  // in MEM with the bus read data still holding a fetch word; latching on a
  // bare mem_ack would capture the wrong value. axi_pending is asserted for
  // the current mem_pkt's transaction and cleared only by its own ack.
  // LR/AMO widths come from funct3 (010=W, 011=D); AMO latches only in its
  // read phase (write ack must not overwrite the old value in load_data_q).
  logic [63:0] load_data_q;
  logic        axi_pending;
  logic        amo_read_ack;
  assign amo_read_ack = mem_pkt.valid & (mem_pkt.ctrl.lsu_op == LSU_AMO) & ~amo_wr_q;
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) load_data_q <= '0;
    else if (axi_pending & mem_ack & mem_pkt.valid & mem_pkt.is_load &
             (mem_pkt.ctrl.lsu_op != LSU_AMO | amo_read_ack))
      load_data_q <= align_load(mem_rdata, mem_pkt.mem_addr[2:0],
        ((mem_pkt.ctrl.lsu_op == LSU_LR) | (mem_pkt.ctrl.lsu_op == LSU_AMO)) ?
          ((mem_pkt.ctrl.funct3 == 3'b011) ? LSU_LD : LSU_LW) :
          mem_pkt.ctrl.lsu_op);
  end
  always_comb begin
    mem_rdata_aligned = load_data_q;
  end

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
  end

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) wb_pkt <= '0;
    else if (!stall) wb_pkt <= wb_pkt_n;
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
      if (!stall && wb_pkt_n.valid)
        $fwrite(cosim_f, "C %h %0d %h %b %b %0d %h %0d\n",
                wb_pkt_n.pc, wb_pkt_n.rd, wb_pkt_n.data, wb_pkt_n.we,
                wb_pkt_n.fp_we, wb_pkt_n.rd, wb_pkt_n.data, priv);
      if (trap)
        $fwrite(cosim_f, "T %h %0d\n", ex_pkt.pc, cause);
      // Completed memory writes only (mem_we excludes AMO read phases
      // and failed SCs, matching what actually reaches memory).
      if (axi_pending & mem_ack & mem_pkt.valid & mem_we)
        $fwrite(cosim_f, "M %h %h %h %h\n",
                mem_pkt.pc, mem_pkt.mem_addr[47:0], mem_pkt.be, mem_wdata);
      $fflush(cosim_f);
    end
  end
  `endif

  // FENCE.I retires in order at WB; the pulse may stretch across a stall
  // (WB holds), which is harmless for the idempotent L1I invalidate.
  assign fence_i_o = wb_pkt.valid & wb_pkt.ctrl.fence_i;
  assign sfence_o = wb_pkt.valid & wb_pkt.ctrl.is_sfence;
  assign satp_we_o = wb_pkt.valid & wb_pkt.ctrl.writes_csr &
                     (wb_pkt.ctrl.csr_addr == CSR_SATP);
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

  logic [4:0] fcsr_fflags_we;
  logic [4:0] fcsr_fflags;
  assign fcsr_fflags_we = wb_pkt.valid & wb_pkt.ctrl.is_fp & (wb_pkt.ctrl.fpu_op != FPU_NONE);
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
    .trap_pc(ex_pkt.pc),
    .cause(cause), .trap(trap),
    .tval_valid(trap_is_fault), .tval(trap_tval),
    .mret(wb_pkt.ctrl.is_mret), .sret(wb_pkt.ctrl.is_sret),
    .epc(epc), .tvec(tvec),
    .new_priv(new_priv),
    .timer_irq(timer_irq), .soft_irq(soft_irq), .ext_irq(ext_irq),
    .irq_pending(irq_pending),
    .fi_we(), .fs_mstatus(),
    .fcsr_fflags_we(fcsr_fflags_we),
    .fcsr_fflags_in(wb_pkt.fflags),
    .fflags(fcsr_fflags),
    .frm(frm),
    .mstatus_o(csr_mstatus),
    .satp_o(csr_satp),
    .sstatus_o(csr_sstatus),
    .trap_deleg_o(csr_trap_deleg)
  );

  // Fault plumbing for mtval: fetch bubble carries its VA, data faults
  // use the faulting EX virtual address.
  logic       trap_is_fault;
  logic [63:0] trap_tval;
  assign trap_is_fault = (ex_pkt.valid & ex_pkt.fault_f) | data_fault;
  assign trap_tval     = (ex_pkt.valid & ex_pkt.fault_f) ? ex_pkt.fva : ex_va_full;

  logic       data_fault;
  logic [4:0] data_cause;
  assign data_fault = ex_mem_valid & mmu_fault_d;
  assign data_cause = mmu_cause_d;

  always_comb begin
    trap = 1'b0; cause = 4'd0;
    if (ex_pkt.valid) begin
      if (ex_pkt.fault_f) begin
        trap = 1'b1; cause = ex_pkt.fcause;
      end else if (ex_pkt.ctrl.illegal) begin
        trap = 1'b1; cause = CAUSE_ILLEGAL_INSN;
      end else if (ex_pkt.ctrl.is_ecall) begin
        trap = 1'b1; cause = (priv == PRIV_M) ? CAUSE_M_ECALL :
                              (priv == PRIV_S) ? CAUSE_SUP_ECALL : CAUSE_USER_ECALL;
      end else if (ex_pkt.ctrl.is_ebreak) begin
        trap = 1'b1; cause = CAUSE_BREAKPOINT;
      end else if (data_fault) begin
        trap = 1'b1; cause = data_cause;
      end
    end
  end

endmodule
