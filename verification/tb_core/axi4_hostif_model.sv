module axi4_hostif_model #(
  parameter ADDR_W = 48,
  parameter DATA_W = 64,
  parameter ID_W   = 4,
  parameter logic [47:0] BASE = 48'h0001_0000_0000
) (
  input  logic clk,
  input  logic rst_n,
  axi4_if.s bus,
  output logic        test_done,
  output logic        test_pass,
  output logic [63:0] tohost_val
);
  import rv64gch_memmap_pkg::*;

  localparam logic [47:0] TOHOST_ADDR   = BASE + TOHOST_OFF[47:0];
  localparam logic [47:0] FROMHOST_ADDR = BASE + FROMHOST_OFF[47:0];
  localparam logic [47:0] CHAROUT_ADDR  = BASE + CHAROUT_OFF[47:0];
  // Test tohost at 0x80001000 (riscv-tests default location)
  localparam logic [47:0] TEST_TOHOST_ADDR = 48'h8000_1000;

  logic [63:0] tohost_r, fromhost_r;

  typedef enum logic [1:0] {W_IDLE, W_DATA, W_RESP} wst_e;
  typedef enum logic [1:0] {R_IDLE, R_DATA} rst_e;
  wst_e wst;
  rst_e rst;

  logic [ADDR_W-1:0] w_addr;
  logic [DATA_W-1:0] w_data;
  logic [ID_W-1:0]   w_id;
  logic [7:0]        r_len;
  logic [ID_W-1:0]   r_id;
  logic [7:0]        r_cnt;
  logic [ADDR_W-1:0] r_addr;

  assign tohost_val = tohost_r;
  assign test_pass  = tohost_r == TOHOST_PASS;
  assign test_done  = tohost_r != 64'd0;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      wst <= W_IDLE;
      tohost_r   <= '0;
      fromhost_r <= '0;
      bus.awready <= 1'b0;
      bus.wready  <= 1'b0;
      bus.bvalid  <= 1'b0;
      bus.bresp   <= 2'b00;
      bus.bid     <= '0;
    end else begin
      case (wst)
        W_IDLE: begin
          bus.bvalid <= 1'b0;
          bus.awready <= 1'b1;
          if (bus.awvalid && bus.awready) begin
            w_addr <= bus.awaddr;
            w_id   <= bus.awid;
            bus.awready <= 1'b0;
            wst <= W_DATA;
          end
        end
        W_DATA: begin
          bus.wready <= 1'b1;
          if (bus.wvalid && bus.wready) begin
            w_data <= bus.wdata;
            bus.wready <= 1'b0;
            wst <= W_RESP;
            if (w_addr == TOHOST_ADDR || w_addr == TEST_TOHOST_ADDR) begin
              tohost_r <= bus.wdata;
              if (bus.wdata != 64'd0)
                $display("[hostif] tohost <= 0x%016h @ %0t", bus.wdata, $time);
            end else if (w_addr == FROMHOST_ADDR) begin
              fromhost_r <= bus.wdata;
            end else if (w_addr == CHAROUT_ADDR) begin
              $write("%c", bus.wdata[7:0]);
              if (bus.wdata[7:0] == 8'h0a || bus.wdata[7:0] == 8'h0d)
                $fflush(1);
            end
          end
        end
        W_RESP: begin
          bus.bvalid <= 1'b1;
          bus.bresp  <= 2'b00;
          bus.bid    <= w_id;
          if (bus.bready && bus.bvalid) begin
            bus.bvalid <= 1'b0;
            wst <= W_IDLE;
          end
        end
      endcase
    end
  end

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      rst <= R_IDLE;
      bus.arready <= 1'b0;
      bus.rvalid  <= 1'b0;
      bus.rresp   <= 2'b00;
      bus.rlast   <= 1'b0;
      bus.rid     <= '0;
      bus.rdata   <= '0;
    end else begin
      case (rst)
        R_IDLE: begin
          bus.rvalid <= 1'b0;
          bus.arready <= 1'b1;
          if (bus.arvalid && bus.arready) begin
            r_addr <= bus.araddr;
            r_len  <= bus.arlen;
            r_id   <= bus.arid;
            r_cnt  <= '0;
            bus.arready <= 1'b0;
            rst <= R_DATA;
          end
        end
        R_DATA: begin
          bus.rvalid <= 1'b1;
          bus.rresp  <= 2'b00;
          bus.rid    <= r_id;
          bus.rlast  <= (r_cnt == r_len);
          if (r_addr == TOHOST_ADDR || r_addr == TEST_TOHOST_ADDR) bus.rdata <= tohost_r;
          else if (r_addr == FROMHOST_ADDR) bus.rdata <= fromhost_r;
          else                              bus.rdata <= '0;
          if (bus.rvalid && bus.rready) begin
            r_addr <= r_addr + (DATA_W/8);
            r_cnt  <= r_cnt + 8'd1;
            if (bus.rlast) begin
              bus.rvalid <= 1'b0;
              rst <= R_IDLE;
            end
          end
        end
      endcase
    end
  end

endmodule
