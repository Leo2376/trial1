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

  // L1 data cache (blocking, write-back) between the core data port and
  // the shared AXI arbiter. The arbiter sees the cache's memory side
  // (l1d_*); FENCE needs no action (in-order + blocking retires everything
  // before it) and there is no coherence/DMA yet, so flush is tied off.
  logic        l1d_req, l1d_we, l1d_ack, l1d_ready, l1d_lock;
  logic [47:0] l1d_addr;
  logic [7:0]  l1d_be;
  logic [63:0] l1d_wdata, l1d_rdata;
  l1d #(.ADDR_W(ADDR_W), .DATA_W(DATA_W)) u_l1d (
    .clk(clk), .rst_n(rst_n),
    .req_i(dmem_req), .we_i(dmem_we), .addr_i(dmem_addr),
    .be_i(dmem_be), .wdata_i(dmem_wdata), .lock_i(dmem_lock),
    .rdata_o(dmem_rdata), .ack_o(dmem_ack), .ready_o(dmem_ready),
    .req_o(l1d_req), .we_o(l1d_we), .addr_o(l1d_addr), .be_o(l1d_be),
    .wdata_o(l1d_wdata), .lock_o(l1d_lock),
    .rdata_i(l1d_rdata), .ack_i(l1d_ack), .ready_i(l1d_ready),
    .flush_i(1'b0)
  );

  assign core_active_o = (dbg_pc != 32'd0);

  // Unified L2 victim shared by both L1s. Port A serves L1I fills
  // (read-only); port B serves L1D fills/writebacks with data-side
  // priority inside the L2. The L2 is blocking with a single memory-side
  // port, so it is the only AXI requester: no arbitration or owner
  // tracking is needed downstream (the stale-ready race that required the
  // old owner latch cannot occur with one requester).
  logic        m2_req, m2_we, m2_ack, m2_ready, m2_lock;
  logic [47:0] m2_addr;
  logic [7:0]  m2_be;
  logic [63:0] m2_wdata, m2_rdata;
  l2 #(.ADDR_W(ADDR_W), .DATA_W(DATA_W)) u_l2 (
    .clk(clk), .rst_n(rst_n),
    .req_a_i(l1_req), .addr_a_i(l1_addr),
    .rdata_a_o(l1_rdata), .ack_a_o(l1_ack), .ready_a_o(l1_ready),
    .req_b_i(l1d_req), .we_b_i(l1d_we), .addr_b_i(l1d_addr),
    .be_b_i(l1d_be), .wdata_b_i(l1d_wdata), .lock_b_i(l1d_lock),
    .rdata_b_o(l1d_rdata), .ack_b_o(l1d_ack), .ready_b_o(l1d_ready),
    .req_o(m2_req), .we_o(m2_we), .addr_o(m2_addr), .be_o(m2_be),
    .wdata_o(m2_wdata), .lock_o(m2_lock),
    .rdata_i(m2_rdata), .ack_i(m2_ack), .ready_i(m2_ready)
  );

  logic        axi_req, axi_we, axi_ack, axi_ready, axi_err, axi_idle;
  logic [47:0] axi_addr;
  logic [7:0]  axi_be;
  logic [63:0] axi_wdata, axi_rdata;

  assign axi_req   = m2_req & m2_ready;
  assign axi_we    = m2_we;
  assign axi_addr  = m2_addr;
  assign axi_be    = m2_be;
  assign axi_wdata = m2_wdata;

  assign m2_rdata = axi_rdata;
  assign m2_ack   = axi_ack;
  assign m2_ready = axi_ready;

  axi4_master #(.ADDR_W(ADDR_W), .DATA_W(DATA_W), .ID_W(ID_W)) u_axi (
    .clk(clk), .rst_n(rst_n),
    .req(axi_req), .we(axi_we),
    .addr(axi_addr), .be(axi_be), .wdata(axi_wdata),
    .size(4'd3), .lock(m2_lock),
    .rdata(axi_rdata), .ack(axi_ack), .ready(axi_ready), .err(axi_err),
    .idle_o(axi_idle),
    .bus(mem)
  );

  assign dmem_err  = axi_err;
  assign fetch_err = axi_err;

endmodule
