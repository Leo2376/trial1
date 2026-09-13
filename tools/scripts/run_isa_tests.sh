#!/usr/bin/env bash
# Compile and run a subset of riscv-tests under the Verilator testbench.
# Usage: run_isa_tests.sh [test1 test2 ...]
#
# Selects the test family (rv64ui / rv64um) via the EXT environment variable
# (default: rv64ui). When EXT=rv64um the default test list is the M-extension
# subset; otherwise the base integer subset.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
RISCV_SRC="${RISCV_SRC:-/tmp/riscv-tests/isa}"
EXT="${EXT:-rv64ui}"
ENVDIR="$ROOT/software/riscv-tests-env/rv64gch"
SIM="$ROOT/sim/verilator/obj_dir/Vtb_rv64gch_core"
MARCH="rv64imafd_zicsr_zifencei"
MABI="lp64d"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

if [ "$EXT" = "rv64um" ]; then
  DEFAULT_TESTS="mul mulh mulhsu mulhu div divu rem remu \
mulw divw divuw remw remuw"
else
  DEFAULT_TESTS="add addi addw addiw and andi auipc beq bge bgeu blt bltu bne \
jal jalr lui or ori simple slli slliw sll sllw slt slti sltiu sltu \
srai sraiw sra sraw srli srliw srl srlw sub subw xor xori \
lb lbu lh lhu lw lwu ld sb sh sw sd"
fi

TESTS="${*:-$DEFAULT_TESTS}"

pass=0; fail=0; failed_list=""
for t in $TESTS; do
  src="$RISCV_SRC/$EXT/$t.S"
  if [ ! -f "$src" ]; then echo "SKIP $t (no source)"; continue; fi
  elf="$WORK/$t.elf"; hex="$WORK/$t.hex"
  if ! riscv64-unknown-elf-gcc -march=$MARCH -mabi=$MABI -nostdlib -nostartfiles -static \
        -T "$ENVDIR/link.ld" -I "$ENVDIR" -I "$ROOT/software/riscv-tests-env" \
        -I "$RISCV_SRC" -I "$RISCV_SRC/macros/scalar" \
        "$src" -o "$elf" 2>"$WORK/$t.cc_err"; then
    echo "COMPILE_FAIL $t"; fail=$((fail+1)); failed_list="$failed_list $t"; continue
  fi
  python3 "$ROOT/tools/scripts/elf2hex.py" "$elf" "$hex" >/dev/null 2>&1 || true
  out="$("$SIM" +hex="$hex" 2>/dev/null | grep -E '\[tb\] TEST (PASSED|FAILED)') || true"
  if echo "$out" | grep -q PASSED; then
    echo "PASS $t"; pass=$((pass+1))
  else
    th=$(echo "$out" | grep -oE 'tohost=0x[0-9a-f]+' | head -1)
    echo "FAIL $t ($th)"; fail=$((fail+1)); failed_list="$failed_list $t"
  fi
done
echo "============================="
echo "[$EXT] PASS=$pass FAIL=$fail"
[ -n "$failed_list" ] && echo "FAILED:$failed_list"
[ "$fail" -ne 0 ] && exit 1
