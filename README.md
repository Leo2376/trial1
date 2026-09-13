# RV64GCH RISC-V Processor

A modular, ASIC-targeted RV64GCH (RV64IMAFDC + Hypervisor) RISC-V processor core,
dual-issue in-order with an integrated FPU, MMU, RVV 1.0 vector engine
(VLEN = 256), and IME 1.0 matrix extension.

## Key Features

- **ISA**: RV64GCH (I/M/A/F/D/C + Hypervisor extension).
- **Microarchitecture**: Dual-issue, in-order pipeline.
- **FPU**: Integrated floating-point unit (F/D extensions).
- **Memory system**:
  - L1 instruction cache: 32 KiB.
  - L1 data cache: 32 KiB.
  - Unified L2 cache: 256 KiB (CPU-private).
  - Shared L2/last-level cache: 1 MiB, shared between the CPU, the vector
    engine, and the matrix engine.
- **MMU**: Sv48 (and hypervisor two-stage) virtual memory.
- **Vector/Matrix engine**: unified processing unit implementing RVV 1.0
  (VLEN = 256 bits) and IME 1.0; the two extensions share the register file
  and most of the execution hardware.
- **Target**: ASIC (standard-cell synthesis, not FPGA).

## Directory Layout

```
.
├── README.md                 # This file.
├── LICENSE                   # Project license.
├── .gitignore                # Ignored build/simulation artifacts.
├── docs/                     # Architecture and microarchitecture specs.
│   ├── architecture.md       # ISA profile, extensions, privilege model.
│   ├── microarchitecture.md  # Pipeline, issue, execute, memory diagrams.
│   ├── cache_hierarchy.md    # L1/L2/LLC sizing, coherence, sharing policy.
│   ├── vector_engine.md      # RVV 1.0 microarchitecture, VLEN=256.
│   ├── matrix_engine.md     # IME 1.0 microarchitecture.
│   ├── soc_integration.md   # Top-level integration, AXI/CHI, interrupts.
│   └── verification_plan.md  # Verification strategy, coverage goals.
├── rtl/                      # synthesizable SystemVerilog / Verilog.
│   ├── core/                 # scalar core pipeline.
│   │   ├── frontend/         # fetch, branch prediction, decode.
│   │   ├── issue/            # dual-issue in-order scheduling.
│   │   ├── int_alu/          # integer ALU execution lanes.
│   │   ├── fpu/              # floating-point unit (F/D).
│   │   ├── mul_div/          # multiply / divide units.
│   │   ├── lsu/              # load/store unit, address gen, ordering.
│   │   ├── csr/              # CSR file and trap/interrupt logic.
│   │   ├── regfile/          # integer and FP register files.
│   │   └── ctrl/             # pipeline control, hazards, flush.
│   ├── mmu/                  # MMU, TLB, page-table walker (Sv48 + 2-stage).
│   ├── cache/
│   │   ├── l1i/              # 32 KiB L1 instruction cache.
│   │   ├── l1d/              # 32 KiB L1 data cache.
│   │   ├── l2/               # 256 KiB unified private L2.
│   │   ├── llc/              # 1 MiB shared L2/LLC.
│   │   └── coherence/        # coherence / snoop / directory logic.
│   ├── vpu/                  # unified vector/matrix processing unit.
│   │   │                        # RVV 1.0 (VLEN = 256) and IME 1.0 share the
│   │   │                        # register file and most execution hardware.
│   │   ├── regfile/          # shared vector/matrix register file.
│   │   ├── vlane/            # vector execution lanes (RVV).
│   │   ├── vsew_lmul/        # RVV SEW/LMUL configuration logic.
│   │   ├── munit/            # matrix execution units (IME).
│   │   ├── ldst/             # shared vector/matrix load/store unit.
│   │   └── ctrl/             # shared vector/matrix issue & control.
│   ├── soc/                   # top-level integration.
│   │   ├── top/               # chip/core top.
│   │   ├── fabric/            # interconnect (AXI/CHI) for L2/LLC sharing.
│   │   ├── clint/             # timer / software interrupts.
│   │   ├── plic/              # external interrupt controller.
│   │   └── debug/             # debug module, triggers, trace.
│   └── lib/                   # reusable primitives (flops, muxes, FIFOs).
├── verification/              # testbench and verification environment.
│   ├── tb_core/              # scalar core testbenches.
│   ├── tb_cache/             # cache hierarchy testbenches.
│   ├── tb_mmu/               # MMU / page-walker testbenches.
│   ├── tb_vpu/               # unified vector/matrix (VPU) testbenches.
│   ├── tb_soc/               # full-chip / integration testbenches.
│   ├── uvm/                  # UVM components and environments.
│   ├── formal/               # formal property checks (SymbiYosys / Jasper).
│   └── regressions/          # regression scripts and result logs.
├── software/                 # bare-metal and OS test programs.
│   ├── firmware/             # boot ROM and early boot code.
│   ├── tests/                # isolated ISA test programs.
│   ├── benchmarks/           # core/vector/matrix benchmarks.
│   └── linker/               # linker scripts and build helpers.
├── sim/                      # simulation flow scripts.
│   ├── iverilog/             # Icarus Verilog scripts.
│   ├── vcs/                  # Synopsys VCS scripts.
│   ├── verilator/            # Verilator scripts.
│   └── models/               # behavioral memory and IO models.
├── syn/                      # synthesis flow.
│   ├── constr/               # timing / area / power constraints (SDC).
│   └── scripts/              # synthesis tool scripts (DC, Genus).
├── tech/                     # technology / PDK data.
│   ├── stdcells/             # standard-cell liberty/lef.
│   └── io/                   # IO and corner models.
└── tools/                    # helper scripts (lint, gen, packaging).
    ├── lint/                 # linter config and wrappers.
    └── scripts/              # code-gen and register-layout helpers.
```

## Build and Simulation

Tooling is intentionally tool-agnostic. Drivers live under `sim/`:

- RTL simulation: `sim/verilator`, `sim/iverilog`, `sim/vcs`.
- ASIC synthesis: `syn/scripts` with `syn/constr` SDC constraints.
- Technology data: `tech/stdcells`, `tech/io`.

### Continuous Integration

CI builds the Verilator testbench, runs the smoke test, then compiles and
runs the `riscv-tests` `rv64ui` subset under it.

- GitHub Actions: `.github/workflows/sim-verilator.yml` (smoke) and
  `.github/workflows/isa-tests.yml` (rv64ui regression).
- GitLab CI: `.gitlab-ci.yml` defines two stages — `sim` (build + smoke)
  and `isa-tests` (rv64ui regression, gated on `sim`). Both use the
  `debian:bookworm` image and install `verilator` and
  `gcc-riscv64-unknown-elf` via apt; on a self-hosted runner that already
  has them, set `VERILATOR_SKIP_INSTALL=1` for the `sim` job.

## Status

This repository has been reset from its previous EDA-tool content to host the
RV64GCH processor. RTL is scaffolded; implementation is in progress.
