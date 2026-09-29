// TB-ONLY IRQ stimulus: two SW-writable words driving the SoC PLIC
// sources for directed testing (no ASIC footprint; lives in the testbench
// MMIO map, not in rv64gch_top).
//
//   STIM_LO @ +0x0 : bit b drives PLIC source b+1 (sources 1..32)
//   STIM_HI @ +0x8 : bit b drives PLIC source b+33 (sources 33..64)
//
// Single-beat AXI slave; writes byte-masked, reads return the word.
module axi4_stim_model #(
  parameter ADDR_W = 48,
  parameter DATA_W = 64,
  parameter ID_W   = 4,
  parameter logic [47:0] BASE = 48'h0001_0008_0000
) (
  input  logic clk,
  input  logic rst_n,
  axi4_if.s bus,
  output logic [64:1] sources_o
);

  logic [31:0] stim_lo, stim_hi;
  assign sources_o[32:1]  = stim_lo;
  assign sources_o[64:33] = stim_hi;

  typedef enum logic [1:0] {W_IDLE, W_DATA, W_RESP} wst_e;
  typedef enum logic [1:0] {R_IDLE, R_DATA} rst_e;
  wst_e wst;
  rst_e rst;

  logic [47:0] w_off, r_off;
  logic [3:0]  w_id, r_id;

  function automatic logic [31:0] lane_mask(input logic [3:0] be);
    logic [31:0] m;
    m = '0;
    for (int i = 0; i < 4; i++)
      if (be[i]) m[i*8 +: 8] = 8'hFF;
    return m;
  endfunction

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      wst <= W_IDLE; rst <= R_IDLE;
      bus.awready <= 1'b0; bus.wready <= 1'b0;
      bus.bvalid  <= 1'b0; bus.bresp  <= 2'b00; bus.bid <= '0;
      bus.arready <= 1'b0;
      bus.rvalid  <= 1'b0; bus.rresp  <= 2'b00; bus.rid <= '0;
      bus.rdata   <= '0;   bus.rlast  <= 1'b0;
      stim_lo <= 32'd0; stim_hi <= 32'd0;
      w_off <= '0; r_off <= '0; w_id <= '0; r_id <= '0;
    end else begin
      case (wst)
        W_IDLE: begin
          bus.bvalid <= 1'b0;
          bus.awready <= 1'b1;
          if (bus.awvalid && bus.awready) begin
            w_off <= bus.awaddr - BASE;
            w_id  <= bus.awid;
            bus.awready <= 1'b0;
            wst <= W_DATA;
          end
        end
        W_DATA: begin
          bus.wready <= 1'b1;
          if (bus.wvalid && bus.wready) begin
            bus.wready <= 1'b0;
            wst <= W_RESP;
            if (w_off == 48'd0)
              stim_lo <= (stim_lo & ~lane_mask(bus.wstrb[3:0])) |
                         (bus.wdata[31:0] & lane_mask(bus.wstrb[3:0]));
            else if (w_off == 48'd8)
              stim_hi <= (stim_hi & ~lane_mask(bus.wstrb[3:0])) |
                         (bus.wdata[31:0] & lane_mask(bus.wstrb[3:0]));
          end
        end
        W_RESP: begin
          bus.bvalid <= 1'b1;
          bus.bresp  <= 2'b00;
          bus.bid    <= w_id;
          if (bus.bvalid && bus.bready) begin
            bus.bvalid <= 1'b0;
            wst <= W_IDLE;
          end
        end
        default: wst <= W_IDLE;
      endcase
      case (rst)
        R_IDLE: begin
          bus.rvalid <= 1'b0;
          bus.arready <= 1'b1;
          if (bus.arvalid && bus.arready) begin
            r_off <= bus.araddr - BASE;
            r_id  <= bus.arid;
            bus.arready <= 1'b0;
            rst <= R_DATA;
          end
        end
        R_DATA: begin
          bus.rvalid <= 1'b1;
          bus.rresp  <= 2'b00;
          bus.rid    <= r_id;
          bus.rlast  <= 1'b1;
          if (r_off == 48'd0)
            bus.rdata <= {32'd0, stim_lo};
          else if (r_off == 48'd8)
            bus.rdata <= {32'd0, stim_hi};
          else
            bus.rdata <= '0;
          if (bus.rvalid && bus.rready) begin
            bus.rvalid <= 1'b0;
            bus.rlast  <= 1'b0;
            rst <= R_IDLE;
          end
        end
        default: rst <= R_IDLE;
      endcase
    end
  end

endmodule
