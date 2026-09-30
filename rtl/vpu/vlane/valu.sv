// VALU: element-serial integer vector ALU (RVV v0: e8 OPIVV + vmv.v.v).
//
// Occupies MEM exactly like the VLSU (the whole backend holds while
// sequencing) but touches no memory: one element per cycle, operands from
// the shared VRF read ports (vs1 on the data port, vs2 on the index port,
// v0 mask on the mask port -- the same four ports the VLSU uses, muxed in
// the core since only one unit is ever active), result sunk to vd the
// same cycle. Masked-off elements skip (no write, dest undisturbed);
// elements below vstart are never touched. vl/vstart sampled at sequence
// start (both stable: vset drains before vector issue, traps flush); a
// trap aborts. Cannot fault, so there is no fault path and no vstart
// update. Vector ops stay strictly serialized by the hold, hence no VRF
// forwarding is needed: every op sees fully-retired vector state.
module valu (
  input  logic         clk,
  input  logic         rst_n,
  // Occupancy: vector ALU op held in MEM (level). trap_i aborts.
  input  logic         active_i,
  input  logic         trap_i,
  input  logic [5:0]   aluop_i,    // funct6 (ADD/SUB/AND/OR/XOR/COPY)
  input  logic [4:0]   vd_i,
  input  logic [4:0]   vs1_i,      // second operand (rs1 field; COPY source)
  input  logic [4:0]   vs2_i,      // first operand (rs2 field)
  input  logic         masked_i,   // vm=0: skip v0.mask==0 elements
  input  logic [7:0]   vl_i,
  input  logic [7:0]   vstart_i,
  // VRF ports (byte granular, SEW=8; shared with the VLSU).
  output logic [4:0]   vrf_raddr_o,  // vs1
  output logic [4:0]   vrf_ridx_o,
  input  logic [7:0]   vrf_rdata_i,
  output logic [4:0]   vrf_iaddr_o,  // vs2
  output logic [4:0]   vrf_iidx_o,
  input  logic [7:0]   vrf_idata_i,
  output logic [4:0]   vrf_maddr_o,  // v0 mask
  output logic [4:0]   vrf_midx_o,
  input  logic [7:0]   vrf_mdata_i,
  output logic [4:0]   vrf_waddr_o,  // vd
  output logic [4:0]   vrf_widx_o,
  output logic [7:0]   vrf_wdata_o,
  output logic         vrf_we_o,
  output logic         busy_o,
  output logic         done_o
);
  import rtl_core_pkg::*;

  logic [7:0] i_q;         // current element index
  logic [7:0] vl_q;        // sampled vl
  logic       started_q;   // sequence latched start values

  assign vrf_raddr_o = vs1_i;
  assign vrf_ridx_o  = i_q[4:0];
  assign vrf_iaddr_o = vs2_i;
  assign vrf_iidx_o  = i_q[4:0];
  // Mask bit i = bit i of v0 (RVV LMUL=1 layout).
  assign vrf_maddr_o = 5'd0;
  assign vrf_midx_o  = i_q[4:3];
  logic mask_bit, masked_off;
  assign mask_bit   = (vrf_mdata_i >> i_q[2:0]) & 1'b1;
  assign masked_off = masked_i & ~mask_bit;

  // vd[i] = vs2[i] op vs1[i] (8-bit wrap); COPY moves vs1 (vmv.v.v).
  logic [7:0] opa, opb, res;
  assign opa = vrf_idata_i;
  assign opb = vrf_rdata_i;
  always_comb begin
    case (aluop_i)
      VALU_ADD:  res = opa + opb;
      VALU_SUB:  res = opa - opb;
      VALU_AND:  res = opa & opb;
      VALU_OR:   res = opa | opb;
      VALU_XOR:  res = opa ^ opb;
      VALU_COPY: res = opb;
      default:   res = 8'd0;
    endcase
  end

  assign vrf_waddr_o = vd_i;
  assign vrf_widx_o  = i_q[4:0];
  assign vrf_wdata_o = res;
  // Level (not pulsed): i advances every active cycle, so each element is
  // written exactly once; masked-off elements skip the write entirely.
  assign vrf_we_o = active_i & started_q & ~done_o & ~masked_off;

  assign done_o = started_q & (i_q >= vl_q);
  assign busy_o = active_i & started_q & ~done_o;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      i_q <= '0; vl_q <= '0; started_q <= 1'b0;
    end else if (trap_i || !active_i) begin
      i_q <= '0; started_q <= 1'b0;
    end else begin
      if (!started_q) begin
        // First active cycle: sample vl/vstart (both stable, see header).
        i_q <= vstart_i;
        vl_q <= vl_i;
        started_q <= 1'b1;
      end else if (!done_o) begin
        // One element per cycle (masked-off keeps the same pace).
        i_q <= i_q + 8'd1;
      end
    end
  end

endmodule
