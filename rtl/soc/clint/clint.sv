// CLINT: Core-Local Interruptor (single hart, SiFive-style map).
//
//   msip      @ +0x0    (bit 0, W; upper bits read 0)
//   mtimecmp  @ +0x4000 (64-bit, W)
//   mtime     @ +0xBFF8 (64-bit, R; +1/cycle, WARL-increment only)
//
// timer_irq_o = (mtime >= mtimecmp); soft_irq_o = msip. Reset parks
// mtimecmp at all-ones so no spurious timer interrupt fires.
// Single-beat AXI slave; byte-masked writes via wstrb (sb/sh/sw/sd all
// work); reads return the 64-bit word (msip in bit 0).
module clint #(
  parameter logic [47:0] BASE = 48'h0001_0010_0000
) (
  input  logic             clk,
  input  logic             rst_n,
  axi4_if.s                bus,
  output logic             timer_irq_o,
  output logic             soft_irq_o
);

  localparam logic [47:0] MSIP_OFF     = 48'h0000_0000_0000;
  localparam logic [47:0] MTIMECMP_OFF = 48'h0000_0000_4000;
  localparam logic [47:0] MTIME_OFF    = 48'h0000_0000_BFF8;

  logic        msip_q;
  logic [63:0] mtimecmp_q;
  logic [63:0] mtime_q;

  assign timer_irq_o = (mtime_q >= mtimecmp_q);
  assign soft_irq_o  = msip_q;

  typedef enum logic [1:0] {W_IDLE, W_DATA, W_RESP} wst_e;
  typedef enum logic [1:0] {R_IDLE, R_DATA} rst_e;
  wst_e wst;
  rst_e rst;

  logic [47:0] w_off, r_off;
  logic [3:0]  w_id;
  logic [63:0] w_data;
  logic [7:0]  w_strb;
  logic [3:0]  r_id;

  function automatic logic [63:0] strb_mask(input logic [7:0] strb);
    logic [63:0] m;
    m = '0;
    for (int i = 0; i < 8; i++)
      if (strb[i]) m[i*8 +: 8] = 8'hFF;
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
      msip_q     <= 1'b0;
      mtimecmp_q <= 64'hFFFF_FFFF_FFFF_FFFF;
      mtime_q    <= 64'd0;
      w_off <= '0; r_off <= '0; w_id <= '0;
      w_data <= '0; w_strb <= '0; r_id <= '0;
    end else begin
      // mtime free-runs every cycle.
      mtime_q <= mtime_q + 64'd1;
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
            w_data <= bus.wdata;
            w_strb <= bus.wstrb;
            bus.wready <= 1'b0;
            wst <= W_RESP;
            if (w_off == MSIP_OFF && bus.wstrb[0])
              msip_q <= bus.wdata[0];
            else if (w_off == MTIMECMP_OFF)
              mtimecmp_q <= (mtimecmp_q & ~strb_mask(bus.wstrb)) |
                            (bus.wdata & strb_mask(bus.wstrb));
            // mtime is read-only (writes ignored).
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
          if (r_off == MSIP_OFF)
            bus.rdata <= {63'd0, msip_q};
          else if (r_off == MTIMECMP_OFF)
            bus.rdata <= mtimecmp_q;
          else if (r_off == MTIME_OFF)
            bus.rdata <= mtime_q;
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
