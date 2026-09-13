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
    .dbg_pc(dbg_pc)
  );

  assign core_active_o = (dbg_pc != 32'd0);

  logic        axi_req, axi_we, axi_ack, axi_ready, axi_err;
  logic [47:0] axi_addr;
  logic [7:0]  axi_be;
  logic [63:0] axi_wdata, axi_rdata;
  logic        sel_dmem;

  assign sel_dmem = dmem_req;

  assign axi_req   = sel_dmem ? dmem_req   : (fetch_req & fetch_ready);
  assign axi_we    = sel_dmem ? dmem_we    : 1'b0;
  assign axi_addr  = sel_dmem ? dmem_addr  : fetch_addr;
  assign axi_be    = sel_dmem ? dmem_be    : fetch_be;
  assign axi_wdata = sel_dmem ? dmem_wdata : fetch_wdata;

  assign dmem_rdata  = axi_rdata;
  assign fetch_rdata = axi_rdata;

  logic dmem_pending, fetch_pending;
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      dmem_pending  <= 1'b0;
      fetch_pending <= 1'b0;
    end else begin
      if (axi_ack) begin
        dmem_pending  <= 1'b0;
        fetch_pending <= 1'b0;
      end else if (sel_dmem && dmem_req && axi_req && !axi_ack)
        dmem_pending <= 1'b1;
      else if (!sel_dmem && fetch_req && axi_req && !axi_ack)
        fetch_pending <= 1'b1;
    end
  end

  assign dmem_ack   = axi_ack & (dmem_pending | (sel_dmem & dmem_req));
  assign fetch_ack  = axi_ack & (fetch_pending | (~sel_dmem & fetch_req));
  assign dmem_ready = ~sel_dmem | axi_ready;
  assign fetch_ready = sel_dmem | axi_ready;

  axi4_master #(.ADDR_W(ADDR_W), .DATA_W(DATA_W), .ID_W(ID_W)) u_axi (
    .clk(clk), .rst_n(rst_n),
    .req(axi_req), .we(axi_we),
    .addr(axi_addr), .be(axi_be), .wdata(axi_wdata),
    .size(4'd3), .lock(dmem_lock & sel_dmem),
    .rdata(axi_rdata), .ack(axi_ack), .ready(axi_ready), .err(axi_err),
    .bus(mem)
  );

  assign dmem_err  = axi_err;
  assign fetch_err = axi_err;

endmodule
