module tb_rv64gch_core;

  import rv64gch_memmap_pkg::*;

  localparam ADDR_W = 48;
  localparam DATA_W = 64;
  localparam ID_W   = 4;
  localparam int    CLK_PERIOD = 10;
  localparam int    MAX_CYCLES = 10_000_000;
  localparam string HEX_FILE   = "prog.vh";

  logic clk, rst_n;

  axi4_if #(.ID_W(ID_W), .ADDR_W(ADDR_W), .DATA_W(DATA_W)) cpu_if();
  axi4_if #(.ID_W(ID_W), .ADDR_W(ADDR_W), .DATA_W(DATA_W)) dram_if();
  axi4_if #(.ID_W(ID_W), .ADDR_W(ADDR_W), .DATA_W(DATA_W)) hostif_if();

  logic        test_done, test_pass;
  logic [63:0] tohost_val;

  axi4_master_stub #(
    .ADDR_W(ADDR_W), .DATA_W(DATA_W), .ID_W(ID_W)
  ) u_master (
    .clk(clk), .rst_n(rst_n), .bus(cpu_if)
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
    .MEM_WORDS(64*1024), .HEX_FILE(HEX_FILE)
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
    $display("[tb] reset de-asserted, stub master driving AXI");

    while (!test_done && cycle_cnt < MAX_CYCLES) begin
      @(negedge clk);
      cycle_cnt = cycle_cnt + 1;
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
