/*
 * l1i_conflict.S — directed L1I conflict/eviction test.
 *
 * Five 8-byte functions placed 8 KiB apart land in the same L1I set
 * (256 sets, 4 ways: same index [12:5], different tags). Calling all five
 * forces a tree-PLRU eviction; re-calling func0 forces a refill. Any
 * tag/way/data mix-up returns wrong values -> FAIL.
 *
 * NOTE: spacing assumes the 32 KiB / 4-way / 32B-line geometry in
 * rtl/cache/l1i/l1i.sv. Re-derive the stride if the cache changes.
 *
 * PASS: tohost = 1. FAIL: tohost = (3 << 1) | 1 = 7.
 *
 * Build & run (from repo root):
 *   riscv64-unknown-elf-gcc -march=rv64imafdc_zicsr_zifencei -mabi=lp64d \
 *     -nostdlib -nostartfiles -static \
 *     -T software/riscv-tests-env/rv64gch/link.ld \
 *     software/tests/l1i_conflict.S -o /tmp/l1i_conflict.elf
 *   python3 tools/scripts/elf2hex.py /tmp/l1i_conflict.elf /tmp/l1i_conflict.hex
 *   ./sim/verilator/obj_dir/Vtb_rv64gch_core +hex=/tmp/l1i_conflict.hex
 */
#define TOHOST_ADDR 0x100000000
.section .text.init, "ax"
.globl _start
_start:
    li sp, 0x8000fffff8
    li t0, (1 << 13)
    csrs mstatus, t0          # enable FP (harmless)

    call f0
    mv s0, a0
    call f1
    mv s1, a0
    call f2
    mv s2, a0
    call f3
    mv s3, a0
    call f4
    mv s4, a0
    # 5 lines in one 4-way set -> eviction happened; refill f0
    call f0
    mv s5, a0

    li t0, 0x111
    bne s0, t0, fail
    li t0, 0x222
    bne s1, t0, fail
    li t0, 0x333
    bne s2, t0, fail
    li t0, 0x444
    bne s3, t0, fail
    li t0, 0x555
    bne s4, t0, fail
    li t0, 0x111
    bne s5, t0, fail
pass:
    li t0, TOHOST_ADDR
    li t1, 1
    sd t1, 0(t0)
    j pass
fail:
    li t1, TOHOST_ADDR
    li t0, 3                  # id=3 -> tohost 7
    slli t0, t0, 1
    ori t0, t0, 1
    sd t0, 0(t1)
    j fail

.section .text, "ax"
.option norvc
.org 0x0
f0: addi a0, zero, 0x111
    jalr x0, 0(ra)
.org 0x2000
f1: addi a0, zero, 0x222
    jalr x0, 0(ra)
.org 0x4000
f2: addi a0, zero, 0x333
    jalr x0, 0(ra)
.org 0x6000
f3: addi a0, zero, 0x444
    jalr x0, 0(ra)
.org 0x8000
f4: addi a0, zero, 0x555
    jalr x0, 0(ra)
