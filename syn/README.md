# Synthesis (Yosys + ASAP7 7nm)

RTL synthesis flow using the open-source [Yosys](https://yosyshq.net/yosys/)
synthesizer and the [ASAP7](https://github.com/The-OpenROAD-Project/asap7)
7nm predictive process design kit (7.5-track, RVT, typical-typical corner).

## Directory layout

```
syn/
├── filelist.f            # synthesis-only RTL filelist (no testbench/IFs)
├── scripts/
│   ├── Makefile          # driver: fetch ASAP7, decompress libs, run Yosys
│   ├── synth_yosys.tcl   # Yosys TCL script (read RTL + liberty, synth, map)
│   └── merge_libs.py    # merge the 5 RVT_TT cell-category liberty files
├── constr/
│   └── clock.sdc        # clock + I/O delay + false-path constraints
├── lib/                  # generated: merged ASAP7 RVT_TT liberty   (gitignored)
├── output/               # generated: netlist + stat/area reports   (gitignored)
└── third_party/asap7/    # generated: cloned ASAP7 PDK              (gitignored)
```

`lib/`, `output/`, and `third_party/` are build artifacts and are gitignored.

## Prerequisites

- `yosys` (>= 0.10) — RTL → gate synthesis
- `7z` / `p7zip` — ASAP7 liberty files are 7z-compressed
- `git` — to fetch the ASAP7 repository and its `asap7sc7p5t_28` submodule
- `python3` — liberty merge helper
- `make`

On Debian/Ubuntu:

```bash
sudo apt-get install -y yosys p7zip-full python3 git make
```

## Running

From `syn/scripts/`:

```bash
make libs     # clone ASAP7, decompress + merge the RVT_TT NLDM liberty
make synth    # run Yosys synthesis (depends on libs)
```

Or in one step:

```bash
make synth TOP=rv64gch_core
```

Outputs land in `syn/output/`:

- `synth.v`    — mapped gate-level netlist (ASAP7 cells)
- `synth.json` — netlist in JSON for downstream tools
- `stat.rpt`, `area.rpt` — area / cell-count statistics

## Technology target

The flow targets the ASAP7 **7.5-track** standard-cell library
(`asap7sc7p5t_28`), **RVT (regular-Vt)** cells at the **typical-typical**
corner. ASAP7 splits the library by cell category; this flow decompresses
and merges the five RVT_TT NLDM liberty files into a single
`asap7_RVT_TT.lib` for Yosys:

- `asap7sc7p5t_AO_RVT_TT_nldm_211120`
- `asap7sc7p5t_INVBUF_RVT_TT_nldm_220122`
- `asap7sc7p5t_OA_RVT_TT_nldm_211120`
- `asap7sc7p5t_SEQ_RVT_TT_nldm_220123`
- `asap7sc7p5t_SIMPLE_RVT_TT_nldm_211120`

LEF files (cell LEF `asap7sc7p5t_28_R_1x_220121a.lef` and tech LEF
`asap7_tech_1x_201209.lef`) are used by placement-and-routing, not Yosys,
and are available in the fetched clone under
`third_party/asap7/asap7sc7p5t_28/`.

## Scope / limitations

The open-source Yosys Verilog frontend supports SystemVerilog packages,
structs, enums, and typedefs, but **does not support SystemVerilog
`interface` constructs**. The SoC fabric modules
(`axi4_master`, `axi4_decoder`, `axi4_if`, `rv64gch_top`) use the
`axi4_if` interface and are therefore excluded from this flow.

The default synthesis top is **`rv64gch_core`**, which uses plain logic
ports and is fully synthesizable with the open-source frontend. The SoC
fabric should be synthesized with a commercial frontend (Verific /
Synopsys) that supports SV interfaces.

Constraint file `constr/clock.sdc` defines a 1 GHz virtual clock (1.0 ns
period) and conservative I/O delays. SDC is passed to the commercial
backend timing flow; Yosys itself does not read SDC, so timing is a
best-effort RTL-area estimate here. The SDC is consumed by the
place-and-route (OpenROAD/Innovus) stage that runs after this synthesis.
