interface axi4_if #(
  parameter ID_W   = 4,
  parameter ADDR_W = 48,
  parameter DATA_W = 64
) ();

  localparam STRB_W = DATA_W/8;

  logic [ID_W-1:0]    awid;
  logic [ADDR_W-1:0]  awaddr;
  logic [7:0]         awlen;
  logic [2:0]         awsize;
  logic [1:0]         awburst;
  logic               awvalid;
  logic               awready;

  logic [DATA_W-1:0]  wdata;
  logic [STRB_W-1:0]  wstrb;
  logic               wlast;
  logic               wvalid;
  logic               wready;

  logic [ID_W-1:0]    bid;
  logic [1:0]         bresp;
  logic               bvalid;
  logic               bready;

  logic [ID_W-1:0]    arid;
  logic [ADDR_W-1:0]  araddr;
  logic [7:0]         arlen;
  logic [2:0]         arsize;
  logic [1:0]         arburst;
  logic               arvalid;
  logic               arready;

  logic [ID_W-1:0]    rid;
  logic [DATA_W-1:0]  rdata;
  logic [1:0]         rresp;
  logic               rlast;
  logic               rvalid;
  logic               rready;

  modport m (
    output awid, awaddr, awlen, awsize, awburst, awvalid,
    input  awready,
    output wdata, wstrb, wlast, wvalid,
    input  wready,
    input  bid, bresp, bvalid,
    output bready,
    output arid, araddr, arlen, arsize, arburst, arvalid,
    input  arready,
    input  rid, rdata, rresp, rlast, rvalid,
    output rready
  );

  modport s (
    input  awid, awaddr, awlen, awsize, awburst, awvalid,
    output awready,
    input  wdata, wstrb, wlast, wvalid,
    output wready,
    output bid, bresp, bvalid,
    input  bready,
    input  arid, araddr, arlen, arsize, arburst, arvalid,
    output arready,
    output rid, rdata, rresp, rlast, rvalid,
    input  rready
  );

endinterface
