// Vector register file (RVV v0 skeleton): 32 x VLEN(256) bits.
//
// Byte-granular ports match the SEW=8-only skeleton VLSU (one element per
// cycle). Wider SEW/LMUL later widens these ports; the 32x32B array itself
// is already full-VLEN. Combinational read, synchronous write. v0 is
// undisturbed on unwritten tail/prestart elements (writer only touches
// active elements); agnostic tails simply leave stale bytes.
module vregfile #(
  parameter int VLEN_B = 32, // VLEN in bytes (256b)
  parameter int NREG   = 32
) (
  input  logic             clk,
  input  logic             rst_n,
  // Read port (VLSU store-data source): combinational.
  input  logic [4:0]       raddr_i,
  input  logic [4:0]       ridx_i,   // byte element index (SEW=8)
  output logic [7:0]       rdata_o,
  // Write port (VLSU load-data sink): synchronous.
  input  logic [4:0]       waddr_i,
  input  logic [4:0]       widx_i,
  input  logic [7:0]       wdata_i,
  input  logic             we_i
);

  logic [7:0] vrf [NREG][VLEN_B];

  assign rdata_o = vrf[raddr_i][ridx_i];

  always_ff @(posedge clk) begin
    if (we_i)
      vrf[waddr_i][widx_i] <= wdata_i;
  end

endmodule
