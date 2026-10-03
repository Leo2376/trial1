/*
 * v_slide.S -- RVV slide/gather bring-up (OPIVX/OPMVX/OPIVI, e8).
 *
 * Slides and gather run on the VALU wide path (R+W sub-FSM). Scalar
 * offset/index/fill rides the MEM scalar field (x[rs1] for .vx, 5-bit
 * uimm for .vi).
 *
 * M setup: HS identity tables (satp Sv39: root/L1/L0a identity + tohost
 * root[4] leaf). No traps are expected in S-mode (any M trap fails).
 *
 * Operands (vl=8 throughout): v4 = V = 0A..11, v0 = mask as noted,
 * vd preloaded with the AA sentinel wherever undisturbed bytes are
 * checked (slideup low region, oversized offsets).
 *
 * S phase 0 (config): vsetivli 8 -> rd==8.
 * S phase 1: vslideup.vx off=3 -> AA AA AA 0A 0B 0C 0D 0E.
 * S phase 2: vslideup.vi off=2 -> AA AA 0A 0B 0C 0D 0E 0F.
 * S phase 3: vslideup.vx off=10 (>=vl) -> all AA undisturbed.
 * S phase 4: vslide1up.vx fill=7F -> 7F 0A 0B 0C 0D 0E 0F 10.
 * S phase 5: vslidedown.vx off=3 -> 0D 0E 0F 10 11 00 00 00.
 * S phase 6: vslidedown.vi off=5 -> 0F 10 11 00 00 00 00 00.
 * S phase 7: vslide1down.vx fill=7E -> 0B 0C 0D 0E 0F 10 11 7E.
 * S phase 8: vrgather.vv idx=[7,0,3,40,2,1,5,4] -> 11 0A 0D 00 0C 0B 0F 0E
 *   (idx 40 >= vlmax 32 -> 0).
 * S phase 9: vrgather.vx s=5 -> all 0F.
 * S phase 10: vrgather.vx s=40 -> all 00.
 * S phase 11: vrgather.vi u=2 -> all 0C.
 * S phase 12: masked vslidedown.vx off=3 (mask F0, vd=0) ->
 *   00 00 00 00 11 00 00 00.
 *
 * PASS: tohost = 1. FAIL: tohost = (id << 1) | 1, or (mcause << 1) | 1.
 *
 * Build & run (from repo root, CI toolchain):
 *   riscv64-unknown-elf-gcc -march=rv64imafdcv_zicsr_zifencei -mabi=lp64d \
 *     -nostdlib -nostartfiles -static \
 *     -T software/riscv-tests-env/rv64gch/link.ld \
 *     software/tests/v_slide.S -o /tmp/v_slide.elf
 *   python3 tools/scripts/elf2hex.py /tmp/v_slide.elf /tmp/v_slide.hex
 *   ./sim/verilator/obj_dir/Vtb_rv64gch_core +hex=/tmp/v_slide.hex
 */
#define TOHOST_ADDR 0x100000000
#define VEC_V       0x80023000
#define VEC_IDX     0x80023008
#define SENT_AA     0x80023010
#define FILL7F      0x80023018
#define FILL7E      0x80023020
#define MSKF0       0x80023028
#define ZEROS       0x80023030
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
    li t0, VEC_V
    li t1, 0x11100F0E0D0C0B0A
    sd t1, 0(t0)                 # V = 0A..11
    li t1, 0x0405010228030007
    sd t1, 8(t0)                 # IDX = 7 0 3 40 2 1 5 4
    li t0, SENT_AA
    li t1, 0xAAAAAAAAAAAAAAAA
    sd t1, 0(t0)
    li t0, FILL7F
    li t1, 0x7F7F7F7F7F7F7F7F
    sd t1, 0(t0)
    li t0, FILL7E
    li t1, 0x7E7E7E7E7E7E7E7E
    sd t1, 0(t0)
    li t0, MSKF0
    li t1, 0xF0
    sd t1, 0(t0)
    sd zero, 8(t0)               # zeros
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
    # --- phase 0: vl==8, V->v4 ---
    vsetivli t1, 8, e8, m1, ta, ma
    li t2, 8
    bne t1, t2, failF0
    li t0, VEC_V
    vle8.v v4, (t0)

    # --- phase 1: vslideup.vx off=3 (vd=AA) -> 0E0D0C0B0AAAAAAA ---
    li t0, SENT_AA
    vle8.v v2, (t0)
    li t0, 3
    vslideup.vx v2, v4, t0
    li t0, DST
    vse8.v v2, (t0)
    li t0, DST
    ld t1, 0(t0)
    li t2, 0x0E0D0C0B0AAAAAAA
    bne t1, t2, fail10

    # --- phase 2: vslideup.vi off=2 (vd=AA) -> 0F0E0D0C0B0AAAAA ---
    li t0, SENT_AA
    vle8.v v2, (t0)
    vslideup.vi v2, v4, 2
    li t0, DST
    vse8.v v2, (t0)
    li t0, DST
    ld t1, 0(t0)
    li t2, 0x0F0E0D0C0B0AAAAA
    bne t1, t2, fail12

    # --- phase 3: vslideup.vx off=10 (vd=AA) -> all AA ---
    li t0, SENT_AA
    vle8.v v2, (t0)
    li t0, 10
    vslideup.vx v2, v4, t0
    li t0, DST
    vse8.v v2, (t0)
    li t0, DST
    ld t1, 0(t0)
    li t2, 0xAAAAAAAAAAAAAAAA
    bne t1, t2, fail14

    # --- phase 4: vslide1up.vx fill=7F -> 100F0E0D0C0B0A7F ---
    li t0, FILL7F
    vle8.v v2, (t0)             # any preload (fully overwritten)
    li t0, 0x7F
    vslide1up.vx v2, v4, t0
    li t0, DST
    vse8.v v2, (t0)
    li t0, DST
    ld t1, 0(t0)
    li t2, 0x100F0E0D0C0B0A7F
    bne t1, t2, fail16

    # --- phase 5: vslidedown.vx off=3 -> 00000011100F0E0D ---
    li t0, 3
    vslidedown.vx v2, v4, t0
    li t0, DST
    vse8.v v2, (t0)
    li t0, DST
    ld t1, 0(t0)
    li t2, 0x00000011100F0E0D
    bne t1, t2, fail18

    # --- phase 6: vslidedown.vi off=5 -> 0000000011100F... ---
    vslidedown.vi v2, v4, 5
    li t0, DST
    vse8.v v2, (t0)
    li t0, DST
    ld t1, 0(t0)
    li t2, 0x0000000011100F
    bne t1, t2, fail1A

    # --- phase 7: vslide1down.vx fill=7E -> 7E11100F0E0D0C0B ---
    li t0, 0x7E
    vslide1down.vx v2, v4, t0
    li t0, DST
    vse8.v v2, (t0)
    li t0, DST
    ld t1, 0(t0)
    li t2, 0x7E11100F0E0D0C0B
    bne t1, t2, fail1C

    # --- phase 8: vrgather.vv -> 0E0F0B0C000D0A11 ---
    li t0, VEC_IDX
    vle8.v v5, (t0)             # index vector
    vrgather.vv v2, v4, v5
    li t0, DST
    vse8.v v2, (t0)
    li t0, DST
    ld t1, 0(t0)
    li t2, 0x0E0F0B0C000D0A11
    bne t1, t2, fail1E

    # --- phase 9: vrgather.vx s=5 -> all 0F ---
    li t0, 5
    vrgather.vx v2, v4, t0
    li t0, DST
    vse8.v v2, (t0)
    li t0, DST
    ld t1, 0(t0)
    li t2, 0x0F0F0F0F0F0F0F0F
    bne t1, t2, fail20

    # --- phase 10: vrgather.vx s=40 -> all 00 ---
    li t0, 40
    vrgather.vx v2, v4, t0
    li t0, DST
    vse8.v v2, (t0)
    li t0, DST
    ld t1, 0(t0)
    bnez t1, fail22

    # --- phase 11: vrgather.vi u=2 -> all 0C ---
    vrgather.vi v2, v4, 2
    li t0, DST
    vse8.v v2, (t0)
    li t0, DST
    ld t1, 0(t0)
    li t2, 0x0C0C0C0C0C0C0C0C
    bne t1, t2, fail24

    # --- phase 12: masked vslidedown.vx off=3 (mask F0, vd=0) ---
    li t0, ZEROS
    vle8.v v2, (t0)
    li t0, MSKF0
    vle8.v v0, (t0)
    li t0, 3
    vslidedown.vx v2, v4, t0, v0.t
    li t0, DST
    vse8.v v2, (t0)
    li t0, DST
    ld t1, 0(t0)
    li t2, 0x0000001100000000
    bne t1, t2, fail26

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
fail26: li t3, 0x26; j failT3
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
