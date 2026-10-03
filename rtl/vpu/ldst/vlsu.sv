// VLSU: vector load/store sequencer (RVV unit/stride/indexed).
//
// Shared-path design: the VLSU time-multiplexes the CPU's existing data
// path. While a vector ld/st occupies MEM, the core muxes the MMU data
// port (VA/rd/wr/valid) and the L1D beat (req/we/addr/be/wdata) to the
// VLSU and gates the scalar LSU off. Byte-serial over (element, byte):
// one byte per beat, ew bytes per element (ew = 1<<SEW, SEW from the
// vtype CSR, equal to the instruction EEW by decode construction).
//
//   unit:    VA=base+j (j = e*ew+k, contiguous bytes)
//   strided: VA=va_elem(e)+k, va_elem advances by x[rs2] per element
//   indexed: VA=base+vs2[e]+k (e8 indices, zero-extended; each element
//            independent so restarts need no accumulator)
//   -> wait TLB hit (walker stalls pipe via dtlb_miss, VLSU holds) ->
//   latch PA -> mem beat -> ack -> next byte (next element at k=ew-1).
//
// Faults are precise per element: the MMU fault cause is reported with
// elem_idx_o so the core traps with vstart=e (restartable). A fault on
// byte k>0 of an element still reports vstart=e; restart re-executes the
// whole element idempotently (same bytes). Interrupts cannot coincide
// (the core only takes them with an empty backend). Masked (vm=0, v0
// mask) and unmasked: masked-off elements skip all ew bytes, never fault,
// and leave dest/memory undisturbed. vl/vstart are element counts sampled
// at sequence start (both stable: vset drains before vector issue, traps
// flush). Stride comes from the stable MEM packet (x[rs2] latched at
// EX->MEM, backend holds).
//
// Sequencer (re)start: back-to-back vector ops hand MEM over with no idle
// gap, so the active level alone cannot delimit sequences. The core pulses
// start_i for the cycle a new vector op occupies MEM; the unit (re)samples
// vl/vstart then and holds the pipe for that cycle.
module vlsu #(
  parameter int XLEN = 64
) (
  input  logic             clk,
  input  logic             rst_n,
  // Occupancy: vector op held in MEM (level). trap_i aborts.
  input  logic             active_i,
  input  logic             trap_i,
  // Pulse: a new vector op has just entered MEM (re)sample this cycle.
  input  logic             start_i,
  input  logic             is_load_i,
  input  logic             is_stride_i,  // vlse/vsse: VA advances by stride
  input  logic [63:0]      stride_i,     // byte stride (x[rs2], signed)
  input  logic             is_indexed_i, // vluxei/vsuxei: VA=base+vs2[e]
  input  logic [4:0]       vs2_i,        // index vector reg (rs2 field)
  input  logic             masked_i,     // vm=0: skip v0.mask==0 elements
  input  logic [1:0]       sew_i,        // SEW code: 0/1/2/3 = 8/16/32/64
  input  logic [63:0]      base_va_i,
  input  logic [4:0]       vd_i,
  input  logic [7:0]       vl_i,         // element count
  input  logic [7:0]       vstart_i,     // element index
  // VRF ports (byte granular).
  output logic [4:0]       vrf_raddr_o,
  output logic [4:0]       vrf_ridx_o,   // byte j of the element
  input  logic [7:0]       vrf_rdata_i,
  output logic [4:0]       vrf_iaddr_o,  // index source (vs2[e], e8)
  output logic [4:0]       vrf_iidx_o,
  input  logic [7:0]       vrf_idata_i,
  output logic [4:0]       vrf_maddr_o,  // mask source (v0 bit e)
  output logic [4:0]       vrf_midx_o,
  input  logic [7:0]       vrf_mdata_i,
  output logic [4:0]       vrf_waddr_o,
  output logic [4:0]       vrf_widx_o,   // byte j of the element
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

  logic [7:0]  e_q;        // current element index
  logic [2:0]  k_q;        // current byte within the element
  logic [7:0]  vl_q;       // sampled vl (elements)
  logic [63:0] va_q;       // strided running element VA
  logic        started_q;  // sequence latched start values
  logic        fault_q;    // element fault latched (until !active/trap)
  // Beat handshake (mirrors u_lsu issued/pending: no double-issue of a
  // store beat, no stale-ack capture on loads).
  logic        have_pa_q;  // PA latched for the current byte
  logic [47:0] pa_q;
  logic        issued_q;
  logic        pending_q;
  // Fresh-op pulse, gated on occupancy.
  logic w_start;
  assign w_start = start_i & active_i;

  logic [7:0]  ew;         // element width in bytes (1/2/4/8)
  assign ew = 8'd1 << sew_i;
  // Byte index within the whole transfer (e*ew+k <= 31: vl <= 32/ew).
  logic [7:0]  j;
  assign j = (e_q << sew_i) | {5'd0, k_q};

  assign vrf_iaddr_o = vs2_i;
  assign vrf_iidx_o  = e_q[4:0];
  // Mask bit e = bit e of v0 (RVV LMUL=1 layout: byte e>>3, bit e&7).
  // Evaluated per element; skipped elements never touch memory, never
  // fault (checked before mmu_fault_i below) and leave the destination
  // undisturbed.
  assign vrf_maddr_o = 5'd0;
  assign vrf_midx_o  = e_q[4:3];
  logic mask_bit;
  assign mask_bit = (vrf_mdata_i >> e_q[2:0]) & 1'b1;
  logic masked_off;
  assign masked_off = masked_i & ~mask_bit;
  // Byte VA: unit = base+j; strided = running element VA + k;
  // indexed = base + e8-index(e) + k (byte offsets, unscaled).
  // All stride/index inputs ride the stable MEM packet (backend holds
  // while sequencing), so live use is safe. 8b vstart x 64b stride mult.
  logic [63:0] va_cur;
  assign va_cur = is_stride_i ? (va_q + {61'd0, k_q}) :
                  (is_indexed_i ? (base_va_i + {56'd0, vrf_idata_i} +
                                    {61'd0, k_q}) :
                                   (base_va_i + {56'd0, j}));
  assign elem_idx_o = e_q;

  // VRF: store source reads byte j combinationally; load sink writes
  // the extracted byte on the beat's own ack. The (re)sample cycle never
  // writes (e/k not yet sampled).
  assign vrf_raddr_o = vd_i;
  assign vrf_ridx_o  = j[4:0];
  logic [7:0] elem_byte;
  assign elem_byte = vrf_rdata_i;
  // PA[2:0]==VA[2:0] (translation preserves the page offset).
  logic [2:0] lane;
  assign lane = va_cur[2:0];
  assign vrf_waddr_o = vd_i;
  assign vrf_widx_o  = j[4:0];
  assign vrf_wdata_o = mem_rdata_i >> (lane*8);
  assign vrf_we_o = active_i & started_q & ~w_start & ~fault_q & is_load_i &
                    ~masked_off & pending_q & mem_ack_i;

  // MMU drive: present the current byte VA until it faults; hold it
  // across walker misses (pipe stall keeps everything stable). Masked-off
  // elements present nothing (valid 0, so no translation, no fault).
  // Nothing is presented during the (re)sample cycle (VA not yet sampled).
  assign mmu_va_o    = va_cur;
  assign mmu_rd_o    = is_load_i;
  assign mmu_wr_o    = ~is_load_i;
  assign mmu_valid_o = active_i & started_q & ~w_start & ~fault_q & ~done_o &
                       ~masked_off;

  // L1D beat: only with a translated PA (never issue VA as PA).
  assign mem_req_o   = active_i & started_q & ~w_start & ~fault_q & ~done_o &
                       ~masked_off & have_pa_q & ~issued_q & ~fence_hold_i;
  assign mem_we_o    = ~is_load_i;
  assign mem_addr_o  = pa_q;
  assign mem_be_o    = 8'h01 << lane;
  assign mem_wdata_o = {56'd0, elem_byte} << (lane*8);

  assign done_o  = started_q & (e_q >= vl_q) & ~w_start;
  assign fault_o = fault_q;
  assign beat_o  = active_i & started_q & ~w_start & pending_q & mem_ack_i;
  // Hold the pipe while sequencing (bytes remain, no fault, not done).
  // The (re)sample cycle always holds: the stale done must not release a
  // newly arrived op before it samples.
  assign busy_o  = active_i & (w_start | (started_q & ~fault_q & ~done_o));

  // Last byte of the element?
  logic last_byte;
  assign last_byte = ({5'd0, k_q} == (ew - 8'd1));

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      e_q <= '0; k_q <= '0; vl_q <= '0; va_q <= '0;
      started_q <= 1'b0; fault_q <= 1'b0;
      have_pa_q <= 1'b0; pa_q <= '0; issued_q <= 1'b0; pending_q <= 1'b0;
    end else if (trap_i || !active_i) begin
      e_q <= '0; k_q <= '0; started_q <= 1'b0; fault_q <= 1'b0;
      have_pa_q <= 1'b0; issued_q <= 1'b0; pending_q <= 1'b0;
    end else begin
      if (!started_q || w_start) begin
        // First active cycle, or a new op handed over with no idle gap:
        // (re)sample vl/vstart (both stable, see header); drop any stale
        // beat state (a new op never resumes an old element's PA/ack).
        // Strided init skips vstart elements so a restart after a fault
        // resumes at the right address.
        e_q <= vstart_i;
        k_q <= '0;
        vl_q <= vl_i;
        va_q <= base_va_i + ({56'd0, vstart_i} * stride_i);
        started_q <= 1'b1;
        fault_q <= 1'b0;
        have_pa_q <= 1'b0; issued_q <= 1'b0; pending_q <= 1'b0;
      end else if (!fault_q && !done_o) begin
        // Masked-off element: skip all ew bytes (no fault possible, dest
        // undisturbed). Checked before mmu_fault_i so a wild VA on a
        // masked-off element can never latch a fault. Strided VA keeps
        // pace (va_q unused by unit/indexed).
        if (masked_off) begin
          e_q <= e_q + 8'd1;
          va_q <= va_q + stride_i;
        end else if (mmu_fault_i) begin
          // Latch the MMU fault for this byte (core traps; vstart=e).
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
            // Byte complete: next byte (load byte already sunk to VRF by
            // vrf_we_o this same edge); next element at ew boundary.
            have_pa_q <= 1'b0;
            issued_q <= 1'b0;
            pending_q <= 1'b0;
            if (last_byte) begin
              e_q <= e_q + 8'd1;
              k_q <= '0;
              va_q <= va_q + stride_i;
            end else begin
              k_q <= k_q + 3'd1;
            end
          end
        end
      end
    end
  end

endmodule
