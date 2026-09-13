# Yosys synthesis script targeting ASAP7 7nm (7.5-track, RVT, TT corner).
#
# Usage:
#   yosys -c synth_yosys.tcl
# Driven by ../scripts/Makefile which sets the variables below.
#
# Variables (overridable from the environment / command line):
#   LIBFILE   - merged ASAP7 RVT_TT liberty file
#   FILELIST  - path to the synthesis filelist (syn/filelist.f)
#   TOP       - top module to synthesize (default: rv64gch_core)
#   OUTDIR    - output directory for netlist / reports

if {![info exists LIBFILE]}   { set LIBFILE "../lib/asap7_RVT_TT.lib" }
if {![info exists FILELIST]}  { set FILELIST "../filelist.f" }
if {![info exists TOP]}       { set TOP "rv64gch_core" }
if {![info exists OUTDIR]}   { set OUTDIR "../output" }

file mkdir $OUTDIR

# --- Read ASAP7 liberty (technology library) -------------------------------
# abc / dfflibmap map generic gates onto these ASAP7 cells.
read_liberty $LIBFILE

# --- Read RTL ----------------------------------------------------------------
# SystemVerilog packages / structs / enums / typedefs are supported by -sv.
# SV `interface` constructs are NOT supported and must be excluded.
set fp [open $FILELIST r]
set files [split [read $fp] "\n"]
close $fp
foreach f $files {
    set f [string trim $f]
    if {$f eq "" || [string index $f 0] eq "#"} { continue }
    yosys read_verilog -sv $f
}

# --- Generic synthesis --------------------------------------------------------
synth -top $TOP -flatten

# --- Technology mapping -------------------------------------------------------
# Map flip-flops onto ASAP7 library cells.
dfflibmap -liberty $LIBFILE

# Map combinational logic with area-oriented ABC pass. ASAP7 cells do not all
# have a clean hierarchy; restrict abc to standard logic cells and avoid
# physical-only / special cells via dont_use.
# Restrict mapping to standard logic / clock-gating cells only; exclude
# physical-only and special cells that abc must not instantiate.
dont_use {*/DECAPX* */ANTENNAX* */FILL* */TAP* */MOSCAP*}

abc -liberty $LIBFILE

# --- Reports ------------------------------------------------------------------
stat -liberty $LIBFILE > $OUTDIR/stat.rpt
tee -o $OUTDIR/area.rpt stat -liberty $LIBFILE

# --- Netlist ------------------------------------------------------------------
write_verilog $OUTDIR/synth.v
write_json    $OUTDIR/synth.json
