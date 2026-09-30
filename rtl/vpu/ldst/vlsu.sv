// VLSU: vector load/store sequencer (RVV v0 skeleton).
//
// Shared-path design: the VLSU time-multiplexes the CPU's existing data
// path. While a vector ld/st occupies MEM, the core muxes the MMU data
// port (VA/rd/wr/valid) and the L1D beat (req/we/addr/be/wdata) to the
// VLSU and gates the scalar LSU off. One SEW=8 element per beat:
//
//   VA=base+i (unit) or VA=va_q+=stride (strided) -> wait TLB hit
//   (walker stalls pipe via dtlb_miss, VLSU holds) -> latch PA ->
//   mem beat -> ack -> next i (load: byte to VRF).
//
// Faults are precise per element: the MMU fault cause is reported with
// elem_idx_o so the core traps with vstart=i (restartable). Interrupts
// cannot coincide (the core only takes them with an empty backend).
// Only e8, vm=1 (unmasked); vl/vstart sampled at sequence start (both
// stable: vset drains before vector issue, traps flush). Stride comes
// from the stable MEM packet (x[rs2] latched at EX->MEM, backend holds).
module vlsu #(
  parameter int XLEN = 64
) (
  input  logic             clk,
  input  logic             rst_n,
  // Occupancy: vector op held in MEM (level). trap_i aborts.
  input  logic             active_i,
  input  logic             trap_i,
  input  logic             is_load_i,
  input  logic             is_stride_i,  // vlse/vsse: VA advances by stride
  input  logic [63:0]      stride_i,     // byte stride (x[rs2], signed)
  input  logic [63:0]      base_va_i,
  input  logic [4:0]       vd_i,
  input  logic [7:0]       vl_i,
  input  logic [7:0]       vstart_i,
  // VRF ports (byte granular, SEW=8).
  output logic [4:0]       vrf_raddr_o,
  output logic [4:0]       vrf_ridx_o,
  input  logic [7:0]       vrf_rdata_i,
  output logic [4:0]       vrf_waddr_o,
  output logic [4:0]       vrf_widx_o,
  output logic [7:0]       vrf_wdata_o,
  output logic             vrf_we_o,
  // MMU data-port drive (core muxes with the scalar EX side).
  output logic [63:0]      mmu_va_o,
  output logic             mmu_rd_o,
  output logic             mmu_wr_o,
  output logic             mmu_valid_o,
  input  logic             mmu_hit_i,
  input  logic [47:0]      mmu_pa_i,
  input  logic             mmu_fault_i,
  // L1D beat drive (core muxes below u_lsu; PA latched on TLB hit).
  output logic             mem_req_o,
  output logic             mem_we_o,
  output logic [47:0]      mem_addr_o,
  output logic [7:0]       mem_be_o,
  output logic [63:0]      mem_wdata_o,
  input  logic [63:0]      mem_rdata_i,
  input  logic             mem_ack_i,
  input  logic             mem_ready_i,
  input  logic             fence_hold_i,
  // Status to the core: hold the pipe while sequencing; done/fault end it.
  // beat_o pulses when an element beat completes on the bus (for the
  // core's commit tracer: vector stores log like scalar MEM stores).
  output logic             busy_o,
  output logic             done_o,
  output logic             fault_o,
  output logic [7:0]       elem_idx_o,
  output logic             beat_o
);

  logic [7:0]  i_q;        // current element index
  logic [7:0]  vl_q;       // sampled vl
  logic [63:0] va_q;       // strided running VA (base+vstart*stride, +=stride)
  logic        started_q;  // sequence latched start values
  logic        fault_q;    // element fault latched (until !active/trap)
  // Beat handshake (mirrors u_lsu issued/pending: no double-issue of a
  // store beat, no stale-ack capture on loads).
  logic        have_pa_q;  // PA latched for the current element
  logic [47:0] pa_q;
  logic        issued_q;
  logic        pending_q;

  logic [63:0] va_cur;
  // Unit: VA=base+i. Strided: running va_q (init skips vstart elements so a
  // restart after a fault resumes at the right address, not base+vstart*i).
  // All stride/stride-flag inputs ride the stable MEM packet (backend holds
  // while sequencing), so live use is safe. 8b vstart x 64b stride mult.
  assign va_cur = is_stride_i ? va_q : (base_va_i + {56'd0, i_q});
  assign elem_idx_o = i_q;

  // VRF: store source reads element i combinationally; load sink writes
  // the extracted byte on the beat's own ack.
  assign vrf_raddr_o = vd_i;
  assign vrf_ridx_o  = i_q[4:0];
  logic [7:0] elem_byte;
  assign elem_byte = vrf_rdata_i;
  // PA[2:0]==VA[2:0] (translation preserves the page offset).
  logic [2:0] lane;
  assign lane = va_cur[2:0];
  assign vrf_waddr_o = vd_i;
  assign vrf_widx_o  = i_q[4:0];
  assign vrf_wdata_o = mem_rdata_i >> (lane*8);
  assign vrf_we_o = active_i & started_q & ~fault_q & is_load_i &
                    pending_q & mem_ack_i;

  // MMU drive: present the current element VA until it faults; hold it
  // across walker misses (pipe stall keeps everything stable).
  assign mmu_va_o    = va_cur;
  assign mmu_rd_o    = is_load_i;
  assign mmu_wr_o    = ~is_load_i;
  assign mmu_valid_o = active_i & started_q & ~fault_q & ~done_o;

  // L1D beat: only with a translated PA (never issue VA as PA).
  assign mem_req_o   = active_i & started_q & ~fault_q & ~done_o &
                       have_pa_q & ~issued_q & ~fence_hold_i;
  assign mem_we_o    = ~is_load_i;
  assign mem_addr_o  = pa_q;
  assign mem_be_o    = 8'h01 << lane;
  assign mem_wdata_o = {56'd0, elem_byte} << (lane*8);

  assign done_o  = started_q & (i_q >= vl_q);
  assign fault_o = fault_q;
  assign beat_o  = active_i & started_q & pending_q & mem_ack_i;
  // Hold the pipe while sequencing (elements remain, no fault, not done).
  assign busy_o  = active_i & started_q & ~fault_q & ~done_o;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      i_q <= '0; vl_q <= '0; va_q <= '0;
      started_q <= 1'b0; fault_q <= 1'b0;
      have_pa_q <= 1'b0; pa_q <= '0; issued_q <= 1'b0; pending_q <= 1'b0;
    end else if (trap_i || !active_i) begin
      i_q <= '0; started_q <= 1'b0; fault_q <= 1'b0;
      have_pa_q <= 1'b0; issued_q <= 1'b0; pending_q <= 1'b0;
    end else begin
      if (!started_q) begin
        // First active cycle: sample vl/vstart (both stable, see header).
        i_q <= vstart_i;
        vl_q <= vl_i;
        va_q <= base_va_i + ({56'd0, vstart_i} * stride_i);
        started_q <= 1'b1;
        have_pa_q <= 1'b0; issued_q <= 1'b0; pending_q <= 1'b0;
      end else if (!fault_q && !done_o) begin
        // Latch the MMU fault for this element (core traps; vstart=i).
        if (mmu_fault_i) begin
          fault_q <= 1'b1;
        end else begin
          // Latch PA on TLB hit (VA held, so the hit stays valid).
          if (mmu_hit_i && !have_pa_q) begin
            pa_q <= mmu_pa_i;
            have_pa_q <= 1'b1;
          end
          if (mem_req_o & mem_ready_i) begin
            issued_q <= 1'b1;
            pending_q <= 1'b1;
          end
          if (pending_q & mem_ack_i) begin
            // Beat complete: next element (load byte already sunk to VRF
            // by vrf_we_o this same edge).
            i_q <= i_q + 8'd1;
            va_q <= va_q + stride_i;
            have_pa_q <= 1'b0;
            issued_q <= 1'b0;
            pending_q <= 1'b0;
          end
        end
      end
    end
  end

endmodule
