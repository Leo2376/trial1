/*
 * sv48_basic.S -- Sv48 translation (M setup, S test). 4-level tables:
 * root48@0x80017000 ([0]->L2b@0x80019000, [1]->L2c@0x8001A000),
 * L2c ([0]->L1c@0x8001B000), L1c ([0]->L0d@0x8001C000, [2]=2M leaf
 * ->PA 0x80000000), L2b ([2]->L1@0x80011000, [4]=1G leaf ->tohost),
 * L1 ([0]->L0a identity 0x80000-0x80021), L0a (identity, A=D=1),
 * L0d ([0]: VA 0x8000000000->PA 0x80020000 RW A=D=0,
 * [1]: VA 0x8000001000->PA 0x80021000 RX).
 * S checks: 4-level data remap + PA alias, fetch remap, 2M-page lw
 * (first insn word), PTE A/D, then ecall (M handler: cause 9).
 *
 * PASS: tohost = 1. FAIL: tohost = (id << 1) | 1, or (mcause << 1) | 1.
 *
 * Build & run (from repo root):
 *   riscv64-unknown-elf-gcc -march=rv64imafdc_zicsr_zifencei -mabi=lp64d \
 *     -nostdlib -nostartfiles -static \
 *     -T software/riscv-tests-env/rv64gch/link.ld \
 *     software/tests/sv48_basic.S -o /tmp/sv48_basic.elf
 *   python3 tools/scripts/elf2hex.py /tmp/sv48_basic.elf /tmp/sv48_basic.hex
 *   ./sim/verilator/obj_dir/Vtb_rv64gch_core +hex=/tmp/sv48_basic.hex
 */
#define TOHOST_ADDR 0x100000000
.section .text.init, "ax"
.globl _start
_start:
    li sp, 0x8000fffff8
    la t0, m_trap
    csrw mtvec, t0

    # root48[0] -> L2b, root48[1] -> L2c
    li t0, 0x80017000
    li t1, 0x20006401            # PPN 0x80019, V
    sd t1, 0(t0)
    li t1, 0x20006801            # PPN 0x8001A, V
    sd t1, 8(t0)
    # L2c[0] -> L1c (level-1 table: VPN1-indexed)
    li t0, 0x8001A000
    li t1, 0x20006C01            # PPN 0x8001B, V
    sd t1, 0(t0)
    # L2b[2] -> L1, L2b[4] 1G leaf -> tohost
    li t0, 0x80019000
    li t1, 0x20004401            # PPN 0x80011, V
    sd t1, 16(t0)               # index 2
    li t1, 0x400000C7          # PPN 0x100000, V|R|W|A|D
    sd t1, 32(t0)               # index 4
    # L1[0] -> L0a
    li t0, 0x80011000
    li t1, 0x20004801
    sd t1, 0(t0)
    # L1c[2] 2M leaf -> PA 0x80000000 (same L1c as the 4K remap path)
    li t0, 0x8001B000
    li t1, 0x200000C7          # PPN 0x80000, V|R|W|A|D
    sd t1, 16(t0)               # index 2
    # L0a: identity 34 pages, VRWX, A=D=1
    li t0, 0x80012000
    li t1, 0x200000CF
    li t2, 34
0:  sd t1, 0(t0)
    addi t1, t1, 0x400
    addi t0, t0, 8
    addi t2, t2, -1
    bnez t2, 0b
    # L1c[0] -> L0d (level-0 table: VPN0-indexed)
    li t0, 0x8001B000
    li t1, 0x20007001            # PPN 0x8001C, V
    sd t1, 0(t0)
    # L0d[0]: VA ..000000->PA 0x80020000, V|R|W, A=D=0
    li t0, 0x8001C000
    li t1, 0x20008007
    sd t1, 0(t0)
    # L0d[1]: VA ..001000->PA 0x80021000, V|R|X
    li t1, 0x2000840B
    sd t1, 8(t0)
    # copy func template to PA 0x80021000
    la t0, func_tpl
    ld t1, 0(t0)
    li t0, 0x80021000
    sd t1, 0(t0)
    fence.i

    # Sv48, PPN=root48
    li t0, 0x9000000000080017   # MODE=9, PPN=0x80017
    csrw satp, t0
    sfence.vma zero, zero
    li t0, (1 << 7) | (1 << 11)
    csrs mstatus, t0
    la t0, s_entry
    csrw mepc, t0
    mret

s_entry:                        # S-mode, Sv48 on
    # 4-level data remap: VA 0x8000000000 -> PA 0x80020000
    li t0, 0x8000000000
    li t1, 0xDEADBEEFCAFEBABE
    sd t1, 0(t0)
    ld t2, 0(t0)
    bne t1, t2, fail10
    # PA alias
    li t0, 0x80020000
    ld t2, 0(t0)
    bne t1, t2, fail12
    # fetch remap: VA 0x8000001000 (PA 0x80021000)
    li t0, 0x8000001000
    jalr ra, 0(t0)
    li t1, 0x5A5
    bne a0, t1, fail14
    # 2M page: VA 0x8000400000 -> PA 0x80000000 (lui sp insn)
    li t0, 0x8000400000
    lw t1, 0(t0)
    li t2, 0x00008137
    bne t1, t2, fail16
    # walker A/D on L0d[0] (PTE @0x8001C000)
    li t0, 0x8001C000
    ld t1, 0(t0)
    li t2, 0x200080C7
    bne t1, t2, fail18
    ecall
    j failFF

fail10: li t3, 10; j failS
fail12: li t3, 12; j failS
fail14: li t3, 14; j failS
fail16: li t3, 16; j failS
fail18: li t3, 18; j failS
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
m_trap:
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
