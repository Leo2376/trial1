module axi4_decoder #(
  parameter ADDR_W = 48,
  parameter DATA_W = 64,
  parameter ID_W   = 4,
  parameter logic [47:0] BASE0,
  parameter logic [47:0] SIZE0,
  parameter logic [47:0] BASE1,
  parameter logic [47:0] SIZE1
) (
  axi4_if.s  m,
  axi4_if.m  s0,
  axi4_if.m  s1
);

  logic aw_sel, ar_sel;

  always_comb begin
    aw_sel = (m.awaddr >= BASE1) && (m.awaddr < (BASE1 + SIZE1));
    ar_sel = (m.araddr >= BASE1) && (m.araddr < (BASE1 + SIZE1));
  end

  always_comb begin
    s0.awid    = m.awid;     s1.awid    = m.awid;
    s0.awaddr  = m.awaddr;    s1.awaddr  = m.awaddr;
    s0.awlen   = m.awlen;     s1.awlen   = m.awlen;
    s0.awsize  = m.awsize;     s1.awsize  = m.awsize;
    s0.awburst = m.awburst;   s1.awburst = m.awburst;
    s0.awvalid = !aw_sel && m.awvalid;
    s1.awvalid =  aw_sel && m.awvalid;
    s0.wdata   = m.wdata;     s1.wdata   = m.wdata;
    s0.wstrb   = m.wstrb;     s1.wstrb   = m.wstrb;
    s0.wlast   = m.wlast;     s1.wlast   = m.wlast;
    s0.wvalid  = !aw_sel && m.wvalid;
    s1.wvalid  =  aw_sel && m.wvalid;
    s0.bready  = !aw_sel && m.bready;
    s1.bready  =  aw_sel && m.bready;
    s0.arid    = m.arid;      s1.arid    = m.arid;
    s0.araddr  = m.araddr;    s1.araddr  = m.araddr;
    s0.arlen   = m.arlen;     s1.arlen   = m.arlen;
    s0.arsize  = m.arsize;     s1.arsize  = m.arsize;
    s0.arburst = m.arburst;   s1.arburst = m.arburst;
    s0.arvalid = !ar_sel && m.arvalid;
    s1.arvalid =  ar_sel && m.arvalid;
    s0.rready  = !ar_sel && m.rready;
    s1.rready  =  ar_sel && m.rready;
  end

  always_comb begin
    m.awready = aw_sel ? s1.awready : s0.awready;
    m.wready  = aw_sel ? s1.wready  : s0.wready;
    m.bvalid  = aw_sel ? s1.bvalid  : s0.bvalid;
    m.bresp   = aw_sel ? s1.bresp   : s0.bresp;
    m.bid     = aw_sel ? s1.bid     : s0.bid;
    m.arready = ar_sel ? s1.arready : s0.arready;
    m.rvalid  = ar_sel ? s1.rvalid  : s0.rvalid;
    m.rdata   = ar_sel ? s1.rdata   : s0.rdata;
    m.rresp   = ar_sel ? s1.rresp   : s0.rresp;
    m.rlast   = ar_sel ? s1.rlast   : s0.rlast;
    m.rid     = ar_sel ? s1.rid     : s0.rid;
  end

endmodule
