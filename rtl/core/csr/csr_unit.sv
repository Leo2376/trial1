module csr_unit #(
  parameter int XLEN = 64
) (
  input  logic              clk,
  input  logic              rst_n,
  input  logic              flush,
  input  logic [1:0]        priv,
  input  logic [XLEN-1:0]   hartid,
  input  logic              csr_we,
  input  logic [11:0]       csr_addr,
  input  logic [11:0]       csr_raddr,
  input  logic [XLEN-1:0]   csr_wdata,
  input  logic [1:0]        csr_op,
  input  logic [4:0]        csr_rs1,
  output logic [XLEN-1:0]   csr_rdata,
  // Trap record (EX-stage faulting instruction; sampled with trap).
  input  logic [XLEN-1:0]   trap_pc,
  input  logic [4:0]        cause,
  input  logic              trap,
  input  logic              tval_valid,
  input  logic [XLEN-1:0]   tval,
  input  logic              mret,
  input  logic              sret,
  // EX-stage xret kind for the redirect target: epc must follow the
  // instruction (mret->mepc, sret->sepc), NOT ambient priv. A
  // backend-stalled xret re-resolves after its own priv switch; muxing on
  // priv would then redirect to the wrong epc (e.g. mret->sepc==0).
  input  logic              ex_mret_i,
  input  logic              ex_sret_i,
  output logic [XLEN-1:0]   epc,
  output logic [XLEN-1:0]   tvec,
  output logic [1:0]        new_priv,
  input  logic              timer_irq,
  input  logic              soft_irq,
  input  logic              ext_irq,
  output logic             irq_pending,
  // Interrupt trap at an instruction boundary (core-driven): cause +
  // take flag. mcause/scause record the interrupt bit (XLEN-1).
  output logic             irq_take_o,
  output logic [4:0]       irq_cause_o,
  // This trap is an interrupt (not a sync fault): delegate via mideleg
  // and set the mcause/scause interrupt bit.
  input  logic              trap_irq_i,
  output logic             fi_we,
  output logic              fs_mstatus,
  output logic [4:0]        fcsr_fflags_we,
  input  logic [4:0]        fcsr_fflags_in,
  output logic [4:0]        fflags,
  output logic [2:0]        frm,
  // VM/privilege state for the MMU (Sv39 stage).
  output logic [XLEN-1:0]   mstatus_o,
  output logic [XLEN-1:0]   satp_o,
  // SSTATUS for SRET privilege (SPP bit 8); composed view not needed here.
  output logic [XLEN-1:0]   sstatus_o,
  // Whether the live trap input delegates (for the core priv switch).
  output logic              trap_deleg_o,
  // H extension: virtualization state + stage-2 context for the MMU.
  output logic              virt_o,
  output logic [XLEN-1:0]   vsatp_o,
  output logic [XLEN-1:0]   hgatp_o,
  output logic [XLEN-1:0]   vsstatus_o,
  output logic              trap_to_vs_o,
  output logic [1:0]        new_virt_priv_o,
  output logic              new_virt_o,
  output logic [XLEN-1:0]   hstatus_o,
  // RVV v0: vset retire commit + vector-fault vstart + state readback.
  input  logic              vset_we_i,
  input  logic [7:0]        vset_vl_i,
  input  logic [10:0]       vset_vtype_i,
  input  logic              vset_vill_i,
  input  logic              vec_trap_i,
  input  logic [7:0]        vec_idx_i,
  output logic [7:0]        vl_o,
  output logic [63:0]       vtype_o,
  output logic [7:0]        vstart_o
);
  import rtl_core_pkg::*;

  logic [XLEN-1:0] mstatus, mie, mtvec, mepc, mcause, mtval, mip, mscratch;
  logic [XLEN-1:0] medeleg, mideleg;
  logic [XLEN-1:0] mtval2, mtinst;
  // H extension state. virt_q=1 means running in VS/VU guest.
  logic virt_q;
  logic [XLEN-1:0] hstatus, hedeleg, hideleg, hie, hcounteren, hgeie;
  logic [XLEN-1:0] htval, htinst, hgatp, hvip;
  logic [XLEN-1:0] vsstatus, vsie, vstvec, vsscratch, vsepc, vscause, vstval;
  logic [XLEN-1:0] vsip, vsatp;
  // RVV v0 skeleton state (SEW=8/LMUL=1 only; see vset commit below).
  logic [7:0]  v_vstart, v_vl;
  logic [63:0] v_vtype;
  // Delegation for the live trap input.
  // M-mode never delegates. Guest (V=1) traps consult hedeleg/hideleg
  // first (to VS); otherwise they fall to HS. HS/U (V=0) traps consult
  // medeleg/mideleg (to HS); otherwise to M.
  logic trap_to_vs, trap_to_hs;
  logic trap_deleg;
  assign trap_to_vs = virt_q && (priv != PRIV_M) &&
                      (trap_irq_i ? hideleg[cause] : hedeleg[cause]);
  assign trap_to_hs = !trap_to_vs && (priv != PRIV_M) &&
                      (trap_irq_i ? mideleg[cause] : medeleg[cause]);
  assign trap_deleg = trap_to_vs || trap_to_hs;
  assign trap_deleg_o = trap_deleg;
  assign trap_to_vs_o = trap_to_vs;
  // Next privilege + virt, combinational so the core tracks transitions
  // (trap, mret, sret) on the committing edge. Held otherwise.
  logic [1:0] new_priv_comb;
  logic new_virt_comb;
  // SRET target: in VS guest uses vsstatus.SPP; in HS uses hstatus.SPV/SPVP
  // (return to guest) or sstatus.SPP (stay in HS/U).
  logic sret_to_virt;
  logic [1:0] sret_priv;
  assign sret_to_virt = !virt_q && hstatus[7];
  assign sret_priv = virt_q ? (vsstatus[8] ? PRIV_S : PRIV_U) :
                     sret_to_virt ? (hstatus[8] ? PRIV_S : PRIV_U) :
                     (sstatus[8] ? PRIV_S : PRIV_U);
  assign new_priv_comb =
    trap ? (trap_to_vs ? PRIV_S : (trap_to_hs ? PRIV_S : PRIV_M)) :
    mret ? ((mstatus[12:11] == 2'b10) ? PRIV_U : priv_e'(mstatus[12:11])) :
    sret ? sret_priv : new_priv;
  assign new_virt_comb =
    trap ? (trap_to_vs ? 1'b1 : 1'b0) :
    mret ? mstatus[39] :
    sret ? (virt_q ? 1'b1 : hstatus[7]) : virt_q;
  assign new_virt_o = new_virt_comb;
  assign new_virt_priv_o = new_priv_comb;
  // new_priv output driven below (flop holding new_priv_comb).
  logic [XLEN-1:0] sstatus, sie, stvec, sepc, scause, stval, sip, sscratch;
  logic [XLEN-1:0] mcycle, minstret;
  logic [XLEN-1:0] fcsr;
  logic [XLEN-1:0] satp;
  logic [XLEN-1:0] csr_rdata_q;

  // CSR write semantics: CSRRW writes the operand; CSRRS sets (OR) the bits,
  // CSRRC clears (AND-NOT) the bits. CSRRS/CSRRC with rs1==0 perform no write
  // (read-only access). The effective write value is computed from the old
  // register value and the operand according to the op.
  logic        csr_op_we;
  logic [XLEN-1:0] csr_wval;
  always_comb begin
    csr_op_we = csr_we;
    csr_wval  = csr_wdata;
    case (csr_op)
      2'b01: begin // CSRRW
        csr_op_we = csr_we;
        csr_wval  = csr_wdata;
      end
      2'b10: begin // CSRRS
        csr_op_we = csr_we & (csr_rs1 != 5'd0);
        csr_wval  = csr_val(csr_addr) | csr_wdata;
      end
      2'b11: begin // CSRRC
        csr_op_we = csr_we & (csr_rs1 != 5'd0);
        csr_wval  = csr_val(csr_addr) & ~csr_wdata;
      end
      default: begin
        csr_op_we = csr_we;
        csr_wval  = csr_wdata;
      end
    endcase
  end
  // Current value of a CSR at the write port's address, including the
  // fflags an FP op retires in WB this same cycle (accumulated into
  // fcsr[4:0] at the WB posedge, so a read/modify in this cycle must see it).
  function automatic logic [XLEN-1:0] csr_val(input logic [11:0] a);
    logic [XLEN-1:0] v;
    case (a)
      CSR_MSTATUS:  v = mstatus;
      CSR_MISA:     v = 64'h80000000001411AD;
      CSR_MIE:      v = mie;
      CSR_MTVEC:    v = mtvec;
      CSR_MEPC:     v = mepc;
      CSR_MCAUSE:   v = mcause;
      CSR_MTVAL:    v = mtval;
      CSR_MIP:      v = mip;
      CSR_MEDELEG:  v = medeleg;
      CSR_MIDELEG:  v = mideleg;
      CSR_MSCRATCH: v = mscratch;
      CSR_MCYCLE:   v = mcycle;
      CSR_CYCLE:    v = mcycle;
      CSR_MINSTRET: v = minstret;
      CSR_INSTRET:  v = minstret;
      CSR_MVENDORID:v = '0;
      CSR_MARCHID:  v = '0;
      CSR_MIMPID:   v = '0;
      CSR_MHARTID:  v = hartid;
      // SSTATUS is a restricted view: FS[14:13]/XS[16:15]/SUM[18]/MXR[19]
      // live in mstatus and are overlaid here (sstatus flop holds the
      // S-only bits: SIE/SPIE/UBE/SPP/VS). UXL[33:32] hardwires to 2 (RV64).
      // RVV: mstatus.VS[10:9] is aliased the same way (sstatus/vsstatus
      // writes route through; vset sets Dirty).
      CSR_SSTATUS:  v = ((sstatus & ~64'h0000_0003_000F_6600) |
                         (mstatus & 64'h0000_0000_000F_6600)) |
                        64'h0000_0002_0000_0000;
      CSR_SATP:     v = satp;
      CSR_SIE:      v = sie;
      CSR_STVEC:    v = stvec;
      CSR_SEPC:     v = sepc;
      CSR_SCAUSE:   v = scause;
      CSR_STVAL:    v = stval;
      CSR_SIP:      v = sip;
      CSR_SSCRATCH: v = sscratch;
      CSR_MTVAL2:   v = mtval2;
      CSR_MTINST:   v = mtinst;
      CSR_HSTATUS:  v = hstatus;
      CSR_HEDELEG:  v = hedeleg;
      CSR_HIDELEG:  v = hideleg;
      CSR_HIE:      v = hie;
      CSR_HCOUNTEREN: v = hcounteren;
      CSR_HGEIE:    v = hgeie;
      CSR_HTVAL:    v = htval;
      CSR_HTINST:   v = htinst;
      CSR_HGATP:    v = hgatp;
      CSR_HIP:      v = {hvip[63:11], 1'b0, hvip[9:7], 1'b0, hvip[5:3], 1'b0, hvip[1], 1'b0};
      CSR_HVIP:     v = hvip;
      CSR_HGEIP:    v = '0;
      CSR_VSSTATUS: v = ((vsstatus & ~64'h0000_0003_000F_6600) |
                         (mstatus & 64'h0000_0000_000F_6600)) |
                        64'h0000_0002_0000_0000;
      CSR_VSIE:     v = vsie;
      CSR_VSTVEC:   v = vstvec;
      CSR_VSSCRATCH: v = vsscratch;
      CSR_VSEPC:    v = vsepc;
      CSR_VSCAUSE:  v = vscause;
      CSR_VSTVAL:   v = vstval;
      CSR_VSIP:     v = vsip | (hvip & 64'h0000_0000_0000_0444);
      CSR_VSATP:    v = vsatp;
      CSR_VSTART:   v = {56'd0, v_vstart};
      CSR_VL:       v = {56'd0, v_vl};
      CSR_VTYPE:    v = v_vtype;
      CSR_FCSR:     v = (fcsr & ~64'd31) |
                        (fcsr_fflags_we ? {59'd0, fcsr[4:0] | fcsr_fflags_in}
                                        : {59'd0, fcsr[4:0]});
      CSR_FFLAGS:   v = {59'd0, fcsr_fflags_we ? (fcsr[4:0] | fcsr_fflags_in)
                                             : fcsr[4:0]};
      CSR_FRM:      v = {61'd0, fcsr[7:5]};
      default:      v = '0;
    endcase
    return v;
  endfunction

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      mstatus  <= {64'h0000000A00000000};
      medeleg <= '0; mideleg <= '0;
      new_priv <= PRIV_M;
      virt_q <= 1'b0;
      mie      <= '0; mtvec <= '0; mepc <= '0; mcause <= '0; mtval <= '0;
      mip      <= '0; mscratch <= '0;
      mtval2 <= '0; mtinst <= '0;
      sstatus  <= '0; sie <= '0; stvec <= '0; sepc <= '0; scause <= '0;
      stval    <= '0; sip <= '0; sscratch <= '0;
      hstatus <= '0; hedeleg <= '0; hideleg <= '0; hie <= '0;
      hcounteren <= '0; hgeie <= '0; htval <= '0; htinst <= '0;
      hgatp <= '0; hvip <= '0;
      vsstatus <= '0; vsie <= '0; vstvec <= '0; vsscratch <= '0;
      vsepc <= '0; vscause <= '0; vstval <= '0; vsip <= '0; vsatp <= '0;
      v_vstart <= '0; v_vl <= '0; v_vtype <= '0;
      mcycle   <= '0; minstret <= '0; fcsr <= '0;
      satp <= '0;
    end else begin
      mcycle   <= mcycle + 64'd1;
      minstret <= minstret + 64'd1;
      mip[7]  <= timer_irq;
      mip[3]  <= soft_irq;
      mip[11] <= ext_irq;

      // Trap entry is exempt from the flush gate (trap implies flush).
      new_priv <= new_priv_comb;
      virt_q <= new_virt_comb;
      if (trap) begin
        // RVV: a faulting vector op restarts at the faulting element.
        // The vstart update dirties mstatus.VS like any vector state change.
        if (vec_trap_i) begin
          v_vstart <= {56'd0, vec_idx_i};
          mstatus[10:9] <= 2'b11;
        end
        if (trap_to_vs) begin
          vsepc   <= trap_pc;
          vscause <= {trap_irq_i, 58'd0, cause};
          vstval  <= tval_valid ? tval : '0;
          vsstatus[8] <= priv[0];
          vsstatus[5] <= vsie[1];
          vsie        <= vsie & ~64'd2;
        end else if (trap_to_hs) begin
          sepc   <= trap_pc;
          scause <= {trap_irq_i, 58'd0, cause};
          stval  <= tval_valid ? tval : '0;
          sstatus[8] <= priv[0];      // SPP = previous priv (U->0, S->1)
          sstatus[5] <= sie[1];       // SPIE = SIE
          sie        <= sie & ~64'd2; // SIE = 0
          // Record guest state for SRET return.
          hstatus[7] <= virt_q;       // SPV = previous V
          hstatus[8] <= priv[0];      // SPVP = previous priv bit
          if (cause inside {5'd20, 5'd21, 5'd23})
            htval <= tval_valid ? {tval[63:2], 2'b0} : '0;
        end else begin
          mepc   <= trap_pc;
          mcause <= {trap_irq_i, 58'd0, cause};
          mtval  <= tval_valid ? tval : '0;
          mstatus[7]     <= mstatus[3];  // MPIE = MIE
          mstatus[3]     <= 1'b0;        // MIE = 0
          mstatus[12:11] <= priv;        // MPP = previous priv
          mstatus[39]    <= virt_q;      // MPV = previous V
          mstatus[38]    <= 1'b0;        // GVA (guest VA fault extra; kept 0)
          if (cause inside {5'd20, 5'd21, 5'd23})
            mtval2 <= tval_valid ? {tval[63:2], 2'b0} : '0;
        end
      end else if (mret) begin
        mstatus[3] <= mstatus[7];            // MIE = MPIE
        mstatus[7] <= 1'b1;                  // MPIE = 1
        if (mstatus[12:11] != PRIV_M) mstatus[12:11] <= PRIV_U;
        mstatus[39] <= 1'b0;                 // MPV clears on return
      end else if (sret) begin
        if (virt_q) begin
          vsie <= (vsie & ~64'd2) | {62'd0, vsstatus[5], 1'b0};
          vsstatus[5] <= 1'b1;
          vsstatus[8] <= 1'b0;
        end else if (hstatus[7]) begin
          // HS returning into the guest: clear SPV (V taken from it).
          hstatus[7] <= 1'b0;
          sie        <= (sie & ~64'd2) | {62'd0, sstatus[5], 1'b0};
          sstatus[5] <= 1'b1;
          sstatus[8] <= 1'b0;
        end else begin
          sie        <= (sie & ~64'd2) | {62'd0, sstatus[5], 1'b0}; // SIE = SPIE
          sstatus[5] <= 1'b1;  // SPIE = 1
          sstatus[8] <= 1'b0;  // SPP = U
        end
      end else if (!flush && vset_we_i) begin
        // RVV vsetvli/vsetivli retire: commit vl/vtype, reset vstart,
        // mark mstatus.VS Dirty. vill (unsupported vtype): vl=0, vtype.vill.
        v_vstart <= '0;
        if (vset_vill_i) begin
          v_vl    <= '0;
          v_vtype <= {1'b1, 63'd0};
        end else begin
          v_vl    <= vset_vl_i;
          v_vtype <= {1'b0, 55'd0, vset_vtype_i[7], vset_vtype_i[6],
                      vset_vtype_i[5:3], vset_vtype_i[2:0]};
        end
        mstatus[10:9] <= 2'b11;
      end else if (!flush && csr_op_we) begin
        case (csr_addr)
          CSR_MSTATUS:  mstatus  <= csr_wval;
          CSR_MEDELEG:  medeleg  <= csr_wval;
          CSR_MIDELEG:  mideleg  <= csr_wval;
          CSR_MIE:      mie      <= csr_wval;
          CSR_MTVEC:    mtvec    <= csr_wval;
          CSR_MEPC:     mepc     <= csr_wval;
          CSR_MCAUSE:   mcause   <= csr_wval;
          CSR_MTVAL:    mtval    <= csr_wval;
          CSR_MTVAL2:   mtval2   <= csr_wval;
          CSR_MTINST:   mtinst   <= csr_wval;
          CSR_MIP:      mip      <= csr_wval;
          CSR_MSCRATCH: mscratch <= csr_wval;
          CSR_HSTATUS:  hstatus  <= csr_wval;
          CSR_HEDELEG:  hedeleg  <= csr_wval;
          CSR_HIDELEG:  hideleg  <= csr_wval;
          CSR_HIE:      hie      <= csr_wval;
          CSR_HCOUNTEREN: hcounteren <= csr_wval;
          CSR_HGEIE:    hgeie    <= csr_wval;
          CSR_HTVAL:    htval    <= csr_wval;
          CSR_HTINST:   htinst   <= csr_wval;
          CSR_HGATP: begin
            hgatp[59:0] <= csr_wval[59:0];
            hgatp[63:60] <= ((csr_wval[63:60] == SATP_BARE) ||
                             (csr_wval[63:60] == SATP_SV39) ||
                             (csr_wval[63:60] == SATP_SV48)) ? csr_wval[63:60]
                                                            : SATP_BARE;
          end
          CSR_HVIP:     hvip     <= csr_wval & 64'h0000_0000_0000_0444;
          CSR_VSSTATUS: begin
            vsstatus <= csr_wval;
            mstatus[14:13] <= csr_wval[14:13];
            mstatus[16:15] <= csr_wval[16:15];
            mstatus[18]    <= csr_wval[18];
            mstatus[19]    <= csr_wval[19];
            mstatus[10:9]  <= csr_wval[10:9];
          end
          CSR_VSTART: begin
            v_vstart <= csr_wval[7:0];
            // Explicit vstart writes modify vector state -> VS Dirty.
            mstatus[10:9] <= 2'b11;
          end
          // VL/VTYPE are read-only (written by vsetvli/vsetivli retire).
          CSR_VSIE:      vsie     <= csr_wval;
          CSR_VSTVEC:    vstvec   <= csr_wval;
          CSR_VSSCRATCH: vsscratch <= csr_wval;
          CSR_VSEPC:     vsepc    <= csr_wval;
          CSR_VSCAUSE:   vscause  <= csr_wval;
          CSR_VSTVAL:    vstval   <= csr_wval;
          CSR_VSIP: begin
            vsip <= csr_wval;
            hvip <= (hvip & ~64'h444) | (csr_wval & 64'h444);
          end
          CSR_VSATP: begin
            vsatp[59:0]  <= csr_wval[59:0];
            vsatp[63:60] <= ((csr_wval[63:60] == SATP_BARE) ||
                             (csr_wval[63:60] == SATP_SV39) ||
                             (csr_wval[63:60] == SATP_SV48)) ? csr_wval[63:60]
                                                            : SATP_BARE;
          end
          CSR_SSTATUS: begin
            sstatus <= csr_wval;
            // FS/XS/SUM/MXR/VS alias mstatus; route them through.
            mstatus[14:13] <= csr_wval[14:13];
            mstatus[16:15] <= csr_wval[16:15];
            mstatus[18]    <= csr_wval[18];
            mstatus[19]    <= csr_wval[19];
            mstatus[10:9]  <= csr_wval[10:9];
          end
          CSR_SIE:      sie      <= csr_wval;
          CSR_STVEC:    stvec    <= csr_wval;
          CSR_SEPC:     sepc     <= csr_wval;
          CSR_SCAUSE:   scause   <= csr_wval;
          CSR_STVAL:    stval    <= csr_wval;
          CSR_SIP:      sip      <= csr_wval;
          CSR_SSCRATCH: sscratch <= csr_wval;
          CSR_SATP: begin
            // WARL MODE: Bare, Sv39 and Sv48 legal here.
            satp[59:0]  <= csr_wval[59:0];
            satp[63:60] <= ((csr_wval[63:60] == SATP_BARE) ||
                            (csr_wval[63:60] == SATP_SV39) ||
                            (csr_wval[63:60] == SATP_SV48)) ? csr_wval[63:60]
                                                           : SATP_BARE;
          end
          CSR_FCSR:     fcsr     <= {56'd0, csr_wval[7:0]};
          CSR_FFLAGS:   fcsr[4:0]<= csr_wval[4:0];
          CSR_FRM:      fcsr[7:5] <= csr_wval[2:0];
          default: ;
        endcase
      end

      if (!flush && fcsr_fflags_we) fcsr[4:0] <= fcsr[4:0] | fcsr_fflags_in;
    end
  end

  // CSR read: the reading instruction supplies its own address (csr_raddr)
  // while it is in MEM, one stage ahead of the WB instruction driving the
  // write port (csr_addr). A read of a CSR being written this same cycle, or
  // of fflags being accumulated by an FP op retiring in WB, must forward the
  // about-to-be-written value, not the stale register content.
  always_comb begin
    csr_rdata_q = csr_val(csr_raddr);
    // Same-cycle WB write bypass: only when the reader addresses the same
    // CSR the writer in WB is writing (or the FFLAGS/FCSR aliases).
    if (csr_op_we && (csr_raddr == csr_addr)) begin
      case (csr_raddr)
        CSR_FCSR:   csr_rdata_q = (csr_wval & ~64'd31) |
                                  (fcsr_fflags_we ? {59'd0, fcsr[4:0] | fcsr_fflags_in}
                                                  : {59'd0, fcsr[4:0]});
        CSR_FFLAGS: csr_rdata_q = {59'd0, csr_wval[4:0]} |
                                  (fcsr_fflags_we ? {59'd0, fcsr[4:0] | fcsr_fflags_in}
                                                  : 64'd0);
        CSR_FRM:    csr_rdata_q = {61'd0, csr_wval[2:0]};
        default:    csr_rdata_q = csr_wval;
      endcase
    end else if (csr_op_we && (csr_addr == CSR_FCSR) &&
                 (csr_raddr == CSR_FFLAGS)) begin
      csr_rdata_q = {59'd0, csr_wval[4:0]};
    end else if (csr_op_we && (csr_addr == CSR_FFLAGS) &&
                 (csr_raddr == CSR_FCSR)) begin
      csr_rdata_q = (fcsr & ~64'd31) | {59'd0, csr_wval[4:0]};
    end
  end

  assign csr_rdata = csr_rdata_q;
  // Redirect target for the EX-stage xret: mret uses mepc (V=MPV applies
  // to translation, not the address); sret uses vsepc when entering or
  // staying in the guest (V=1 now, or SPV=1 for HS->VS), else sepc.
  assign epc = ex_mret_i ? mepc :
               (ex_sret_i ? ((virt_q || hstatus[7]) ? vsepc : sepc) : mepc);
  // Trap vector follows the delegated target (VS > HS > M).
  logic [XLEN-1:0] tvec_base;
  assign tvec_base = trap_to_vs ? vstvec : (trap_to_hs ? stvec : mtvec);
  assign tvec = (tvec_base[1:0] == 2'b01) ?
                ({tvec_base[XLEN-1:2], 2'b0} + {57'd0, cause, 2'b00}) :
                tvec_base;
  assign irq_pending = (mip[7] & mie[7]) | (mip[3] & mie[3]) | (mip[11] & mie[11]);
  // Interrupt take: M lines as before; HS lines via mideleg; VS lines
  // (hvip inject, vsie enable, hideleg route) trap to VS when the guest
  // runs (V=1), else to HS when hideleg delegates. Priority within a
  // target: E(11/10) > S(3/2) > T(7/6). VS codes reuse S encodings with
  // the interrupt bit (mcause bit63 distinguishes via trap target).
  // VS pending uses hvip bits 10/6/2 (plus vsip alias writes).
  logic m11, m3, m7, s11, s3, s7, m_any, s_any;
  logic vs10, vs6, vs2, vs_any, vs_deleg;
  assign m11 = mip[11] & mie[11];
  assign m3  = mip[3]  & mie[3];
  assign m7  = mip[7]  & mie[7];
  assign m_any = (m11 | m3 | m7) & mstatus[3];
  assign s11 = mip[11] & mie[11] & mideleg[11];
  assign s3  = mip[3]  & mie[3]  & mideleg[3];
  assign s7  = mip[7]  & mie[7]  & mideleg[7];
  assign s_any = (s11 | s3 | s7) & sie[1];
  assign vs10 = ((hvip[10] | vsip[10]) & vsie[10]);
  assign vs6  = ((hvip[6]  | vsip[6])  & vsie[6]);
  assign vs2  = ((hvip[2]  | vsip[2])  & vsie[2]);
  assign vs_any = (vs10 | vs6 | vs2) & vsstatus[0];
  // VS lines routed to HS (not hideleg-delegated, mideleg-enabled):
  // taken in the guest (V=1) or seen by HS (V=0) with the VS cause.
  logic vs_hs10, vs_hs2, vs_hs6, vs_hs_any;
  assign vs_hs10 = vs10 & ~hideleg[10] & mideleg[10];
  assign vs_hs2  = vs2  & ~hideleg[2]  & mideleg[2];
  assign vs_hs6  = vs6  & ~hideleg[6]  & mideleg[6];
  assign vs_hs_any = (vs_hs10 | vs_hs2 | vs_hs6) & sie[1];
  // hideleg per-line: VS interrupt delegates to VS iff its bit set.
  function automatic logic [4:0] irq_prio(input logic l11, input logic l3,
                                          input logic l7);
    if (l11) return 5'd11;
    if (l3)  return 5'd3;
    return 5'd7;
  endfunction
  function automatic logic [4:0] virq_prio(input logic l10, input logic l2,
                                           input logic l6);
    if (l10) return 5'd10;
    if (l2)  return 5'd2;
    return 5'd6;
  endfunction
  always_comb begin
    irq_take_o = 1'b0;
    irq_cause_o = 5'd7;
    if (priv == PRIV_M && !virt_q) begin
      irq_take_o = m_any;
      irq_cause_o = irq_prio(m11, m3, m7);
    end else if (virt_q) begin
      // Guest running: VS interrupts (hideleg-gated) trap to VS first;
      // non-delegated VS lines trap to HS (VS cause, mideleg-gated).
      if (vs_any && (hideleg[10] & vs10 | hideleg[2] & vs2 | hideleg[6] & vs6)) begin
        irq_take_o = 1'b1;
        // pick highest enabled+delegated line (E > S > T)
        if (vs10 && hideleg[10]) irq_cause_o = 5'd10;
        else if (vs2 && hideleg[2]) irq_cause_o = 5'd2;
        else irq_cause_o = 5'd6;
      end else if (vs_hs_any) begin
        irq_take_o = 1'b1;
        if (vs_hs10) irq_cause_o = 5'd10;
        else if (vs_hs2) irq_cause_o = 5'd2;
        else irq_cause_o = 5'd6;
      end else if (s_any) begin
        irq_take_o = 1'b1;
        irq_cause_o = irq_prio(s11, s3, s7);
      end else begin
        irq_take_o = m_any;
        irq_cause_o = irq_prio(m11, m3, m7);
      end
    end else if (s_any || vs_hs_any) begin
      irq_take_o = 1'b1;
      // HS sees pending VS lines (non-delegated) with the VS cause;
      // ordinary HS lines keep seniority (existing behavior unchanged).
      if (s_any) begin
        irq_cause_o = irq_prio(s11, s3, s7);
      end else begin
        if (vs_hs10) irq_cause_o = 5'd10;
        else if (vs_hs2) irq_cause_o = 5'd2;
        else irq_cause_o = 5'd6;
      end
    end else begin
      irq_take_o = m_any;
      irq_cause_o = irq_prio(m11, m3, m7);
    end
  end
  assign fi_we = 1'b0;
  assign fs_mstatus = mstatus[14:13];
  assign fflags = fcsr[4:0];
  assign frm = fcsr[7:5];
  assign mstatus_o = mstatus;
  assign satp_o = satp;
  assign sstatus_o = sstatus;
  assign virt_o = virt_q;
  assign vsatp_o = vsatp;
  assign hgatp_o = hgatp;
  assign vsstatus_o = vsstatus;
  assign hstatus_o = hstatus;
  assign vl_o = v_vl;
  assign vtype_o = v_vtype;
  assign vstart_o = v_vstart;

endmodule
