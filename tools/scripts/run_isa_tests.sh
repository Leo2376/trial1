#!/usr/bin/env bash
# Compile and run a subset of riscv-tests under the Verilator testbench.
# Usage: run_isa_tests.sh [test1 test2 ...]
#
# Selects the test family (rv64ui / rv64um / rv64uf / rv64uc) via the EXT
# environment variable (default: rv64ui). When EXT=rv64uc the default test
# list is the RVC corner-case suite (rvc.S); the march is extended with `c`
# so the toolchain emits compressed instructions.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
RISCV_SRC="${RISCV_SRC:-/tmp/riscv-tests/isa}"
EXT="${EXT:-rv64ui}"
ENVDIR="$ROOT/software/riscv-tests-env/rv64gch"
SIM="$ROOT/sim/verilator/obj_dir/Vtb_rv64gch_core"
MARCH="rv64imafdc_zicsr_zifencei"
MABI="lp64d"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

case "$EXT" in
  rv64um)
    DEFAULT_TESTS="mul mulh mulhsu mulhu div divu rem remu \
mulw divw divuw remw remuw";;
  rv64uf)
    DEFAULT_TESTS="fadd fdiv fmin fclass fcmp fcvt fcvt_w move ldst fmadd recoding";;
  rv64ud)
    DEFAULT_TESTS="fadd fdiv fmin fclass fcmp fcvt fcvt_w move ldst fmadd recoding structural";;
  rv64uc)
    DEFAULT_TESTS="rvc";;
  rv64ua)
    DEFAULT_TESTS="amoadd_w amoadd_d amoand_w amoand_d amoor_w amoor_d amoxor_w amoxor_d amoswap_w amoswap_d amomin_w amomin_d amominu_w amominu_d amomax_w amomax_d amomaxu_w amomaxu_d lrsc";;
  *)
    DEFAULT_TESTS="add addi addw addiw and andi auipc beq bge bgeu blt bltu bne \
jal jalr lui or ori simple slli slliw sll sllw slt slti sltiu sltu \
srai sraiw sra sraw srli srliw srl srlw sub subw xor xori \
lb lbu lh lhu lw lwu ld sb sh sw sd";;
esac

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
  out="$("$SIM" +hex="$hex" 2>/dev/null | grep -E '\[tb\] TEST (PASSED|FAILED)' || true)"
  if echo "$out" | grep -q PASSED; then
    echo "PASS $t"; pass=$((pass+1))
  else
    th=$(echo "$out" | grep -oE 'tohost=0x[0-9a-f]+' | head -1 || true)
    echo "FAIL $t ($th)"; fail=$((fail+1)); failed_list="$failed_list $t"
  fi
done
echo "============================="
echo "[$EXT] PASS=$pass FAIL=$fail"
[ -n "$failed_list" ] && echo "FAILED:$failed_list"
[ "$fail" -ne 0 ] && exit 1
