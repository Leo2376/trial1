/*
 * l2_wb.S — directed L2 writeback/eviction test.
 *
 * Nine data lines in the same L2 set (1024 sets, 8 ways: BASE + k*32K ->
 * same index [14:5], different tags; also one L1D set, so both levels
 * churn). sd distinct patterns to all 9 (the 9th forces an L2 dirty
 * eviction and DRAM writeback), then ld back (L2 refill from the
 * written-back data). Any lost writeback byte -> FAIL with test id.
 *
 * NOTE: spacing assumes the 256 KiB / 8-way / 32B-line geometry in
 * rtl/cache/l2/l2.sv. Re-derive the stride if the cache changes.
 *
 * PASS: tohost = 1. FAIL: tohost = (id << 1) | 1.
 *
 * Build & run (from repo root):
 *   riscv64-unknown-elf-gcc -march=rv64imafdc_zicsr_zifencei -mabi=lp64d \
 *     -nostdlib -nostartfiles -static \
 *     -T software/riscv-tests-env/rv64gch/link.ld \
 *     software/tests/l2_wb.S -o /tmp/l2_wb.elf
 *   python3 tools/scripts/elf2hex.py /tmp/l2_wb.elf /tmp/l2_wb.hex
 *   ./sim/verilator/obj_dir/Vtb_rv64gch_core +hex=/tmp/l2_wb.hex
 */
#define TOHOST_ADDR 0x100000000
.section .text.init, "ax"
.globl _start
_start:
    li sp, 0x8000fffff8

    li t0, 0x80020000            # line 0
    li t4, 0x8000               # 32K stride
    add t5, t0, t4              # line 1 (+32K)
    add t6, t5, t4              # line 2 (+64K)
    add s1, t6, t4              # line 3 (+96K)
    add s3, s1, t4              # line 4 (+128K)
    add s4, s3, t4              # line 5 (+160K)
    add s5, s4, t4              # line 6 (+192K)
    add s6, s5, t4              # line 7 (+224K)
    add s7, s6, t4              # line 8 (+256K)

    li t1, 0x1111111111111111
    sd t1, 0(t0)
    li t1, 0x2222222222222222
    sd t1, 0(t5)
    li t1, 0x3333333333333333
    sd t1, 0(t6)
    li t1, 0x4444444444444444
    sd t1, 0(s1)
    li t1, 0x5555555555555555
    sd t1, 0(s3)
    li t1, 0x6666666666666666
    sd t1, 0(s4)
    li t1, 0x7777777777777777
    sd t1, 0(s5)
    li t1, 0x8888888888888888
    sd t1, 0(s6)
    li t1, 0x9999999999999999
    sd t1, 0(s7)                # 9th line -> L2 eviction + DRAM writeback

    ld t1, 0(t0)
    li t2, 0x1111111111111111
    li t3, 60
    bne t1, t2, fail
    ld t1, 0(t5)
    li t2, 0x2222222222222222
    li t3, 62
    bne t1, t2, fail
    ld t1, 0(t6)
    li t2, 0x3333333333333333
    li t3, 64
    bne t1, t2, fail
    ld t1, 0(s1)
    li t2, 0x4444444444444444
    li t3, 66
    bne t1, t2, fail
    ld t1, 0(s3)
    li t2, 0x5555555555555555
    li t3, 68
    bne t1, t2, fail
    ld t1, 0(s4)
    li t2, 0x6666666666666666
    li t3, 70
    bne t1, t2, fail
    ld t1, 0(s5)
    li t2, 0x7777777777777777
    li t3, 72
    bne t1, t2, fail
    ld t1, 0(s6)
    li t2, 0x8888888888888888
    li t3, 74
    bne t1, t2, fail
    ld t1, 0(s7)
    li t2, 0x9999999999999999
    li t3, 76
    bne t1, t2, fail
pass:
    li t0, TOHOST_ADDR
    li t1, 1
    sd t1, 0(t0)
    j pass
fail:
    slli t3, t3, 1
    ori t3, t3, 1
    li t1, TOHOST_ADDR
    sd t3, 0(t1)
    j fail
