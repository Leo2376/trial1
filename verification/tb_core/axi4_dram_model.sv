module axi4_dram_model #(
  parameter ADDR_W = 48,
  parameter DATA_W = 64,
  parameter ID_W   = 4,
  parameter MEM_WORDS = 64*1024,
  parameter string HEX_FILE = "prog.vh",
  parameter logic [ADDR_W-1:0] BASE = 0
) (
  input  logic clk,
  input  logic rst_n,
  axi4_if.s bus
);
  localparam STRB_W = DATA_W/8;

  logic [DATA_W-1:0] mem [0:MEM_WORDS-1];
  string hex_file;

  initial begin
    for (int i = 0; i < MEM_WORDS; i++) mem[i] = '0;
    hex_file = HEX_FILE;
    void'($value$plusargs("hex=%s", hex_file));
    if (hex_file != "" && hex_file != "none") begin
      $readmemh(hex_file, mem);
    end
  end

  typedef enum logic [1:0] {W_IDLE, W_DATA, W_RESP} wst_e;
  typedef enum logic [1:0] {R_IDLE, R_DATA} rst_e;
  wst_e wst;
  rst_e rst;

  logic [ADDR_W-1:0] w_addr;
  logic [7:0]        w_len;
  logic [ID_W-1:0]   w_id;
  logic [7:0]        w_cnt;
  logic [ADDR_W-1:0] r_addr;
  logic [7:0]        r_len;
  logic [ID_W-1:0]   r_id;
  logic [7:0]        r_cnt;
  logic [DATA_W-1:0]  wmask;
  logic [ADDR_W-1:0]  w_idx_q;
  logic [ADDR_W-1:0]  r_idx_q;

  function automatic logic [ADDR_W-1:0] word_idx(input logic [ADDR_W-1:0] a);
    return (a - BASE) >> 3;
  endfunction

  // Expand the per-byte write strobe into a DATA_W bit mask and precompute
  // the word indices (avoids function calls inside array NBA indices, which
  // some simulators/elaborators do not accept).
  always_comb begin
    for (int b = 0; b < STRB_W; b++)
      wmask[b*8 +: 8] = {8{bus.wstrb[b]}};
    w_idx_q = word_idx(w_addr);
    r_idx_q = word_idx(r_addr);
  end

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      wst <= W_IDLE;
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
            w_addr  <= bus.awaddr;
            w_len   <= bus.awlen;
            w_id    <= bus.awid;
            bus.awready <= 1'b0;
            wst <= W_DATA;
          end
        end
        W_DATA: begin
          bus.wready <= 1'b1;
          if (bus.wvalid && bus.wready) begin
            // Merge the strobed bytes into the existing word. Writing the
            // whole word (rather than per-byte part-selects) keeps the
            // array-index form synthesis/sim friendly.
            mem[w_idx_q] <= (bus.wdata & wmask) |
                            (mem[w_idx_q] & ~wmask);
            w_addr <= w_addr + (DATA_W/8);
            w_cnt  <= w_cnt + 8'd1;
            if (bus.wlast) begin
              bus.wready <= 1'b0;
              wst <= W_RESP;
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
          bus.rdata  <= mem[r_idx_q];
          bus.rlast  <= (r_cnt == r_len);
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
