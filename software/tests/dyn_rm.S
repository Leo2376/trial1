/*
 * dyn_rm.S — directed test: FP rm=DYN (111) must use fcsr.frm.
 *
 * Covers fdiv.s (1.0/3.0) under frm=RTZ/RNE/RUP and fdiv.d (1.0/10.0)
 * under frm=RTZ/RNE. The csrw frm -> dyn op is back-to-back, so it also
 * exercises the core's frm hazard stall (DYN in ID waits for a pending
 * FRM/FCSR write to retire). riscv-tests never use dyn, so this is the
 * only coverage for the frm substitution mux.
 *
 * PASS: tohost = 1. FAIL: tohost = (test_id << 1) | 1.
 *
 * Build & run (from repo root):
 *   riscv64-unknown-elf-gcc -march=rv64imafdc_zicsr_zifencei -mabi=lp64d \
 *     -nostdlib -nostartfiles -static \
 *     -T software/riscv-tests-env/rv64gch/link.ld software/tests/dyn_rm.S \
 *     -o /tmp/dyn_rm.elf
 *   python3 tools/scripts/elf2hex.py /tmp/dyn_rm.elf /tmp/dyn_rm.hex
 *   ./sim/verilator/obj_dir/Vtb_rv64gch_core +hex=/tmp/dyn_rm.hex
 */
#define TOHOST_ADDR 0x100000000
.section .text.init, "ax"
.globl _start
_start:
    li sp, 0x8000fffff8
    li t0, (1 << 13)
    csrs mstatus, t0          # enable FP

    # --- single: ft0=1.0, ft1=3.0 ---
    li t0, 0x3F800000
    fmv.w.x ft0, t0
    li t0, 0x40400000
    fmv.w.x ft1, t0

    # frm=RTZ (1), back-to-back DYN (tests frm hazard stall path)
    li t0, 1
    csrw frm, t0
    fdiv.s ft2, ft0, ft1, dyn
    fmv.x.w t1, ft2
    li t2, 0x3EAAAAAA         # 1/3 RTZ (truncate); RNE would be ...AB
    li t0, 2
    bne t1, t2, fail

    # frm=RNE (0), DYN must round to nearest even
    li t0, 0
    csrw frm, t0
    fdiv.s ft2, ft0, ft1, dyn
    fmv.x.w t1, ft2
    li t2, 0x3EAAAAAB
    li t0, 4
    bne t1, t2, fail

    # frm=RUP (3): 1/3 positive rounds up -> ...AB (differs from RTZ)
    li t0, 3
    csrw frm, t0
    fdiv.s ft2, ft0, ft1, dyn
    fmv.x.w t1, ft2
    li t2, 0x3EAAAAAB
    li t0, 6
    bne t1, t2, fail

    # --- double: ft3=1.0, ft4=10.0 (1/3 can't discriminate: RNE==RTZ) ---
    la t0, d_one
    fld ft3, 0(t0)
    la t0, d_ten
    fld ft4, 0(t0)

    li t0, 1                  # RTZ
    csrw frm, t0
    fdiv.d ft5, ft3, ft4, dyn
    fmv.x.d t1, ft5
    la t2, d_rtz
    ld t2, 0(t2)              # 0x3FB9999999999999
    li t0, 8
    bne t1, t2, fail

    li t0, 0                  # RNE
    csrw frm, t0
    fdiv.d ft5, ft3, ft4, dyn
    fmv.x.d t1, ft5
    la t2, d_rne
    ld t2, 0(t2)              # 0x3FB999999999999A
    li t0, 10
    bne t1, t2, fail

pass:
    li t0, 0x100000000
    li t1, 1
    sd t1, 0(t0)
    j pass
fail:
    # t0 holds test id; tohost = (id<<1)|1
    slli t0, t0, 1
    ori t0, t0, 1
    li t1, 0x100000000
    sd t0, 0(t1)
    j fail

.section .data
.align 3
d_one:   .dword 0x3FF0000000000000
d_ten:   .dword 0x4024000000000000
d_rtz:   .dword 0x3FB9999999999999
d_rne:   .dword 0x3FB999999999999A
