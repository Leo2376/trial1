# RV64GCH RISC-V Processor Core

## Overview
RV64GCH dual-issue in-order core with integrated FPU, Sv48 MMU, RVV 1.0 vector engine (VLEN=256), and IME 1.0 matrix extension. Target: ASIC (standard-cell synthesis).

## RTL Directory Structure & Module Relationships

```
rtl/
├── core/                          # RV64GCH Core
│   ├── rv64gch_core.sv           # Top-level core module
│   ├── rtl_core_pkg.sv           # Core package (types, constants)
│   ├── frontend/
│   │   └── decompressor.sv       # C-extension decompressor
│   ├── ctrl/
│   │   ├── hazard_unit.sv        # Pipeline hazard detection
│   │   └── forwarding_unit.sv    # Data forwarding logic
│   ├── issue/                    # Dual-issue logic (stubs)
│   ├── regfile/
│   │   ├── regfile_int.sv        # Integer register file (32x64)
│   │   └── regfile_fp.sv         # FP register file (32x64)
│   ├── int_alu/
│   │   └── alu.sv                # Integer ALU
│   ├── mul_div/
│   │   └── mdu.sv                # Multiply/Divide unit
│   ├── fpu/
│   │   └── fpu.sv                # Floating-point unit (F/D)
│   ├── lsu/                      # Load/Store unit (stubs)
│   └── csr/
│       └── csr_unit.sv           # Control/Status registers
│
├── vpu/                           # Vector/Matrix Processing Unit (VLEN=256)
│   ├── ctrl/                     # VPU control logic
│   ├── regfile/                  # Shared vector/matrix register file
│   ├── vlane/                    # Vector lane execution units
│   ├── munit/                    # Matrix execution units
│   ├── vsew_lmul/                # VSEW/VLMUL configuration
│   └── ldst/                     # Vector load/store unit
│
├── mmu/                           # Sv48 MMU (two-stage translation)
│
├── cache/
│   ├── l1i/                      # 32KiB L1 Instruction Cache
│   ├── l1d/                      # 32KiB L1 Data Cache
│   ├── l2/                       # 256KiB Private L2 Cache
│   ├── llc/                      # 1MiB Shared Last-Level Cache
│   └── coherence/                # Cache coherence protocol
│
├── soc/                           # SoC Integration
│   ├── top/
│   │   ├── rv64gch_top.sv        # Top-level SoC module
│   │   └── rv64gch_memmap_pkg.sv # Memory map package
│   ├── fabric/
│   │   ├── axi4_if.sv            # AXI4 interface definitions
│   │   ├── axi4_decoder.sv       # AXI4 address decoder
│   │   └── axi4_master.sv        # AXI4 master bridge
│   ├── clint/                    # Core Local Interruptor (stubs)
│   ├── plic/                     # Platform-Level Interrupt Controller (stubs)
│   └── debug/                    # Debug module (stubs)
│
└── lib/                           # Common libraries/utilities
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
├── lsu/ (load/store)
└── csr/csr_unit.sv
```

### VPU (Vector/Matrix)
```
vpu/ (unified register file)
├── ctrl/
├── regfile/
├── vlane/ (vector execution)
├── munit/ (matrix execution)
├── vsew_lmul/
└── ldst/ (vector memory ops)
```

### Memory Hierarchy
```
L1I (32KiB) ↔ L2 (256KiB) ↔ LLC (1MiB) ↔ AXI4 Fabric
L1D (32KiB) ↔ L2 (256KiB) ↔ LLC (1MiB) ↔ AXI4 Fabric
VPU ldst    ↔ L2 (256KiB) ↔ LLC (1MiB) ↔ AXI4 Fabric
```

### SoC Integration
```
rv64gch_top.sv
├── rv64gch_core.sv (core)
├── vpu/ (vector/matrix)
├── mmu/ (Sv48)
├── cache/ (L1/L2/LLC)
├── fabric/axi4_* (interconnect)
├── clint/ (timer interrupts)
├── plic/ (external interrupts)
└── debug/ (JTAG/DTM)
```

## ISA Support
- **Base**: RV64I
- **Extensions**: M, A, F, D, C, H (Hypervisor)
- **Vector**: RVV 1.0 (VLEN=256, ELEN=64)
- **Matrix**: IME 1.0 (shared VPU regfile)

## Memory System
| Level | Size | Type |
|-------|------|------|
| L1I   | 32 KiB | Instruction cache |
| L1D   | 32 KiB | Data cache |
| L2    | 256 KiB | Private unified |
| LLC   | 1 MiB | Shared (CPU + VPU) |

## Build & Simulation
```bash
# Synthesis (ASIC flow)
make synth

# Simulation
make sim

# Lint
make lint
```

## Directory Conventions
- Each module has its own directory under the functional block
- `.gitkeep` files preserve empty directories in git
- Package files (`*_pkg.sv`) define shared types/constants
- Interface files (`*_if.sv`) define bus/protocol interfaces