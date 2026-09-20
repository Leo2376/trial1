/*
 * deleg_basic.S -- trap delegation + S-mode trap handling + sret.
 *
 * M setup: identity tables, medeleg[9]=1 (S-ecall), stvec = s_trap.
 * S: ecall -> S-trap (sepc/scause/SPP) -> handler verifies, srets back ->
 * ecall again -> handler PASS. Any M-trap or mismatch -> FAIL.
 *
 * PASS: tohost = 1. FAIL: tohost = fixed fail code or (mcause << 1) | 1.
 *
 * Build & run (from repo root):
 *   riscv64-unknown-elf-gcc -march=rv64imafdc_zicsr_zifencei -mabi=lp64d \
 *     -nostdlib -nostartfiles -static \
 *     -T software/riscv-tests-env/rv64gch/link.ld \
 *     software/tests/deleg_basic.S -o /tmp/deleg_basic.elf
 *   python3 tools/scripts/elf2hex.py /tmp/deleg_basic.elf /tmp/deleg_basic.hex
 *   ./sim/verilator/obj_dir/Vtb_rv64gch_core +hex=/tmp/deleg_basic.hex
 */
#define TOHOST_ADDR 0x100000000
.section .text.init, "ax"
.globl _start
_start:
    li sp, 0x8000fffff8
    la t0, m_trap_fail
    csrw mtvec, t0
    la t0, s_trap
    csrw stvec, t0
    li t0, (1 << 9)             # medeleg[S-ecall]
    csrw medeleg, t0

    li t0, 0x80010000
    li t1, 0x20004401            # root[2] -> L1
    sd t1, 16(t0)
    li t1, 0x400000C7          # root[4] 1G leaf -> tohost
    sd t1, 32(t0)
    li t0, 0x80011000
    li t1, 0x20004801            # L1[0] -> L0a
    sd t1, 0(t0)
    li t0, 0x80012000
    li t1, 0x200000CF
    li t2, 40
0:  sd t1, 0(t0)
    addi t1, t1, 0x400
    addi t0, t0, 8
    addi t2, t2, -1
    bnez t2, 0b

    li t0, 0x8000000000080010
    csrw satp, t0
    sfence.vma zero, zero
    li t0, (1 << 7) | (1 << 11)
    csrs mstatus, t0
    la t0, s_entry
    csrw mepc, t0
    mret

s_entry:                        # S-mode, s0 = state (0 first)
    ecall                       # -> S-trap (delegated), s0==0 path
resume1:
    ecall                       # -> S-trap, s0==1 path -> PASS
    j failS

failS:
    li t3, 0xF2
    slli t3, t3, 1
    ori t3, t3, 1
    li t1, TOHOST_ADDR
    sd t3, 0(t1)
    j failS

# S-mode trap handler. Uses t0-t2 (s0 preserved as state).
s_trap:
    csrr t0, scause
    li t1, 9
    bne t0, t1, failS2
    bnez s0, second
    # first entry: sepc == ecall VA, SPP == S
    csrr t0, sepc
    la t1, s_entry
    bne t0, t1, failS2
    csrr t0, sstatus
    andi t0, t0, 0x100         # SPP bit 8
    beqz t0, failS2
    li s0, 1
    la t0, resume1
    csrw sepc, t0
    sret
second:
    # sepc == second ecall, SPP == S; PASS (s0==1 already)
    csrr t0, sepc
    la t1, resume1              # second ecall itself
    bne t0, t1, failS2
    li t0, TOHOST_ADDR
    li t1, 1
    sd t1, 0(t0)
    j .
failS2:
    li t3, 0xF3
    slli t3, t3, 1
    ori t3, t3, 1
    li t1, TOHOST_ADDR
    sd t3, 0(t1)
    j failS2

.balign 4
m_trap_fail:                    # must never fire (ecall delegated)
    csrr t0, mcause
    slli t0, t0, 1
    ori t0, t0, 1
    li t1, TOHOST_ADDR
    sd t0, 0(t1)
    j m_trap_fail
