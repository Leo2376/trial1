# RV64GCH Verification Plan

## Verification strategy overview

The RV64GCH core (dual-issue in-order, FPU, MMU, RVV 1.0 VLEN=256, IME 1.0)
requires a layered verification strategy. The consensus from industry RISC-V
projects (NOEL-V, BOOM, Rocket, ImperasDV users, academic surveys) is that
**simulation-based verification alone is insufficient** for a processor this
complex; it must be combined with a reference-model comparison and formal
methods. The plan below goes from heavy/complete down to the lightweight
bring-up harness implemented in this repo.

## Level 1 — Heavy: Architectural compliance (RISCOF / ACT)

The RISC-V International "RISC-V-Compatible" program requires passing the
Architectural Compatibility Test (ACT) suite via the RISCOF framework.

- Reference (golden) model: the official **Sail-RISC-V** formal ISA model.
- DUT plugin: a custom plugin that runs each compiled test on the RTL and
  dumps a signature region.
- RISCOF runs each test on both the DUT and Sail, then compares the signature
  memory dump; mismatches are reported with the failing test/offset.
- ISA/Platform YAMLs describe the exact configuration
  (`RV64IMAFDC + H + V + Zv*`) and are validated with `riscv-config`.
- This is mandatory before claiming "RISC-V Compatible" trademark use.

Scope here: scalar ISA + privilege + (eventually) vector. Matrix (IME) ACT
coverage is still emerging, so IME leans on Levels 2-3.

## Level 2 — Heavy: Lock-step co-simulation

Run the same compiled program on the RTL and an ISS **in lock-step**, comparing
architectural state every retired instruction. This is the method used by
Gaisler NOEL-V (vs Spike), ImperasDV (ImperasFPM), and the symbolic-execution
workflows.

- ISS candidates: **Spike** (riscv-isa-sim, supports RV64GC + V) or
  **Imperas OVPsim / ImperasDV**.
- After each RTL retirement, single-step the ISS and compare: PC, integer
  regs, FP regs, CSRs (selected), and vector regs.
- Mismatches are reported immediately at the failing instruction — far better
  than post-run trace/signature compare, which can mask earlier bugs.
- Hook the ISS to the RTL via DPI/VPI. The host interface in this repo
  (`tohost`/`fromhost`) doubles as the run/stop handshake.

This catches microarchitectural bugs that pure compliance tests miss
(restartability, interrupts, MMU two-stage, multi-issue interactions).

## Level 3 — Heavy: Random instruction generation + regressions

- **riscv-dv** (Google): constrained-random, legal-but-stressful programs in
  RV64GC + V. Pair with the lock-step co-sim from Level 2.
- **riscv-torture**: long random kernels for pipeline/cache/MMU stress.
- Run thousands of seeds nightly; track coverage with `riscv-isac`
  (ISA-level) and sim functional/coverage reports.

## Level 4 — Heavy: Formal verification

- Block-level formal on the building blocks: ALU, FPU, mul/div, regfile
  forwarding, TLB, cache coherence, branch predictor, vector SEW/LMUL decode,
  matrix tile addressing.
- Property checking (SymbiYosys / JasperGold / VC Formal) for:
  - no X-propagation on valid inputs,
  - AXI protocol assertions (the AXI4 interface in this repo is the contract),
  - hazard/fifo never-full/never-overflow,
  - page-table walker state-machine reachability.

## Level 5 — Lightweight: Co-verification bring-up harness (implemented here)

For day-to-day bring-up and quick smoke tests, a lightweight harness is
sufficient and fast. This is the same pattern used by Flute/Piccolo (Bluespec),
riscv-tests `tohost`/`fromhost`, and most academic cores.

### Flow

1. Write a test program in assembly (`*.S`) — see `software/tests/hello.S`.
2. Compile with the standard RISC-V GNU toolchain:
   ```
   riscv64-unknown-elf-gcc -march=rv64gc -mabi=lp64d -nostdlib \
       -T software/linker/rv64gch_link.ld software/tests/hello.S -o prog.elf
   ```
3. Convert the ELF to a Verilog `$readmemh` hex with
   `tools/scripts/elf2hex.py prog.elf prog.vh`.
4. Run the RTL testbench, which loads `prog.vh` into the AXI DRAM model and
   boots the core from the DRAM base.

### Memory map (AXI4, 64-bit data, 48-bit address)

| Region        | Base            | Size     | Device                          |
|---------------|-----------------|----------|---------------------------------|
| DRAM          | 0x0000_8000_0000 | 64 KiB+  | `axi4_dram_model` (code+data)   |
| Host I/F      | 0x0001_0000_0000 | 64 KiB   | `axi4_hostif_model`             |

Host interface registers (MMIO):

| Offset | Name        | Meaning                                   |
|--------|-------------|-------------------------------------------|
| 0x000  | tohost      | write 1 = PASS, write <testnum<<1>|1 = FAIL |
| 0x008  | fromhost    | host→core (unused in bring-up)            |
| 0x010  | charout     | write low byte → printed to sim stdout    |

This is the canonical riscv-tests convention (`tohost`/`fromhost`) extended
with a character-output register so tests can print debug info without a UART.

### Files

- `rtl/soc/top/rv64gch_memmap_pkg.sv` — shared address-map constants.
- `rtl/soc/fabric/axi4_if.sv` — AXI4 interface (48-bit addr, 64-bit data).
- `rtl/soc/fabric/axi4_decoder.sv` — 2-slave address decoder.
- `verification/tb_core/axi4_dram_model.sv` — DRAM model, `$readmemh` loader.
- `verification/tb_core/axi4_hostif_model.sv` — tohost/fromhost + charout.
- `verification/tb_core/axi4_master_stub.sv` — temporary AXI master used to
  validate the harness before the real core exists; replaced by the CPU once
  RTL is available.
- `verification/tb_core/tb_rv64gch_core.sv` — top testbench: clock/reset,
  instantiates stub+decoder+DRAM+hostif, polls tohost, reports PASS/FAIL.
- `software/tests/hello.S` — example test program.
- `software/linker/rv64gch_link.ld` — linker script (DRAM at 0x8000_0000).
- `tools/scripts/elf2hex.py` — ELF → `$readmemh` hex converter.
- `sim/iverilog/Makefile`, `sim/verilator/Makefile` — run entry points.

### Running the harness (no CPU yet)

The harness is validated with the stub master so it works before the core RTL
exists:
```
cd sim/verilator && make     # builds and runs; expects "TEST PASSED"
```
Once the real RV64GCH core exists, swap `axi4_master_stub` for the CPU and the
same testbench, DRAM model, and host interface remain unchanged.

### Plugging in the real core

Replace the `u_master` instantiation in `tb_rv64gch_core.sv` with the CPU top,
driving `cpu_if` as an AXI4 master. Set the CPU reset PC to `DRAM_BASE`
(0x0000_8000_0000). The compiled test binary is preloaded into DRAM, so no
boot ROM is needed for bring-up.

## Recommended sequencing

1. Bring up the scalar core on Level 5 (this harness) with hand-written tests.
2. Add Level 2 lock-step co-sim with Spike as the core stabilizes.
3. Run Level 1 RISCOF/ACT for compliance sign-off.
4. Add Level 3 random generation for regression breadth.
5. Layer Level 4 formal on individual blocks throughout.
