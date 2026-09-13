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
  output logic [31:0]      dbg_pc
);
  import rtl_core_pkg::*;
  import rv64gch_memmap_pkg::RESET_PC;

  logic [XLEN-1:0] pc_f, pc_d, pc_x, pc_m;
  logic [31:0]     instr_f, instr_d;
  logic            valid_f, valid_d, valid_x, valid_m, valid_w;
  logic            is_c_f, is_c_d;
  logic            flush_all, flush_id, flush_ex;
  logic            stall;
  logic [1:0]      priv;

  ctrl_t           dc;
  logic [63:0]     imm;
  logic [4:0]      rs1_d, rs2_d, rs1_x, rs2_x, rd_x, rd_m, rd_w;
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
    logic [63:0] rs1;
    logic [63:0] rs2;
    logic [63:0] imm;
  } ex_pkt_t;
  ex_pkt_t ex_pkt, ex_pkt_n;

  typedef struct packed {
    logic        valid;
    logic [63:0] pc;
    ctrl_t       ctrl;
    logic [63:0] alu_res;
    logic [63:0] rs2;
    logic [63:0] mem_addr;
    logic        is_store;
    logic        is_load;
    logic [63:0] store_data;
    logic [7:0]  be;
    logic        lock;
  } mem_pkt_t;
  mem_pkt_t mem_pkt, mem_pkt_n;

  typedef struct packed {
    logic        valid;
    logic [63:0] pc;
    ctrl_t       ctrl;
    logic [63:0] data;
    logic [4:0]  rd;
    logic        we;
    logic        fp_we;
  } wb_pkt_t;
  wb_pkt_t wb_pkt, wb_pkt_n;

  assign dbg_pc = pc_d;

  assign priv = PRIV_M;

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
  logic [31:0] fetch_instr;
  logic [63:0] fetch_word_q;   // latched fetch word, held across stalls
  logic [63:0] fetch_pc_q;     // pc the latched word was fetched for
  logic        fetch_complete;  // fetch read returned, awaiting consumption
  logic        fetch_done;
  logic        fetch_busy;
  // A latched fetch result is only usable if it corresponds to the
  // current pc_f. Redirects/flushes change pc_f; a stale result from the
  // previous pc must not be consumed. Comparing the latched pc against
  // pc_f (using the word-aligned address) makes the skid buffer safe
  // across flushes without relying solely on flush_all clearing it.
  logic fetch_res_valid;
  assign fetch_res_valid = fetch_complete & (fetch_pc_q[47:3] == pc_f[47:3]);
  // Assemble the 32-bit instruction window from the latched fetched
  // 64-bit word based on pc_f[2:1]. A 32-bit (non-compressed) instruction
  // can straddle the 32-bit boundary inside the 64-bit fetch word when it
  // is located at byte offset 2 (pc_f[2:1] == 2'b01), so the lower and
  // upper halves must be stitched together. Compressed (16-bit)
  // instructions never straddle a 16-bit boundary, so the half-word
  // selected by pc_f[1] is always valid.
  always_comb begin
    unique case (pc_f[2:1])
      2'b00: fetch_instr = fetch_word_q[31:0];
      2'b01: fetch_instr = {fetch_word_q[47:32], fetch_word_q[31:16]};
      2'b10: fetch_instr = fetch_word_q[63:32];
      2'b11: fetch_instr = {16'b0, fetch_word_q[63:48]};
    endcase
  end
  // The decompressor inspects the lowest 16 bits of the assembled window.
  decompressor u_decomp (.cin(fetch_instr[15:0]), .iout(instr_expanded), .is_c(fetch_is_c));

  logic [31:0] instr_d_use;
  assign instr_d_use = fetch_is_c ? instr_expanded : fetch_instr;

  // fetch_done is a latched (level) signal gated by the result being valid
  // for the current pc and the pipeline being able to consume it. This
  // prevents a fetch completion pulse from being lost while the pipeline is
  // stalled (e.g. a load-use hazard or multi-cycle LSU access), which would
  // otherwise deadlock the core, while a stale result from a flushed pc is
  // ignored.
  assign fetch_done    = fetch_res_valid & ~stall;
  assign fetch_req     = valid_f & fetch_ready & ~stall & ~fetch_busy & ~fetch_res_valid;
  assign fetch_we      = 1'b0;
  assign fetch_addr    = pc_f;
  assign fetch_be      = 8'hFF;
  assign fetch_wdata   = '0;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      valid_f        <= 1'b1;
      fetch_busy     <= 1'b0;
      fetch_complete <= 1'b0;
      fetch_word_q   <= '0;
      fetch_pc_q     <= '0;
    end else if (flush_all) begin
      fetch_busy     <= 1'b0;
      fetch_complete <= 1'b0;
      valid_f        <= 1'b1;
    end else begin
      // Latch the returned word on completion so it survives a stall.
      if (fetch_ack & fetch_busy) begin
        fetch_word_q   <= fetch_rdata;
        fetch_pc_q     <= fetch_addr;
        fetch_complete <= 1'b1;
      end
      // A new fetch is issued only when the master is idle and the fetch
      // wins arbitration. Busy stays set until the read returns; complete
      // then holds the result until the unstalled pipeline consumes it.
      if (fetch_req & fetch_ready)
        fetch_busy <= 1'b1;
      if (fetch_done) begin
        fetch_busy     <= 1'b0;
        fetch_complete <= 1'b0;
      end
    end
  end

  assign instr_f = instr_d_use;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      valid_d <= 1'b0; pc_d <= '0; instr_d <= '0; is_c_d <= 1'b0;
    end else if (flush_all) begin
      valid_d <= 1'b0;
    end else if (!stall) begin
      if (fetch_done) begin
        valid_d <= valid_f;
        pc_d    <= pc_f;
        is_c_d  <= fetch_is_c;
        instr_d <= instr_d_use;
      end else begin
        valid_d <= 1'b0;
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
                    end
                    default: begin
                      c.reads_csr = 1'b1; c.writes_csr = (f3 != 3'b010);
                      c.csr_addr = i[31:20]; c.csr_op = f3[1:0];
                    end
                  endcase end
      OP_FENCE:  begin
                  if (f3 == 3'b001) c.fence_i = 1'b1;
                end
      OP_AMO:    begin c.wb_sel = WB_MEM; c.lsu_op = LSU_AMO;
                  c.amo_op = amo_op_e'(i[31:27]);
                  c.a_src = SRC_REG; end
      OP_FPLOAD: begin c.wb_sel = WB_FP; c.lsu_op = LSU_LD; c.is_fp = 1'b1; end
      OP_FPSTORE:begin c.wb_sel = WB_NONE; c.lsu_op = LSU_SD; c.is_fp = 1'b1; end
      OP_FPOP:   begin c.wb_sel = WB_FP; c.is_fp = 1'b1;
                  c.fpu_op = fpu_op_e'(i[31:25]); end
      default:   c.illegal = 1'b1;
    endcase
    return c;
  endfunction

  function automatic logic [63:0] gen_imm(logic [31:0] i);
    opcode_t op = i[6:0];
    logic [2:0] f3 = i[14:12];
    logic [63:0] r;
    case (op)
      OP_LUI, OP_AUIPC: r = {{32{i[31]}}, i[31:12], 12'b0};
      OP_JAL:  r = {{44{i[31]}}, i[19:12], i[20], i[30:21], 1'b0};
      OP_JALR: r = {{52{i[31]}}, i[31:20]};
      OP_BRANCH:r = {{51{i[31]}}, i[7], i[30:25], i[11:8], 1'b0};
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
    .raddr1(rs1_d), .raddr2(rs2_d), .raddr3(rs1_d),
    .rdata1(fp_rdata1), .rdata2(fp_rdata2), .rdata3(fp_rdata3)
  );

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

  hazard_unit u_haz (
    .id_rs1(rs1_d), .id_rs2(rs2_d),
    .ex_rd(rd_x), .ex_mem_read(mem_is_load_x),
    .ex_mul_busy(mdu_busy), .ex_fpu_busy(fpu_busy),
    .mem_lsu_busy(lsu_busy),
    .branch_taken(redirect), .trap(trap),
    .is_csr_op(dc.writes_csr), .csr_hazard(load_use_hazard_csr),
    .stall(stall), .flush_id(flush_id), .flush_ex(flush_ex)
  );

  logic flush_redirect;
  assign flush_redirect = redirect | trap;
  assign flush_all = flush_id | flush_ex;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      ex_pkt <= '0;
    end else if (trap) begin
      ex_pkt <= '0;
    end else if (!stall) begin
      if (flush_redirect) begin
        ex_pkt <= '0;
      end else begin
        ex_pkt.valid <= valid_d & ~dc.illegal;
        ex_pkt.pc    <= pc_d;
        ex_pkt.instr <= instr_d;
        ex_pkt.ctrl  <= dc;
        ex_pkt.rs1   <= rf_rdata1;
        ex_pkt.rs2   <= rf_rdata2;
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

  assign redirect = ex_pkt.valid & (ex_pkt.ctrl.is_branch & branch_resolved |
                                    ex_pkt.ctrl.is_jal | ex_pkt.ctrl.is_jalr);
  assign redirect_target = branch_target;

  assign mem_is_load_x = (ex_pkt.ctrl.lsu_op >= LSU_LB) & (ex_pkt.ctrl.lsu_op <= LSU_LWU);
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

  fpu u_fpu (
    .clk(clk), .rst_n(rst_n),
    .start(fpu_start), .op(ex_pkt.ctrl.fpu_op), .rm(ex_pkt.ctrl.fp_rm),
    .a(fp_rdata1), .b(fp_rdata2),
    .result(fpu_res), .fflags(), .done(fpu_done), .busy(fpu_busy_q)
  );
  assign fpu_busy = fpu_in_ex & ~fpu_done;

  logic [63:0] ex_result;
  always_comb begin
    ex_result = alu_y;
    if (is_mdu_op(ex_pkt.ctrl.alu_op))
      ex_result = mdu_res;
    if (ex_pkt.ctrl.fpu_op != FPU_NONE) ex_result = fpu_res;
    if (ex_pkt.ctrl.is_jal | ex_pkt.ctrl.is_jalr)
      ex_result = ex_pkt.pc + 64'd4;
  end

  always_comb begin
    mem_pkt_n = '0;
    mem_pkt_n.valid = ex_pkt.valid;
    mem_pkt_n.pc    = ex_pkt.pc;
    mem_pkt_n.ctrl  = ex_pkt.ctrl;
    mem_pkt_n.alu_res = ex_result;
    mem_pkt_n.rs2   = rs2_fwd;
    mem_pkt_n.mem_addr = rs1_fwd + ex_pkt.imm;
    mem_pkt_n.is_store = mem_is_store_x;
    mem_pkt_n.is_load  = mem_is_load_x;
    mem_pkt_n.store_data = rs2_fwd << (mem_pkt_n.mem_addr[2:0]*8);
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
    endcase
  end

  // axi_pending marks the in-flight transaction of the current mem_pkt so
  // that only its own completion (mem_ack) is interpreted as this load's/
  // store's response. axi_issued suppresses a re-issue of the same
  // transaction: once the AXI master has accepted a load/store request it
  // stays asserted until the load/store leaves the MEM stage (the pipeline
  // advances mem_pkt), so a completed transaction cannot be re-driven. lsu_busy
  // is raised when a load/store enters MEM and drops when that transaction's
  // own ack returns, unstalling the pipeline so the load/store drains to WB.
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      mem_pkt     <= '0;
      lsu_busy    <= 1'b0;
      axi_issued  <= 1'b0;
      axi_pending <= 1'b0;
    end else if (trap) begin
      mem_pkt     <= '0;
      lsu_busy    <= 1'b0;
      axi_issued  <= 1'b0;
      axi_pending <= 1'b0;
    end else if (!stall) begin
      if (ex_pkt.valid)
        mem_pkt <= mem_pkt_n;
      else
        mem_pkt <= '0;
      if (mem_pkt_n.valid & (mem_pkt_n.is_store | mem_pkt_n.is_load)) begin
        lsu_busy    <= 1'b1;
        axi_issued  <= 1'b0;
        axi_pending <= 1'b0;
      end else begin
        lsu_busy    <= 1'b0;
        axi_issued  <= 1'b0;
        axi_pending <= 1'b0;
      end
    end else begin
      // Pipeline stalled (lsu_busy holds it). Issue the AXI request once and
      // keep it issued until the load/store leaves MEM; clear lsu_busy only on
      // this transaction's own completion so the pipeline can then drain.
      if (mem_req & mem_ready) begin
        axi_issued  <= 1'b1;
        axi_pending <= 1'b1;
      end
      if (axi_pending & mem_ack) begin
        lsu_busy    <= 1'b0;
        axi_pending <= 1'b0;
      end
    end
  end

  assign rd_m = mem_pkt.ctrl.rd;
  assign reg_we_m = mem_pkt.valid &
                   ((mem_pkt.ctrl.wb_sel == WB_INT) | (mem_pkt.ctrl.wb_sel == WB_MEM)) &
                   (mem_pkt.ctrl.rd != 5'd0);
  assign fp_we_m = mem_pkt.valid & (mem_pkt.ctrl.wb_sel == WB_FP) & (mem_pkt.ctrl.rd != 5'd0);
  assign mem_alu_y = mem_pkt.alu_res;

  // mem_req is asserted only until the AXI master accepts the load/store
  // request (axi_issued). Staying asserted past acceptance would let the
  // shared master re-issue the same transaction after it completes (e.g. a
  // duplicate store write whose B response later arrives as a stale ack and
  // corrupts a following load's lsu_busy). axi_issued clears when the
  // transaction's ack returns, readying for the next load/store.
  logic axi_issued;
  assign mem_req   = mem_pkt.valid & (mem_pkt.is_store | mem_pkt.is_load) & ~axi_issued;
  assign mem_we    = mem_pkt.is_store;
  assign mem_addr  = mem_pkt.mem_addr;
  assign mem_be    = mem_pkt.be;
  assign mem_wdata = mem_pkt.store_data;
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
  logic [63:0] load_data_q;
  logic        axi_pending;
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) load_data_q <= '0;
    else if (axi_pending & mem_ack & mem_pkt.valid & mem_pkt.is_load)
      load_data_q <= align_load(mem_rdata, mem_pkt.mem_addr[2:0], mem_pkt.ctrl.lsu_op);
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
    case (mem_pkt.ctrl.wb_sel)
      WB_INT: wb_pkt_n.data = mem_pkt.alu_res;
      WB_MEM: wb_pkt_n.data = mem_rdata_aligned;
      default: wb_pkt_n.data = mem_pkt.alu_res;
    endcase
    if (mem_pkt.ctrl.reads_csr) wb_pkt_n.data = csr_rdata;
  end

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) wb_pkt <= '0;
    else if (!stall) wb_pkt <= wb_pkt_n;
  end

  assign rd_w = wb_pkt.rd;
  assign rd_w_fp = wb_pkt.rd;
  assign reg_we_w = wb_pkt.we;
  assign fp_we_w = wb_pkt.fp_we;
  assign wb_data_w = wb_pkt.data;

  logic [4:0] fcsr_fflags_we_dummy;
  csr_unit u_csr (
    .clk(clk), .rst_n(rst_n), .flush(flush_all),
    .priv(priv), .hartid(hartid_i),
    .csr_we(wb_pkt.ctrl.writes_csr & wb_pkt.valid),
    .csr_addr(wb_pkt.ctrl.csr_addr),
    .csr_wdata(wb_pkt.data),
    .csr_op(wb_pkt.ctrl.csr_op),
    .csr_rdata(csr_rdata),
    .pc(wb_pkt.pc),
    .cause(cause), .trap(trap),
    .tval_valid(1'b0), .tval('0),
    .mret(wb_pkt.ctrl.is_mret), .sret(wb_pkt.ctrl.is_sret),
    .epc(epc), .tvec(tvec),
    .new_priv(new_priv),
    .timer_irq(timer_irq), .soft_irq(soft_irq), .ext_irq(ext_irq),
    .irq_pending(irq_pending),
    .fi_we(), .fs_mstatus(),
    .fcsr_fflags_we(fcsr_fflags_we_dummy),
    .fcsr_fflags_in('0)
  );

  always_comb begin
    trap = 1'b0; cause = 4'd0;
    if (ex_pkt.valid & ex_pkt.ctrl.illegal) begin
      trap = 1'b1; cause = CAUSE_ILLEGAL_INSN;
    end
  end

endmodule
