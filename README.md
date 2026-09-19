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
| FPU fflags/frm/fcsr CSRs | **DONE** | move.S, fsflags readback |
| SoC top + AXI4 fabric + DRAM model | **DONE** | core-level sim boot |
| D extension (double-precision) | Partial (datapath exists, unverified) | — |
| C extension (RVC decompressor) | **DONE** | rv64uc/rvc PASS, tb_decompressor 44/44 |
| A extension (LR/SC/AMO) | **DONE** | rv64ua 19/19 PASS |
| L1 I$/D$, L2 caches | Not started | — |
| MMU (Sv39/Sv48) | Not started | — |
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
2. **D extension (rv64ud)** — nearest win. Double-precision datapath
   functions already in `fpu.sv`; test-and-fix. Completes "G".
3. **A extension (rv64ua)** — **DONE**. LR/SC reservation + AMO
   read-modify-write implemented in the MEM-stage LSU (single-hart
   atomicity, `aq/rl` ignored, AXI `lock` path still unconnected).
4. **L1 I$/D$ (32 KiB each) + L2 (256 KiB)** — first caches; biggest
   architectural gap toward ASIC target. Prerequisite for dual-issue fetch
   bandwidth.
5. **MMU (Sv39/Sv48)** — page-table walk unit, TLBs, satp plumbing.
6. **Dual-issue frontend** — 8B/cycle fetch, dual decode, ALU+MDU/FPU pairing,
   wider hazard/forwarding.
7. **RVV 1.0 (VLEN=256) + IME 1.0** — no separate VPU memory interface:
   vector/matrix traffic arbitrates onto the same AXI4 bus/fabric as the
   CPU (alongside LSU/fetch in `rv64gch_top`) and shares the L2/LLC chain.

## Verification Scheme

Three levels, all driven by the upstream riscv-tests ISA suites:

1. **Unit level** — `sim/verilator/tb_fpu.sv` (`make fpu`): 61 directed
   vectors taken from rv64uf (fadd/fdiv/fmin/fcmp/fclass/fcvt/fcvt_w/move/
   fmadd), checking result bits and exact fflags per op.
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

# FPU unit testbench
cd sim/verilator && make fpu      # 61/61 PASS

# Decompressor (RVC) unit testbench
cd sim/verilator && make decomp   # 44/44 PASS
```

Last full regression: rv64ui 50/50, rv64um 13/13, rv64uf 11/11, rv64uc 1/1 (rvc), rv64ua 19/19, tb_fpu 61/61, tb_decompressor 44/44.

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
│   │   └── fpu.sv                # FPU: F verified, D datapath unverified
│   ├── csr/
│   │   └── csr_unit.sv           # CSRs: M/S-mode, fcsr, separate read port
│   ├── issue/                    # Dual-issue logic (EMPTY, future)
│   └── lsu/                      # LSU logic lives in rv64gch_core.sv (MEM stage)
├── vpu/                           # Vector/Matrix Unit (EMPTY, future)
│   ├── ctrl/  regfile/  vlane/  munit/  vsew_lmul/  ldst/
├── mmu/                           # Sv48 MMU (EMPTY, future)
├── cache/                         # (EMPTY, future)
│   ├── l1i/  l1d/  l2/  llc/  coherence/
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
- **Extensions**: M ✓, F ✓, Zicsr/Zifencei ✓ | D ~, C ✓, A ✓ | H planned
- **Vector**: RVV 1.0 (VLEN=256, ELEN=64) — planned, shared CPU AXI4 bus (no separate IF)
- **Matrix**: IME 1.0 (shared VPU regfile) — planned, shared CPU AXI4 bus (no separate IF)

## Memory System (target)

| Level | Size | Type | Status |
|-------|------|------|--------|
| L1I   | 32 KiB | Instruction cache | planned |
| L1D   | 32 KiB | Data cache | planned |
| L2    | 256 KiB | Private unified | planned |
| LLC   | 1 MiB | Shared CPU+VPU over the single AXI4 bus | planned |

## Directory Conventions

- Each module has its own directory under the functional block
- `.gitkeep` files preserve empty directories in git
- Package files (`*_pkg.sv`) define shared types/constants
- Interface files (`*_if.sv`) define bus/protocol interfaces
- `rtl/core/lsu/` is intentionally empty: LSU logic currently lives inline in
  `rv64gch_core.sv` (MEM stage) and will be extracted when the L1D lands
