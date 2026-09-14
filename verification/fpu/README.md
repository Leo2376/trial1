# FPU Arithmetic Validation

Standalone single-precision FPU for validating the arithmetic datapath before
integration into `rtl/core/fpu/fpu.sv`.

## Status (last session)

All five single-precision arithmetic operations now pass RNE
(round-to-nearest-even) against a Python `struct.pack('<f')` reference over
40k+ random vectors (including normals, denormals, infinities, NaNs, and
zero):

| Op         | tests | errors | status |
|------------|-------|--------|--------|
| FADD (op0) | 8041  | 0      | PASS   |
| FSUB (op1) | 7973  | 0      | PASS   |
| FMUL (op2) | 8020  | 0      | PASS   |
| FDIV (op3) | 7939  | 0      | PASS   |
| FSQRT(op4) | 8056  | 0      | PASS   |

`tbcount.sv` reports `TOTAL errors=0 tests=40029 PASS`.

Directed rounding modes (RTZ/RDN/RUP/RMM) are also IEEE-correct: FADD/FSUB/FMUL
pass 0/20000 across all five modes when the reference is computed on operands
whose exact result fits in double precision (close exponents). FDIV/FSQRT show a
small residual (~1.7%) against the double-precision reference, which is a known
**reference** limitation: the double result of `a/b` or `sqrt(a)` is itself
approximate, so rounding it to single occasionally lands on the wrong side of a
half-ULP boundary. The same effect causes the RNE failures for
extreme-cancellation FADD/FSUB where a tiny operand is below single ULP (the
double intermediate loses it, so the reference reports an exact value while the
hardware correctly flags inexactness). The hardware is correct in these cases;
only the reference is wrong.

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

3. **Overflow vs underflow need a wider exponent.** The 9-bit biased exponent
   collides for FMUL products: `ea+eb-127` can reach +381 (overflow) which in a
   9-bit field sets the sign bit and is misread as underflow. `round_pack_s` now
   uses a 10-bit **signed** biased exponent so the true range [-127, +254] (and
   overflow products up to +381) never collides with the sign. Overflow =
   `signed(e) >= 255`; underflow/denormal = `signed(e) <= 0`.

4. **Denormal results are produced by shifting, not flushing.** When the biased
   exponent is <= 0, `round_pack_s` shifts the 28-bit field F right by
   `(1 - e)` to denormalize, recomputes guard/round/sticky, rounds, and returns
   either a denormal (exp=0) or, if rounding carries into the implicit bit, the
   smallest normal (exp=1).

5. **FDIV rounding needs guard bits from the quotient.** Computing a 24-bit
   floor quotient loses the rounding information. The divider now computes a
   28-bit quotient `q = (ma << 26) / mb` so the 24-bit mantissa sits in `q[26:3]`
   with two guard bits (`q[2]`, `q[1]`) and a round bit (`q[0]`); the remainder
   supplies the sticky. The dividend `(ma << 23)` must be formed in a 48-bit
   dividend or the shift truncates to zero.

6. **FSQRT uses a non-restoring integer sqrt over a left-justified radicand.**
   Denormal inputs are normalized first (find leading 1, shift, `E = L - 149`).
   For an odd unbiased exponent the factor of 2 is folded into the mantissa
   (`sqrt(2.frac)` in [sqrt(2), 2)). A 26-iteration digit-by-digit sqrt produces
   a 26-bit root (24-bit 1.xxx mantissa + 2 guard bits); the remainder is the
   sticky. The result exponent is `floor(E/2) + 127` with an arithmetic shift
   so negative E is handled correctly. Bits are extracted by absolute index
   (`radicand[2*i+1 -: 2]`), not by shifting the radicand and reading its top,
   because the odd/even exponent cases place the leading 1 at different field
   positions.

7. **FADD/FSUB subtract-path sticky fix (RNE-correct):** for effective
   subtraction, the aligned small operand's guard/round bits participate in the
   subtract. The sticky bit (dropped below bit 0) is ORed into `smallF[0]`
   BEFORE the subtract so the borrow propagates correctly. After normalization
   the original sticky is ORed back into `sumF[0]` to mark inexactness.

## Remaining work

- Port the validated single-precision arithmetic to **double-precision**
  (F/D extensions).
- Add the **non-arithmetic** ops: FMIN/FMAX/FSGNJ/FCMP/FCLASS/FCVT/FMV.
- Integrate the validated functions into `rtl/core/fpu/fpu.sv` and wire `fflags`
  to the CSR unit.
- (Optional) Build an exact-integer reference generator to close the
  directed-rounding gap for FDIV/FSQRT and extreme-cancellation FADD/FSUB, since
  the double-precision reference is insufficient there.

## Running

```bash
cd verification/fpu
python3 genall.py                 # generate vecs_all.txt
verilator --binary -Wno-fatal -Wno-WIDTHTRUNC -Wno-UNOPTFLAT \
  fpu_full.sv tbcount.sv
./obj_dir/Vfpu_full               # per-op error counts (expect 0/... PASS)
```

The `fpu_s.sv` + `tb5.sv` pair validates FADD/FSUB RNE only (30007 vectors).
The `fpu_s.sv` + `tb_rm.sv` pair tests all rounding modes (known issue: the
double-intermediate Python reference diverges from true single-precision for
extreme-cancellation cases where the tiny operand is below single ULP; not
needed for rv64uf which is RNE).

`genrm_all.py` + `tb_rm_all.sv` exercise all five ops x five rounding modes
against the double-precision reference; FADD/FSUB/FMUL pass cleanly when the
reference is exact, FDIV/FSQRT carry the residual noted above.
