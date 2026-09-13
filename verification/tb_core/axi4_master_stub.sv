module axi4_master_stub #(
  parameter ADDR_W = 48,
  parameter DATA_W = 64,
  parameter ID_W   = 4
) (
  input  logic clk,
  input  logic rst_n,
  axi4_if.m bus
);
  import rv64gch_memmap_pkg::*;

  localparam logic [47:0] CHAROUT_ADDR = HOSTIF_BASE + CHAROUT_OFF[47:0];
  localparam logic [47:0] TOHOST_ADDR  = HOSTIF_BASE + TOHOST_OFF[47:0];

  typedef enum logic [2:0] {
    S_IDLE, S_AW0, S_W0, S_B0, S_AW1, S_W1, S_B1, S_DONE
  } st_e;
  st_e st;

  localparam string MSG = "stub ok\n";
  int idx;

  initial idx = 0;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      st <= S_IDLE;
      bus.awvalid <= 1'b0;
      bus.wvalid  <= 1'b0;
      bus.bready  <= 1'b0;
      bus.arvalid <= 1'b0;
      bus.rready  <= 1'b0;
      bus.awaddr  <= '0;
      bus.wdata   <= '0;
    end else begin
      bus.awvalid <= 1'b0;
      bus.wvalid  <= 1'b0;
      bus.bready  <= 1'b0;
      case (st)
        S_IDLE: begin
          if (idx < MSG.len()) begin
            bus.awaddr  <= CHAROUT_ADDR;
            bus.wdata   <= {56'd0, MSG[idx]};
            bus.awvalid <= 1'b1;
            st <= S_AW0;
          end else begin
            bus.awaddr  <= TOHOST_ADDR;
            bus.wdata   <= TOHOST_PASS;
            bus.awvalid <= 1'b1;
            st <= S_AW1;
          end
        end
        S_AW0: begin
          if (bus.awready) begin
            bus.wvalid <= 1'b1;
            st <= S_W0;
          end else begin
            bus.awvalid <= 1'b1;
          end
        end
        S_W0: begin
          bus.wvalid <= 1'b1;
          if (bus.wready) begin
            bus.wvalid <= 1'b0;
            bus.bready <= 1'b1;
            st <= S_B0;
          end
        end
        S_B0: begin
          bus.bready <= 1'b1;
          if (bus.bvalid) begin
            bus.bready <= 1'b0;
            idx = idx + 1;
            st <= S_IDLE;
          end
        end
        S_AW1: begin
          if (bus.awready) begin
            bus.wvalid <= 1'b1;
            st <= S_W1;
          end else begin
            bus.awvalid <= 1'b1;
          end
        end
        S_W1: begin
          bus.wvalid <= 1'b1;
          if (bus.wready) begin
            bus.wvalid <= 1'b0;
            bus.bready <= 1'b1;
            st <= S_B1;
          end
        end
        S_B1: begin
          bus.bready <= 1'b1;
          if (bus.bvalid) begin
            bus.bready <= 1'b0;
            st <= S_DONE;
          end
        end
        S_DONE: st <= S_DONE;
      endcase
    end
  end

  always_comb begin
    bus.awid    = '0;
    bus.awlen   = 8'd0;
    bus.awsize  = 3'd3;
    bus.awburst = 2'b01;
    bus.wstrb   = '1;
    bus.wlast   = 1'b1;
    bus.arid    = '0;
    bus.araddr  = '0;
    bus.arlen   = 8'd0;
    bus.arsize  = 3'd3;
    bus.arburst = 2'b01;
  end

endmodule
