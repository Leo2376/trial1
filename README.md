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
- **Vector engine**: RVV 1.0 compliant, VLEN = 256 bits.
- **Matrix engine**: IME 1.0 compliant.
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
│   ├── vector/               # RVV 1.0 vector engine (VLEN = 256).
│   │   ├── vregfile/          # vector register file.
│   │   ├── vlane/             # vector execution lanes.
│   │   ├── vsew_lmul/         # SEW/LMU configuration logic.
│   │   ├── vldst/             # vector load/store unit.
│   │   └── vctrl/             # vector issue/control.
│   ├── matrix/                # IME 1.0 matrix extension.
│   │   ├── mregfile/          # matrix/tile register file.
│   │   ├── munit/             # matrix execution units.
│   │   ├── mldst/             # matrix load/store unit.
│   │   └── mctrl/             # matrix issue/control.
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
│   ├── tb_vector/            # vector engine testbenches.
│   ├── tb_matrix/            # matrix engine testbenches.
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

## Status

This repository has been reset from its previous EDA-tool content to host the
RV64GCH processor. RTL is scaffolded; implementation is in progress.
