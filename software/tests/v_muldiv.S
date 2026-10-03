/*
 * v_muldiv.S -- RVV integer multiply/divide bring-up (OPMVV/OPMVX e8).
 *
 * Element-serial wide-path VALU (R+W sub-FSM, 2 cycles/element at e8);
 * RISC-V scalar divide semantics (div0 -> -1, overflow -> INT_MIN;
 * rem0 -> dividend, rem-overflow -> 0).
 *
 * M setup: HS identity tables (satp Sv39: root/L1/L0a identity + tohost
 * root[4] leaf). No traps are expected in S-mode (any M trap fails).
 *
 * Operands (vl=8 throughout):
 *   v4 = A = 7F 7F C8 80 40 FF 10 07
 *   v5 = B = 7F FF C8 80 40 FF 10 08
 *   v6/v7 = D/E (signed div pair), v8/v9 not used (divu pair in v4/v5
 *   reloaded: U/V).
 *
 * S phase 0 (config): vsetivli 8 -> rd==8.
 * S phases 1-4: vmul/mulh/mulhu/mulhsu of (A,B).
 * S phases 5-6: vdiv/vrem of (D,E) incl. div-by-zero (-1/dividend) and
 *   INT_MIN/-1 overflow (quot -128, rem 0).
 * S phases 7-8: vdivu/vremu of (U,V) incl. div-by-zero.
 * S phases 9-10: .vx spot checks (vadd.vx +7, vmul.vx *3).
 * S phase 11: masked vmul (mask 0F): low = products, high = AA sentinel.
 *
 * PASS: tohost = 1. FAIL: tohost = (id << 1) | 1, or (mcause << 1) | 1.
 *
 * Build & run (from repo root, CI toolchain):
 *   riscv64-unknown-elf-gcc -march=rv64imafdcv_zicsr_zifencei -mabi=lp64d \
 *     -nostdlib -nostartfiles -static \
 *     -T software/riscv-tests-env/rv64gch/link.ld \
 *     software/tests/v_muldiv.S -o /tmp/v_muldiv.elf
 *   python3 tools/scripts/elf2hex.py /tmp/v_muldiv.elf /tmp/v_muldiv.hex
 *   ./sim/verilator/obj_dir/Vtb_rv64gch_core +hex=/tmp/v_muldiv.hex
 */
#define TOHOST_ADDR 0x100000000
#define MUL_A       0x80023000
#define MUL_B       0x80023008
#define DIV_A       0x80023010
#define DIV_B       0x80023018
#define DIVU_A      0x80023020
#define DIVU_B      0x80023028
#define MSK0F       0x80023030
#define SENT_AA     0x80023038
#define DST         0x80023100
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

    # --- operands ---
    li t0, MUL_A
    li t1, 0x0710FF4080C87F7F
    sd t1, 0(t0)                 # A
    li t1, 0x0810FF4080C8FF7F
    sd t1, 8(t0)                 # B
    li t0, DIV_A
    li t1, 0x050007FF807F9C64
    sd t1, 0(t0)                 # D (signed)
    li t1, 0x03050000FFFF0703
    sd t1, 8(t0)                 # E (signed)
    li t0, DIVU_A
    li t1, 0x0905000780FFC864
    sd t1, 0(t0)                 # U (unsigned)
    li t1, 0x02030500FF000703
    sd t1, 8(t0)                 # V (unsigned)
    li t0, MSK0F
    li t1, 0x0F
    sd t1, 0(t0)                 # mask byte 0F
    li t1, 0xAAAAAAAAAAAAAAAA
    sd t1, 8(t0)                 # AA sentinel (8B)
    li t0, DST
    sd zero, 0(t0)
    sd zero, 8(t0)
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
    # --- phase 0: vl==8 ---
    vsetivli t1, 8, e8, m1, ta, ma
    li t2, 8
    bne t1, t2, failF0
    li t0, MUL_A
    vle8.v v4, (t0)
    li t0, MUL_B
    vle8.v v5, (t0)

    # --- phase 1: vmul.vv -> 3800010000408101 ---
    vmul.vv v2, v4, v5
    li t0, DST
    vse8.v v2, (t0)
    li t0, DST
    ld t1, 0(t0)
    li t2, 0x3800010000408101
    bne t1, t2, fail10

    # --- phase 2: vmulh.vv (signed) -> 00010010400CFF3F ---
    vmulh.vv v2, v4, v5
    li t0, DST
    vse8.v v2, (t0)
    li t0, DST
    ld t1, 0(t0)
    li t2, 0x00010010400CFF3F
    bne t1, t2, fail12

    # --- phase 3: vmulhu.vv (unsigned) -> 0001FE10409C7E3F ---
    vmulhu.vv v2, v4, v5
    li t0, DST
    vse8.v v2, (t0)
    li t0, DST
    ld t1, 0(t0)
    li t2, 0x0001FE10409C7E3F
    bne t1, t2, fail14

    # --- phase 4: vmulhsu.vv (signed x unsigned) -> 0001FF10C0D47E3F ---
    vmulhsu.vv v2, v4, v5
    li t0, DST
    vse8.v v2, (t0)
    li t0, DST
    ld t1, 0(t0)
    li t2, 0x0001FF10C0D47E3F
    bne t1, t2, fail16

    # --- div phases: D->v4, E->v5 ---
    li t0, DIV_A
    vle8.v v4, (t0)
    li t0, DIV_B
    vle8.v v5, (t0)

    # --- phase 5: vdiv.vv (div0->FF, ovf->80) -> 0100FFFF8081F221 ---
    vdiv.vv v2, v4, v5
    li t0, DST
    vse8.v v2, (t0)
    li t0, DST
    ld t1, 0(t0)
    li t2, 0x0100FFFF8081F221
    bne t1, t2, fail18

    # --- phase 6: vrem.vv (rem0->dividend, ovf->0) -> 020007FF0000FE01 ---
    vrem.vv v2, v4, v5
    li t0, DST
    vse8.v v2, (t0)
    li t0, DST
    ld t1, 0(t0)
    li t2, 0x020007FF0000FE01
    bne t1, t2, fail1A

    # --- divu phases: U->v4, V->v5 ---
    li t0, DIVU_A
    vle8.v v4, (t0)
    li t0, DIVU_B
    vle8.v v5, (t0)

    # --- phase 7: vdivu.vv -> 040100FF00FF1C21 ---
    vdivu.vv v2, v4, v5
    li t0, DST
    vse8.v v2, (t0)
    li t0, DST
    ld t1, 0(t0)
    li t2, 0x040100FF00FF1C21
    bne t1, t2, fail1C

    # --- phase 8: vremu.vv -> 0102000780FF0401 ---
    vremu.vv v2, v4, v5
    li t0, DST
    vse8.v v2, (t0)
    li t0, DST
    ld t1, 0(t0)
    li t2, 0x0102000780FF0401
    bne t1, t2, fail1E

    # --- .vx spot checks: A->v4 ---
    li t0, MUL_A
    vle8.v v4, (t0)

    # --- phase 9: vadd.vx v2,v4,7 -> 0E17064787CF8686 ---
    li t0, 7
    vadd.vx v2, v4, t0
    li t0, DST
    vse8.v v2, (t0)
    li t0, DST
    ld t1, 0(t0)
    li t2, 0x0E17064787CF8686
    bne t1, t2, fail20

    # --- phase 10: vmul.vx v2,v4,3 -> 1530FDC080587D7D ---
    li t0, 3
    vmul.vx v2, v4, t0
    li t0, DST
    vse8.v v2, (t0)
    li t0, DST
    ld t1, 0(t0)
    li t2, 0x1530FDC080587D7D
    bne t1, t2, fail22

    # --- phase 11: masked vmul (mask 0F, vd=AA) -> AAAAAAAA00408101 ---
    li t0, SENT_AA
    vle8.v v2, (t0)             # sentinel dest
    li t0, MSK0F
    vle8.v v0, (t0)             # mask
    li t0, MUL_B
    vle8.v v5, (t0)
    vmul.vv v2, v4, v5, v0.t
    li t0, DST
    vse8.v v2, (t0)
    li t0, DST
    ld t1, 0(t0)
    li t2, 0xAAAAAAAA00408101
    bne t1, t2, fail24

    li t0, TOHOST_ADDR
    li t1, 1
    sd t1, 0(t0)
    j .

failF0: li t3, 0xF0; j failT3
fail10: li t3, 0x10; j failT3
fail12: li t3, 0x12; j failT3
fail14: li t3, 0x14; j failT3
fail16: li t3, 0x16; j failT3
fail18: li t3, 0x18; j failT3
fail1A: li t3, 0x1A; j failT3
fail1C: li t3, 0x1C; j failT3
fail1E: li t3, 0x1E; j failT3
fail20: li t3, 0x20; j failT3
fail22: li t3, 0x22; j failT3
fail24: li t3, 0x24; j failT3
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
