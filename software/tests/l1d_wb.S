/*
 * l1d_wb.S — directed L1D writeback/eviction test.
 *
 * Five 8-byte stores to data lines sharing one L1D set (256 sets, 4 ways:
 * BASE + k*8K -> same index [12:5], different tags) force a dirty eviction
 * and writeback; reloading all five checks the full dirty-evict-writeback-
 * refill chain byte-exactly. Also covers sub-word sb/sh write-merge.
 * Any lost byte -> FAIL with test id.
 *
 * NOTE: spacing assumes the 32 KiB / 4-way / 32B-line geometry in
 * rtl/cache/l1d/l1d.sv. Re-derive the stride if the cache changes.
 *
 * PASS: tohost = 1. FAIL: tohost = (id << 1) | 1.
 *
 * Build & run (from repo root):
 *   riscv64-unknown-elf-gcc -march=rv64imafdc_zicsr_zifencei -mabi=lp64d \
 *     -nostdlib -nostartfiles -static \
 *     -T software/riscv-tests-env/rv64gch/link.ld \
 *     software/tests/l1d_wb.S -o /tmp/l1d_wb.elf
 *   python3 tools/scripts/elf2hex.py /tmp/l1d_wb.elf /tmp/l1d_wb.hex
 *   ./sim/verilator/obj_dir/Vtb_rv64gch_core +hex=/tmp/l1d_wb.hex
 */
#define TOHOST_ADDR 0x100000000
.section .text.init, "ax"
.globl _start
_start:
    li sp, 0x8000fffff8

    li t0, 0x80020000            # line 0 (set S)
    li t4, 0x2000
    add t5, t0, t4              # line 1: +0x2000
    add t6, t5, t4              # line 2: +0x4000
    slli s0, t4, 2              # 0x8000
    add s1, t0, s0              # line 4: +0x8000
    slli s2, t4, 1              # 0x4000
    add s3, t0, s2
    add s3, s3, t4              # line 3: +0x6000

    li t1, 0x1111111111111111
    sd t1, 0(t0)
    li t1, 0x2222222222222222
    sd t1, 0(t5)
    li t1, 0x3333333333333333
    sd t1, 0(t6)
    li t1, 0x4444444444444444
    sd t1, 0(s3)
    li t1, 0x5555555555555555
    sd t1, 0(s1)                # 5th line -> eviction + writeback
    # sub-word merge into line 1 (sb then sh)
    li t1, 0xAB
    sb t1, 1(t5)
    li t1, 0xCDEF
    sh t1, 4(t5)

    # read back all (refills come from the written-back data)
    ld t1, 0(t0)
    li t2, 0x1111111111111111
    li t3, 40
    bne t1, t2, fail
    ld t1, 0(t5)
    li t2, 0x2222CDEF2222AB22
    li t3, 42
    bne t1, t2, fail
    ld t1, 0(t6)
    li t2, 0x3333333333333333
    li t3, 44
    bne t1, t2, fail
    ld t1, 0(s3)
    li t2, 0x4444444444444444
    li t3, 46
    bne t1, t2, fail
    ld t1, 0(s1)
    li t2, 0x5555555555555555
    li t3, 48
    bne t1, t2, fail
pass:
    li t0, TOHOST_ADDR
    li t1, 1
    sd t1, 0(t0)
    j pass
fail:
    # t3 holds test id; tohost = (id<<1)|1
    slli t3, t3, 1
    ori t3, t3, 1
    li t1, TOHOST_ADDR
    sd t3, 0(t1)
    j fail
