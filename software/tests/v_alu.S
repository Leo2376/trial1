/*
 * v_alu.S -- RVV integer ALU bring-up (OPIVV e8 + vmv.v.v via VALU).
 *
 * Element-serial VALU occupies MEM (backend holds, like the VLSU);
 * vd[i] = vs2[i] op vs1[i], 8-bit wrap, masked (vm=0, v0) and unmasked.
 *
 * M setup: HS identity tables (satp Sv39: root/L1/L0a identity + tohost
 * root[4] leaf). No traps are expected in S-mode (any M trap fails).
 *
 * S phase 0 (config): vsetvli e8m1ta_ma -> vl==32; then vsetivli 8.
 *   v0 = pattern (BASE1), v1 = 8xAA, v4 = 8xFF, v5 = 8x01, v6 = zeros.
 * S phase 1 (sub-self): vsub.vv v2,v0,v0 -> vse8 -> all zero.
 * S phase 2 (and-zero): vand.vv v2,v0,v6 -> all zero.
 * S phase 3 (or-ones): vor.vv v2,v0,v4 -> all 0xFF.
 * S phase 4 (xor-self): vxor.vv v2,v0,v0 -> all zero.
 * S phase 5 (xor round-trip): vxor.vv v2,v0,v1; vxor.vv v3,v2,v1 -> v3==v0.
 * S phase 6 (add wrap): v0=FF, v1=01; vadd.vv v2,v0,v1 -> all zero.
 * S phase 7 (vmv): v0=pattern; vmv.v.v v3,v0 -> v3==v0.
 * S phase 8 (masked add): mask=0x55; v2=AA sentinel; v0=pattern; v1=01;
 *   vadd.vv v2,v0,v1,v0.t -> even=P+1 (wrap), odd=AA undisturbed.
 *
 * PASS: tohost = 1. FAIL: tohost = (id << 1) | 1, or (mcause << 1) | 1.
 *
 * Build & run (from repo root):
 *   riscv64-unknown-elf-gcc -march=rv64imafdcv_zicsr_zifencei -mabi=lp64d \
 *     -nostdlib -nostartfiles -static \
 *     -T software/riscv-tests-env/rv64gch/link.ld \
 *     software/tests/v_alu.S -o /tmp/v_alu.elf
 *   python3 tools/scripts/elf2hex.py /tmp/v_alu.elf /tmp/v_alu.hex
 *   ./sim/verilator/obj_dir/Vtb_rv64gch_core +hex=/tmp/v_alu.hex
 */
#define TOHOST_ADDR 0x100000000
#define BASE1       0x80023000
#define BASE2       0x80023100
#define SENT_AA     0x80023020
#define SENT_FF     0x80023028
#define SENT_01     0x80023030
#define SCRATCH     0x80023200
.section .text.init, "ax"
.globl _start
_start:
    li sp, 0x8000fffff8
    la t0, m_trap
    csrw mtvec, t0

    # --- HS identity tables ---
    li t0, 0x80010000
    li t1, 0x20004401            # root[2] -> L1
    sd t1, 16(t0)
    li t1, 0x400000C7            # root[4] 1G leaf -> tohost (VPN2=4)
    sd t1, 32(t0)
    li t0, 0x80011000
    li t1, 0x20004801            # L1[0] -> L0a (identity)
    sd t1, 0(t0)
    li t0, 0x80012000
    li t1, 0x200000CF
    li t2, 36
0:  sd t1, 0(t0)
    addi t1, t1, 0x400
    addi t0, t0, 8
    addi t2, t2, -1
    bnez t2, 0b

    # --- pattern, sentinels, zero area ---
    li t0, BASE1
    li t1, 0x0123456789ABCDEF
    sd t1, 0(t0)
    li t1, 0xFEDCBA9876543210
    sd t1, 8(t0)
    li t1, 0xAAAAAAAAAAAAAAAA
    sd t1, 16(t0)
    li t1, 0x5555555555555555
    sd t1, 24(t0)
    li t0, SENT_AA
    li t1, 0xAAAAAAAAAAAAAAAA
    sd t1, 0(t0)
    li t0, SENT_FF
    li t1, -1
    sd t1, 0(t0)
    li t0, SENT_01
    li t1, 0x0101010101010101
    sd t1, 0(t0)
    li t0, BASE2
    sd zero, 0(t0)
    sd zero, 8(t0)
    sd zero, 16(t0)
    sd zero, 24(t0)
    fence.i

    li t0, 0x8000000000080010   # satp Sv39
    csrw satp, t0
    sfence.vma zero, zero
    li t0, (1 << 7) | (1 << 11) # MPIE=1, MPP=S
    csrs mstatus, t0
    la t0, s_entry
    csrw mepc, t0
    mret

s_entry:                        # S-mode, translation ON
    # --- phase 0: vl==32, then vl=8 + operand load ---
    vsetvli t0, zero, e8, m1, ta, ma
    li t1, 32
    bne t0, t1, failF0
    vsetivli zero, 8, e8, m1, ta, ma
    li t0, BASE1
    vle8.v v0, (t0)
    li t0, SENT_AA
    vle8.v v1, (t0)
    li t0, SENT_FF
    vle8.v v4, (t0)
    li t0, SENT_01
    vle8.v v5, (t0)
    li t0, BASE2
    vle8.v v6, (t0)             # zeros

    # --- phase 1: vsub.vv v2,v0,v0 -> zero ---
    vsub.vv v2, v0, v0
    li t0, BASE2 + 8
    vse8.v v2, (t0)
    li t0, BASE2 + 8
    ld t1, 0(t0)
    bnez t1, failF2

    # --- phase 2: vand.vv v2,v0,v6(zero) -> zero ---
    vand.vv v2, v0, v6
    li t0, BASE2 + 8
    vse8.v v2, (t0)
    li t0, BASE2 + 8
    ld t1, 0(t0)
    bnez t1, failF4

    # --- phase 3: vor.vv v2,v0,v4(FF) -> 0xFF ---
    vor.vv v2, v0, v4
    li t0, BASE2 + 8
    vse8.v v2, (t0)
    li t0, BASE2 + 8
    ld t1, 0(t0)
    li t2, -1
    bne t1, t2, failF6

    # --- phase 4: vxor.vv v2,v0,v0 -> zero ---
    vxor.vv v2, v0, v0
    li t0, BASE2 + 8
    vse8.v v2, (t0)
    li t0, BASE2 + 8
    ld t1, 0(t0)
    bnez t1, failF8

    # --- phase 5: vxor round-trip v3=(v0^AA)^AA==v0 ---
    vxor.vv v2, v0, v1
    vxor.vv v3, v2, v1
    li t0, BASE2 + 8
    vse8.v v3, (t0)
    li t0, BASE1
    li t1, BASE2 + 8
    ld t2, 0(t0)
    ld t3, 0(t1)
    bne t2, t3, failFA

    # --- phase 6: vadd wrap 0xFF+0x01 -> zero ---
    li t0, SENT_FF
    vle8.v v0, (t0)
    li t0, SENT_01
    vle8.v v1, (t0)
    vadd.vv v2, v0, v1
    li t0, BASE2 + 8
    vse8.v v2, (t0)
    li t0, BASE2 + 8
    ld t1, 0(t0)
    bnez t1, failFC

    # --- phase 7: vmv.v.v copy ---
    li t0, BASE1
    vle8.v v0, (t0)
    vmv.v.v v3, v0
    li t0, BASE2 + 8
    vse8.v v3, (t0)
    li t0, BASE1
    li t1, BASE2 + 8
    ld t2, 0(t0)
    ld t3, 0(t1)
    bne t2, t3, failFE

    # --- phase 8: masked vadd (mask=0x55): even=P+1, odd=AA ---
    # v0 holds the mask after this; operands live in v4 (pattern) and
    # v5 (0x01, loaded in phase 0 and never overwritten).
    li t0, SCRATCH
    li t1, 0x55
    sb t1, 0(t0)
    vle8.v v0, (t0)             # mask: even elements active
    li t0, SENT_AA
    vle8.v v2, (t0)             # sentinel dest
    li t0, BASE1
    vle8.v v4, (t0)             # pattern operand
    vadd.vv v2, v4, v5, v0.t    # even=P+1 (wrap), odd=AA undisturbed
    li t0, BASE2 + 16
    vse8.v v2, (t0)
    li t0, BASE1
    li t1, BASE2 + 16
    lbu t2, 0(t0)
    addi t2, t2, 1
    andi t2, t2, 0xFF
    lbu t3, 0(t1)
    bne t2, t3, failA0
    lb t3, 1(t1)
    li t4, -86
    bne t3, t4, failA2
    lbu t2, 2(t0)
    addi t2, t2, 1
    andi t2, t2, 0xFF
    lbu t3, 2(t1)
    bne t2, t3, failA4
    lb t3, 3(t1)
    bne t3, t4, failA6
    lbu t2, 4(t0)
    addi t2, t2, 1
    andi t2, t2, 0xFF
    lbu t3, 4(t1)
    bne t2, t3, failA8
    lb t3, 5(t1)
    bne t3, t4, failAA
    lbu t2, 6(t0)
    addi t2, t2, 1
    andi t2, t2, 0xFF
    lbu t3, 6(t1)
    bne t2, t3, failAC
    lb t3, 7(t1)
    bne t3, t4, failAE

    li t0, TOHOST_ADDR
    li t1, 1
    sd t1, 0(t0)
    j .

failF0: li t3, 0xF0; j failT3
failF2: li t3, 0xF2; j failT3
failF4: li t3, 0xF4; j failT3
failF6: li t3, 0xF6; j failT3
failF8: li t3, 0xF8; j failT3
failFA: li t3, 0xFA; j failT3
failFC: li t3, 0xFC; j failT3
failFE: li t3, 0xFE; j failT3
failA0: li t3, 0xA0; j failT3
failA2: li t3, 0xA2; j failT3
failA4: li t3, 0xA4; j failT3
failA6: li t3, 0xA6; j failT3
failA8: li t3, 0xA8; j failT3
failAA: li t3, 0xAA; j failT3
failAC: li t3, 0xAC; j failT3
failAE: li t3, 0xAE; j failT3
failT3:
    slli t3, t3, 1
    ori t3, t3, 1
    li t1, TOHOST_ADDR
    sd t3, 0(t1)
    j failT3

.balign 4
m_trap:                         # no trap expected in this test
    csrr t0, mcause
    slli t0, t0, 1
    ori t0, t0, 1
    li t1, TOHOST_ADDR
    sd t0, 0(t1)
    j m_trap
