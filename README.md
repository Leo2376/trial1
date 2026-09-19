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
| MMU Sv48 | Not started | — |
| Dual-issue frontend | Not started | — |
| RVV 1.0 vector engine | Not started | — |
| IME 1.0 matrix extension | Not started | — |

Current pipeline: 5-stage (F/D, EX, MEM, WB) in-order single-issue with full
hazard/forwarding for INT, FP and MDU; multi-cycle FPU (FADD/FSUB/FMUL
single-cycle, FDIV/FSQRT iterative); fflags accumulate to CSR via WB.

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
   VPU traffic), then MMU.
5. **MMU Sv39** — **DONE** (`rtl/mmu/mmu.sv`: shared 32-entry TLB, HW
   walker with 4K/2M/1G leaves + A/D updates, PIPT so both caches are
   untouched; S/U priv, satp/SFENCE.VMA, SUM/MXR/MPRV, faults 12/13/15 +
   access 1/5/7 with mtval, all traps to M incl. working mret-redirect).
   Walker reads PTEs through a new L2 port C (coherent with drained L1D
   lines); SFENCE/SATP/FENCE.I retire drains L1D. Bring-up fixed three
   latent core bugs: 63-bit B-type immediate (backward branches wild),
   mret/sret never redirecting to epc, and traps recording nothing (flush
   gate) / S-traps vectoring to zero stvec. Remaining: **Sv48** (mode 9
   currently WARLs to Bare), trap delegation, ASID tagging.
6. **MMU (Sv48)** — 4-level walk extension of the same engine.
7. **Dual-issue frontend** — 8B/cycle fetch, dual decode, ALU+MDU/FPU pairing,
   wider hazard/forwarding.
8. **RVV 1.0 (VLEN=256) + IME 1.0** — no separate VPU memory interface:
   vector/matrix traffic arbitrates onto the same AXI4 bus/fabric as the
   CPU (alongside LSU/fetch in `rv64gch_top`) and shares the L2/LLC chain.

## Verification Scheme

Three levels, all driven by the upstream riscv-tests ISA suites:

1. **Unit level** — `sim/verilator/tb_fpu.sv` (`make fpu`): 79 directed
   vectors (61 single from rv64uf + 18 double from rv64ud: add/sub/mul/
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
   `software/tests/sv39_sfence.S` (remap visible after SFENCE.VMA).
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
cd sim/verilator && make fpu      # 79/79 PASS

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
```

Last full regression (L1I + L1D + L2 + Sv39 MMU in path): rv64ui 50/50, rv64um 13/13, rv64uf 11/11, rv64uc 1/1 (rvc), rv64ua 19/19, rv64ud 12/12, tb_fpu 79/79, tb_decompressor 44/44, dyn_rm PASS, l1i_conflict PASS, l1d_wb PASS, l2_wb PASS, sv39_basic/fault/sfence PASS.

## RTL Directory Structure & Module Relationships

Implemented modules vs stubs/empty placeholders:

```
rtl/
├── core/                          # RV64GCH Core (IMPLEMENTED)
│   ├── rv64gch_core.sv           # Top-level core: 5-stage in-order pipeline
│   ├── rtl_core_pkg.sv           # Package: opcodes, enums (alu/fpu/mdu), ctrl struct
│   ├── frontend/
│   │   └── decompressor.sv       # C-extension decompressor (IMPLEMENTED)
│   ├── ctrl/
│   │   ├── hazard_unit.sv        # Stalls: load-use, MDU/FPU busy, LSU, CSR
│   │   └── forwarding_unit.sv    # INT MEM/WB forwarding
│   ├── regfile/
│   │   ├── regfile_int.sv        # Integer regfile (32x64)
│   │   └── regfile_fp.sv         # FP regfile (32x64, 3 read ports)
│   ├── int_alu/
│   │   └── alu.sv                # Integer ALU
│   ├── mul_div/
│   │   └── mdu.sv                # Multiply/Divide unit (iterative)
│   ├── fpu/
│   │   └── fpu.sv                # FPU: F + D verified (single + double)
│   ├── csr/
│   │   └── csr_unit.sv           # CSRs: M/S-mode, fcsr, separate read port
│   ├── issue/                    # Dual-issue logic (EMPTY, future)
│   └── lsu/                      # LSU logic lives in rv64gch_core.sv (MEM stage)
├── vpu/                           # Vector/Matrix Unit (EMPTY, future)
│   ├── ctrl/  regfile/  vlane/  munit/  vsew_lmul/  ldst/
├── mmu/mmu.sv                   # Sv39 MMU: TLB + walker (IMPLEMENTED)
├── cache/                         # l1i + l1d DONE, rest EMPTY (future)
│   ├── l1i/l1i.sv               # L1I 32KiB 4-way blocking (IMPLEMENTED)
│   ├── l1d/l1d.sv               # L1D 32KiB 4-way write-back (IMPLEMENTED)
│   ├── l2/l2.sv                 # L2 256KiB 8-way write-back (IMPLEMENTED)
│   ├── llc/  coherence/
├── soc/                           # SoC integration (IMPLEMENTED)
│   ├── top/
│   │   ├── rv64gch_top.sv        # Top-level SoC: core + fabric + boot ROM
│   │   └── rv64gch_memmap_pkg.sv # Memory map
│   ├── fabric/
│   │   ├── axi4_if.sv            # AXI4 interface definitions
│   │   ├── axi4_master.sv        # Core-side AXI4 master bridge
│   │   └── axi4_decoder.sv       # AXI4 address decoder
│   ├── clint/  plic/  debug/     # (EMPTY, future)
└── lib/                           # Common libraries (EMPTY, future)
```

## Key Module Dependencies

### Core Pipeline

```
rv64gch_core.sv
├── frontend/decompressor.sv
├── ctrl/hazard_unit.sv
├── ctrl/forwarding_unit.sv
├── regfile/regfile_int.sv
├── regfile/regfile_fp.sv
├── int_alu/alu.sv
├── mul_div/mdu.sv
├── fpu/fpu.sv
├── csr/csr_unit.sv
└── soc/fabric/axi4_master.sv (load/store path)
```

### SoC Integration

```
rv64gch_top.sv
├── core/rv64gch_core.sv
├── fabric/axi4_* (interconnect)
├── (verification) axi4_dram_model + axi4_hostif_model
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
- **Extensions**: M ✓, F ✓, D ✓, C ✓, A ✓ ("G" complete), Zicsr/Zifencei ✓ | H planned
- **Vector**: RVV 1.0 (VLEN=256, ELEN=64) — planned, shared CPU AXI4 bus (no separate IF)
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
- `rtl/core/lsu/` is intentionally empty: LSU logic currently lives inline in
  `rv64gch_core.sv` (MEM stage) and will be extracted when the L1D lands
