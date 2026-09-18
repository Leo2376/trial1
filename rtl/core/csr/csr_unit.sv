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
  input  logic [XLEN-1:0]   pc,
  input  logic [4:0]        cause,
  input  logic              trap,
  input  logic              tval_valid,
  input  logic [XLEN-1:0]   tval,
  input  logic              mret,
  input  logic              sret,
  output logic [XLEN-1:0]   epc,
  output logic [XLEN-1:0]   tvec,
  output logic [1:0]        new_priv,
  input  logic              timer_irq,
  input  logic              soft_irq,
  input  logic              ext_irq,
  output logic             irq_pending,
  output logic             fi_we,
  output logic              fs_mstatus,
  output logic [4:0]        fcsr_fflags_we,
  input  logic [4:0]        fcsr_fflags_in,
  output logic [4:0]        fflags,
  output logic [2:0]        frm
);
  import rtl_core_pkg::*;

  logic [XLEN-1:0] mstatus, mie, mtvec, mepc, mcause, mtval, mip, mscratch;
  logic [XLEN-1:0] sstatus, sie, stvec, sepc, scause, stval, sip, sscratch;
  logic [XLEN-1:0] mcycle, minstret;
  logic [XLEN-1:0] fcsr;
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
      CSR_MSCRATCH: v = mscratch;
      CSR_MCYCLE:   v = mcycle;
      CSR_CYCLE:    v = mcycle;
      CSR_MINSTRET: v = minstret;
      CSR_INSTRET:  v = minstret;
      CSR_MVENDORID:v = '0;
      CSR_MARCHID:  v = '0;
      CSR_MIMPID:   v = '0;
      CSR_MHARTID:  v = hartid;
      CSR_SSTATUS:  v = sstatus;
      CSR_SIE:      v = sie;
      CSR_STVEC:    v = stvec;
      CSR_SEPC:     v = sepc;
      CSR_SCAUSE:   v = scause;
      CSR_STVAL:    v = stval;
      CSR_SIP:      v = sip;
      CSR_SSCRATCH: v = sscratch;
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
      mie      <= '0; mtvec <= '0; mepc <= '0; mcause <= '0; mtval <= '0;
      mip      <= '0; mscratch <= '0;
      sstatus  <= '0; sie <= '0; stvec <= '0; sepc <= '0; scause <= '0;
      stval    <= '0; sip <= '0; sscratch <= '0;
      mcycle   <= '0; minstret <= '0; fcsr <= '0;
    end else if (!flush) begin
      mcycle   <= mcycle + 64'd1;
      minstret <= minstret + 64'd1;
      mip[7]  <= timer_irq;
      mip[3]  <= soft_irq;
      mip[11] <= ext_irq;

      if (trap) begin
        mepc   <= pc;
        mcause <= {51'd0, cause};
        mtval  <= tval_valid ? tval : '0;
        mstatus <= {mstatus[XLEN-1:12], 2'b00, mstatus[3:0]};
        new_priv <= PRIV_M;
      end else if (mret) begin
        mstatus[3:0] <= mstatus[7:4];
        new_priv <= mstatus[7:4];
      end else if (sret) begin
        new_priv <= PRIV_S;
      end else if (csr_op_we) begin
        case (csr_addr)
          CSR_MSTATUS:  mstatus  <= csr_wval;
          CSR_MIE:      mie      <= csr_wval;
          CSR_MTVEC:    mtvec    <= csr_wval;
          CSR_MEPC:     mepc     <= csr_wval;
          CSR_MCAUSE:  mcause   <= csr_wval;
          CSR_MTVAL:    mtval    <= csr_wval;
          CSR_MIP:      mip      <= csr_wval;
          CSR_MSCRATCH: mscratch <= csr_wval;
          CSR_SSTATUS:  sstatus  <= csr_wval;
          CSR_SIE:      sie      <= csr_wval;
          CSR_STVEC:    stvec    <= csr_wval;
          CSR_SEPC:     sepc     <= csr_wval;
          CSR_SCAUSE:   scause   <= csr_wval;
          CSR_STVAL:    stval    <= csr_wval;
          CSR_SIP:      sip      <= csr_wval;
          CSR_SSCRATCH: sscratch <= csr_wval;
          CSR_FCSR:     fcsr     <= {56'd0, csr_wval[7:0]};
          CSR_FFLAGS:   fcsr[4:0]<= csr_wval[4:0];
          CSR_FRM:      fcsr[7:5] <= csr_wval[2:0];
          default: ;
        endcase
      end

      if (fcsr_fflags_we) fcsr[4:0] <= fcsr[4:0] | fcsr_fflags_in;
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
  assign epc = (priv == PRIV_M) ? mepc : sepc;
  assign tvec = (priv == PRIV_M) ? mtvec : stvec;
  assign irq_pending = (mip[7] & mie[7]) | (mip[3] & mie[3]) | (mip[11] & mie[11]);
  assign fi_we = 1'b0;
  assign fs_mstatus = mstatus[14:13];
  assign fflags = fcsr[4:0];
  assign frm = fcsr[7:5];

endmodule
