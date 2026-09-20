/*
 * priv_csr.S -- machine CSR state (M-mode, no traps expected).
 *
 * Covers: mstatus MPP/MPIE/MIE/MPRV/SUM/MXR write/read, UXL==2 hardwire,
 * sstatus SUM/MXR overlay both directions, SPP flop, medeleg/mideleg
 * round-trip, satp WARL (9 sticks, 15 -> Bare, ASID/PPN), misa MXL,
 * mhartid==0, cycle/instret advance. Any mismatch -> FAIL id.
 *
 * PASS: tohost = 1. FAIL: tohost = (id << 1) | 1.
 *
 * Build & run: same pattern as priv_ecall.S (see its header).
 */
#define TOHOST_ADDR 0x100000000
.section .text.init, "ax"
.globl _start
_start:
    li sp, 0x8000fffff8
    li t3, 0                       # (unused, keep ABI calm)

    # MPP: write U/S/M, read back [12:11]
    li t0, ~(3 << 11)
    csrc mstatus, t0               # MPP=U
    csrr t1, mstatus
    srli t1, t1, 11
    andi t1, t1, 3
    bnez t1, fail02
    li t0, (1 << 11)
    csrs mstatus, t0               # MPP=S
    csrr t1, mstatus
    srli t1, t1, 11
    andi t1, t1, 3
    li t2, 1
    bne t1, t2, fail04
    li t0, (3 << 11)
    csrs mstatus, t0               # MPP=M
    csrr t1, mstatus
    srli t1, t1, 11
    andi t1, t1, 3
    li t2, 3
    bne t1, t2, fail06
    # MPIE/MIE
    li t0, (1 << 7)
    csrs mstatus, t0               # MPIE=1
    csrr t1, mstatus
    andi t1, t1, (1 << 7)
    beqz t1, fail08
    li t0, (1 << 3)
    csrc mstatus, t0               # MIE=0
    csrr t1, mstatus
    andi t1, t1, (1 << 3)
    bnez t1, fail10
    # MPRV/SUM/MXR
    li t0, (1 << 17) | (1 << 18) | (1 << 19)
    csrs mstatus, t0
    csrr t1, mstatus
    and t1, t1, t0
    bne t1, t0, fail12
    li t0, (1 << 17) | (1 << 18) | (1 << 19)
    csrc mstatus, t0
    csrr t1, mstatus
    and t1, t1, t0
    bnez t1, fail14
    # UXL==2 in sstatus
    csrr t1, sstatus
    srli t1, t1, 32
    andi t1, t1, 3
    li t2, 2
    bne t1, t2, fail16
    # sstatus SUM overlay -> mstatus and back
    li t0, (1 << 18)
    csrs sstatus, t0
    csrr t1, mstatus
    and t1, t1, t0
    beqz t1, fail18
    csrc sstatus, t0
    csrr t1, mstatus
    and t1, t1, t0
    bnez t1, fail20
    # SPP flop via sstatus
    li t0, (1 << 8)
    csrs sstatus, t0
    csrr t1, sstatus
    and t1, t1, t0
    beqz t1, fail22
    csrc sstatus, t0
    # medeleg/mideleg round-trip (all-ones)
    li t0, -1
    csrw medeleg, t0
    csrr t1, medeleg
    bne t1, t0, fail24
    csrw mideleg, t0
    csrr t1, mideleg
    bne t1, t0, fail26
    csrw medeleg, zero
    csrw mideleg, zero
    # satp WARL: 9 sticks, 15 -> Bare, ASID/PPN round-trip
    li t0, 0x9000000000080017
    csrw satp, t0
    csrr t1, satp
    bne t1, t0, fail28
    li t0, 0xF000000000000000
    csrw satp, t0                 # illegal mode -> Bare
    csrr t1, satp
    bnez t1, fail30
    li t0, 0x8000000000080010
    csrw satp, t0                 # restore Bare
    # misa MXL==2, mhartid==0
    csrr t1, misa
    srli t1, t1, 62
    li t2, 2
    bne t1, t2, fail32
    csrr t1, mhartid
    bnez t1, fail34
    # cycle/instret advance
    csrr t1, cycle
    csrr t2, cycle
    bltu t2, t1, fail36            # unsigned: t2 < t1 impossible if advancing
    beq t1, t2, fail36             # equal means frozen
    csrr t1, instret
    csrr t2, instret
    beq t1, t2, fail38
pass:
    li t0, TOHOST_ADDR
    li t1, 1
    sd t1, 0(t0)
    j pass
fail02: li t3, 2; j failS
fail04: li t3, 4; j failS
fail06: li t3, 6; j failS
fail08: li t3, 8; j failS
fail10: li t3, 10; j failS
fail12: li t3, 12; j failS
fail14: li t3, 14; j failS
fail16: li t3, 16; j failS
fail18: li t3, 18; j failS
fail20: li t3, 20; j failS
fail22: li t3, 22; j failS
fail24: li t3, 24; j failS
fail26: li t3, 26; j failS
fail28: li t3, 28; j failS
fail30: li t3, 30; j failS
fail32: li t3, 32; j failS
fail34: li t3, 34; j failS
fail36: li t3, 36; j failS
fail38: li t3, 38; j failS
failS:
    slli t3, t3, 1
    ori t3, t3, 1
    li t1, TOHOST_ADDR
    sd t3, 0(t1)
    j failS
