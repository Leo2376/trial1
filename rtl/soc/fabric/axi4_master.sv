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

  axi4_if.m                bus
);
  localparam STRB_W = DATA_W/8;

  typedef enum logic [2:0] {
    A_IDLE, A_AW, A_W, A_B, A_AR, A_R
  } ast_e;
  ast_e st;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      st <= A_IDLE;
      bus.awvalid <= 1'b0;
      bus.wvalid  <= 1'b0;
      bus.bready  <= 1'b0;
      bus.arvalid <= 1'b0;
      bus.rready  <= 1'b0;
      bus.awaddr  <= '0;
      bus.wdata   <= '0;
      bus.wstrb   <= '0;
      bus.araddr  <= '0;
      ack <= 1'b0; rdata <= '0; err <= 1'b0;
    end else begin
      ack <= 1'b0;
      bus.awvalid <= 1'b0;
      bus.wvalid  <= 1'b0;
      bus.bready <= 1'b0;
      bus.arvalid <= 1'b0;
      bus.rready  <= 1'b0;
      case (st)
        A_IDLE: begin
          if (req) begin
            if (we) begin
              bus.awaddr  <= addr;
              bus.wdata   <= wdata;
              bus.wstrb   <= be;
              bus.awvalid <= 1'b1;
              st <= A_AW;
            end else begin
              bus.araddr  <= addr;
              bus.arvalid <= 1'b1;
              st <= A_AR;
            end
          end
        end
        A_AW: begin
          bus.awvalid <= 1'b1;
          if (bus.awready) begin
            bus.awvalid <= 1'b0;
            bus.wvalid  <= 1'b1;
            st <= A_W;
          end
        end
        A_W: begin
          bus.wvalid <= 1'b1;
          if (bus.wready) begin
            bus.wvalid <= 1'b0;
            bus.bready <= 1'b1;
            st <= A_B;
          end
        end
        A_B: begin
          bus.bready <= 1'b1;
          if (bus.bvalid) begin
            bus.bready <= 1'b0;
            ack  <= 1'b1;
            err  <= bus.bresp[1];
            st   <= A_IDLE;
          end
        end
        A_AR: begin
          bus.arvalid <= 1'b1;
          if (bus.arready) begin
            bus.arvalid <= 1'b0;
            bus.rready  <= 1'b1;
            st <= A_R;
          end
        end
        A_R: begin
          bus.rready <= 1'b1;
          if (bus.rvalid) begin
            bus.rready <= 1'b0;
            rdata <= bus.rdata;
            err   <= bus.rresp[1];
            ack   <= 1'b1;
            st    <= A_IDLE;
          end
        end
      endcase
    end
  end

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

  assign ready = (st == A_IDLE);

endmodule
