/*
 * sv39_basic.S — Sv39 translation bring-up (M-mode setup, S-mode test).
 *
 * Tables: root@0x80010000, L1@0x80011000, L0a@0x80012000 (identity
 * 0x80000000-0x80021FFF incl. tables, VRWX, A=D=1), L0b@0x80013000
 * (VA 0x80200000->PA 0x80020000 RW, A=D=0; VA 0x80201000->PA 0x80021000
 * RX), root[4] 1G leaf for tohost MMIO (VA=PA 0x100000000).
 * S-mode checks: sd/ld through remap + PA alias, jalr to remapped code,
 * walker A/D bits set (PTE readback), then ecall (M handler: cause 9).
 *
 * PASS: tohost = 1. FAIL: tohost = (id << 1) | 1, or (mcause << 1) | 1.
 *
 * Build & run (from repo root):
 *   riscv64-unknown-elf-gcc -march=rv64imafdc_zicsr_zifencei -mabi=lp64d \
 *     -nostdlib -nostartfiles -static \
 *     -T software/riscv-tests-env/rv64gch/link.ld \
 *     software/tests/sv39_basic.S -o /tmp/sv39_basic.elf
 *   python3 tools/scripts/elf2hex.py /tmp/sv39_basic.elf /tmp/sv39_basic.hex
 *   ./sim/verilator/obj_dir/Vtb_rv64gch_core +hex=/tmp/sv39_basic.hex
 */
#define TOHOST_ADDR 0x100000000
.section .text.init, "ax"
.globl _start
_start:
    li sp, 0x8000fffff8
    la t0, m_trap
    csrw mtvec, t0

    # --- root[2] -> L1 (pointer V) ---
    li t0, 0x80010000
    li t1, 0x20004401            # PPN 0x80011, V
    sd t1, 16(t0)               # index 2
    # --- root[64]: 1G leaf -> tohost PA 0x100000000 ---
    li t1, 0x400000C7          # PPN 0x100000, V|R|W|A|D
    sd t1, 512(t0)              # index 64
    # --- L1[0] -> L0a, L1[1] -> L0b ---
    li t0, 0x80011000
    li t1, 0x20004801            # PPN 0x80012, V
    sd t1, 0(t0)
    li t1, 0x20004C01            # PPN 0x80013, V
    sd t1, 8(t0)
    # --- L0a: identity 34 pages (0x80000-0x80021), VRWX, A=D=1 ---
    # (covers code+tables and the PA-alias data pages 0x80020/0x80021)
    li t0, 0x80012000
    li t1, 0x200000CF
    li t2, 34
0:  sd t1, 0(t0)
    addi t1, t1, 0x400         # next PPN (<<10)
    addi t0, t0, 8
    addi t2, t2, -1
    bnez t2, 0b
    # --- L0b[0]: VA 0x80200000 -> PA 0x80020000, V|R|W, A=D=0 ---
    # --- L0b[1]: VA 0x80201000 -> PA 0x80021000, V|R|X ---
    # (VPN1=1, VPN0=0/1: 0x80200000>>21&511=1)
    li t0, 0x80013000
    li t1, 0x20008007
    sd t1, 0(t0)
    li t1, 0x2000840B
    sd t1, 8(t0)
    # --- copy func template to PA 0x80021000 ---
    la t0, func_tpl
    ld t1, 0(t0)
    li t0, 0x80021000
    sd t1, 0(t0)
    fence.i                     # L1I invalidate + L1D drain (copy visible)

    # --- enable Sv39, S-mode entry ---
    li t0, 0x8000000000080010   # MODE=8, PPN=0x80010
    csrw satp, t0
    sfence.vma zero, zero       # TLB flush + L1D drain (PTEs to L2)
    li t0, (1 << 7) | (1 << 11) # MPIE=1, MPP=S
    csrs mstatus, t0
    la t0, s_entry
    csrw mepc, t0
    mret

s_entry:                        # S-mode, translation ON
    # data remap: VA 0x80200000 -> PA 0x80020000
    li t0, 0x80200000
    li t1, 0xDEADBEEFCAFEBABE
    sd t1, 0(t0)
    ld t2, 0(t0)
    bne t1, t2, fail10
    # PA alias sees the same bytes
    li t0, 0x80020000
    ld t2, 0(t0)
    bne t1, t2, fail12
    # fetch remap: call VA 0x80201000 (PA 0x80021000)
    li t0, 0x80201000
    jalr ra, 0(t0)
    li t1, 0x5A5
    bne a0, t1, fail14
    # walker set A+D on L0b[0] (PTE @0x80013000)
    li t0, 0x80013000
    ld t1, 0(t0)
    li t2, 0x200080C7
    bne t1, t2, fail16
    ecall                       # M handler checks cause==9 -> PASS
    j failFF

fail10: li t3, 10; j failS
fail12: li t3, 12; j failS
fail14: li t3, 14; j failS
fail16: li t3, 16; j failS
failFF: li t3, 0xFF; j failS
failS:
    slli t3, t3, 1
    ori t3, t3, 1
    li t1, TOHOST_ADDR
    sd t3, 0(t1)
    j failS

func_tpl:
    addi a0, zero, 0x5A5
    jalr x0, 0(ra)

.balign 4
m_trap:                         # M-mode: expect S-ecall (cause 9)
    csrr t0, mcause
    li t1, 9
    bne t0, t1, failM
    li t0, TOHOST_ADDR
    li t1, 1
    sd t1, 0(t0)
    j .
failM:
    slli t0, t0, 1
    ori t0, t0, 1
    li t1, TOHOST_ADDR
    sd t0, 0(t1)
    j failM
