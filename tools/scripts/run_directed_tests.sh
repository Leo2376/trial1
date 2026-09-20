#!/usr/bin/env bash
# Build and run the directed core tests in software/tests/.
# Usage: run_directed_tests.sh [test1 test2 ...]  (default: all)
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
ENVDIR="$ROOT/software/riscv-tests-env/rv64gch"
SIM="$ROOT/sim/verilator/obj_dir/Vtb_rv64gch_core"
MARCH="rv64imafdc_zicsr_zifencei"
MABI="lp64d"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

DEFAULT_TESTS="dyn_rm l1i_conflict l1d_wb l2_wb sv39_basic sv39_fault sv39_sfence deleg_basic asid_test sv48_basic priv_ecall priv_csr"
TESTS="${*:-$DEFAULT_TESTS}"

pass=0; fail=0; failed_list=""
for t in $TESTS; do
  src="$ROOT/software/tests/$t.S"
  if [ ! -f "$src" ]; then echo "SKIP $t (no source)"; continue; fi
  elf="$WORK/$t.elf"; hex="$WORK/$t.hex"
  if ! riscv64-unknown-elf-gcc -march=$MARCH -mabi=$MABI -nostdlib -nostartfiles -static \
        -T "$ENVDIR/link.ld" "$src" -o "$elf" 2>"$WORK/$t.cc_err"; then
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
echo "[directed] PASS=$pass FAIL=$fail"
[ -n "$failed_list" ] && echo "FAILED:$failed_list"
[ "$fail" -ne 0 ] && exit 1
