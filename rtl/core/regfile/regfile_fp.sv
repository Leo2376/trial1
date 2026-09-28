module regfile_fp #(
  parameter int XLEN = 64
) (
  input  logic             clk,
  input  logic             rst_n,
  input  logic [4:0]       waddr,
  input  logic             we,
  input  logic [XLEN-1:0]  wdata,
  input  logic [4:0]       raddr1,
  input  logic [4:0]       raddr2,
  input  logic [4:0]       raddr3,
  output logic [XLEN-1:0]  rdata1,
  output logic [XLEN-1:0]  rdata2,
  output logic [XLEN-1:0]  rdata3,
  // Extra read ports for dual-fetch slot 1 (Decode).
  input  logic [4:0]       raddr4,
  input  logic [4:0]       raddr5,
  input  logic [4:0]       raddr6,
  output logic [XLEN-1:0]  rdata4,
  output logic [XLEN-1:0]  rdata5,
  output logic [XLEN-1:0]  rdata6
);
  logic [XLEN-1:0] regs [0:31];

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      for (int i = 0; i < 32; i++) regs[i] <= '0;
    end else if (we) begin
      regs[waddr] <= wdata;
    end
  end

  assign rdata1 = regs[raddr1];
  assign rdata2 = regs[raddr2];
  assign rdata3 = regs[raddr3];
  assign rdata4 = regs[raddr4];
  assign rdata5 = regs[raddr5];
  assign rdata6 = regs[raddr6];

endmodule
