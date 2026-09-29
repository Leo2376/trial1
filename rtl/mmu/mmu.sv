// MMU: Sv39 address translation with a shared TLB and a hardware walker.
//
// One 32-entry fully-associative TLB shared by fetch and data lookups
// (dual combinational lookup ports). Bare mode (satp.MODE==0) and M-mode
// without MPRV bypass with PA=VA. A miss on either port runs the walker
// (data port first); the walker reads page tables through the memory-side
// port (routed to L2 port C, so PTEs stay coherent with drained L1D lines)
// and supports 4 KiB / 2 MiB / 1 GiB leaves with hardware A/D updates.
//
// Translation outcomes are precise: {hit, miss, fault+cause} are mutually
// exclusive per port. Fault causes: fetch 12/1, load 13/5, store 15/7
// (page vs access). A latched walker fault only applies to the VA it was
// raised for (VA-match qualified), so a redirect past a faulting page can
// never take a stale trap. No ASID tagging: any SFENCE.VMA or SATP write
// must flush (flush_i, edge-detected; clears all valid bits via sweep).
//
// Physical addresses are 48 bits. Translated PAs or table addresses that
// exceed 48 bits raise access faults. Virtual addresses must be canonical
// (va[63:39]==va[38]) in VM mode or they page-fault.
module mmu #(
  parameter int ADDR_W      = 48,
  parameter int TLB_ENTRIES = 32
) (
  input  logic              clk,
  input  logic              rst_n,

  // CSR state.
  input  logic [63:0]       satp_i,      // MODE/ASID/PPN
  input  logic [63:0]       mstatus_i,   // SUM/MXR/MPRV/MPP
  input  logic [1:0]        priv_i,      // current privilege
  // H extension: V=1 runs the VS-stage (vsatp) + G-stage (hgatp).
  input  logic              virt_i,      // virtualization mode
  input  logic [63:0]       vsatp_i,     // VS MODE/ASID/PPN (GPA root when G on)
  input  logic [63:0]       hgatp_i,     // G MODE/VMID/PPN (physical root)
  input  logic [63:0]       vsstatus_i,  // VS SUM/MXR for stage-1 checks
  input  logic              flush_all_i, // satp-write retire: clear all
  // Selective SFENCE.VMA (single-cycle pulse from EX): clear entries
  // matching (va iff has_va, asid iff has_asid); neither set = all.
  input  logic              flush_sel_i,
  input  logic [63:0]       flush_va_i,
  input  logic [15:0]       flush_asid_i,
  input  logic              flush_has_va_i,
  input  logic              flush_has_asid_i,

  // Fetch translate (exec; MPRV never applies to fetches).
  input  logic [63:0]       va_f_i,
  input  logic [1:0]        priv_f_i,
  output logic              hit_f_o,
  output logic [ADDR_W-1:0] pa_f_o,
  output logic              miss_f_o,
  output logic              fault_f_o,
  output logic [4:0]        cause_f_o,

  // Data translate (MPRV already applied by the core into priv_d_i).
  input  logic [63:0]       va_d_i,
  input  logic [1:0]        priv_d_i,
  input  logic              rd_d_i,      // needs R (loads, LR, AMO)
  input  logic              wr_d_i,      // needs W (stores, SC, AMO)
  input  logic              valid_d_i,   // EX holds a memory op
  output logic              hit_d_o,
  output logic [ADDR_W-1:0] pa_d_o,
  output logic              miss_d_o,
  output logic              fault_d_o,
  output logic [4:0]        cause_d_o,

  // Walker memory port (physical, single-beat 8B; -> L2 port C).
  output logic              req_o,
  output logic              we_o,
  output logic [ADDR_W-1:0] addr_o,
  output logic [7:0]        be_o,
  output logic [63:0]       wdata_o,
  output logic              lock_o,
  input  logic [63:0]       rdata_i,
  input  logic              ack_i,
  input  logic              ready_i
);

  import rtl_core_pkg::*;

  // satp fields (+ H stage-1/stage-2 roots).
  logic [3:0]  satp_mode;
  logic [43:0] satp_ppn;
  assign satp_mode = satp_i[63:60];
  assign satp_ppn  = satp_i[43:0];
  logic [3:0]  vsatp_mode;
  logic [43:0] vsatp_ppn;
  assign vsatp_mode = vsatp_i[63:60];
  assign vsatp_ppn  = vsatp_i[43:0];
  logic [3:0]  hgatp_mode;
  logic [43:0] hgatp_ppn;
  assign hgatp_mode = hgatp_i[63:60];
  assign hgatp_ppn  = hgatp_i[43:0];
  // Effective stage-1 root: vsatp when V=1 else satp.
  logic [3:0]  eff_mode;
  assign eff_mode = virt_i ? vsatp_mode : satp_mode;
  // G-stage active only for guests with a non-Bare hgatp.
  logic g_enable;
  assign g_enable = virt_i && (hgatp_mode == SATP_SV39 || hgatp_mode == SATP_SV48);
  logic g_sv48;
  assign g_sv48 = (hgatp_mode == SATP_SV48);

  logic vm_enable_f, vm_enable_d;
  logic is_sv48;
  assign is_sv48 = (eff_mode == SATP_SV48);
  assign vm_enable_f = ((eff_mode == SATP_SV39) || is_sv48) && (priv_f_i != PRIV_M);
  assign vm_enable_d = ((eff_mode == SATP_SV39) || is_sv48) && (priv_d_i != PRIV_M);
  // Bare+guest still needs the G-stage: a guest VA==GPA must translate.
  logic bare_g_f, bare_g_d;
  assign bare_g_f = virt_i && (eff_mode == SATP_BARE) && g_enable && (priv_f_i != PRIV_M);
  assign bare_g_d = virt_i && (eff_mode == SATP_BARE) && g_enable && (priv_d_i != PRIV_M);

  // SUM/MXR come from vsstatus in the guest, mstatus otherwise.
  logic mstatus_sum, mstatus_mxr;
  assign mstatus_sum = virt_i ? vsstatus_i[18] : mstatus_i[18];
  assign mstatus_mxr = virt_i ? vsstatus_i[19] : mstatus_i[19];
  // G-stage checks run as HS (S) with the host SUM/MXR.
  logic g_sum, g_mxr;
  assign g_sum = mstatus_i[18];
  assign g_mxr = mstatus_i[19];

  // ---------------------------------------------------------------- TLB --
  // Sv39: VPN 27 bits (VPN2/1/0), levels 2/1/0 = 1G/2M/4K.
  // Sv48: VPN 36 bits (VPN3/2/1/0), levels 3/2/1/0 = 512G/1G/2M/4K.
  localparam int VPN_BITS = 36;
  // Valid as a packed vector so a flush clears (masked) in one shot.
  logic [TLB_ENTRIES-1:0] tlb_valid;
  logic [VPN_BITS-1:0] tlb_vpn   [TLB_ENTRIES];
  logic [1:0]          tlb_level [TLB_ENTRIES]; // 3=512G, 2=1G, 1=2M, 0=4K
  logic [43:0]         tlb_ppn   [TLB_ENTRIES];
  logic                tlb_u     [TLB_ENTRIES];
  logic                tlb_r     [TLB_ENTRIES];
  logic                tlb_w     [TLB_ENTRIES];
  logic                tlb_x     [TLB_ENTRIES];
  logic                tlb_d     [TLB_ENTRIES];
  logic [15:0]         tlb_asid  [TLB_ENTRIES];
  logic                tlb_virt  [TLB_ENTRIES];
  logic [15:0]         tlb_vmid  [TLB_ENTRIES];
  // Round-robin victim cursor (translation misses are rare; no LRU).
  logic [$clog2(TLB_ENTRIES)-1:0] tlb_rr_q;
  logic [15:0] satp_asid;
  assign satp_asid = satp_i[59:44];

  // Effective permission check (M-mode bypassed by the caller).
  function automatic logic perm_ok(
    input logic [1:0] priv, input logic u, input logic r,
    input logic w, input logic x,
    input logic rd, input logic wr, input logic exec,
    input logic sum, input logic mxr);
    if (exec) begin
      // S executes U=0 only; U executes U=1 only.
      if (priv == PRIV_S) return (x && !u);
      else                return (x && u);
    end
    if (priv == PRIV_S && u) begin
      if (!sum) return 1'b0;
      if (rd && !(r || (mxr && x))) return 1'b0;
      if (wr && !w) return 1'b0;
      return 1'b1;
    end
    if (priv == PRIV_U && !u) return 1'b0;
    if (rd && !(r || (mxr && x))) return 1'b0;
    if (wr && !w) return 1'b0;
    return 1'b1;
  endfunction

  // VPN match mask per page size (superpages ignore low VPN bits).
  // VPN layout [35:0] = VPN3[35:27] VPN2[26:18] VPN1[17:9] VPN0[8:0].
  function automatic logic [VPN_BITS-1:0] level_mask(input logic [1:0] lvl);
    if (lvl == 2'd3)      level_mask = 36'hFF8000000; // keep VPN3 (512G)
    else if (lvl == 2'd2) level_mask = 36'hFFFFC0000; // keep VPN3/2 (1G)
    else if (lvl == 2'd1) level_mask = 36'hFFFFFFE00; // keep VPN3/2/1 (2M)
    else                  level_mask = 36'hFFFFFFFFF; // keep all (4K)
  endfunction

  // PA assembly per page size (PPN range vetted by the walker at install:
  // ppn[43:36]==0 always; superpage low-PPN alignment page-faults).
  function automatic logic [ADDR_W-1:0] make_pa(
    input logic [43:0] ppn, input logic [1:0] lvl, input logic [63:0] va);
    if (lvl == 2'd3)      make_pa = {ppn[35:27], va[38:0]};
    else if (lvl == 2'd2) make_pa = {ppn[35:18], va[29:0]};
    else if (lvl == 2'd1) make_pa = {ppn[35:9], va[20:0]};
    else                  make_pa = {ppn[35:0], va[11:0]};
  endfunction

  // Shared combinational lookup. way_o=TLB_ENTRIES on miss; need_d_o asks
  // the walker for a D update (a write to a D=0 entry re-walks).
  // H: entries are tagged {virt,vmid,asid}; guests match all three.
  function automatic logic [5:0] tlb_lookup(
    input logic [63:0] va, input logic [1:0] priv,
    input logic rd, input logic wr, input logic exec,
    input logic sum, input logic mxr, input logic [15:0] asid,
    input logic virt, input logic [15:0] vmid,
    output logic [ADDR_W-1:0] pa, output logic need_d);
    logic [VPN_BITS-1:0] vpn;
    integer e;
    tlb_lookup = 6'd32;
    pa = '0; need_d = 1'b0;
    vpn = va[47:12];
    for (e = 0; e < TLB_ENTRIES; e = e + 1) begin
      if (tlb_valid[e] && (tlb_virt[e] == virt) &&
          (!virt || (tlb_vmid[e] == vmid)) && (tlb_asid[e] == asid) &&
          ((vpn & level_mask(tlb_level[e])) ==
           (tlb_vpn[e] & level_mask(tlb_level[e]))) &&
          perm_ok(priv, tlb_u[e], tlb_r[e], tlb_w[e], tlb_x[e],
                  rd, wr, exec, sum, mxr)) begin
        pa = make_pa(tlb_ppn[e], tlb_level[e], va);
        need_d = wr && !tlb_d[e];
        tlb_lookup = e[5:0];
      end
    end
  endfunction

  function automatic logic canonical(input logic [63:0] va, input logic sv48);
    if (sv48) return (va[63:48] == {16{va[47]}});
    else      return (va[63:39] == {25{va[38]}});
  endfunction

  logic [15:0] hgatp_vmid;
  assign hgatp_vmid = hgatp_i[59:44];
  logic [15:0] eff_asid;
  assign eff_asid = virt_i ? vsatp_i[59:44] : satp_asid;
  // Fetch-port lookup (exec; never needs D).
  logic [5:0]           f_way;
  logic [ADDR_W-1:0]    f_pa;
  logic                 f_need_d;
  logic                 f_canon;
  assign f_canon = canonical(va_f_i, is_sv48);
  assign f_way = tlb_lookup(va_f_i, priv_f_i, 1'b0, 1'b0, 1'b1,
                            mstatus_sum, mstatus_mxr, eff_asid,
                            virt_i, hgatp_vmid, f_pa, f_need_d);

  // Data-port lookup.
  logic [5:0]           d_way;
  logic [ADDR_W-1:0]    d_pa;
  logic                 d_need_d;
  logic                 d_canon;
  assign d_canon = canonical(va_d_i, is_sv48);
  assign d_way = tlb_lookup(va_d_i, priv_d_i, rd_d_i, wr_d_i, 1'b0,
                            mstatus_sum, mstatus_mxr, eff_asid,
                            virt_i, hgatp_vmid, d_pa, d_need_d);

  // Walker state (serves one miss at a time; data port first).
  // (wst + WR_* states declared below with the G-stage registers.)
  logic        walk_which_q; // 0 = fetch, 1 = data
  logic [63:0] walk_va_q;
  logic        walk_wr_q;    // needs W (store-side)
  logic [1:0]  walk_priv_q;
  logic [1:0]  walk_level_q;
  logic [43:0] walk_ppn_q;   // current table base PPN (GPA when guest+G)
  logic [63:0] walk_pte_q;
  logic        walk_virt_q;  // guest walk (VS-stage + G-stage)
  // Latched fault (cause + VA), cleared by a new walk or flush edge.
  logic        fault_q;
  logic        fault_which_q;
  logic [4:0]  fault_cause_q;
  logic [63:0] fault_va_q;
  // Flush edges (retire pulses stretch across stalls; apply once).
  logic flush_all_d_q, flush_sel_d_q;
  // Selective clear mask (blocking): entries matching (va iff has_va,
  // asid iff has_asid). Superpage lines match when covering the VA.
  logic [TLB_ENTRIES-1:0] flush_mask;
  always_comb begin
    flush_mask = '0;
    for (integer e = 0; e < TLB_ENTRIES; e = e + 1) begin
      if (tlb_valid[e] &&
          (!flush_has_asid_i || (tlb_asid[e] == flush_asid_i)) &&
          (!flush_has_va_i ||
           (((flush_va_i[47:12] & level_mask(tlb_level[e])) ==
             (tlb_vpn[e] & level_mask(tlb_level[e]))))))
        flush_mask[e] = 1'b1;
    end
  end

  // Walker fault applies only to the VA it was raised for.
  logic fault_f_match, fault_d_match;
  assign fault_f_match = fault_q && !fault_which_q && (fault_va_q == va_f_i);
  assign fault_d_match = fault_q && fault_which_q && (fault_va_q == va_d_i) &&
                         valid_d_i;

  // Which port wants a walk (lookup missed incl. D-update, no fault)?
  // Data needs a live EX memory op; fetch is quasi-always needed.
  // Guest-Bare (VA==GPA) still walks the G-stage on a TLB miss.
  logic want_d, want_f;
  assign want_d = (vm_enable_d || bare_g_d) && valid_d_i &&
                  ((d_way == 6'd32) || d_need_d) && !fault_d_match;
  assign want_f = (vm_enable_f || bare_g_f) && (f_way == 6'd32) && !fault_f_match;

  // Port outputs (mutually exclusive hit/miss/fault per port).
  logic f_bare, d_bare;
  assign f_bare = !vm_enable_f && !bare_g_f;
  assign d_bare = !vm_enable_d && !bare_g_d;

  assign hit_f_o   = f_bare || (f_canon && (f_way != 6'd32));
  assign pa_f_o    = f_bare ? va_f_i[ADDR_W-1:0] : f_pa;
  assign fault_f_o = !f_bare && (!f_canon || fault_f_match);
  assign cause_f_o = !f_canon ? CAUSE_FETCH_PAGE_FAULT : fault_cause_q;
  assign miss_f_o  = !hit_f_o && !fault_f_o;

  assign hit_d_o   = d_bare || (d_canon && (d_way != 6'd32) && !d_need_d);
  assign pa_d_o    = d_bare ? va_d_i[ADDR_W-1:0] : d_pa;
  assign fault_d_o = !d_bare && (!d_canon || fault_d_match);
  assign cause_d_o = !d_canon ? (wr_d_i ? CAUSE_STORE_PAGE_FAULT
                                        : CAUSE_LOAD_PAGE_FAULT)
                              : fault_cause_q;
  assign miss_d_o  = !hit_d_o && !fault_d_o && valid_d_i && !d_bare;

  // Walker states: VS-stage (W_*) + nested G-stage (G_*) for guests.
  // G-walk translates one GPA (g_va_q) to HPA; on completion the walker
  // resumes the saved VS step (resume_q): 0=read VS PTE at HPA,
  // 1=install final HPA, 2=VS A/D write at HPA.
  typedef enum logic [3:0] {
    WR_IDLE, WR_READ, WR_WAIT, WR_EVAL, WR_WRITE, WR_WWAIT,
    WR_GREAD, WR_GWAIT, WR_GEVAL, WR_GWRITE, WR_GWWAIT
  } walk2_e;
  // Walk state register (replaces wst below; kept name wst for port logic).
  walk2_e wst;
  // VS-stage walk registers.
  logic [43:0] vs_ppn_q;      // current VS table base (GPA when G on)
  logic [47:0] vs_hpa_q;      // translated HPA of the pending VS PTE
  logic [63:0] vs_gpa_q;      // pending VS PTE GPA (pre-translation)
  logic [63:0] final_gpa_q;   // VS leaf GPA awaiting G-translate
  logic [1:0]  final_level_q;
  logic [43:0] final_ppn_q;
  logic        final_u_q, final_r_q, final_w_q, final_x_q, final_d_q;
  logic [1:0]  resume_q;      // 0=VS-read, 1=final-install, 2=VS-write
  // G-stage walk registers.
  logic [1:0]  g_level_q;
  logic [43:0] g_ppn_q;
  logic [63:0] g_pte_q;
  logic [63:0] g_va_q;        // GPA under translation
  // GPA of a VS PTE: {table_ppn, vpn[level]}. Table base is a GPA here.
  function automatic logic [63:0] vs_pte_gpa(
    input logic [43:0] ppn, input logic [1:0] lvl, input logic [63:0] va);
    vs_pte_gpa = {8'd0, ppn[35:0],
                  lvl == 2'd3 ? va[47:39] :
                  lvl == 2'd2 ? va[38:30] :
                  lvl == 2'd1 ? va[29:21] : va[20:12],
                  3'b000};
  endfunction
  // GPA of a G PTE from a physical table base (same indexing).
  function automatic logic [47:0] g_pte_hpa(
    input logic [43:0] ppn, input logic [1:0] lvl, input logic [63:0] gpa);
    g_pte_hpa = {ppn[35:0],
                 lvl == 2'd3 ? gpa[47:39] :
                 lvl == 2'd2 ? gpa[38:30] :
                 lvl == 2'd1 ? gpa[29:21] : gpa[20:12],
                 3'b000};
  endfunction

  // Walker memory port (single outstanding beat).
  // VS reads/writes go to the translated HPA when G is on; G reads/writes
  // are physical. A/D data word selected by which stage is writing.
  logic in_g_state;
  assign in_g_state = (wst == WR_GREAD) || (wst == WR_GWAIT) ||
                      (wst == WR_GEVAL) || (wst == WR_GWRITE) ||
                      (wst == WR_GWWAIT);
  assign req_o   = (wst == WR_READ) || (wst == WR_WRITE) ||
                   (wst == WR_GREAD) || (wst == WR_GWRITE);
  assign we_o    = (wst == WR_WRITE) || (wst == WR_GWRITE);
  assign be_o    = 8'hFF;
  assign lock_o  = 1'b0;
  // PTE address: VS-stage uses the translated HPA; G-stage walks physical.
  assign addr_o  = in_g_state ? g_pte_hpa(g_ppn_q, g_level_q, g_va_q) :
                   (walk_virt_q && g_enable ? vs_hpa_q[47:0] :
                    {walk_ppn_q[35:0],
                     walk_level_q == 2'd3 ? walk_va_q[47:39] :
                     walk_level_q == 2'd2 ? walk_va_q[38:30] :
                     walk_level_q == 2'd1 ? walk_va_q[29:21] : walk_va_q[20:12],
                     3'b000});
  // A/D update: set A(6), plus D(7) when the walk needs W.
  // G-stage write uses the G PTE (needs W only for VS writes? G leaf D
  // tracks VS writes too: set D when the outer walk is a store).
  assign wdata_o = in_g_state ? (g_pte_q | {56'h0, (walk_wr_q ? 8'hC0 : 8'h40)}) :
                   (walk_pte_q | {56'h0, (walk_wr_q ? 8'hC0 : 8'h40)});

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      wst <= WR_IDLE;
      walk_which_q <= 1'b0;
      walk_va_q <= '0; walk_wr_q <= 1'b0; walk_priv_q <= PRIV_M;
      walk_level_q <= 2'd2; walk_ppn_q <= '0; walk_pte_q <= '0;
      walk_virt_q <= 1'b0;
      vs_ppn_q <= '0; vs_hpa_q <= '0; vs_gpa_q <= '0;
      final_gpa_q <= '0; final_level_q <= 2'd0; final_ppn_q <= '0;
      final_u_q <= 1'b0; final_r_q <= 1'b0; final_w_q <= 1'b0;
      final_x_q <= 1'b0; final_d_q <= 1'b0;
      resume_q <= 2'd0;
      g_level_q <= 2'd2; g_ppn_q <= '0; g_pte_q <= '0; g_va_q <= '0;
      fault_q <= 1'b0; fault_which_q <= 1'b0;
      fault_cause_q <= '0; fault_va_q <= '0;
      tlb_rr_q <= '0;
      tlb_valid <= '0;
      flush_all_d_q <= 1'b0;
      flush_sel_d_q <= 1'b0;
    end else begin
      flush_all_d_q <= flush_all_i;
      flush_sel_d_q <= flush_sel_i;
      // Flush edges apply instantly (single nonblocking clear) and abort
      // any walk + drop the latched fault. Instant application keeps
      // younger lookups exact with no stall or sweep.
      if (flush_all_i && !flush_all_d_q) begin
        tlb_valid <= '0;
        if (wst != WR_IDLE) wst <= WR_IDLE;
        fault_q <= 1'b0;
      end else if (flush_sel_i && !flush_sel_d_q) begin
        tlb_valid <= tlb_valid & ~flush_mask;
        if (wst != WR_IDLE) wst <= WR_IDLE;
        fault_q <= 1'b0;
      end else begin
        case (wst)
          WR_IDLE: begin
            // Data port first (older), then fetch.
            if (want_d) begin
              walk_which_q <= 1'b1;
              walk_va_q    <= va_d_i;
              walk_wr_q    <= wr_d_i;
              walk_priv_q  <= priv_d_i;
              walk_level_q <= is_sv48 ? 2'd3 : 2'd2;
              walk_ppn_q   <= virt_i ? vsatp_ppn : satp_ppn;
              walk_virt_q  <= virt_i;
              fault_q      <= 1'b0;
              if (virt_i && (vsatp_mode == SATP_BARE) && g_enable) begin
                // Guest-Bare: VA==GPA, G-translate directly then install.
                g_va_q    <= va_d_i;
                g_level_q <= g_sv48 ? 2'd3 : 2'd2;
                g_ppn_q   <= hgatp_ppn;
                resume_q  <= 2'd1;
                final_level_q <= 2'd0;
                final_u_q <= 1'b1; final_r_q <= 1'b1;
                final_w_q <= wr_d_i; final_x_q <= 1'b0;
                final_d_q <= 1'b0;
                final_gpa_q <= va_d_i;
                if (hgatp_ppn[43:36] != 8'd0) begin
                  fault_q       <= 1'b1;
                  fault_which_q <= 1'b1;
                  fault_cause_q <= wr_d_i ? CAUSE_STORE_GUEST_FAULT
                                           : CAUSE_LOAD_GUEST_FAULT;
                  fault_va_q    <= va_d_i;
                end else begin
                  wst <= WR_GREAD;
                end
              end else if ((virt_i ? vsatp_ppn : satp_ppn) >> 36 != 8'd0) begin
                fault_q       <= 1'b1;
                fault_which_q <= 1'b1;
                fault_cause_q <= CAUSE_LOAD_ACCESS;
                fault_va_q    <= va_d_i;
              end else if (virt_i && g_enable) begin
                // Guest VS walk: first VS PTE address is a GPA.
                vs_gpa_q <= vs_pte_gpa(virt_i ? vsatp_ppn : satp_ppn,
                                       is_sv48 ? 2'd3 : 2'd2, va_d_i);
                vs_ppn_q <= virt_i ? vsatp_ppn : satp_ppn;
                g_va_q   <= vs_pte_gpa(virt_i ? vsatp_ppn : satp_ppn,
                                       is_sv48 ? 2'd3 : 2'd2, va_d_i);
                g_level_q <= g_sv48 ? 2'd3 : 2'd2;
                g_ppn_q   <= hgatp_ppn;
                resume_q  <= 2'd0;
                wst <= WR_GREAD;
              end else begin
                wst <= WR_READ;
              end
            end else if (want_f) begin
              walk_which_q <= 1'b0;
              walk_va_q    <= va_f_i;
              walk_wr_q    <= 1'b0;
              walk_priv_q  <= priv_f_i;
              walk_level_q <= is_sv48 ? 2'd3 : 2'd2;
              walk_ppn_q   <= virt_i ? vsatp_ppn : satp_ppn;
              walk_virt_q  <= virt_i;
              fault_q      <= 1'b0;
              if (virt_i && (vsatp_mode == SATP_BARE) && g_enable) begin
                g_va_q    <= va_f_i;
                g_level_q <= g_sv48 ? 2'd3 : 2'd2;
                g_ppn_q   <= hgatp_ppn;
                resume_q  <= 2'd1;
                final_level_q <= 2'd0;
                final_u_q <= 1'b1; final_r_q <= 1'b1;
                final_w_q <= 1'b0; final_x_q <= 1'b1;
                final_d_q <= 1'b0;
                final_gpa_q <= va_f_i;
                if (hgatp_ppn[43:36] != 8'd0) begin
                  fault_q       <= 1'b1;
                  fault_which_q <= 1'b0;
                  fault_cause_q <= CAUSE_FETCH_GUEST_FAULT;
                  fault_va_q    <= va_f_i;
                end else begin
                  wst <= WR_GREAD;
                end
              end else if ((virt_i ? vsatp_ppn : satp_ppn) >> 36 != 8'd0) begin
                fault_q       <= 1'b1;
                fault_which_q <= 1'b0;
                fault_cause_q <= CAUSE_FETCH_ACCESS;
                fault_va_q    <= va_f_i;
              end else if (virt_i && g_enable) begin
                vs_gpa_q <= vs_pte_gpa(virt_i ? vsatp_ppn : satp_ppn,
                                       is_sv48 ? 2'd3 : 2'd2, va_f_i);
                vs_ppn_q <= virt_i ? vsatp_ppn : satp_ppn;
                g_va_q   <= vs_pte_gpa(virt_i ? vsatp_ppn : satp_ppn,
                                       is_sv48 ? 2'd3 : 2'd2, va_f_i);
                g_level_q <= g_sv48 ? 2'd3 : 2'd2;
                g_ppn_q   <= hgatp_ppn;
                resume_q  <= 2'd0;
                wst <= WR_GREAD;
              end else begin
                wst <= WR_READ;
              end
            end
          end
          WR_READ: begin
            // req_o held until the downstream port accepts.
            if (req_o && ready_i) wst <= WR_WAIT;
          end
          WR_WAIT: begin
            if (ack_i) begin
              walk_pte_q <= rdata_i;
              wst <= WR_EVAL;
            end
          end
          WR_EVAL: begin
            // PTE: V[0] R[1] W[2] X[3] U[4] G[5] A[6] D[7], PPN[53:10].
            logic v, r, w, x, u, a, d;
            logic [43:0] ppn;
            logic is_leaf, reserved, fault_now;
            logic [4:0] page_cause, access_cause;
            v = walk_pte_q[0]; r = walk_pte_q[1];
            w = walk_pte_q[2]; x = walk_pte_q[3];
            u = walk_pte_q[4]; a = walk_pte_q[6]; d = walk_pte_q[7];
            ppn = walk_pte_q[53:10];
            is_leaf = r || x;
            reserved = !v || (w && !r) || (!is_leaf && x);
            page_cause   = walk_which_q ? (walk_wr_q ? CAUSE_STORE_PAGE_FAULT
                                                     : CAUSE_LOAD_PAGE_FAULT)
                                        : CAUSE_FETCH_PAGE_FAULT;
            access_cause = walk_which_q ? (walk_wr_q ? CAUSE_STORE_ACCESS
                                                     : CAUSE_LOAD_ACCESS)
                                        : CAUSE_FETCH_ACCESS;
            fault_now = 1'b0;
            if (reserved) begin
              fault_now = 1'b1;
              fault_cause_q <= page_cause;
            end else if (is_leaf) begin
              // Superpage alignment + 48-bit PA range.
              logic misaligned, oor;
              if (walk_level_q == 2'd3) begin
                misaligned = (ppn[26:0] != 27'd0);
                oor = (ppn[43:36] != 8'd0);
              end else if (walk_level_q == 2'd2) begin
                misaligned = (ppn[17:0] != 18'd0);
                oor = (ppn[43:36] != 8'd0);
              end else if (walk_level_q == 2'd1) begin
                misaligned = (ppn[8:0] != 9'd0);
                oor = (ppn[43:36] != 8'd0);
              end else begin
                misaligned = 1'b0;
                oor = (ppn[43:36] != 8'd0);
              end
              if (misaligned) begin
                fault_now = 1'b1;
                fault_cause_q <= page_cause;
              end else if (oor) begin
                fault_now = 1'b1;
                fault_cause_q <= access_cause;
              end else if (!perm_ok(walk_priv_q, u, r, w, x, 1'b1, walk_wr_q,
                                    !walk_which_q, mstatus_sum, mstatus_mxr)) begin
                fault_now = 1'b1;
                fault_cause_q <= page_cause;
              end else if (!a || (walk_wr_q && !d)) begin
                if (walk_virt_q && g_enable) begin
                  // VS A/D write lands at the translated HPA.
                  resume_q <= 2'd2;
                  g_va_q   <= vs_gpa_q;
                  g_level_q <= g_sv48 ? 2'd3 : 2'd2;
                  g_ppn_q   <= hgatp_ppn;
                  wst <= WR_GREAD;
                end else begin
                  wst <= WR_WRITE;
                end
              end else if (walk_virt_q && g_enable) begin
                // VS leaf GPA -> G-translate before installing.
                final_gpa_q   <= make_pa(ppn, walk_level_q, walk_va_q);
                final_level_q <= walk_level_q;
                final_ppn_q   <= ppn;
                final_u_q <= u; final_r_q <= r; final_w_q <= w;
                final_x_q <= x; final_d_q <= d || walk_wr_q;
                g_va_q    <= make_pa(ppn, walk_level_q, walk_va_q);
                g_level_q <= g_sv48 ? 2'd3 : 2'd2;
                g_ppn_q   <= hgatp_ppn;
                resume_q  <= 2'd1;
                wst <= WR_GREAD;
              end else begin
                // Install TLB entry (round-robin victim).
                tlb_valid[tlb_rr_q] <= 1'b1;
                tlb_virt[tlb_rr_q]  <= walk_virt_q;
                tlb_vmid[tlb_rr_q]  <= hgatp_vmid;
                tlb_asid[tlb_rr_q]  <= eff_asid;
                tlb_vpn[tlb_rr_q]   <= walk_va_q[47:12];
                tlb_level[tlb_rr_q] <= walk_level_q;
                tlb_ppn[tlb_rr_q]   <= ppn;
                tlb_u[tlb_rr_q]     <= u;
                tlb_r[tlb_rr_q]     <= r;
                tlb_w[tlb_rr_q]     <= w;
                tlb_x[tlb_rr_q]     <= x;
                tlb_d[tlb_rr_q]     <= d || walk_wr_q;
                tlb_rr_q <= tlb_rr_q + 1'b1;
                wst <= WR_IDLE;
              end
            end else begin
              // Pointer: descend (table base must fit PA space).
              if (ppn[43:36] != 8'd0) begin
                fault_now = 1'b1;
                fault_cause_q <= access_cause;
              end else if (walk_virt_q && g_enable) begin
                // Descend: next VS table base is a GPA; translate its PTE.
                walk_ppn_q <= ppn;
                walk_level_q <= walk_level_q - 1'b1;
                vs_ppn_q <= ppn;
                vs_gpa_q <= vs_pte_gpa(ppn, walk_level_q - 1'b1, walk_va_q);
                g_va_q   <= vs_pte_gpa(ppn, walk_level_q - 1'b1, walk_va_q);
                g_level_q <= g_sv48 ? 2'd3 : 2'd2;
                g_ppn_q   <= hgatp_ppn;
                resume_q  <= 2'd0;
                wst <= WR_GREAD;
              end else begin
                walk_ppn_q <= ppn;
                walk_level_q <= walk_level_q - 1'b1;
                wst <= WR_READ;
              end
            end
            `ifdef MMU_DEBUG
            $display("[mmu %0t] EVAL lvl=%0d pte=%h leaf=%b fault=%b wr=%b",
                     $time, walk_level_q, walk_pte_q, is_leaf, fault_now, walk_wr_q);
            `endif
            if (fault_now) begin
              fault_q       <= 1'b1;
              fault_which_q <= walk_which_q;
              fault_va_q    <= walk_va_q;
              wst           <= WR_IDLE;
            end
          end
          WR_WRITE: begin
            if (req_o && ready_i) wst <= WR_WWAIT;
          end
          WR_WWAIT: begin
            if (ack_i) begin
              // PTE updated in memory; install with A/D set. For guests
              // the leaf PPN is a GPA: G-translate before installing.
              if (walk_virt_q && g_enable) begin
                final_gpa_q   <= make_pa(walk_pte_q[53:10], walk_level_q,
                                         walk_va_q);
                final_level_q <= walk_level_q;
                final_ppn_q   <= walk_pte_q[53:10];
                final_u_q <= walk_pte_q[4]; final_r_q <= walk_pte_q[1];
                final_w_q <= walk_pte_q[2]; final_x_q <= walk_pte_q[3];
                final_d_q <= 1'b1;
                g_va_q    <= make_pa(walk_pte_q[53:10], walk_level_q,
                                     walk_va_q);
                g_level_q <= g_sv48 ? 2'd3 : 2'd2;
                g_ppn_q   <= hgatp_ppn;
                resume_q  <= 2'd1;
                wst <= WR_GREAD;
              end else begin
                tlb_valid[tlb_rr_q] <= 1'b1;
                tlb_virt[tlb_rr_q]  <= walk_virt_q;
                tlb_vmid[tlb_rr_q]  <= hgatp_vmid;
                tlb_asid[tlb_rr_q]  <= eff_asid;
                tlb_vpn[tlb_rr_q]   <= walk_va_q[47:12];
                tlb_level[tlb_rr_q] <= walk_level_q;
                tlb_ppn[tlb_rr_q]   <= walk_pte_q[53:10];
                tlb_u[tlb_rr_q]     <= walk_pte_q[4];
                tlb_r[tlb_rr_q]     <= walk_pte_q[1];
                tlb_w[tlb_rr_q]     <= walk_pte_q[2];
                tlb_x[tlb_rr_q]     <= walk_pte_q[3];
                tlb_d[tlb_rr_q]     <= 1'b1;
                tlb_rr_q <= tlb_rr_q + 1'b1;
                wst <= WR_IDLE;
              end
            end
          end
          // ---- G-stage sub-walk: translate g_va_q (GPA) to HPA ----
          WR_GREAD: begin
            `ifdef MMU_DEBUG
            if (req_o && ready_i)
              $display("[mmu %0t] GREAD gva=%h lvl=%0d ppn=%h resume=%0d", $time,
                       g_va_q, g_level_q, g_ppn_q, resume_q);
            `endif
            if (req_o && ready_i) wst <= WR_GWAIT;
          end
          WR_GWAIT: begin
            if (ack_i) begin
              g_pte_q <= rdata_i;
              `ifdef MMU_DEBUG
              $display("[mmu %0t] GACK pte=%h", $time, rdata_i);
              `endif
              wst <= WR_GEVAL;
            end
          end
          WR_GEVAL: begin
            logic v, r, w, x, u, a, d;
            logic [43:0] ppn;
            logic is_leaf, reserved, fault_now;
            logic [4:0] guest_cause, g_access_cause;
            v = g_pte_q[0]; r = g_pte_q[1];
            w = g_pte_q[2]; x = g_pte_q[3];
            u = g_pte_q[4]; a = g_pte_q[6]; d = g_pte_q[7];
            ppn = g_pte_q[53:10];
            is_leaf = r || x;
            reserved = !v || (w && !r) || (!is_leaf && x);
            guest_cause = walk_which_q ? (walk_wr_q ? CAUSE_STORE_GUEST_FAULT
                                                    : CAUSE_LOAD_GUEST_FAULT)
                                       : CAUSE_FETCH_GUEST_FAULT;
            g_access_cause = walk_which_q ? (walk_wr_q ? CAUSE_STORE_ACCESS
                                                       : CAUSE_LOAD_ACCESS)
                                          : CAUSE_FETCH_ACCESS;
            fault_now = 1'b0;
            `ifdef MMU_DEBUG
            $display("[mmu %0t] GEVAL lvl=%0d pte=%h leaf=%b rsv=%b resume=%0d", $time,
                     g_level_q, g_pte_q, is_leaf, reserved, resume_q);
            `endif
            if (reserved) begin
              fault_now = 1'b1;
              fault_cause_q <= guest_cause;
            end else if (is_leaf) begin
              logic misaligned, oor;
              if (g_level_q == 2'd3) begin
                misaligned = (ppn[26:0] != 27'd0);
                oor = (ppn[43:36] != 8'd0);
              end else if (g_level_q == 2'd2) begin
                misaligned = (ppn[17:0] != 18'd0);
                oor = (ppn[43:36] != 8'd0);
              end else if (g_level_q == 2'd1) begin
                misaligned = (ppn[8:0] != 9'd0);
                oor = (ppn[43:36] != 8'd0);
              end else begin
                misaligned = 1'b0;
                oor = (ppn[43:36] != 8'd0);
              end
              if (misaligned) begin
                fault_now = 1'b1;
                fault_cause_q <= guest_cause;
              end else if (oor) begin
                fault_now = 1'b1;
                fault_cause_q <= g_access_cause;
              end else if (!perm_ok(PRIV_S, u, r, w, x, 1'b1, walk_wr_q,
                                    !walk_which_q, g_sum, g_mxr)) begin
                fault_now = 1'b1;
                fault_cause_q <= guest_cause;
              end else if (!a || (walk_wr_q && !d)) begin
                wst <= WR_GWRITE;
              end else if (resume_q == 2'd0) begin
                // VS PTE HPA resolved; read it next.
                vs_hpa_q <= {16'd0, make_pa(ppn, g_level_q, g_va_q)};
                wst <= WR_READ;
              end else if (resume_q == 2'd2) begin
                vs_hpa_q <= {16'd0, make_pa(ppn, g_level_q, g_va_q)};
                wst <= WR_WRITE;
              end else begin
                // Final GPA resolved: install combined entry.
                logic [47:0] g_hpa_page;
                logic [47:0] fin_hpa;
                g_hpa_page = make_pa(ppn, g_level_q, g_va_q);
                if (final_level_q == 2'd3)
                  fin_hpa = {g_hpa_page[47:39], final_gpa_q[38:0]};
                else if (final_level_q == 2'd2)
                  fin_hpa = {g_hpa_page[47:30], final_gpa_q[29:0]};
                else if (final_level_q == 2'd1)
                  fin_hpa = {g_hpa_page[47:21], final_gpa_q[20:0]};
                else
                  fin_hpa = {g_hpa_page[47:12], final_gpa_q[11:0]};
                tlb_valid[tlb_rr_q] <= 1'b1;
                tlb_virt[tlb_rr_q]  <= 1'b1;
                tlb_vmid[tlb_rr_q]  <= hgatp_vmid;
                tlb_asid[tlb_rr_q]  <= eff_asid;
                tlb_vpn[tlb_rr_q]   <= walk_va_q[47:12];
                tlb_level[tlb_rr_q] <= final_level_q;
                // Stored PPN must satisfy make_pa(PPN,level,VA)==fin_hpa:
                // level-0 PPN is PA>>12 (upper PPN bits zero); superpage
                // levels carry the page offset in the low PPN bits as zero.
                if (final_level_q == 2'd3)
                  tlb_ppn[tlb_rr_q] <= {fin_hpa[47:39], 27'd0};
                else if (final_level_q == 2'd2)
                  tlb_ppn[tlb_rr_q] <= {fin_hpa[47:30], 18'd0};
                else if (final_level_q == 2'd1)
                  tlb_ppn[tlb_rr_q] <= {fin_hpa[47:21], 9'd0};
                else
                  tlb_ppn[tlb_rr_q] <= {8'd0, fin_hpa[47:12]};
                tlb_u[tlb_rr_q]     <= final_u_q;
                tlb_r[tlb_rr_q]     <= final_r_q;
                tlb_w[tlb_rr_q]     <= final_w_q;
                tlb_x[tlb_rr_q]     <= final_x_q;
                tlb_d[tlb_rr_q]     <= final_d_q;
                tlb_rr_q <= tlb_rr_q + 1'b1;
                wst <= WR_IDLE;
              end
            end else begin
              if (ppn[43:36] != 8'd0) begin
                fault_now = 1'b1;
                fault_cause_q <= g_access_cause;
              end else begin
                g_ppn_q <= ppn;
                g_level_q <= g_level_q - 1'b1;
                wst <= WR_GREAD;
              end
            end
            if (fault_now) begin
              fault_q       <= 1'b1;
              fault_which_q <= walk_which_q;
              fault_va_q    <= walk_va_q;
              wst           <= WR_IDLE;
            end
          end
          WR_GWRITE: begin
            if (req_o && ready_i) wst <= WR_GWWAIT;
          end
          WR_GWWAIT: begin
            if (ack_i) begin
              // G PTE A/D set; re-evaluate the leaf (now with A/D).
              g_pte_q <= g_pte_q | {56'h0, (walk_wr_q ? 8'hC0 : 8'h40)};
              wst <= WR_GEVAL;
            end
          end
          default: wst <= WR_IDLE;
        endcase
      end
    end
  end

endmodule
