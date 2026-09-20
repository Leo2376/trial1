/*
 * asid_test.S -- ASID tagging + selective SFENCE.VMA (M setup, S test).
 *
 * Two roots (A@0x80010000 ASID=1, B@0x80014000 ASID=2) map VA 0x80200000
 * to PA 0x80020000 (A) / 0x80022000 (B). Part A: switch satp across ASIDs
 * (S can write satp), expect A/B/A (no cross-ASID aliasing). Part B:
 * touch VA1+VA2, rewrite PTEs (VA1 RO, VA2 invalid), sfence.vma VA1-only;
 * store VA2 must SUCCEED (surviving entry; a full flush would fault) and
 * store VA1 must FAULT 15 (re-walk enforces RO). M handler matches.
 *
 * PASS: tohost = 1. FAIL: tohost = fixed fail code or (mcause << 1) | 1.
 *
 * Build & run: same pattern as deleg_basic.S (see its header).
 */
#define TOHOST_ADDR 0x100000000
.section .text.init, "ax"
.globl _start
_start:
    li sp, 0x8000fffff8
    la t0, m_trap
    csrw mtvec, t0

    # rootA
    li t0, 0x80010000
    li t1, 0x20004401
    sd t1, 16(t0)               # rootA[2] -> L1A
    li t1, 0x400000C7
    sd t1, 32(t0)               # rootA[4] 1G leaf -> tohost
    # L1A
    li t0, 0x80011000
    li t1, 0x20004801
    sd t1, 0(t0)                # L1A[0] -> L0a
    li t1, 0x20004C01
    sd t1, 8(t0)                # L1A[1] -> L0bA
    # rootB
    li t0, 0x80014000
    li t1, 0x20005801            # PPN 0x80016, V
    sd t1, 16(t0)               # rootB[2] -> L1B
    li t1, 0x400000C7
    sd t1, 32(t0)               # rootB[4] 1G leaf -> tohost
    # L1B
    li t0, 0x80016000
    li t1, 0x20004801
    sd t1, 0(t0)                # L1B[0] -> L0a (shared)
    li t1, 0x20005401            # PPN 0x80015, V
    sd t1, 8(t0)                # L1B[1] -> L0bB
    # L0a identity 40 pages
    li t0, 0x80012000
    li t1, 0x200000CF
    li t2, 40
0:  sd t1, 0(t0)
    addi t1, t1, 0x400
    addi t0, t0, 8
    addi t2, t2, -1
    bnez t2, 0b
    # L0bA: idx0 ->0x80020 RW, idx1 ->0x80021 RW (A=D=1)
    li t0, 0x80013000
    li t1, 0x200080C7
    sd t1, 0(t0)
    li t1, 0x200084C7
    sd t1, 8(t0)
    # L0bB: idx0 ->0x80022 RW (A=D=1)
    li t0, 0x80015000
    li t1, 0x200088C7
    sd t1, 0(t0)
    # patterns: PA 0x80020000=A, 0x80021000=C, 0x80022000=B
    li t0, 0x80020000
    li t1, 0xAAAAAAAAAAAAAAAA
    sd t1, 0(t0)
    li t0, 0x80021000
    li t1, 0xCCCCCCCCCCCCCCCC
    sd t1, 0(t0)
    li t0, 0x80022000
    li t1, 0xBBBBBBBBBBBBBBBB
    sd t1, 0(t0)
    fence.i

    # ASID=1, rootA: satp = (8<<60)|(1<<44)|0x80010
    li t0, 0x8001000000080010
    csrw satp, t0
    sfence.vma zero, zero
    li t0, (1 << 7) | (1 << 11)
    csrs mstatus, t0
    la t0, s_entry
    csrw mepc, t0
    mret

s_entry:                        # S-mode, ASID=1 rootA
    li t0, 0x80200000
    ld t1, 0(t0)                # expect A
    li t2, 0xAAAAAAAAAAAAAAAA
    bne t1, t2, failS
    # switch to ASID=2 rootB (S can write satp)
    # satp = (8<<60)|(2<<44)|0x80014
    li t0, 0x8002000000080014
    csrw satp, t0
    # NOTE: satp write auto-flushes the TLB; no sfence needed here
    li t0, 0x80200000
    ld t1, 0(t0)                # expect B (ASID2 mapping)
    li t2, 0xBBBBBBBBBBBBBBBB
    bne t1, t2, failS
    # switch back to ASID=1 rootA
    li t0, 0x8001000000080010
    csrw satp, t0
    li t0, 0x80200000
    ld t1, 0(t0)                # expect A again (no aliasing)
    li t2, 0xAAAAAAAAAAAAAAAA
    bne t1, t2, failS
    # Part B: selective sfence. Touch VA1+VA2 (install, ASID1).
    li t0, 0x80200000
    ld t1, 0(t0)                # VA1
    li t0, 0x80201000
    ld t1, 0(t0)                # VA2 (pattern C, just installs)
    # rewrite PTEs: VA1 RO, VA2 invalid (tables identity-mapped)
    li t0, 0x80013000
    li t1, 0x200080C3          # VA1: V|R|A|D (no W)
    sd t1, 0(t0)
    sd zero, 8(t0)              # VA2: invalid
    # sfence.vma VA1-only (rs1=VA1, rs2=0): flushes VA1, keeps VA2
    li t0, 0x80200000
    sfence.vma t0, zero
    # store VA2 (0x80201000) must SUCCEED (surviving entry)
    li t0, 0x80201000
    li t1, 0xDDDDDDDDDDDDDDDD
    sd t1, 0(t0)
    # store VA1 must FAULT 15 (re-walk sees RO)
    li t0, 0x80200000
    sd t1, 0(t0)
    j failS                     # must trap
failS:
    li t3, 0xF4
    slli t3, t3, 1
    ori t3, t3, 1
    li t1, TOHOST_ADDR
    sd t3, 0(t1)
    j failS
.balign 4
.balign 4
m_trap:                         # expect store fault (15) on VA1
    csrr t0, mcause
    li t1, 15
    bne t0, t1, failM
    csrr t0, mtval
    li t1, 0x80200000
    bne t0, t1, failM
    li t0, TOHOST_ADDR
    li t1, 1
    sd t1, 0(t0)
    j .
failM:
    csrr t0, mcause
    slli t0, t0, 1
    ori t0, t0, 1
    li t1, TOHOST_ADDR
    sd t0, 0(t1)
    j failM
