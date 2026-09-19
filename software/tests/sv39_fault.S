/*
 * sv39_fault.S — Sv39 protection/faults (M setup, S triggers, M checks).
 *
 * Five fault cases (load-unmapped 13, store-R-only 15, fetch-NX 12,
 * S-load-U-page 13, non-canonical load 13); the M-mode handler matches
 * (mcause, mtval) per case, resumes at the next case label via mepc, and
 * passes on the final ecall (cause 9, all 5 done). S code is norvc so the
 * data-fault resume is exact; fetch faults longjmp via the resume table.
 *
 * PASS: tohost = 1. FAIL: tohost = (mcause << 1) | 1 or fixed fail code.
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
    li t1, 0x4000000C7          # root[4] 1G leaf -> tohost (VPN2 of 2^32 = 4)
    sd t1, 32(t0)
    li t0, 0x80011000
    li t1, 0x20004801            # L1[0] -> L0a
    sd t1, 0(t0)
    li t1, 0x20004C01            # L1[1] -> L0b
    sd t1, 8(t0)
    # L0a: identity 40 pages, VRWX, A=D=1
    li t0, 0x80012000
    li t1, 0x200000CF
    li t2, 40
0:  sd t1, 0(t0)
    addi t1, t1, 0x400
    addi t0, t0, 8
    addi t2, t2, -1
    bnez t2, 0b
    # L0b entries (VA 0x80200+k*4K)
    li t0, 0x80013000
    li t1, 0x200080C7          # idx0: ->0x80020 V|R|W|A|D
    sd t1, 0(t0)
    li t1, 0x200088C3          # idx2: ->0x80022 V|R|A|D (no W)
    sd t1, 16(t0)
    # idx3: unmapped (stays 0)
    li t1, 0x200090C3          # idx4: ->0x80023 V|R|A|D (no X)
    sd t1, 32(t0)
    li t1, 0x200094D7          # idx5: ->0x80024 V|R|W|U|A|D
    sd t1, 40(t0)

    li t0, 0x8000000000080010
    csrw satp, t0
    sfence.vma zero, zero
    li t0, (1 << 7) | (1 << 11)
    csrs mstatus, t0
    la t0, s_entry
    csrw mepc, t0
    mret

.option norvc
s_entry:                        # S-mode
    # sanity: mapped RW page works
    li t0, 0x80200000
    li t1, 0xA5A5A5A5A5A5A5A5
    sd t1, 0(t0)
    ld t2, 0(t0)
    bne t1, t2, failS
c0: # case0: load from unmapped page -> 13
    li t0, 0x80203000
    ld t1, 0(t0)                # faults -> handler resumes next line
    nop
c1: # case1: store to R-only page -> 15
    li t0, 0x80202000
    sd t1, 0(t0)                # faults -> handler resumes next line
    nop
c2: # case2: fetch from NX page -> 12
    li t0, 0x80204000
    jalr ra, 0(t0)              # faults -> handler resumes next line
    nop
c3: # case3: U page, SUM=0 -> 13
    li t0, 0x80205000
    ld t1, 0(t0)                # faults -> handler resumes next line
    nop
c4: # case4: non-canonical VA -> 13
    li t0, 0x800000000000
    ld t1, 0(t0)                # faults -> handler resumes next line
    nop
c5: ecall                       # handler: cause 9 + 5 cases -> PASS
    j failS
failS:
    li t3, 0xF0
    slli t3, t3, 1
    ori t3, t3, 1
    li t1, TOHOST_ADDR
    sd t3, 0(t1)
    j failS
.option rvc

m_trap:
    csrr t0, mcause
    li t1, 9
    beq t0, t1, pass_check
    # fault case: match (cause, tval) against exp_tab[case_i]
    la t2, case_i
    ld t3, 0(t2)                # case index
    slli t4, t3, 4
    slli t5, t3, 3
    add t4, t4, t5              # t4 = case*24
    la t5, exp_tab
    add t5, t5, t4
    ld t4, 0(t5)                # expected cause
    bne t0, t4, failM
    csrr t0, mtval
    ld t4, 8(t5)                # expected tval
    bne t0, t4, failM
    ld t0, 16(t5)               # resume pc for this case
    csrw mepc, t0
    addi t3, t3, 1
    la t2, case_i
    sd t3, 0(t2)
    mret
pass_check:
    la t2, case_i
    ld t3, 0(t2)
    li t4, 5
    bne t3, t4, failM
    li t0, TOHOST_ADDR
    li t1, 1
    sd t1, 0(t0)
    j .
failM:
    # t0 holds mcause (or garbage); report (mcause<<1)|1
    csrr t0, mcause
    slli t0, t0, 1
    ori t0, t0, 1
    li t1, TOHOST_ADDR
    sd t0, 0(t1)
    j failM

.section .data
.align 3
case_i:  .dword 0
exp_tab:                        # (cause, tval, resume) x5
    .dword 13, 0x80203000, c1
    .dword 15, 0x80202000, c2
    .dword 12, 0x80204000, c3
    .dword 13, 0x80205000, c4
    .dword 13, 0x800000000000, c5
