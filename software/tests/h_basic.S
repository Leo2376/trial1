/*
 * h_basic.S -- H-extension bring-up (2-stage translation + virt traps/IRQ).
 *
 * M setup: HS identity tables (satp Sv39), G-stage tables (hgatp Sv39x4)
 * with GPA 0x80020000 -> HPA 0x80021000 remap, VS tables (vsatp Sv39) with
 * VA 0x80200000 -> GPA 0x80020000 plus identity code map and a
 * VA 0x80400000 -> GPA 0x90000000 G-fault probe. medeleg/mideleg cover the
 * VS-IRQ lines routed to HS.
 *
 * HS: CSR readback (hstatus/hedeleg/hideleg/hgatp/vsatp/hvip), hfence.vvma /
 * hfence.gvma execution, hvip[6] inject, then sret into VS (SPV=1, SPVP=S).
 *
 * VS: interrupt (VSTI, hideleg=0 -> HS, scause irq+6) -> HS clears hvip and
 * resumes; VS data remap load (VA->GPA->HPA remap, sentinel check);
 * VS ecall (hedeleg[10] -> VS, vscause==10) -> VS handler jumps to probe;
 * VS load of VA 0x80400000 -> G-stage fault (cause 21 -> HS) -> HS PASS.
 *
 * PASS: tohost = 1. FAIL: tohost = (id << 1) | 1, or (mcause << 1) | 1.
 *
 * Build & run (from repo root):
 *   riscv64-unknown-elf-gcc -march=rv64imafdc_h_zicsr_zifencei -mabi=lp64d \
 *     -nostdlib -nostartfiles -static \
 *     -T software/riscv-tests-env/rv64gch/link.ld \
 *     software/tests/h_basic.S -o /tmp/h_basic.elf
 *   python3 tools/scripts/elf2hex.py /tmp/h_basic.elf /tmp/h_basic.hex
 *   ./sim/verilator/obj_dir/Vtb_rv64gch_core +hex=/tmp/h_basic.hex
 */
#define TOHOST_ADDR 0x100000000
#define STATE_ADDR  0x80022000
#define SENT_HPA    0x80021000
#define ALIAS_HPA   0x80020000
#define GVA_DATA    0x80200000
#define GVA_PROBE   0x80400000
#define SENT_VAL    0x123456789ABCDEF0
.section .text.init, "ax"
.globl _start
_start:
    li sp, 0x8000fffff8
    la t0, m_trap_fail
    csrw mtvec, t0
    # VS-IRQ lines (VSSI/VSTI/VSEI = 2/6/10) routable to HS.
    li t0, (1 << 2) | (1 << 6) | (1 << 10)
    csrw mideleg, t0
    # Guest-page faults (20/21/23) fall through hedeleg to HS.
    li t0, (1 << 20) | (1 << 21) | (1 << 23)
    csrw medeleg, t0

    # --- HS identity tables: root@0x80010000, L1@0x80011000,
    # L0a@0x80012000 (identity 0x80000-0x80022, VRWX A=D=1),
    # root[64] 1G leaf -> tohost ---
    li t0, 0x80010000
    li t1, 0x20004401
    sd t1, 16(t0)
    li t1, 0x400000C7
    sd t1, 32(t0)
    li t0, 0x80011000
    li t1, 0x20004801
    sd t1, 0(t0)
    li t0, 0x80012000
    li t1, 0x200000CF
    li t2, 36
0:  sd t1, 0(t0)
    addi t1, t1, 0x400
    addi t0, t0, 8
    addi t2, t2, -1
    bnez t2, 0b

    # --- G-stage tables: groot@0x80014000, gL1@0x80015000, gL0@0x80016000
    # groot[2] -> gL1; groot[64] -> tohost 1G leaf; gL1[0] -> gL0;
    # gL0[i] identity except i=0x20 (GPA 0x80020000 -> HPA 0x80021000) ---
    li t0, 0x80014000
    li t1, 0x20005401            # PPN 0x80015 (gL1), V
    sd t1, 16(t0)               # index 2
    li t1, 0x400000CF
    sd t1, 32(t0)              # index 4: tohost (VPN2(0x100000000)=4)
    li t0, 0x80015000
    li t1, 0x20005801            # PPN 0x80016 (gL0), V
    sd t1, 0(t0)                # index 0
    li t0, 0x80016000
    li t1, 0x200000CF
    li t2, 36
1:  sd t1, 0(t0)
    addi t1, t1, 0x400
    addi t0, t0, 8
    addi t2, t2, -1
    bnez t2, 1b
    li t0, 0x80016000
    li t1, 0x200084CF            # PPN 0x80021 (HPA 0x80021000), VRWX A=D
    sd t1, 256(t0)              # index 0x20: the remap

    # --- VS tables (placed at GPA==HPA): vsroot@0x80017000,
    # vsL1@0x80018000, vsL0a@0x80019000 (identity 32 pgs), vsL0b@0x8001A000,
    # vsL0c@0x8001B000 (probe) ---
    li t0, 0x80017000
    li t1, 0x20006001            # PPN 0x80018 (vsL1), V
    sd t1, 16(t0)               # index 2
    li t1, 0x400000C7
    sd t1, 32(t0)              # index 4: tohost GPA leaf
    li t0, 0x80018000
    li t1, 0x20006401            # PPN 0x80019 (vsL0a), V
    sd t1, 0(t0)                # index 0
    li t1, 0x20006801            # PPN 0x8001A (vsL0b), V
    sd t1, 8(t0)                # index 1: VA 0x80200000
    li t1, 0x20006C01            # PPN 0x8001B (vsL0c), V
    sd t1, 16(t0)               # index 2: VA 0x80400000
    li t0, 0x80019000
    li t1, 0x200000CF
    li t2, 36
2:  sd t1, 0(t0)
    addi t1, t1, 0x400
    addi t0, t0, 8
    addi t2, t2, -1
    bnez t2, 2b
    li t0, 0x8001A000
    li t1, 0x20008007            # PPN 0x80020 (GPA 0x80020000), V|R|W A=D=0
    sd t1, 0(t0)
    li t0, 0x8001B000
    li t1, 0x24000007            # PPN 0x90000 (GPA 0x90000000), V|R|W
    sd t1, 0(t0)

    # --- data: sentinel at remap target, distinguisher at alias ---
    li t0, SENT_HPA
    li t1, SENT_VAL
    sd t1, 0(t0)
    li t0, ALIAS_HPA
    li t1, 0xDEADDEADDEADDEAD
    sd t1, 0(t0)
    li t0, STATE_ADDR
    sd zero, 0(t0)
    fence.i

    # --- enable HS (satp Sv39), enter HS via mret (MPP=S) ---
    li t0, 0x8000000000080010
    csrw satp, t0
    sfence.vma zero, zero
    li t0, (1 << 7) | (1 << 11)
    csrs mstatus, t0
    la t0, hs_entry
    csrw mepc, t0
    mret

hs_entry:                       # HS (V=0, priv=S)
    # CSR readback: hstatus
    li t0, 0xA5A5
    csrw hstatus, t0
    csrr t1, hstatus
    bne t0, t1, fail20
    csrw hstatus, zero
    # hedeleg / hideleg
    li t0, (1 << 10) | (1 << 12) | (1 << 13) | (1 << 15)
    csrw hedeleg, t0
    csrr t1, hedeleg
    bne t0, t1, fail22
    csrw hideleg, zero
    csrr t1, hideleg
    bnez t1, fail24
    # hgatp Sv39x4 (MODE=8) root 0x80014
    li t0, 0x8000000000080014
    csrw hgatp, t0
    csrr t1, hgatp
    bne t0, t1, fail26
    # vsatp Sv39 root 0x80017
    li t0, 0x8000000000080017
    csrw vsatp, t0
    csrr t1, vsatp
    bne t0, t1, fail28
    # wstvec / vstvec / hvip / vsie
    la t0, vs_trap
    csrw vstvec, t0
    csrr t1, vstvec
    bne t0, t1, fail2A
    la t0, hs_trap
    csrw stvec, t0
    li t0, (1 << 6)             # inject VS-timer interrupt
    csrw hvip, t0
    csrr t1, hvip
    andi t1, t1, (1 << 6)
    beqz t1, fail2C
    li t0, (1 << 6)
    csrw vsie, t0
    li t0, 2                    # SIE=1 so HS takes the routed IRQ
    csrs sie, t0
    # hfences execute (flush-all, no trap)
    hfence.vvma zero, zero
    hfence.gvma zero, zero
    # enter VS (SPV=1, SPVP=S), vsepc = vs_entry
    li t0, 0x180
    csrs hstatus, t0
    la t0, vs_entry
    csrw vsepc, t0
    sret

vs_entry:                       # VS guest (V=1, priv=S)
    # data remap: VA 0x80200000 -> GPA 0x80020000 -> HPA 0x80021000
    li t0, GVA_DATA
    ld t1, 0(t0)
    li t2, SENT_VAL
    bne t1, t2, fail40
vs_ecall_insn:
    ecall                       # -> VS handler (hedeleg[10])
    j failFF

vs_badload:                     # resumed by VS handler
    li t0, GVA_PROBE
    ld t1, 0(t0)                # G-fault (cause 21 -> HS) expected
    j failFF

# --- VS trap handler (delegated VS ecall) ---
vs_trap:
    csrr t0, vscause
    li t1, 10
    bne t0, t1, failVS
    csrr t0, vsepc
    la t1, vs_ecall_insn        # vsepc must equal the ecall insn VA
    bne t0, t1, failVS
    li t0, STATE_ADDR
    li t1, 2
    sd t1, 0(t0)
    la t0, vs_badload
    csrw vsepc, t0
    sret
failVS:
    li t3, 0xE1
    j failT3

# --- HS trap handler: VS-timer IRQ (resume) or G-fault (PASS) ---
hs_trap:
    csrr t0, scause
    bltz t0, hs_irq             # interrupt bit set
    li t1, 21
    bne t0, t1, failHS
    # load guest-page fault: must be in state 2 (post-ecall)
    li t0, STATE_ADDR
    ld t1, 0(t0)
    li t2, 2
    bne t1, t2, failHS
    li t0, TOHOST_ADDR
    li t1, 1
    sd t1, 0(t0)
    j .
hs_irq:
    # expect VSTI (cause 6 + int bit), state 0
    li t1, 6
    slli t2, t0, 1
    srli t2, t2, 1              # clear int bit
    bne t2, t1, failHS
    li t0, STATE_ADDR
    ld t1, 0(t0)
    bnez t1, failHS
    li t1, 1
    sd t1, 0(t0)
    csrw hvip, zero             # clear injection
    sret                        # SPV=1 -> back to guest
failHS:
    li t3, 0xE2
    j failT3

fail20: li t3, 0x20; j failT3
fail22: li t3, 0x22; j failT3
fail24: li t3, 0x24; j failT3
fail26: li t3, 0x26; j failT3
fail28: li t3, 0x28; j failT3
fail2A: li t3, 0x2A; j failT3
fail2C: li t3, 0x2C; j failT3
fail40: li t3, 0x40; j failT3
failFF: li t3, 0xFF; j failT3
failT3:
    slli t3, t3, 1
    ori t3, t3, 1
    li t1, TOHOST_ADDR
    sd t3, 0(t1)
    j failT3

.balign 4
m_trap_fail:
    csrr t0, mcause
    slli t0, t0, 1
    ori t0, t0, 1
    li t1, TOHOST_ADDR
    sd t0, 0(t1)
    j m_trap_fail
