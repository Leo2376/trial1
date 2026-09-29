/*
 * plic_basic.S -- 64-source PLIC: priority, threshold, claim/complete.
 *
 * M-mode Bare. Sources are driven by the TB stim model (STIM_BASE):
 * STIM_LO bit b -> source b+1, STIM_HI bit b -> source b+33.
 * Phase 1 (threshold 0): assert sources 1 (prio 1) + 64 (prio 2);
 *   expect MEI trap, claim 64, complete, claim 1, complete, claim 0.
 * Phase 2 (threshold 1): assert both again; only 64 is eligible
 *   (2 > 1, 1 > 1 false); claim 64, complete; drop threshold to 0 and
 *   claim 1. Then clear stim, disarm, PASS. mepc must be the spinner.
 *
 * PASS: tohost = 1. FAIL: tohost = (id << 1) | 1.
 *
 * Build & run (from repo root):
 *   riscv64-unknown-elf-gcc -march=rv64imafdc_zicsr_zifencei -mabi=lp64d \
 *     -nostdlib -nostartfiles -static \
 *     -T software/riscv-tests-env/rv64gch/link.ld software/tests/plic_basic.S \
 *     -o /tmp/plic_basic.elf
 *   python3 tools/scripts/elf2hex.py /tmp/plic_basic.elf /tmp/plic_basic.hex
 *   ./sim/verilator/obj_dir/Vtb_rv64gch_core +hex=/tmp/plic_basic.hex
 */
#define TOHOST_ADDR 0x100000000
#define STIM_BASE   0x100080000
#define PLIC_BASE   0x100200000
#define MCAUSE_MEI  0x800000000000000b
/* far-MMIO helpers: t6 scratch, base kept */
.macro stw reg, off, base
    li t6, \off
    add t6, \base, t6
    sw \reg, 0(t6)
.endm
.macro ldw reg, off, base
    li t6, \off
    add t6, \base, t6
    lw \reg, 0(t6)
.endm
.section .text.init, "ax"
.globl _start
_start:
    li sp, 0x8000fffff8
    la t0, m_trap
    csrw mtvec, t0
    li s0, PLIC_BASE
    # priority[64] = 2, priority[1] = 1
    li t1, 2
    stw t1, 256, s0               # 4*64
    li t1, 1
    stw t1, 4, s0                 # 4*1
    # enable M word2 bit0 (source 64) + word0 bit1 (source 1)
    li t1, 1
    stw t1, 0x2008, s0
    li t1, 2
    stw t1, 0x2000, s0
    # threshold M = 0
    stw zero, 0x200000, s0
    # drive sources 1 + 64 via stim
    li t0, STIM_BASE
    li t1, 1
    sw t1, 0(t0)                  # source 1
    li t1, 0x80000000
    sw t1, 8(t0)                  # source 64 (stim_hi bit31)
    # mie.MEIE = 1, mstatus.MIE = 1
    li t0, (1 << 11)
    csrw mie, t0
    csrs mstatus, 8
spin:
    j spin

m_trap:
    csrr t0, mcause
    li t1, MCAUSE_MEI
    bne t0, t1, fail02            # must be an external interrupt
    csrr t0, mepc
    la t1, spin
    bne t0, t1, fail04            # trapped insn is the spinner
    # pending word0 bit1 (src1) + word2 bit0 (src64)
    ldw t0, 0x1000, s0
    srli t0, t0, 1
    andi t0, t0, 1
    beqz t0, fail06
    ldw t0, 0x1008, s0
    andi t0, t0, 1
    beqz t0, fail08
    # phase 1: claim -> 64
    ldw t0, 0x200004, s0
    li t1, 64
    bne t0, t1, fail10
    # complete 64, then deassert it so source 1 can win next
    stw t0, 0x200004, s0
    li t0, STIM_BASE
    sw zero, 8(t0)                # source 64 off
    # claim -> 1
    ldw t0, 0x200004, s0
    li t1, 1
    bne t0, t1, fail12
    # complete 1
    stw t0, 0x200004, s0
    # clear both stim sources, then nothing is pending
    li t0, STIM_BASE
    sw zero, 0(t0)                # source 1 off
    # (source 64 already off)
    # claim -> 0 (none)
    ldw t0, 0x200004, s0
    bnez t0, fail14
    # phase 2: threshold 1 masks source 1 (prio 1), not 64 (prio 2).
    # re-assert 64 first.
    li t0, STIM_BASE
    li t1, 0x80000000
    sw t1, 8(t0)                  # source 64 on
    li t0, 1
    stw t0, 0x200000, s0          # threshold 1
    ldw t0, 0x200004, s0
    li t1, 64
    bne t0, t1, fail16
    stw t0, 0x200004, s0
    # drop 64 again; assert 1: still masked by threshold 1
    li t0, STIM_BASE
    sw zero, 8(t0)                # source 64 off
    li t1, 1
    sw t1, 0(t0)                  # source 1 on
    ldw t0, 0x200004, s0
    bnez t0, fail18               # expect none
    # threshold back to 0: source 1 eligible again
    stw zero, 0x200000, s0
    ldw t0, 0x200004, s0
    li t1, 1
    bne t0, t1, fail20
    stw t0, 0x200004, s0
    # phase 3: middle word coverage (source 40: word1 bit8).
    li t1, 3
    stw t1, 160, s0               # priority[40] = 3 (4*40)
    li t1, 0x100
    stw t1, 0x2004, s0            # enable word1 bit8
    li t0, STIM_BASE
    li t1, 0x80
    sw t1, 8(t0)                  # stim_hi bit7 -> source 40
    ldw t0, 0x200004, s0
    li t1, 40
    bne t0, t1, fail22
    stw t0, 0x200004, s0
    # clear stim sources
    li t0, STIM_BASE
    sw zero, 0(t0)
    sw zero, 8(t0)
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
fail08:
    li t0, 8
    j failrep
fail10:
    li t0, 10
    j failrep
fail12:
    li t0, 12
    j failrep
fail14:
    li t0, 14
    j failrep
fail16:
    li t0, 16
    j failrep
fail18:
    li t0, 18
    j failrep
fail20:
    li t0, 20
    j failrep
fail22:
    li t0, 22
    j failrep
failrep:
    # tohost = (id<<1)|1
    slli t0, t0, 1
    ori t0, t0, 1
    li t1, TOHOST_ADDR
    sd t0, 0(t1)
    j failrep
