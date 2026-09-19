module rv64gch_top #(
  parameter ADDR_W = 48,
  parameter DATA_W = 64,
  parameter ID_W   = 4,
  parameter XLEN    = 64
) (
  input  logic                clk,
  input  logic                rst_n,

  input  logic [XLEN-1:0]    hartid_i,
  input  logic                msi_n_i,
  input  logic [1:0]          dbg_req_i,
  input  logic                dbg_halt_req_i,

  output logic                core_active_o,

  axi4_if.m                  mem
);
  import rv64gch_memmap_pkg::*;

  logic        fetch_req, fetch_we, fetch_ack, fetch_ready, fetch_err;
  logic [47:0] fetch_addr;
  logic [7:0]  fetch_be;
  logic [63:0] fetch_wdata, fetch_rdata;

  logic        dmem_req, dmem_we, dmem_ack, dmem_ready, dmem_err, dmem_lock;
  logic [47:0] dmem_addr;
  logic [7:0]  dmem_be;
  logic [63:0] dmem_wdata, dmem_rdata;

  logic [31:0] dbg_pc;
  logic        timer_irq, soft_irq, ext_irq;
  logic        fence_i_retire;

  assign timer_irq = 1'b0;
  assign soft_irq  = 1'b0;
  assign ext_irq   = 1'b0;

  rv64gch_core #(.XLEN(XLEN)) u_core (
    .clk(clk), .rst_n(rst_n),
    .hartid_i(hartid_i),
    .timer_irq(timer_irq), .soft_irq(soft_irq), .ext_irq(ext_irq),
    .fetch_req(fetch_req), .fetch_we(fetch_we),
    .fetch_addr(fetch_addr), .fetch_be(fetch_be),
    .fetch_wdata(fetch_wdata), .fetch_rdata(fetch_rdata),
    .fetch_ack(fetch_ack), .fetch_ready(fetch_ready), .fetch_err(fetch_err),
    .mem_req(dmem_req), .mem_we(dmem_we),
    .mem_addr(dmem_addr), .mem_be(dmem_be),
    .mem_wdata(dmem_wdata), .mem_lock(dmem_lock),
    .mem_rdata(dmem_rdata), .mem_ack(dmem_ack),
    .mem_ready(dmem_ready), .mem_err(dmem_err),
    .dbg_pc(dbg_pc), .fence_i_o(fence_i_retire)
  );

  // L1 instruction cache (blocking, read-only) between the core fetch port
  // and the shared AXI arbiter below. The arbiter now sees the cache's
  // fill port (l1_*); the core fetch contract is served from cache lines.
  logic        l1_req, l1_ack, l1_ready;
  logic [47:0] l1_addr;
  logic [63:0] l1_rdata;
  l1i #(.ADDR_W(ADDR_W), .DATA_W(DATA_W)) u_l1i (
    .clk(clk), .rst_n(rst_n),
    .req_i(fetch_req), .addr_i(fetch_addr),
    .rdata_o(fetch_rdata), .ack_o(fetch_ack), .ready_o(fetch_ready),
    .req_o(l1_req), .addr_o(l1_addr),
    .rdata_i(l1_rdata), .ack_i(l1_ack), .ready_i(l1_ready),
    .flush_i(fence_i_retire)
  );

  assign core_active_o = (dbg_pc != 32'd0);

  logic        axi_req, axi_we, axi_ack, axi_ready, axi_err, axi_idle;
  logic [47:0] axi_addr;
  logic [7:0]  axi_be;
  logic [63:0] axi_wdata, axi_rdata;
  logic        sel_dmem;
  logic        axi_owner_dmem;  // latched: 1 = in-flight AXI transaction owned by dmem

  // Data memory has priority over instruction fetch for the shared AXI port.
  // A request is forwarded to the master only when the master is idle
  // (axi_ready). The owner of the in-flight transaction is latched so the
  // completion ack is routed correctly even if the request selectors change
  // while the transaction is in progress (e.g. a pipeline flush dropping a
  // fetch request).
  assign sel_dmem = dmem_req;

  assign axi_req   = sel_dmem ? dmem_req   : (l1_req & l1_ready);
  assign axi_we    = sel_dmem ? dmem_we    : 1'b0;
  assign axi_addr  = sel_dmem ? dmem_addr  : l1_addr;
  assign axi_be    = sel_dmem ? dmem_be    : 8'hFF;
  assign axi_wdata = sel_dmem ? dmem_wdata : 64'd0;

  assign dmem_rdata = axi_rdata;
  assign l1_rdata   = axi_rdata;

  // The owner is latched exactly when the AXI master accepts a new
  // request (its A_IDLE && req sampling). Gated by the master's
  // combinational idle_o, not the registered ready: after an accept, ready
  // stays high for one more cycle while the master is already in A_AR/A_AW,
  // and a request present in that window (held fill req, or a data request
  // racing a just-accepted fill beat) must NOT re-latch ownership, or the
  // in-flight transaction's ack would be misrouted. When a transaction
  // completes (axi_ack) the master returns to idle in the same cycle, so a
  // new request can be accepted simultaneously; the new owner must take
  // precedence over clearing the previous one.
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      axi_owner_dmem <= 1'b0;
    end else if (axi_idle && axi_req) begin
      axi_owner_dmem <= sel_dmem;
      `ifdef L1I_DEBUG
      $display("[top %0t] ACCEPT sel_dmem=%b addr=%h", $time, sel_dmem, axi_addr);
      `endif
    end else if (axi_ack) begin
      axi_owner_dmem <= 1'b0;
      `ifdef L1I_DEBUG
      $display("[top %0t] ACK owner_dmem=%b rdata=%h", $time, axi_owner_dmem, axi_rdata);
      `endif
    end
  end

  assign dmem_ack = axi_ack &  axi_owner_dmem;
  assign l1_ack   = axi_ack & ~axi_owner_dmem;

  // Fill requests can issue when the master is idle and no data request
  // is pending. Data memory can issue when the master is idle.
  assign l1_ready   = axi_ready & ~sel_dmem;
  assign dmem_ready = axi_ready;

  axi4_master #(.ADDR_W(ADDR_W), .DATA_W(DATA_W), .ID_W(ID_W)) u_axi (
    .clk(clk), .rst_n(rst_n),
    .req(axi_req), .we(axi_we),
    .addr(axi_addr), .be(axi_be), .wdata(axi_wdata),
    .size(4'd3), .lock(dmem_lock & sel_dmem),
    .rdata(axi_rdata), .ack(axi_ack), .ready(axi_ready), .err(axi_err),
    .idle_o(axi_idle),
    .bus(mem)
  );

  assign dmem_err  = axi_err;
  assign fetch_err = axi_err;

endmodule
