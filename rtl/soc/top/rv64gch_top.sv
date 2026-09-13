module rv64gch_top #(
  parameter ADDR_W = 48,
  parameter DATA_W = 64,
  parameter ID_W   = 4,
  parameter XLEN    = 64
) (
  input  logic                clk,
  input  logic                rst_n,

  input  logic [XLEN-1:0]     hartid_i,
  input  logic                msi_n_i,
  input  logic [1:0]          dbg_req_i,
  input  logic                dbg_halt_req_i,

  output logic                core_active_o,

  axi4_if.m                  mem
);

  import rv64gch_memmap_pkg::*;

  localparam logic [47:0] CHAROUT_ADDR = HOSTIF_BASE + CHAROUT_OFF[47:0];
  localparam logic [47:0] TOHOST_ADDR  = HOSTIF_BASE + TOHOST_OFF[47:0];

  typedef enum logic [3:0] {
    ST_RESET,
    ST_FETCH_AW,
    ST_FETCH_W,
    ST_FETCH_B,
    ST_FETCH_AR,
    ST_FETCH_R0,
    ST_FETCH_R1,
    ST_EXEC,
    ST_CHAROUT_AW,
    ST_CHAROUT_W,
    ST_CHAROUT_B,
    ST_TOHOST_AW,
    ST_TOHOST_W,
    ST_TOHOST_B,
    ST_DONE
  } cpu_st_e;

  cpu_st_e st;

  logic [ADDR_W-1:0] pc;
  logic [DATA_W-1:0] fetch_word;
  logic [DATA_W-1:0] insn_lo, insn_hi;
  logic [47:0]       cur_addr;
  logic [DATA_W-1:0] cur_wdata;

  localparam string MSG = "RV64GCH stub: hello from CPU top\n";
  int msg_idx;

  assign core_active_o = (st != ST_DONE) && (st != ST_RESET);

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      st          <= ST_RESET;
      pc          <= RESET_PC;
      msg_idx     <= 0;
      mem.awvalid <= 1'b0;
      mem.wvalid  <= 1'b0;
      mem.bready  <= 1'b0;
      mem.arvalid <= 1'b0;
      mem.rready  <= 1'b0;
      mem.awaddr  <= '0;
      mem.wdata   <= '0;
    end else begin
      mem.awvalid <= 1'b0;
      mem.wvalid  <= 1'b0;
      mem.bready  <= 1'b0;
      mem.arvalid <= 1'b0;
      mem.rready  <= 1'b0;
      case (st)
        ST_RESET: begin
          pc      <= RESET_PC;
          msg_idx <= 0;
          st      <= ST_FETCH_AR;
        end

        ST_FETCH_AR: begin
          mem.araddr  <= pc;
          mem.arvalid <= 1'b1;
          if (mem.arvalid && mem.arready) begin
            mem.arvalid <= 1'b0;
            mem.rready  <= 1'b1;
            st <= ST_FETCH_R0;
          end
        end

        ST_FETCH_R0: begin
          mem.rready <= 1'b1;
          if (mem.rvalid && mem.rready) begin
            insn_lo <= mem.rdata;
            mem.rready <= 1'b0;
            st <= ST_FETCH_R1;
          end
        end
        ST_FETCH_R1: begin
          mem.rready <= 1'b1;
          if (mem.rvalid && mem.rready) begin
            insn_hi <= mem.rdata;
            mem.rready <= 1'b0;
            st <= ST_EXEC;
          end
        end

        ST_EXEC: begin
          if (msg_idx < MSG.len()) begin
            cur_addr  <= CHAROUT_ADDR;
            cur_wdata <= {56'd0, MSG[msg_idx]};
            mem.awaddr  <= CHAROUT_ADDR;
            mem.wdata   <= {56'd0, MSG[msg_idx]};
            mem.awvalid <= 1'b1;
            st <= ST_CHAROUT_AW;
          end else begin
            cur_addr  <= TOHOST_ADDR;
            cur_wdata <= TOHOST_PASS;
            mem.awaddr  <= TOHOST_ADDR;
            mem.wdata   <= TOHOST_PASS;
            mem.awvalid <= 1'b1;
            st <= ST_TOHOST_AW;
          end
        end

        ST_CHAROUT_AW: begin
          mem.awaddr  <= cur_addr;
          mem.wdata   <= cur_wdata;
          mem.awvalid <= 1'b1;
          if (mem.awready) begin
            mem.awvalid <= 1'b0;
            mem.wvalid  <= 1'b1;
            st <= ST_CHAROUT_W;
          end
        end
        ST_CHAROUT_W: begin
          mem.awaddr <= cur_addr;
          mem.wdata  <= cur_wdata;
          mem.wvalid <= 1'b1;
          if (mem.wready) begin
            mem.wvalid <= 1'b0;
            mem.bready <= 1'b1;
            st <= ST_CHAROUT_B;
          end
        end
        ST_CHAROUT_B: begin
          mem.bready <= 1'b1;
          if (mem.bvalid) begin
            mem.bready <= 1'b0;
            msg_idx <= msg_idx + 1;
            st <= ST_EXEC;
          end
        end

        ST_TOHOST_AW: begin
          mem.awaddr  <= cur_addr;
          mem.wdata   <= cur_wdata;
          mem.awvalid <= 1'b1;
          if (mem.awready) begin
            mem.awvalid <= 1'b0;
            mem.wvalid  <= 1'b1;
            st <= ST_TOHOST_W;
          end
        end
        ST_TOHOST_W: begin
          mem.awaddr <= cur_addr;
          mem.wdata  <= cur_wdata;
          mem.wvalid <= 1'b1;
          if (mem.wready) begin
            mem.wvalid <= 1'b0;
            mem.bready <= 1'b1;
            st <= ST_TOHOST_B;
          end
        end
        ST_TOHOST_B: begin
          mem.bready <= 1'b1;
          if (mem.bvalid) begin
            mem.bready <= 1'b0;
            st <= ST_DONE;
          end
        end

        ST_DONE: st <= ST_DONE;
      endcase
    end
  end

  always_comb begin
    mem.awid    = '0;
    mem.awlen   = 8'd0;
    mem.awsize  = 3'd3;
    mem.awburst = 2'b01;
    mem.wstrb   = '1;
    mem.wlast   = 1'b1;
    mem.arid    = '0;
    mem.arlen   = 8'd1;
    mem.arsize  = 3'd3;
    mem.arburst = 2'b01;
  end

endmodule
