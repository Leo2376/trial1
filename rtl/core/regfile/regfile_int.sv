module regfile_int #(
  parameter int XLEN = 64
) (
  input  logic             clk,
  input  logic             rst_n,
  input  logic [4:0]       waddr,
  input  logic             we,
  input  logic [XLEN-1:0]  wdata,
  // Second write port for dual-issue lane B (younger). On a same-cycle
  // same-address WAW pair, lane B wins (in-order retirement).
  input  logic [4:0]       waddr_b,
  input  logic             we_b,
  input  logic [XLEN-1:0]  wdata_b,
  input  logic [4:0]       raddr1,
  input  logic [4:0]       raddr2,
  output logic [XLEN-1:0]  rdata1,
  output logic [XLEN-1:0]  rdata2,
  // Extra read ports for dual-fetch slot 1 (Decode).
  input  logic [4:0]       raddr3,
  input  logic [4:0]       raddr4,
  output logic [XLEN-1:0]  rdata3,
  output logic [XLEN-1:0]  rdata4
);
  logic [XLEN-1:0] regs [1:31];

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      for (int i = 1; i < 32; i++) regs[i] <= '0;
    end else begin
      if (we && waddr != 5'd0) begin
        regs[waddr] <= wdata;
      end
      if (we_b && waddr_b != 5'd0) begin
        regs[waddr_b] <= wdata_b;
      end
    end
  end

  assign rdata1 = (raddr1 == 5'd0) ? '0 : regs[raddr1];
  assign rdata2 = (raddr2 == 5'd0) ? '0 : regs[raddr2];
  assign rdata3 = (raddr3 == 5'd0) ? '0 : regs[raddr3];
  assign rdata4 = (raddr4 == 5'd0) ? '0 : regs[raddr4];

endmodule
