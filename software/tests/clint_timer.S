/*
 * clint_timer.S -- CLINT mtime/mtimecmp + machine timer interrupt.
 *
 * M-mode Bare: programs mtimecmp = mtime + delta, enables MTIE/MIE, spins.
 * The trap handler checks mcause == MTI-with-interrupt-bit and mepc == the
 * spinning insn, disarms the timer (mtimecmp = max), and reports PASS.
 * Any other trap or mismatch -> FAIL.
 *
 * PASS: tohost = 1. FAIL: tohost = (id << 1) | 1.
 *
 * Build & run (from repo root):
 *   riscv64-unknown-elf-gcc -march=rv64imafdc_zicsr_zifencei -mabi=lp64d \
 *     -nostdlib -nostartfiles -static \
 *     -T software/riscv-tests-env/rv64gch/link.ld software/tests/clint_timer.S \
 *     -o /tmp/clint_timer.elf
 *   python3 tools/scripts/elf2hex.py /tmp/clint_timer.elf /tmp/clint_timer.hex
 *   ./sim/verilator/obj_dir/Vtb_rv64gch_core +hex=/tmp/clint_timer.hex
 */
#define TOHOST_ADDR 0x100000000
#define CLINT_BASE  0x100100000
#define MTIMECMP_OFF 0x4000
#define MTIME_OFF    0xBFF8
#define MCAUSE_MTI  0x8000000000000007
/* far-MMIO helpers: t6 scratch, base kept */
.macro ldd reg, off, base
    li t6, \off
    add t6, \base, t6
    ld \reg, 0(t6)
.endm
.macro sdd reg, off, base
    li t6, \off
    add t6, \base, t6
    sd \reg, 0(t6)
.endm
.section .text.init, "ax"
.globl _start
_start:
    li sp, 0x8000fffff8
    la t0, m_trap
    csrw mtvec, t0
    # mtimecmp = mtime + delta (delta >> setup cost so we trap in spin)
    li t0, CLINT_BASE
    ldd t1, MTIME_OFF, t0
    li t2, 10000
    add t1, t1, t2
    sdd t1, MTIMECMP_OFF, t0
    # mie.MTIE = 1, mstatus.MIE = 1
    li t0, (1 << 7)
    csrw mie, t0
    csrs mstatus, 8
spin:
    j spin

m_trap:
    csrr t0, mcause
    li t1, MCAUSE_MTI
    bne t0, t1, fail02            # must be a timer interrupt
    csrr t0, mepc
    la t1, spin
    bne t0, t1, fail04            # trapped insn is the spinner
    # mip.MTIP must read 1 (level source still armed here)
    csrr t0, mip
    andi t0, t0, (1 << 7)
    beqz t0, fail06
    # disarm: mtimecmp = max
    li t0, CLINT_BASE
    li t1, -1
    sdd t1, MTIMECMP_OFF, t0
    j pass

pass:
    li t0, TOHOST_ADDR
    li t1, 1
    sd t1, 0(t0)
    j pass
fail02:
    li t0, 2
    j failrep
fail04:
    li t0, 4
    j failrep
fail06:
    li t0, 6
    j failrep
failrep:
    # tohost = (id<<1)|1
    slli t0, t0, 1
    ori t0, t0, 1
    li t1, TOHOST_ADDR
    sd t0, 0(t1)
    j failrep
