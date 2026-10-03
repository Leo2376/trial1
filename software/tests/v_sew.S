/*
 * v_sew.S -- RVV SEW=16/32/64 bring-up (vsetvli VLMAX, EEW ld/st, wide ALU).
 *
 * VLSU byte-serial (element,byte) sequencing; VALU wide-path R+W sub-FSM.
 * vl/vstart are element counts; VLMAX = 32/16/8/4.
 *
 * M setup: HS identity tables (satp Sv39: root/L1/L0a identity + tohost
 * root[4] leaf). Traps: only the deliberate EEW-mismatch illegal-insn is
 * expected (phase 15); anything else fails.
 *
 * S phase 0 (e16 config): vsetvli e16 -> vl==16; AVL-reg form (rs1=5)
 *   -> vl==5; restore 16.
 * S phase 1: vle16/vse16 round trip (32B, 4 dwords).
 * S phase 2: vadd16.
 * S phase 3: vmul16 (low half).
 * S phase 4: vminu16.
 * S phase 5: vmseq16 (A vs A) -> dword0==0xFFFF, dword1==0.
 * S phase 6: masked vadd16 (mask 03, vd=AA) -> 0xAAAAAAAA01000003, AA*.
 * S phase 7 (e32 config): vsetvli e32 -> vl==8.
 * S phase 8: vle32/vse32 round trip.
 * S phase 9: vadd32.
 * S phase 10: vmul32 (low word).
 * S phase 11: vdiv32 (incl. div0 -> FFFFFFFF, ovf -> 80000000).
 * S phase 12: vmseq32 -> dword0==0xFF, dword1==0.
 * S phase 13: masked vadd32 (mask 01, vd=0) -> dword0==3, dword1==0.
 * S phase 14 (e64 config + ops): vsetvli e64 -> vl==4; round trip;
 *   vadd64; vmul64; vdiv64 (incl. ovf); vmseq64 -> dword0==0x0F.
 * S phase 15 (illegal): e8 mode + vle16.v -> illegal-insn trap (mcause 2);
 *   M handler checks STATE==1, bumps mepc and sets STATE=2; S checks 2.
 *
 * PASS: tohost = 1. FAIL: tohost = (id << 1) | 1, or (mcause << 1) | 1.
 *
 * Build & run (from repo root, CI toolchain):
 *   riscv64-unknown-elf-gcc -march=rv64imafdcv_zicsr_zifencei -mabi=lp64d \
 *     -nostdlib -nostartfiles -static \
 *     -T software/riscv-tests-env/rv64gch/link.ld \
 *     software/tests/v_sew.S -o /tmp/v_sew.elf
 *   python3 tools/scripts/elf2hex.py /tmp/v_sew.elf /tmp/v_sew.hex
 *   ./sim/verilator/obj_dir/Vtb_rv64gch_core +hex=/tmp/v_sew.hex
 */
#define TOHOST_ADDR 0x100000000
#define W16A        0x80023000
#define W16B        0x80023020
#define W32A        0x80023040
#define W32B        0x80023060
#define W64A        0x80023080
#define W64B        0x800230A0
#define MSK03       0x800230C0
#define MSK01       0x800230C8
#define SENT_AA     0x800230D0
#define ZERO32      0x800230F0
#define STATE       0x80023200
#define DST         0x80023120
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

    # --- e16 operands (4 dwords each) ---
    li t0, W16A
    li t1, 0x80007FFF00FF0001
    sd t1, 0(t0)
    li t1, 0x0000ABCD1234FFFF
    sd t1, 8(t0)
    li t1, 0x0190012C00C80064
    sd t1, 16(t0)
    li t1, 0x032002BC025801F4
    sd t1, 24(t0)
    li t0, W16B
    li t1, 0x0001000100010002
    sd t1, 0(t0)
    li t1, 0x0005000100010001
    sd t1, 8(t0)
    li t1, 0x0009000000070003
    sd t1, 16(t0)
    li t1, 0x0006000400000002
    sd t1, 24(t0)
    # --- e32 operands ---
    li t0, W32A
    li t1, 0x7FFFFFFF00000001
    sd t1, 0(t0)
    li t1, 0xFFFFFFFF80000000
    sd t1, 8(t0)
    li t1, 0x0000000012345678
    sd t1, 16(t0)
    li t1, 0xFFFFFFFF000186A0
    sd t1, 24(t0)
    li t0, W32B
    li t1, 0x0000000100000002
    sd t1, 0(t0)
    li t1, 0x0000000000000001
    sd t1, 8(t0)
    li t1, 0x0000000500000001
    sd t1, 16(t0)
    li t1, 0x0000000700000003
    sd t1, 24(t0)
    # --- e64 operands ---
    li t0, W64A
    li t1, 1
    sd t1, 0(t0)
    li t1, 0x7FFFFFFFFFFFFFFF
    sd t1, 8(t0)
    li t1, 0x8000000000000000
    sd t1, 16(t0)
    li t1, -1
    sd t1, 24(t0)
    li t0, W64B
    li t1, 2
    sd t1, 0(t0)
    li t1, 1
    sd t1, 8(t0)
    sd t1, 24(t0)
    li t1, -1
    sd t1, 16(t0)
    # --- masks, sentinels, state ---
    li t0, MSK03
    li t1, 0x03
    sd t1, 0(t0)
    li t1, 0x01
    sd t1, 8(t0)
    li t0, SENT_AA
    li t1, 0xAAAAAAAAAAAAAAAA
    sd t1, 0(t0)
    sd t1, 8(t0)
    sd t1, 16(t0)
    sd t1, 24(t0)
    li t0, ZERO32
    sd zero, 0(t0)
    sd zero, 8(t0)
    sd zero, 16(t0)
    sd zero, 24(t0)
    li t0, STATE
    sd zero, 0(t0)
    li t0, DST
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
    # --- phase 0: e16 config (vl==16), AVL-reg form (5), restore ---
    vsetvli t1, zero, e16, m1, ta, ma
    li t2, 16
    bne t1, t2, failF0
    li t0, 5
    vsetvli t1, t0, e16, m1, ta, ma
    li t2, 5
    bne t1, t2, failF0
    vsetvli zero, zero, e16, m1, ta, ma
    csrr t1, vl
    li t2, 16
    bne t1, t2, failF0
    # A->v4, B->v5 (32B each)
    li t0, W16A
    vle16.v v4, (t0)
    li t0, W16B
    vle16.v v5, (t0)

    # --- phase 1: round trip (4 dwords) ---
    li t0, DST
    vse16.v v4, (t0)
    li t0, W16A
    li t1, DST
    ld t2, 0(t0)
    ld t3, 0(t1)
    bne t2, t3, fail10
    ld t2, 8(t0)
    ld t3, 8(t1)
    bne t2, t3, fail10
    ld t2, 16(t0)
    ld t3, 16(t1)
    bne t2, t3, fail10
    ld t2, 24(t0)
    ld t3, 24(t1)
    bne t2, t3, fail10

    # --- phase 2: vadd16 ---
    vadd.vv v2, v4, v5
    li t0, DST
    vse16.v v2, (t0)
    li t0, DST
    ld t1, 0(t0)
    li t2, 0x8001800001000003
    bne t1, t2, fail12
    ld t1, 8(t0)
    li t2, 0x0005ABCE12350000
    bne t1, t2, fail12
    ld t1, 16(t0)
    li t2, 0x0199012C00CF0067
    bne t1, t2, fail12
    ld t1, 24(t0)
    li t2, 0x032602C0025801F6
    bne t1, t2, fail12

    # --- phase 3: vmul16 (low) ---
    vmul.vv v2, v4, v5
    li t0, DST
    vse16.v v2, (t0)
    li t0, DST
    ld t1, 0(t0)
    li t2, 0x80007FFF00FF0002
    bne t1, t2, fail14
    ld t1, 8(t0)
    li t2, 0x0000ABCD1234FFFF
    bne t1, t2, fail14
    ld t1, 16(t0)
    li t2, 0x0E1000000578012C
    bne t1, t2, fail14
    ld t1, 24(t0)
    li t2, 0x12C00AF0000003E8
    bne t1, t2, fail14

    # --- phase 4: vminu16 ---
    vminu.vv v2, v4, v5
    li t0, DST
    vse16.v v2, (t0)
    li t0, DST
    ld t1, 0(t0)
    li t2, 0x0001000100010001
    bne t1, t2, fail16
    ld t1, 8(t0)
    li t2, 0x0000000100010001
    bne t1, t2, fail16
    ld t1, 16(t0)
    li t2, 0x0009000000070003
    bne t1, t2, fail16
    ld t1, 24(t0)
    li t2, 0x0006000400000002
    bne t1, t2, fail16

    # --- phase 5: vmseq16 (A vs A) -> dword0 FFFF, dword1 0 ---
    li t0, ZERO32
    vle16.v v6, (t0)
    vmseq.vv v6, v4, v4
    li t0, DST
    vse16.v v6, (t0)
    li t0, DST
    ld t1, 0(t0)
    li t2, 0xFFFF
    bne t1, t2, fail18
    ld t1, 8(t0)
    bnez t1, fail18

    # --- phase 6: masked vadd16 (mask 03, vd=AA) ---
    li t0, SENT_AA
    vle16.v v2, (t0)
    li t0, MSK03
    vle16.v v0, (t0)             # mask byte 03
    vadd.vv v2, v4, v5, v0.t
    li t0, DST
    vse16.v v2, (t0)
    li t0, DST
    ld t1, 0(t0)
    li t2, 0xAAAAAAAA01000003
    bne t1, t2, fail1A
    ld t1, 8(t0)
    li t2, 0xAAAAAAAAAAAAAAAA
    bne t1, t2, fail1A

    # --- phase 7: e32 config (vl==8), A->v4, B->v5 ---
    vsetvli t1, zero, e32, m1, ta, ma
    li t2, 8
    bne t1, t2, fail1C
    li t0, W32A
    vle32.v v4, (t0)
    li t0, W32B
    vle32.v v5, (t0)

    # --- phase 8: round trip ---
    li t0, DST
    vse32.v v4, (t0)
    li t0, W32A
    li t1, DST
    ld t2, 0(t0)
    ld t3, 0(t1)
    bne t2, t3, fail1E
    ld t2, 8(t0)
    ld t3, 8(t1)
    bne t2, t3, fail1E
    ld t2, 16(t0)
    ld t3, 16(t1)
    bne t2, t3, fail1E
    ld t2, 24(t0)
    ld t3, 24(t1)
    bne t2, t3, fail1E

    # --- phase 9: vadd32 ---
    vadd.vv v2, v4, v5
    li t0, DST
    vse32.v v2, (t0)
    li t0, DST
    ld t1, 0(t0)
    li t2, 0x8000000000000003
    bne t1, t2, fail20
    ld t1, 8(t0)
    li t2, 0xFFFFFFFF80000001
    bne t1, t2, fail20
    ld t1, 16(t0)
    li t2, 0x0000000512345679
    bne t1, t2, fail20
    ld t1, 24(t0)
    li t2, 0x00000006000186A3
    bne t1, t2, fail20

    # --- phase 10: vmul32 (low) ---
    vmul.vv v2, v4, v5
    li t0, DST
    vse32.v v2, (t0)
    li t0, DST
    ld t1, 0(t0)
    li t2, 0x7FFFFFFF00000002
    bne t1, t2, fail22
    ld t1, 8(t0)
    li t2, 0x0000000080000000
    bne t1, t2, fail22
    ld t1, 16(t0)
    li t2, 0x0000000012345678
    bne t1, t2, fail22
    ld t1, 24(t0)
    li t2, 0xFFFFFFF9000493E0
    bne t1, t2, fail22

    # --- phase 11: vdiv32 (div0->FFFFFFFF, ovf->80000000) ---
    vdiv.vv v2, v4, v5
    li t0, DST
    vse32.v v2, (t0)
    li t0, DST
    ld t1, 0(t0)
    li t2, 0x7FFFFFFF00000000
    bne t1, t2, fail24
    ld t1, 8(t0)
    li t2, 0xFFFFFFFF80000000
    bne t1, t2, fail24
    ld t1, 16(t0)
    li t2, 0x0000000012345678
    bne t1, t2, fail24
    ld t1, 24(t0)
    li t2, 0x0000000000008235
    bne t1, t2, fail24

    # --- phase 12: vmseq32 -> dword0 FF, dword1 0 ---
    li t0, ZERO32
    vle32.v v6, (t0)
    vmseq.vv v6, v4, v4
    li t0, DST
    vse32.v v6, (t0)
    li t0, DST
    ld t1, 0(t0)
    li t2, 0xFF
    bne t1, t2, fail26
    ld t1, 8(t0)
    bnez t1, fail26

    # --- phase 13: masked vadd32 (mask 01, vd=0) -> dword0 3 ---
    li t0, ZERO32
    vle32.v v2, (t0)
    li t0, MSK01
    vle32.v v0, (t0)             # mask byte 01
    vadd.vv v2, v4, v5, v0.t
    li t0, DST
    vse32.v v2, (t0)
    li t0, DST
    ld t1, 0(t0)
    li t2, 3
    bne t1, t2, fail28
    ld t1, 8(t0)
    bnez t1, fail28

    # --- phase 14: e64 (vl==4): round trip, add, mul, div, seq ---
    vsetvli t1, zero, e64, m1, ta, ma
    li t2, 4
    bne t1, t2, fail2A
    li t0, W64A
    vle64.v v4, (t0)
    li t0, W64B
    vle64.v v5, (t0)
    li t0, DST
    vse64.v v4, (t0)
    li t0, W64A
    li t1, DST
    ld t2, 0(t0)
    ld t3, 0(t1)
    bne t2, t3, fail2A
    ld t2, 8(t0)
    ld t3, 8(t1)
    bne t2, t3, fail2A
    ld t2, 16(t0)
    ld t3, 16(t1)
    bne t2, t3, fail2A
    ld t2, 24(t0)
    ld t3, 24(t1)
    bne t2, t3, fail2A
    vadd.vv v2, v4, v5
    li t0, DST
    vse64.v v2, (t0)
    li t0, DST
    ld t1, 0(t0)
    li t2, 3
    bne t1, t2, fail2C
    ld t1, 8(t0)
    li t2, 0x8000000000000000
    bne t1, t2, fail2C
    ld t1, 16(t0)
    li t2, 0x7FFFFFFFFFFFFFFF
    bne t1, t2, fail2C
    ld t1, 24(t0)
    bnez t1, fail2C
    vmul.vv v2, v4, v5
    li t0, DST
    vse64.v v2, (t0)
    li t0, DST
    ld t1, 0(t0)
    li t2, 2
    bne t1, t2, fail2E
    ld t1, 8(t0)
    li t2, 0x7FFFFFFFFFFFFFFF
    bne t1, t2, fail2E
    ld t1, 16(t0)
    li t2, 0x8000000000000000
    bne t1, t2, fail2E
    ld t1, 24(t0)
    li t2, -1
    bne t1, t2, fail2E
    vdiv.vv v2, v4, v5
    li t0, DST
    vse64.v v2, (t0)
    li t0, DST
    ld t1, 0(t0)
    bnez t1, fail30
    ld t1, 8(t0)
    li t2, 0x7FFFFFFFFFFFFFFF
    bne t1, t2, fail30
    ld t1, 16(t0)
    li t2, 0x8000000000000000
    bne t1, t2, fail30
    ld t1, 24(t0)
    li t2, -1
    bne t1, t2, fail30
    li t0, ZERO32
    vle64.v v6, (t0)
    vmseq.vv v6, v4, v4
    li t0, DST
    vse64.v v6, (t0)
    li t0, DST
    ld t1, 0(t0)
    li t2, 0x0F
    bne t1, t2, fail32
    ld t1, 8(t0)
    bnez t1, fail32
    ld t1, 16(t0)
    bnez t1, fail32
    ld t1, 24(t0)
    bnez t1, fail32

    # --- phase 15: EEW mismatch is illegal (e8 + vle16 -> mcause 2) ---
    # M handler checks (mcause==2, STATE==1) and reports PASS directly
    # (no resume: this is the last phase).
    vsetvli zero, zero, e8, m1, ta, ma
    li t0, STATE
    li t1, 1
    sd t1, 0(t0)
    li t0, W16A
    vle16.v v0, (t0)            # ILLEGAL under SEW=8
    j failFF                     # must trap, never fall through

pass_cont:
    j failFF                     # recovered spuriously (never expected)

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
fail26: li t3, 0x26; j failT3
fail28: li t3, 0x28; j failT3
fail2A: li t3, 0x2A; j failT3
fail2C: li t3, 0x2C; j failT3
fail2E: li t3, 0x2E; j failT3
fail30: li t3, 0x30; j failT3
fail32: li t3, 0x32; j failT3
fail34: li t3, 0x34; j failT3
failFF: li t3, 0xFF; j failT3
failT3:
    slli t3, t3, 1
    ori t3, t3, 1
    li t1, TOHOST_ADDR
    sd t3, 0(t1)
    j failT3

.balign 4
m_trap:                         # only the phase-15 EEW trap may arrive
    csrr t0, mcause
    li t1, 2
    bne t0, t1, failM
    li t0, STATE
    ld t1, 0(t0)
    li t2, 1
    bne t1, t2, failMS
    li t0, TOHOST_ADDR
    li t1, 1
    sd t1, 0(t0)                # PASS
    j .
failMS:
    li t0, 0xE0
    slli t0, t0, 1
    ori t0, t0, 1
    li t1, TOHOST_ADDR
    sd t0, 0(t1)
    j failMS
failM:
    slli t0, t0, 1
    ori t0, t0, 1
    li t1, TOHOST_ADDR
    sd t0, 0(t1)
    j failM
