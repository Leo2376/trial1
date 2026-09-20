/*
 * priv_ecall.S -- ecall/ebreak/illegal causes per privilege (M driver).
 *
 * M sets identity+tohost tables plus a U-RX page holding one ecall, then
 * drives 5 cases by mret'ing with (MPP, mepc): U-ecall (8), S-ecall (9),
 * M-ecall (11), S-ebreak (3), M-illegal (2). The M handler matches
 * (cause, epc), advances, and returns to M with the next case.
 *
 * PASS: tohost = 1. FAIL: tohost = (mcause << 1) | 1.
 *
 * Build & run (from repo root):
 *   riscv64-unknown-elf-gcc -march=rv64imafdc_zicsr_zifencei -mabi=lp64d \
 *     -nostdlib -nostartfiles -static \
 *     -T software/riscv-tests-env/rv64gch/link.ld \
 *     software/tests/priv_ecall.S -o /tmp/priv_ecall.elf
 *   python3 tools/scripts/elf2hex.py /tmp/priv_ecall.elf /tmp/priv_ecall.hex
 *   ./sim/verilator/obj_dir/Vtb_rv64gch_core +hex=/tmp/priv_ecall.hex
 */
#define TOHOST_ADDR 0x100000000
.section .text.init, "ax"
.globl _start
_start:
    li sp, 0x8000fffff8
    la t0, m_trap
    csrw mtvec, t0
    # tables: root/L1/L0a identity + tohost leaf + L0b U-RX page
    li t0, 0x80010000
    li t1, 0x20004401
    sd t1, 16(t0)               # root[2] -> L1
    li t1, 0x400000C7
    sd t1, 32(t0)               # root[4] 1G leaf -> tohost
    li t0, 0x80011000
    li t1, 0x20004801
    sd t1, 0(t0)                # L1[0] -> L0a
    li t1, 0x20004C01
    sd t1, 8(t0)                # L1[1] -> L0b
    li t0, 0x80012000
    li t1, 0x200000CF
    li t2, 40
0:  sd t1, 0(t0)
    addi t1, t1, 0x400
    addi t0, t0, 8
    addi t2, t2, -1
    bnez t2, 0b
    li t0, 0x80013000
    li t1, 0x200080DB          # L0b[0]: ->0x80020 U|V|R|X|A|D (no W)
    sd t1, 0(t0)
    # U page holds a single ecall (PA 0x80020000)
    li t0, 0x80020000
    li t1, 0x00000073
    sd t1, 0(t0)
    fence.i
    li t0, 0x8000000000080010
    csrw satp, t0
    sfence.vma zero, zero
    j driver

# driver cases: (MPP, mepc)
driver:
    # case0: U ecall
    li t0, 0x80200000
    li t1, 0
    csrw mstatus, t1            # clear MPP->U (MPP=0), MPIE irrelevant
    csrw mepc, t0
    mret
case1_S:
    ecall
    j failS
case2_M:
    ecall
    j failS
case3_S:
    ebreak
    j failS
case4_M:
    .word 0                     # illegal
    j failS
failS:
    li t3, 0xF5
    slli t3, t3, 1
    ori t3, t3, 1
    li t1, TOHOST_ADDR
    sd t3, 0(t1)
    j failS

# exp_tab: (cause, epc, next_mpp, next_mepc)
# next_mepc ignored on last case (PASS instead).
m_trap:
    csrr t0, mcause
    la t2, case_i
    ld t3, 0(t2)
    slli t4, t3, 5              # 32B/entry
    la t5, exp_tab
    add t5, t5, t4
    ld t4, 0(t5)
    bne t0, t4, failM           # cause
    csrr t0, mepc
    ld t4, 8(t5)
    bne t0, t4, failM           # epc
    addi t3, t3, 1
    sd t3, 0(t2)
    li t4, 5
    beq t3, t4, passNow
    ld t0, 16(t5)               # next_mpp
    li t1, (3 << 11)
    csrc mstatus, t1            # clear MPP
    csrs mstatus, t0            # set next MPP (already shifted)
    ld t0, 24(t5)               # next_mepc
    csrw mepc, t0
    mret
passNow:
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

.section .data
.align 3
case_i:  .dword 0
exp_tab:                        # (cause, epc, next_mpp, next_mepc)
    .dword 8,  0x80200000, (1 << 11), case1_S
    .dword 9,  case1_S,    (3 << 11), case2_M
    .dword 11, case2_M,    (1 << 11), case3_S
    .dword 3,  case3_S,    (3 << 11), case4_M
    .dword 2,  case4_M,    0, 0
