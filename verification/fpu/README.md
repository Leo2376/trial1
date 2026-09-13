# FPU Arithmetic Validation (work-in-progress)

Standalone single-precision FPU for validating the arithmetic datapath before
integration into `rtl/core/fpu/fpu.sv`.

## Status (last session)

| Op         | tests | errors | status |
|------------|-------|--------|--------|
| FADD (op0) | 8041  | 0      | PASS   |
| FSUB (op1) | 7973  | 0      | PASS   |
| FMUL (op2) | 8020  | 927    | WIP    |
| FDIV (op3) | 7939  | 6974   | WIP    |
| FSQRT(op4) | 8056  | 3464   | WIP    |

FADD/FSUB pass RNE (round-to-nearest-even) against a Python `struct.pack('<f')`
reference over 30k+ random vectors.

## Key findings

1. **RNE is the priority for rv64uf CI.** The riscv-tests `rv64uf` suite
   (`fadd.S`, `fdiv.S`, etc.) uses the **default rounding mode** for FP
   arithmetic (no `rm` override on `fadd.s`/`fsub.s`/`fmul.s`/`fdiv.s`/`fsqrt.s`).
   The `flags` arg is `fflags`, not a rounding mode. Only `FCVT.*->int` ops take
   an explicit `rm`. So directed rounding modes (RTZ/RDN/RUP/RMM) are NOT
   exercised by rv64uf FADD/FSUB/FMUL/FDIV/FSQRT.

2. **round_pack_s field layout** (validated): 28-bit field F where the leading 1
   sits at bit 26, fraction at [25:3], guard=F[2], round=F[1], sticky=F[0].
   Round-up adds 8 (not 1) at bit 3. RNE: `round_up = g & (r | s_bit | lsb)`.

3. **FADD/FSUB subtract-path sticky fix (RNE-correct):** for effective
   subtraction, the aligned small operand's guard/round bits participate in the
   subtract. The sticky bit (dropped below bit 0) is ORed into `smallF[0]`
   BEFORE the subtract so the borrow propagates correctly. After normalization
   the original sticky is ORed back into `sumF[0]` to mark inexactness.

## Remaining work

- **FMUL:** field construction uses `(prod >> 21)` (prod[47]) and
  `(prod >> 20)` (prod[46]) with mask `28'h0FFFFFFF`; exp `+1` for prod[47].
  Still ~11% errors to debug (likely denormal/flush cases and exp edge cases).
- **FDIV:** `q = (ma << 23) / mb` with direct `/` for validation; still failing
  (q appears wrong despite correct Python trace). Debug the Verilator width
  handling of `(ma << 23) / mb` assigned to 24-bit `q`.
- **FSQRT:** bit-by-bit sqrt loop has wrong mantissa/exp handling for odd
  exponents; needs rework.
- After single-precision ops validated, port to double-precision, add the
  non-arithmetic ops (FMIN/FMAX/FSGNJ/FCMP/FCLASS/FCVT/FMV), then integrate
  the validated functions into `rtl/core/fpu/fpu.sv` and wire `fflags` to the
  CSR unit.

## Running

```bash
cd verification/fpu
python3 genall.py                 # generate vecs_all.txt
verilator --binary -Wno-fatal -Wno-WIDTHTRUNC -Wno-UNOPTFLAT \
  fpu_full.sv tbcount.sv
./obj_dir/Vfpu_full               # per-op error counts
```

The `fpu_s.sv` + `tb5.sv` pair validates FADD/FSUB RNE only (30007 vectors).
The `fpu_s.sv` + `tb_rm.sv` pair tests all rounding modes (known issue: the
double-intermediate Python reference diverges from true single-precision for
extreme-cancellation cases where the tiny operand is below single ULP; not
needed for rv64uf which is RNE).
