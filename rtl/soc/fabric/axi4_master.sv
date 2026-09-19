module axi4_master #(
  parameter ADDR_W = 48,
  parameter DATA_W = 64,
  parameter ID_W   = 4
) (
  input  logic              clk,
  input  logic              rst_n,

  input  logic              req,
  input  logic              we,
  input  logic [ADDR_W-1:0] addr,
  input  logic [7:0]        be,
  input  logic [DATA_W-1:0] wdata,
  input  logic [3:0]        size,
  input  logic              lock,
  output logic [DATA_W-1:0] rdata,
  output logic              ack,
  output logic              ready,
  output logic              err,
  // Combinational: master will accept a request presented this cycle.
  // (ready is registered and stays high for a cycle after the master
  // leaves IDLE, so it cannot gate ownership.)
  output logic              idle_o,

  axi4_if.m                bus
);
  localparam STRB_W = DATA_W/8;

  typedef enum logic [2:0] {
    A_IDLE, A_AW, A_W, A_B, A_AR, A_R
  } ast_e;
  ast_e st, st_n;

  logic [DATA_W-1:0] rdata_n;
  logic              ack_n, ready_n, err_n;

  logic              awvalid_n, wvalid_n, bready_n, arvalid_n, rready_n;
  logic [ADDR_W-1:0] awaddr_n, araddr_n;
  logic [DATA_W-1:0] wdata_n;
  logic [STRB_W-1:0] wstrb_n;

  always_comb begin
    st_n     = st;
    rdata_n  = rdata;
    ack_n    = 1'b0;
    ready_n  = 1'b0;
    err_n    = 1'b0;

    awvalid_n = 1'b0;
    wvalid_n  = 1'b0;
    bready_n  = 1'b0;
    arvalid_n = 1'b0;
    rready_n  = 1'b0;
    awaddr_n  = bus.awaddr;
    araddr_n  = bus.araddr;
    wdata_n   = bus.wdata;
    wstrb_n   = bus.wstrb;

    case (st)
      A_IDLE: begin
        ready_n = 1'b1;
        if (req) begin
          if (we) begin
            awaddr_n   = addr;
            wdata_n    = wdata;
            wstrb_n    = be;
            awvalid_n  = 1'b1;
            st_n       = A_AW;
          end else begin
            araddr_n   = addr;
            arvalid_n  = 1'b1;
            st_n       = A_AR;
          end
        end
      end
      A_AW: begin
        awvalid_n = 1'b1;
        if (bus.awready) begin
          awvalid_n = 1'b0;
          wvalid_n  = 1'b1;
          st_n      = A_W;
        end
      end
      A_W: begin
        wvalid_n = 1'b1;
        if (bus.wready) begin
          wvalid_n = 1'b0;
          bready_n = 1'b1;
          st_n     = A_B;
        end
      end
      A_B: begin
        bready_n = 1'b1;
        if (bus.bvalid) begin
          bready_n = 1'b0;
          ack_n    = 1'b1;
          err_n    = bus.bresp[1];
          st_n     = A_IDLE;
        end
      end
      A_AR: begin
        arvalid_n = 1'b1;
        if (bus.arready) begin
          arvalid_n = 1'b0;
          rready_n  = 1'b1;
          st_n      = A_R;
        end
      end
      A_R: begin
        rready_n = 1'b1;
        if (bus.rvalid) begin
          rready_n  = 1'b0;
          rdata_n   = bus.rdata;
          err_n     = bus.rresp[1];
          ack_n     = 1'b1;
          st_n      = A_IDLE;
        end
      end
    endcase
  end

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      st       <= A_IDLE;
      bus.awvalid <= 1'b0;
      bus.wvalid  <= 1'b0;
      bus.bready  <= 1'b0;
      bus.arvalid <= 1'b0;
      bus.rready  <= 1'b0;
      bus.awaddr  <= '0;
      bus.wdata   <= '0;
      bus.wstrb   <= '0;
      bus.araddr  <= '0;
      rdata <= '0; ack <= 1'b0; ready <= 1'b0; err <= 1'b0;
    end else begin
      st       <= st_n;
      bus.awvalid <= awvalid_n;
      bus.wvalid  <= wvalid_n;
      bus.bready  <= bready_n;
      bus.arvalid <= arvalid_n;
      bus.rready  <= rready_n;
      bus.awaddr  <= awaddr_n;
      bus.wdata   <= wdata_n;
      bus.wstrb   <= wstrb_n;
      bus.araddr  <= araddr_n;
      rdata <= rdata_n; ack <= ack_n; ready <= ready_n; err <= err_n;
    end
  end

  assign idle_o = (st == A_IDLE);

  always_comb begin
    bus.awid    = '0;
    bus.awlen   = 8'd0;
    bus.awsize  = 3'd3;
    bus.awburst = 2'b01;
    bus.wlast   = 1'b1;
    bus.arid    = '0;
    bus.arlen   = 8'd0;
    bus.arsize  = 3'd3;
    bus.arburst = 2'b01;
  end

endmodule