module tb_rv64gch_core;

  import rv64gch_memmap_pkg::*;

  localparam ADDR_W = 48;
  localparam DATA_W = 64;
  localparam ID_W   = 4;
  localparam int    CLK_PERIOD = 10;
  localparam int    MAX_CYCLES = 50_000_000;
  localparam string HEX_FILE   = "prog.vh";

  logic clk, rst_n;

  axi4_if #(.ID_W(ID_W), .ADDR_W(ADDR_W), .DATA_W(DATA_W)) cpu_if();
  axi4_if #(.ID_W(ID_W), .ADDR_W(ADDR_W), .DATA_W(DATA_W)) dram_if();
  axi4_if #(.ID_W(ID_W), .ADDR_W(ADDR_W), .DATA_W(DATA_W)) hostif_if();

  logic        test_done, test_pass;
  logic [63:0] tohost_val;
  logic        core_active;

  rv64gch_top #(
    .ADDR_W(ADDR_W), .DATA_W(DATA_W), .ID_W(ID_W), .XLEN(64)
  ) u_cpu (
    .clk(clk), .rst_n(rst_n),
    .hartid_i(64'd0),
    .msi_n_i(1'b1),
    .dbg_req_i(2'b00),
    .dbg_halt_req_i(1'b0),
    .core_active_o(core_active),
    .mem(cpu_if)
  );

  axi4_decoder #(
    .ADDR_W(ADDR_W), .DATA_W(DATA_W), .ID_W(ID_W),
    .BASE0(DRAM_BASE),   .SIZE0(DRAM_TOP   - DRAM_BASE),
    .BASE1(HOSTIF_BASE), .SIZE1(HOSTIF_TOP - HOSTIF_BASE)
  ) u_dec (
    .m(cpu_if), .s0(dram_if), .s1(hostif_if)
  );

  axi4_dram_model #(
    .ADDR_W(ADDR_W), .DATA_W(DATA_W), .ID_W(ID_W),
    .MEM_WORDS(64*1024), .HEX_FILE(HEX_FILE), .BASE(DRAM_BASE)
  ) u_dram (
    .clk(clk), .rst_n(rst_n), .bus(dram_if)
  );

  axi4_hostif_model #(
    .ADDR_W(ADDR_W), .DATA_W(DATA_W), .ID_W(ID_W),
    .BASE(HOSTIF_BASE)
  ) u_hostif (
    .clk(clk), .rst_n(rst_n), .bus(hostif_if),
    .test_done(test_done), .test_pass(test_pass), .tohost_val(tohost_val)
  );

  initial begin
    clk = 1'b0;
    forever #(CLK_PERIOD/2) clk = ~clk;
  end

  int cycle_cnt;
  initial begin
    cycle_cnt = 0;
    rst_n     = 1'b0;
    repeat (20) @(posedge clk);
    rst_n = 1'b1;
    $display("[tb] reset de-asserted, rv64gch_top booting from 0x%012h", RESET_PC);

    while (!test_done && cycle_cnt < MAX_CYCLES) begin
      @(negedge clk);
      cycle_cnt = cycle_cnt + 1;
      if (cycle_cnt % 100000 == 0)
        $display("[tb] cycle=%0d pc=%0h core_active=%b trap=%b cause=%0d ex_valid=%b id_valid=%b is_c=%b ill_c=%b stall=%b fpu_busy=%b fetch_done=%b fetch_complete=%b hi_valid=%b need_hi=%b fetch_res_valid=%b valid_f=%b pc_f=%0h fetch_req=%b fetch_ready=%b fetch_ack=%b axi_req=%b axi_ready=%b axi_ack=%b busy=%b hit=%b fault=%b fltq=%b l1ist=%0d priv=%b satp=%h wbpc=%h flAll=%b flId=%b sf=%b satpwe=%b exsf=%b rs1f=%h exva=%h mmpa=%h expc=%h mmpc=%h rdm=%0d malu=%h fwda=%b",
                 cycle_cnt, u_cpu.dbg_pc, core_active, u_cpu.u_core.trap, u_cpu.u_core.cause,
                 u_cpu.u_core.ex_pkt.valid, u_cpu.u_core.valid_d, u_cpu.u_core.is_c_d, u_cpu.u_core.illegal_c_d, u_cpu.u_core.stall, u_cpu.u_core.fpu_busy,
                 u_cpu.u_core.fetch_done, u_cpu.u_core.fetch_complete, u_cpu.u_core.fetch_hi_valid, u_cpu.u_core.fetch_need_hi, u_cpu.u_core.fetch_res_valid, u_cpu.u_core.valid_f, u_cpu.u_core.pc_f,
                 u_cpu.u_core.fetch_req, u_cpu.fetch_ready, u_cpu.fetch_ack,
                 u_cpu.axi_req, u_cpu.axi_ready, u_cpu.axi_ack,
                 u_cpu.u_core.fetch_busy, u_cpu.u_core.mmu_hit_f, u_cpu.u_core.mmu_fault_f,
                 u_cpu.u_core.fault_f_q, u_cpu.u_l1i.st, u_cpu.u_core.priv, u_cpu.u_core.csr_satp,
                 u_cpu.u_core.wb_pkt.pc, u_cpu.u_core.flush_all, u_cpu.u_core.flush_id,
                 u_cpu.u_core.sfence_o, u_cpu.u_core.satp_we_o, u_cpu.u_core.ex_pkt.ctrl.is_sfence,
                 u_cpu.u_core.rs1_fwd, u_cpu.u_core.ex_va_full, u_cpu.u_core.mem_pkt.mem_addr,
                 u_cpu.u_core.ex_pkt.pc, u_cpu.u_core.mem_pkt.pc, u_cpu.u_core.rd_m,
                 u_cpu.u_core.mem_alu_y, u_cpu.u_core.fwd_a);
    end

    if (test_done) begin
      if (test_pass)
        $display("[tb] TEST PASSED (tohost=0x%016h) after %0d cycles", tohost_val, cycle_cnt);
      else
        $display("[tb] TEST FAILED (tohost=0x%016h) after %0d cycles", tohost_val, cycle_cnt);
    end else begin
      $display("[tb] TIMEOUT after %0d cycles (tohost=0x%016h)", MAX_CYCLES, tohost_val);
    end
    $finish;
  end

endmodule
