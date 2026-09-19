/*
 * sv39_sfence.S — remap visibility through SFENCE.VMA (M setup, S test).
 *
 * S-mode reads VA 0x80200000 (pattern A, installs TLB), rewrites its PTE
 * to PA 0x80021000 (dirty L1D line), executes sfence.vma (TLB flush +
 * L1D drain so the walker sees the new PTE), and reads again (pattern B;
 * a stale TLB would return A). ecall -> M handler PASS.
 *
 * Build & run: same pattern as sv39_basic.S (see its header).
 */
#define TOHOST_ADDR 0x100000000
.section .text.init, "ax"
.globl _start
_start:
    li sp, 0x8000fffff8
    la t0, m_trap
    csrw mtvec, t0

    li t0, 0x80010000
    li t1, 0x20004401            # root[2] -> L1
    sd t1, 16(t0)
    li t1, 0x4000000C7          # root[4] 1G leaf -> tohost
    sd t1, 32(t0)
    li t0, 0x80011000
    li t1, 0x20004801            # L1[0] -> L0a
    sd t1, 0(t0)
    li t1, 0x20004C01            # L1[1] -> L0b
    sd t1, 8(t0)
    li t0, 0x80012000
    li t1, 0x200000CF
    li t2, 40
0:  sd t1, 0(t0)
    addi t1, t1, 0x400
    addi t0, t0, 8
    addi t2, t2, -1
    bnez t2, 0b
    li t0, 0x80013000
    li t1, 0x200080C7          # L0b[0]: ->0x80020 V|R|W|A|D
    sd t1, 0(t0)
    # data patterns
    li t0, 0x80020000
    li t1, 0xAAAAAAAAAAAAAAAA
    sd t1, 0(t0)
    li t0, 0x80021000
    li t1, 0xBBBBBBBBBBBBBBBB
    sd t1, 0(t0)
    fence.i

    li t0, 0x8000000000080010
    csrw satp, t0
    sfence.vma zero, zero
    li t0, (1 << 7) | (1 << 11)
    csrs mstatus, t0
    la t0, s_entry
    csrw mepc, t0
    mret

s_entry:                        # S-mode
    li t0, 0x80200000
    ld t1, 0(t0)                # expect A (installs TLB)
    li t2, 0xAAAAAAAAAAAAAAAA
    bne t1, t2, failS
    # rewrite PTE: PA 0x80020 -> 0x80021 (tables identity-mapped)
    li t0, 0x80013000
    li t1, 0x200084C7
    sd t1, 0(t0)
    sfence.vma zero, zero       # TLB flush + L1D drain
    li t0, 0x80200000
    ld t1, 0(t0)                # expect B (stale TLB would give A)
    li t2, 0xBBBBBBBBBBBBBBBB
    bne t1, t2, failS
    ecall
    j failS
failS:
    li t3, 0xF1
    slli t3, t3, 1
    ori t3, t3, 1
    li t1, TOHOST_ADDR
    sd t3, 0(t1)
    j failS

m_trap:
    csrr t0, mcause
    li t1, 9
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
