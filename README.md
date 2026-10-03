# RV64GCH RISC-V Processor Core

## Overview

RV64GCH dual-issue in-order core with integrated FPU, Sv48 MMU, RVV 1.0 vector
engine (VLEN=256), and IME 1.0 matrix extension. Target: ASIC (standard-cell
synthesis), not FPGA.

## Project Status

**Working and verified** (single-issue in-order pipeline, riscv-tests ISA suites):

| Area | Status | Verification |
|------|--------|--------------|
| RV64I base ISA | **DONE** | rv64ui 50/50 PASS |
| M extension (mul/div) | **DONE** | rv64um 13/13 PASS |
| F extension (single-precision FP) | **DONE** | rv64uf 11/11 PASS |
| Zicsr / Zifencei | **DONE** | covered by suites above |
| FPU fflags/frm/fcsr CSRs | **DONE** | move.S, fsflags readback, dyn_rm.S (rm=dyn->frm) |
| SoC top + AXI4 fabric + DRAM model | **DONE** | core-level sim boot |
| D extension (double-precision) | **DONE** | rv64ud 12/12 PASS |
| C extension (RVC decompressor) | **DONE** | rv64uc/rvc PASS, tb_decompressor 44/44 |
| A extension (LR/SC/AMO) | **DONE** | rv64ua 19/19 PASS |
| L1I (32 KiB, 4-way, blocking) | **DONE** | all ISA suites + conflict test PASS |
| L1D (32 KiB, 4-way, blocking, write-back) | **DONE** | all ISA suites (incl. rv64ua) + l1d_wb PASS |
| L2 (256 KiB, 8-way, blocking, write-back) | **DONE** | all ISA suites + l2_wb PASS |
| MMU Sv39 (shared 32-e TLB + HW walker, 4K/2M/1G, A/D) | **DONE** | sv39_basic/fault/sfence PASS |
| Trap delegation (medeleg/mideleg, S-trap entry, vectored tvec) | **DONE** | deleg_basic PASS |
| ASID tags + selective SFENCE.VMA | **DONE** | asid_test PASS |
| MMU Sv48 (4-level walk, 512G/1G/2M/4K) | **DONE** | sv48_basic PASS |
| Dual-issue frontend (8B fetch, dual decode/issue/retire, ALU+ALU and ALU+MDU/FPU) | **DONE (Phase 1+2)** | all ISA suites + directed PASS (see regression line) |
| Branch prediction (static BTFN + BTB/2-bit/RAS/JAL-early) | **DONE (stages a+b)** | all ISA suites PASS; loops ~25% faster |
| Core interrupt take (precise M/S trap on MEI/MSI/MTI) | **DONE** | clint_timer/plic_basic PASS |
| CLINT (mtime/mtimecmp/msip) | **DONE** | clint_timer PASS |
| 64-source PLIC (priority/threshold/claim, M+S contexts) | **DONE** | plic_basic PASS |
| H extension v0.1 (HS/VS/VU, stage-2 walk, hfence, VS-IRQ) | **DONE (v0.1)** | h_basic PASS |
| RVV 1.0 vector engine | **v1 DONE (SEW=8/16/32/64 LMUL=1; unit/stride/e8-indexed ld/st; OPIVV+OPMVV+OPIVX/OPMVX integer ALU incl. mul/div, merge, compares; slides; vrgather; precise fault/restart)** | v_basic + v_strided + v_indexed + v_masked + v_alu + v_alu2 + v_muldiv + v_slide + v_sew PASS |
| IME 1.0 matrix extension | Not started | — |
| LLC (1 MiB, shared) | Not started (only needed with VPU) | — |
| Debug module / coherence dir | Not started (empty stubs) | — |

Current pipeline: 5-stage (F/D, EX, MEM, WB) in-order dual-issue with full
hazard/forwarding for INT, FP and MDU; multi-cycle FPU (FADD/FSUB/FMUL
single-cycle, FDIV/FSQRT iterative); fflags accumulate to CSR via WB.
Fetch serves up to 2 parcels/cycle from each buffered 8B word (retain +
hi-promote, straddle-safe); D0/D1 pair when both are simple-ALU
(ADD/SUB/SLL/SLT(U)/XOR/SRL/SRA/OR/AND, W-variants, LUI, AUIPC) on a
second integer ALU lane with intra-pair bypass; dual retire via a
2-write-port int regfile (younger lane-B wins). Backward branches predict
taken in Decode (static BTFN, verified in EX, redirect only on mispredict).
Jumps predict via BTB/RAS/JAL-early, verified against the resolved target.

## Next Steps (Roadmap)

1. **C extension (rv64uc)** — **DONE**. `decompressor.sv` rewritten from the
   CVA6 reference (RV64+F); core handles `is_c` link (`pc+2`), straddling
   fetch (32-bit insn at offset 6), and reserved-encoding traps.
2. **D extension (rv64ud)** — **DONE** ("G" complete: IMAFD ✓). Double
   datapath implemented in `fpu.sv` instruction-by-instruction
   (add/sub/mul/div/sqrt/min/max/class/cmp/cvt/cvt_w/move/fmadd, plus
   recoding/structural); also fixed `round_pack_d`, fused-op `fmt` decode,
   `FCVT.S.D`/`D.S` decode aliasing, and single-precision NaN-boxing.
3. **A extension (rv64ua)** — **DONE**. LR/SC reservation + AMO
   read-modify-write implemented in the MEM-stage LSU (single-hart
   atomicity, `aq/rl` ignored, AXI `lock` path still unconnected).
4. **L1 caches + L2 (256 KiB)** — **L1I DONE** (32 KiB 4-way
   set-associative blocking in `rtl/cache/l1i/l1i.sv`, 256 sets x 32B
   lines, tree-PLRU, `fence.i` invalidate via retire pulse; 5-line
   same-set conflict/eviction test PASS. Bring-up exposed a stale-`ready`
   owner-latch race in `rv64gch_top`, fixed with a combinational `idle_o`
   accept gate in `axi4_master`).
   **L1D DONE** (32 KiB 4-way write-back in `rtl/cache/l1d/l1d.sv`, inserted
   on the core data port like L1I so the inline LSU is untouched; MMIO at
   or above `MMIO_BASE` bypasses as uncacheable single beats so tohost
   still reaches the hostif model; AMO/LR/SC ride the ordinary read/write
   path, atomic by in-order+blocking construction; `l1d_wb.S` proves the
   dirty-evict-writeback-refill chain byte-exact incl. sb/sh merge).
   L1D bring-up caught two more bugs: writebacks used the missing line's
   address instead of the victim's, and tree-PLRU updates pointed the wrong
   way (fixed in both caches).
   **L2 DONE** (256 KiB 8-way write-back unified in `rtl/cache/l2/l2.sv`,
   1024 sets x 32B lines, tree-PLRU, dual-port with L1D-side priority;
   both L1s feed it and it is the only AXI requester, so the old
   fetch/data arbiter + owner latch in `rv64gch_top` is gone; MMIO
   bypasses as uncacheable on both ports; `l2_wb.S` forces an L2 dirty
   eviction to DRAM and checks the refill byte-exact).
    Memory hierarchy through L2 complete; remaining: LLC (only needed with
    VPU traffic, see 9).
5. **MMU Sv39** — **DONE** (`rtl/mmu/mmu.sv`: shared 32-entry TLB, HW
   walker with 4K/2M/1G leaves + A/D updates, PIPT so both caches are
   untouched; S/U priv, satp/SFENCE.VMA, SUM/MXR/MPRV, faults 12/13/15 +
   access 1/5/7 with mtval, all traps to M incl. working mret-redirect).
   Walker reads PTEs through a new L2 port C (coherent with drained L1D
   lines); SFENCE/SATP/FENCE.I retire drains L1D. Bring-up fixed three
   latent core bugs: 63-bit B-type immediate (backward branches wild),
   mret/sret never redirecting to epc, and traps recording nothing (flush
   gate) / S-traps vectoring to zero stvec.
   **Delegation DONE**: medeleg/mideleg CSRs, S-mode trap entry
   (sepc/scause/stval/SPP/SPIE), vectored mtvec/stvec, combinational
   next-priv tracking (`deleg_basic` proves ecall->S-trap->sret->ecall).
   Fix round 2: direct-mode tvec must not mask low bits; core priv must
   follow delegation (not hard M on trap). **ASID DONE**: per-entry tags,
   retire-time selective SFENCE (VA and/or ASID qualified, rs1/rs2==x0
   means all) with a fence-window freeze instead of drop
    (`asid_test` proves isolation + VA-selective survival; Sv48 in 6).
6. **MMU (Sv48)** — **DONE**. Same engine parameterized: 36-bit VPN,
   level-3 start, 512G leaves (PPN[26:0] alignment), Sv48 canonical rule,
   mode-9 WARL accept. `sv48_basic` proves a 4-level data remap + PA
   alias, fetch remap, 2M-page read, and A/D at depth 3.
7. **Dual-issue frontend** — **DONE (Phase 1)**. 8B/cycle fetch (buffered
   word retain + hi-promote, straddle-safe, zero extra transactions or
   translations), dual decode into a 2-deep D queue with shift, pairing
   via `rtl/core/issue/issue_unit.sv` (ALU+ALU only for now; MDU/FPU/LSU/
   CSR/branch never pair and stay lane-A single), second integer ALU
   (lane-B operand select mirrors lane A incl. shift-immediate-vs-R-type),
   dual MEM/WB pass-through + dual retire. ~20-28% fewer cycles across
   ISA suites (add 4069→2952, lw 3106→2405, sw 4874→3530, lb 2863→2232,
   fcvt_w 6076→4794). Bring-up hardened four latent hazards (all
   timing-masked in single-issue, all deterministic under dense fetch):
   exact read-mask load-use (I-type imm bits in rs2 never stall),
   backend-drain instead of freeze on load-use/FRM holds, FRM pending
   narrowed to EX/MEM, FP-file load-use stall for FLW/FLD consumers,
   xret drain-hold for back-to-back `csrw mepc/sepc → xret`.
   Phase 2 adds ALU+MDU/FPU pairing (lane A runs any MDU/FPU compute,
   lane B a simple ALU; the pair advances in lockstep behind the long op
   and retires the same cycle, so no extra bypass is needed; FP-to-FP
   lane A gates the intra-pair forward). LSU extracted to
   `rtl/core/lsu/lsu.sv` (MEM transaction engine: LR/SC, AMO, AXI
   handshake, aligned load latch; packet/WB/forwarding stay in core).
   Remaining: none (no second MDU/FPU, no VPU pairing).
8. **Branch prediction** — **DONE (stages a+b)**. (a) Static BTFN in
   Decode, verified in EX (redirect only on mispredict). (b) 64-entry
   direct-mapped BTB (tag VA[47:7], per-entry 2-bit counter; branches
   allocate on taken, JALR records its register target, JAL needs no
   entry), 8-deep RAS updated at EX-resolve (no speculative repair:
   wrong-path calls never resolve), early-JAL redirect (exact pc+imm in
   Decode). EX verifies taken-vs-predicted with stored pred target
   (fall-through resume on taken-predicted-not-taken). BTB/RAS are pure
   predictions (no fence/TLB invalidation; stale entries self-correct).
   `software/tests/bpred_ras.S` covers nested RAS calls, a polymorphic
   indirect jump, and a backward loop. Remaining: none planned (no large
   global-history / tournament predictor).
9. **Remaining work** (everything above is DONE and green):
    - **RVV 1.0 (VLEN=256) + IME 1.0** — v1 **DONE**: `vsetvli`/
      `vsetivli` (SEW=8/16/32/64, LMUL=1, ta,ma; rest vill; VLMAX=32/16/
      8/4; AVL-reg form), unit-stride (`vle`/`vse`, EEW==SEW enforced),
      `vlse`/`vsse` strided (VA=base+i*stride, stride=x[rs2],
      negative strides OK) and `vluxei8`/`vsuxei8`
      indexed (VA=base+vs2[i], e8 zero-ext indices, any SEW), each masked
      (vm=0, v0 mask: masked-off elements skip memory, never fault, and
      leave dest/memory undisturbed) and unmasked, via `rtl/vpu/ldst/
      vlsu.sv` time-multiplexing the CPU LSU data path (same MMU port +
      L1D beat, same AXI4/L2 chain — no separate VPU interface, now
      byte-serial over (element, byte) with element-precise vstart),
      `rtl/vpu/regfile/vregfile.sv` (32x32B, data + index + mask + dest
      + gather read ports), vl/vtype/vstart CSRs + VS dirty, precise
      per-element faults (vstart restart). `software/tests/v_basic.S`
      proves config, 32B move, and a straddling load fault;
      `software/tests/v_strided.S` proves stride-4/1/-1 moves, a
      load-sourced stride, and a straddling strided fault;
      `software/tests/v_indexed.S` proves gather/scatter,
      reversed indices, and a load-then-store fault pair to the same VA
      (the pair caught a stale-cause MMU fault latch, now keyed on
      access type); `software/tests/v_masked.S` proves masked unit/
      strided/indexed moves with undisturbed semantics and fault
      avoidance over an unmapped element. Integer compute is in:
      `rtl/vpu/vlane/valu.sv` (element-serial OPIVV add/sub/min/max/and/
      or/xor/saturating/shift + `vmv.v.v`/`vmerge.vvm` + compares, masked
      and unmasked, occupying MEM under the same hold that serializes
      vector ops — no VRF forwarding needed);
       `software/tests/v_alu.S` proves all six ops, wrap/identity
       properties, and masked add (it also caught `vmv.v.v` living in
       OPIVV/funct6, not OPMVV). Sequencer restart is proven: back-to-back
       vector ops hand MEM over with no idle gap, so the VLSU/VALU cannot
       delimit sequences on the active level alone (the second op inherited
       the first op's done state and retired empty -- this swallowed the
       second `vxor` of the `v_alu` round-trip). The core now pulses
       `vec_start_q` when a vector op enters MEM and both units (re)sample
       `vl`/`vstart` on it (`v_alu` phase 5 + the `v_alu2` ALU chain cover
       it). Full OPIVV integer ALU is in: `vminu`/`vmin`/`vmaxu`/`vmax`,
       saturating `vsaddu`/`vsadd`/`vssubu`/`vssub`, `vsll`/`vsrl`/`vsra`
       (amount = low 3 bits of vs1[i]), `vmerge.vvm` (v0 selects, never
       skips), and the mask-producing compares `vmseq`/`vmsne`/`vmsltu`/
       `vmslt`/`vmsleu`/`vmsle` (bit i of vd via a vd read-modify-write
       port, masked and unmasked); `software/tests/v_alu2.S` proves each
       op against scalar-computed immediates incl. signed edges
       (0x80/0x7F), saturation corners, arithmetic shift, and both
       masked-compare undisturbed directions (it also caught the compare
       vd byte needing `i>>3`, not `i`). OPMVV/OPMVX integer multiply/
       divide (`vmul`/`mulh`/`mulhu`/`mulhsu`, `vdiv`/`divu`/`rem`/`remu`
       with scalar div semantics, `.vv` and `.vx`) run on a wide-path
       R+W sub-FSM in the VALU (R assembles the element bytes, W computes
       and writes one byte per cycle; 128-bit products keep MULH exact at
       SEW=64); `software/tests/v_muldiv.S` proves each op incl. div0/
       overflow corners and masked `.vv`. Slides (`vslideup/down/1up/
       1down`, `.vx` + `.vi`) and `vrgather.vv/.vx/.vi` (SEW-wide indices,
       out-of-range -> 0 via a chained gather VRF port) ride the same
       sub-FSM with the scalar (x[rs1]/uimm) in the MEM packet;
       `software/tests/v_slide.S` proves all forms incl. undisturbed-low
       and zero-fill. SEW=16/32/64 (LMUL=1, VLMAX=16/8/4, EEW==SEW
       enforced at decode, e8 indices pair with any SEW) run the VLSU
       byte-serially over (element, byte) with element-precise vstart, and
       the VALU wide path end to end; `software/tests/v_sew.S` proves
       config (incl. AVL-reg vsetvli), round trip, add/mul/div, compares
       and masking per width, plus the EEW-mismatch illegal trap
       (`v_basic` now asserts e16-valid + vill-via-LMUL2 instead of
       e16-vill).
       Vector DONE (v1) recap: `vsetvli`/`vsetivli` (SEW 8/16/32/64,
       LMUL=1, AVL-reg form); unit/stride/e8-indexed ld/st with masking
       and precise faults; full OPIVV integer ALU + merge + compares;
       OPMVV/OPMVX mul/div; OPIVX/OPMVX `.vx` ALU/mul/div; slides and
       gather (`.vv`/`.vx`/`.vi`); back-to-back sequencer restart.
       Vector LEFT:
       - LMUL = 2/4/8 (and fractional) register grouping: VLMAX scaling,
         multi-register layout, EMUL for strided/indexed/segment forms.
       - OPIVI integer `.vi` forms (`vadd.vi`, `vmv.v.i`, compares,
         shifts, mul/div — the uimm scalar path already exists for
         slides/gather).
       - Mask-register ops: `vmand`/`vmor`/`vmxor`/`vmandn`/`vmornot`,
         `vmsbf`/`vmsif`/`vmsof`, `vcpop`/`vfirst`, `viota`/`vid`.
       - Reductions (`vredsum`/`and`/`or`/`xor`/`min`/`max`, needs a
         vector->scalar writeback path), widening (`vwadd`/`vwsub`/
         `vwmul`/`vwmacc`), narrowing (`vnsrl`/`vnsra`/`vnclip`),
         extension (`vzext`/`vsext`), scaling shifts (`vssrl`/`vssra`).
       - Segment, whole-register (`vl1r`/`vs1r`), mask (`vlm`/`vsm`),
         and fault-only-first (`vleff`) load/stores; `vrgatherei16`;
         `vcompress`.
       - OPFVV single/double-precision vector floating point (shares
         the scalar FPU).
       - `vsetvl` (register AVL/vtype form; currently falls into the
         `vsetvli`/vill path).
       - IME 1.0 matrix extension (`munit/`, shared regfile).
    - **LLC (1 MiB, shared CPU+VPU)** — only needed once VPU traffic
      exists; until then the L2 feeds AXI4/DRAM directly.
    - **SoC stubs** — debug module (`rtl/soc/debug/`, RISC-V Debug Spec:
      halt/resume/abstract access) and coherence directory
      (`rtl/cache/coherence/`, needed only with DMA/VPU writers).
    - **H extension v0.1** — **DONE** (`h_basic` PASS: HS/VS/VU modes with
      V bit, hstatus/hedeleg/hideleg/hgatp + vsstatus/vsie/vstvec/vsepc/
      vscause/vstval/vsatp, MPV/SPV/SPVP, VS-ecall cause 10, guest faults
      20/21/23 with htval/mtval2, nested 2-stage walker with G-stage A/D,
      HFENCE.VVMA/GVMA, hvip/vsip virtual interrupts routed to VS or HS).
      Left for later: HLV/HSV insns, hfence privilege checks, full VMID/
      Sv39x4 upper-bit handling, riscv-tests `rv64h` suites.
    - **Verification hardening** — extend the Unicorn lock-step cosim flow
      to dual-issue/predictor paths; run the riscv-tests H-extension
      suites when H lands. No open failures: full regression is green
      (see line below).
10. **SoC interrupts** — **DONE**. CLINT (`rtl/soc/clint/clint.sv`:
    msip/mtimecmp/mtime, timer = mtime>=mtimecmp, reset-parked max) and
    64-source PLIC (`rtl/soc/plic/plic.sv`: priority/threshold/claim per
    context, level sources, lowest-ID tiebreak) live in `rv64gch_top`
    behind chained `axi4_decoder`s (CLINT 0x10010_0000, PLIC 0x10020_0000,
    TB-stim 0x10008_0000 for SW-driven sources in simulation only).
    Core takes precise M/S traps (MEI>MSI>MTI, mideleg routing, int-bit
    mcause, mepc = next unissued insn) once the backend drains.
    `clint_timer` (mtimecmp + MTI trap + mepc/mip checks) and `plic_basic`
    (arbitration/threshold/claim/complete over sources 1/40/64) PASS.

## Verification Scheme

Three levels, all driven by the upstream riscv-tests ISA suites:

1. **Unit level** — `sim/verilator/tb_fpu.sv` (`make fpu`): 80 directed
   vectors (single from rv64uf + double from rv64ud: add/sub/mul/
   div/sqrt/min/max/cmp/class/cvt/move/fmadd), checking result bits and
   exact fflags per op.
   `sim/verilator/tb_decompressor.sv` (`make decomp`): 44 directed vectors
   per RV64C encoding (assembler-captured), checking expanded bits, `is_c`,
   and `illegal`.
2. **Core level** — `verification/tb_core/tb_rv64gch_core.sv`: boots the full
   core + AXI4 fabric + DRAM/hostif models, loads a program hex, and detects
   pass/fail via the riscv-tests `tohost` convention.
3. **ISA regression** — `tools/scripts/run_isa_tests.sh`: compiles riscv-tests
   sources (rv64ui/rv64um/rv64uf/rv64uc/rv64ua, selectable via `EXT=`), converts ELF to hex
   (`tools/scripts/elf2hex.py`), runs the core sim, and reports PASS/FAIL
   per test against the tohost value.
4. **Directed core tests** — `software/tests/dyn_rm.S` (rm=dyn uses
   fcsr.frm for fdiv.s/d incl. the back-to-back csrw->dyn hazard path;
   riscv-tests never use dyn), `software/tests/l1i_conflict.S` (5 code
   lines forced into one 4-way L1I set: eviction + refill byte-exactness),
   and `software/tests/l1d_wb.S` (5 data lines forced into one 4-way L1D
   set: dirty-evict-writeback-refill byte-exactness incl. sb/sh merge),
   and `software/tests/l2_wb.S` (9 data lines forced into one 8-way L2
   set: L2 dirty eviction to DRAM + refill byte-exactness),
   `software/tests/sv39_basic.S` (M setup + S load/store/fetch through a
   remap, walker A/D, ecall), `software/tests/sv39_fault.S` (5 fault
   cases with (cause,tval) matching + handler resume), and
   `software/tests/sv39_sfence.S` (remap visible after SFENCE.VMA),
   `software/tests/deleg_basic.S` (delegated S-ecall handling + sret
   return + second ecall), `software/tests/asid_test.S` (two-ASID
   isolation + VA-selective sfence proven by survival + fault), and
    `software/tests/sv48_basic.S` (4-level remap + alias + fetch + 2M
    page + A/D under Sv48), `software/tests/h_basic.S` (H v0.1: HS CSR
    readback, hfence.vvma/gvma, VS entry via SPV/sret, VS-timer IRQ to
    HS, 2-stage data remap, VS-ecall to VS, G-fault 21 to HS; build with
    `-march=rv64imafdc_h_zicsr_zifencei`).
    Build per the header comments, run with
    `Vtb_rv64gch_core +hex=<test>.hex`, expect `TEST PASSED`.

Debug methodology (proven on the FPU work): when a test fails, disassemble the
failing test case, write a minimal directed asm program that reports the
actual computed value through tohost, and bisect from there. `$display`
traces can be temporarily added behind `ifdef` guards.

```bash
# Build core simulator + run all ISA regressions
cd sim/verilator && make          # builds Vtb_rv64gch_core (smoke test)
EXT=rv64ui tools/scripts/run_isa_tests.sh   # 50/50
EXT=rv64um tools/scripts/run_isa_tests.sh   # 13/13
EXT=rv64uf tools/scripts/run_isa_tests.sh   # 11/11
EXT=rv64uc tools/scripts/run_isa_tests.sh   # 1/1 (rvc)
EXT=rv64ua tools/scripts/run_isa_tests.sh   # 19/19
EXT=rv64ud tools/scripts/run_isa_tests.sh   # 12/12

# FPU unit testbench
cd sim/verilator && make fpu      # 80/80 PASS

# Decompressor (RVC) unit testbench
cd sim/verilator && make decomp   # 44/44 PASS
```

# Directed core tests (see software/tests/*.S headers for build lines)
./sim/verilator/obj_dir/Vtb_rv64gch_core +hex=/tmp/dyn_rm.hex         # TEST PASSED
./sim/verilator/obj_dir/Vtb_rv64gch_core +hex=/tmp/l1i_conflict.hex   # TEST PASSED
./sim/verilator/obj_dir/Vtb_rv64gch_core +hex=/tmp/l1d_wb.hex         # TEST PASSED
./sim/verilator/obj_dir/Vtb_rv64gch_core +hex=/tmp/l2_wb.hex          # TEST PASSED
./sim/verilator/obj_dir/Vtb_rv64gch_core +hex=/tmp/sv39_basic.hex      # TEST PASSED
./sim/verilator/obj_dir/Vtb_rv64gch_core +hex=/tmp/sv39_fault.hex      # TEST PASSED
./sim/verilator/obj_dir/Vtb_rv64gch_core +hex=/tmp/sv39_sfence.hex     # TEST PASSED
./sim/verilator/obj_dir/Vtb_rv64gch_core +hex=/tmp/deleg_basic.hex     # TEST PASSED
./sim/verilator/obj_dir/Vtb_rv64gch_core +hex=/tmp/asid_test.hex       # TEST PASSED
./sim/verilator/obj_dir/Vtb_rv64gch_core +hex=/tmp/sv48_basic.hex      # TEST PASSED
./sim/verilator/obj_dir/Vtb_rv64gch_core +hex=/tmp/h_basic.hex          # TEST PASSED
```

Last full regression (H v0.1 in path): rv64ui 50/50, rv64um 13/13, rv64uf 11/11, rv64uc 1/1 (rvc), rv64ua 19/19, rv64ud 12/12, tb_fpu 80/80, tb_decompressor 44/44, dyn_rm PASS, l1i_conflict PASS, l1d_wb PASS, l2_wb PASS, sv39_basic/fault/sfence PASS, deleg_basic PASS, asid_test PASS, sv48_basic PASS, priv_ecall PASS, priv_csr PASS, bpred_ras PASS, clint_timer PASS, plic_basic PASS, h_basic PASS, v_basic/v_strided/v_indexed/v_masked/v_alu/v_alu2/v_muldiv/v_slide/v_sew PASS.

## RTL Directory Structure & Module Relationships

Implemented modules vs stubs/empty placeholders:

```
rtl/
├── core/                          # RV64GCH Core (IMPLEMENTED)
│   ├── rv64gch_core.sv           # Top-level core: 5-stage dual-issue pipeline
│   ├── rtl_core_pkg.sv           # Package: opcodes, enums (alu/fpu/mdu), ctrl struct
│   ├── frontend/
│   │   └── decompressor.sv       # C-extension decompressor (IMPLEMENTED, x2 instances)
│   ├── ctrl/
│   │   ├── hazard_unit.sv        # Stalls: exact load-use (int+FP), MDU/FPU busy, LSU, FRM/xret holds
│   │   └── forwarding_unit.sv    # INT MEM/WB forwarding (lane-B sources inline in core)
│   ├── regfile/
│   │   ├── regfile_int.sv        # Integer regfile (32x64, 4R dual-decode, 2W dual-retire)
│   │   └── regfile_fp.sv         # FP regfile (32x64, 6R dual-decode)
│   ├── int_alu/
│   │   └── alu.sv                # Integer ALU (x2 instances: lane A + lane B)
│   ├── mul_div/
│   │   └── mdu.sv                # Multiply/Divide unit (iterative, lane A only)
│   ├── fpu/
│   │   └── fpu.sv                # FPU: F + D verified (single + double, lane A only)
│   ├── csr/
│   │   └── csr_unit.sv           # CSRs: M/S-mode, fcsr, separate read port
│   ├── issue/
│   │   └── issue_unit.sv         # Dual-issue pairing predicate (ALU+ALU, ALU+MDU/FPU)
│   ├── lsu/
│   │   └── lsu.sv                # LSU MEM engine: LR/SC, AMO, AXI handshake, load latch
├── vpu/                           # Vector Unit (VLSU/VALU/VRF IMPLEMENTED, munit future)
│   ├── ldst/vlsu.sv             # VLSU: unit/stride/indexed sequencer, SEW-aware (IMPLEMENTED)
│   ├── vlane/valu.sv            # VALU: integer ALU + slides/gather, fast + wide paths (IMPLEMENTED)
│   ├── regfile/vregfile.sv      # VRF: 32x32B, 5R+1W byte ports (IMPLEMENTED)
│   ├── ctrl/ vsew_lmul/ munit/  # (EMPTY, future: LMUL grouping, IME)
├── mmu/mmu.sv                   # Sv39 MMU: TLB + walker (IMPLEMENTED)
├── cache/                         # l1i + l1d DONE, rest EMPTY (future)
│   ├── l1i/l1i.sv               # L1I 32KiB 4-way blocking (IMPLEMENTED)
│   ├── l1d/l1d.sv               # L1D 32KiB 4-way write-back (IMPLEMENTED)
│   ├── l2/l2.sv                 # L2 256KiB 8-way write-back (IMPLEMENTED)
│   ├── llc/  coherence/
├── soc/                           # SoC integration (IMPLEMENTED)
│   ├── top/
│   │   ├── rv64gch_top.sv        # Top-level SoC: core + CLINT + PLIC + fabric
│   │   └── rv64gch_memmap_pkg.sv # Memory map (DRAM/HOSTIF/STIM/CLINT/PLIC)
│   ├── fabric/
│   │   ├── axi4_if.sv            # AXI4 interface definitions
│   │   ├── axi4_master.sv        # Core-side AXI4 master bridge
│   │   └── axi4_decoder.sv       # AXI4 address decoder (chained for MMIO)
│   ├── clint/clint.sv            # CLINT: msip/mtimecmp/mtime (IMPLEMENTED)
│   ├── plic/plic.sv              # 64-source PLIC, M+S contexts (IMPLEMENTED)
│   ├── debug/                    # (EMPTY, future)
└── lib/                           # Common libraries (EMPTY, future)
```

## Key Module Dependencies

### Core Pipeline

```
rv64gch_core.sv
├── frontend/decompressor.sv (x2: slot 0 + slot 1)
├── ctrl/hazard_unit.sv
├── ctrl/forwarding_unit.sv
├── issue/issue_unit.sv
├── lsu/lsu.sv
├── regfile/regfile_int.sv
├── regfile/regfile_fp.sv
├── int_alu/alu.sv (x2: u_alu + u_alu_b)
├── mul_div/mdu.sv
├── fpu/fpu.sv
├── csr/csr_unit.sv
└── soc/fabric/axi4_master.sv (load/store path)
```

### SoC Integration

```
rv64gch_top.sv
├── core/rv64gch_core.sv (now with precise interrupt take)
├── soc/clint/clint.sv + soc/plic/plic.sv (MMIO-mapped IRQs)
├── fabric/axi4_* (interconnect, chained MMIO decoders)
├── (verification) axi4_dram_model + axi4_hostif_model + axi4_stim_model
```

### Planned Memory Hierarchy (single shared bus — no separate VPU interface)

```
L1I (32 KiB) ─┐
              ├─→ L2 (256 KiB) ─→ LLC (1 MiB) ─→ AXI4 ─→ DRAM
L1D (32 KiB) ─┘
VPU (RVV 1.0 + IME 1.0) ──┘
  ↑ vector/matrix load/stores arbitrate onto the same AXI4 bus/fabric
    as the CPU LSU/fetch; there is no dedicated VPU memory interface.
```

## ISA Support

- **Base**: RV64I — **verified**
- **Extensions**: M ✓, F ✓, D ✓, C ✓, A ✓ ("G" complete), Zicsr/Zifencei ✓ | H v0.1 ✓ (HS/VS/VU, 2-stage, hfence, VS-IRQ; HLV/HSV later)
- **Vector**: RVV 1.0 integer (VLEN=256, SEW 8/16/32/64, LMUL=1) — implemented, shared CPU AXI4 bus (no separate IF)
- **Matrix**: IME 1.0 (shared VPU regfile) — planned, shared CPU AXI4 bus (no separate IF)

## Memory System (target)

| Level | Size | Type | Status |
|-------|------|------|--------|
| L1I   | 32 KiB | Instruction cache | done (4-way blocking, tree-PLRU, fence.i invalidate) |
| L1D   | 32 KiB | Data cache | done (4-way WB write-allocate, MMIO bypass) |
| L2    | 256 KiB | Private unified | done (8-way WB, dual-port, tree-PLRU) |
| LLC   | 1 MiB | Shared CPU+VPU over the single AXI4 bus | planned |

## Directory Conventions

- Each module has its own directory under the functional block
- `.gitkeep` files preserve empty directories in git
- Package files (`*_pkg.sv`) define shared types/constants
- Interface files (`*_if.sv`) define bus/protocol interfaces
- `rtl/core/lsu/lsu.sv` holds the MEM transaction engine (LR/SC, AMO, AXI
  handshake, load latch); packet/WB/forwarding stay in `rv64gch_core.sv`
