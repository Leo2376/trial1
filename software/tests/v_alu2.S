/*
 * v_alu2.S -- RVV OPIVV remainder bring-up (min/max/saturating/shift/merge/
 * compare via VALU, e8).
 *
 * Requires the vector (re)start fix (vec_start_q): several phases chain
 * back-to-back VALU ops (compare vd reuse, the v2->v3->v4 chain).
 *
 * M setup: HS identity tables (satp Sv39: root/L1/L0a identity + tohost
 * root[4] leaf). No traps are expected in S-mode (any M trap fails).
 *
 * Operands (vl=8 throughout):
 *   v4 = A = 00 01 7F 80 FF 55 AA 00 (CMP_A)
 *   v5 = B = 01 01 80 7F 00 56 55 FF (CMP_B)
 *   X/Y, SX/SY analogous pairs for saturating/shift phases.
 *
 * S phase 0 (config): vsetivli 8 -> rd==8.
 * S phases 1-4 (min/max): vminu/vmaxu/vmin/vmax of (A,B).
 * S phases 5-8 (saturating): vsaddu/vsadd/vssubu/vssub of (X,Y).
 * S phases 9-11 (shifts): vsll/vsrl/vsra of (SX,SY) (amount = low 3 bits).
 * S phase 12 (merge): vmerge.vvm v2,v4(FF),v5(01),v0t mask=F0 ->
 *   elements 0-3 = 01, 4-7 = FF.
 * S phases 13-18 (compares, vd pre-zeroed): vmseq/vmsne/vmsltu/vmslt/
 *   vmsleu/vmsle of (A,B) -> 02/FD/A5/79/A7/7B in byte 0.
 * S phase 19 (masked compare): vd=0 preload, mask=FD, vmsne,v0.t -> FD
 *   (masked-off TRUE element 1 stays 0; broken masking would give FF).
 * S phase 20 (masked compare): vd=FF preload, mask=02, vmseq,v0.t -> FF
 *   (masked-off FALSE elements stay 1; broken masking would give 02).
 * S phase 21 (chain): vadd v2=A+B; vsub v3=v2-A (=B); vxor v4=v3^B (=0).
 *
 * PASS: tohost = 1. FAIL: tohost = (id << 1) | 1, or (mcause << 1) | 1.
 *
 * Build & run (from repo root, CI toolchain):
 *   riscv64-unknown-elf-gcc -march=rv64imafdcv_zicsr_zifencei -mabi=lp64d \
 *     -nostdlib -nostartfiles -static \
 *     -T software/riscv-tests-env/rv64gch/link.ld \
 *     software/tests/v_alu2.S -o /tmp/v_alu2.elf
 *   python3 tools/scripts/elf2hex.py /tmp/v_alu2.elf /tmp/v_alu2.hex
 *   ./sim/verilator/obj_dir/Vtb_rv64gch_core +hex=/tmp/v_alu2.hex
 */
#define TOHOST_ADDR 0x100000000
#define CMP_A       0x80023000
#define CMP_B       0x80023008
#define SAT_X       0x80023010
#define SAT_Y       0x80023018
#define SH_X        0x80023020
#define SH_Y        0x80023028
#define FF8         0x80023030
#define ONE8        0x80023038
#define MSKF0       0x80023040
#define ZEROS       0x80023048
#define MSKFD       0x80023050
#define MSK02       0x80023058
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
    li t0, CMP_A
    li t1, 0x00AA55FF807F0100
    sd t1, 0(t0)                 # A = 00 01 7F 80 FF 55 AA 00
    li t1, 0xFF5556007F800101
    sd t1, 8(t0)                 # B = 01 01 80 7F 00 56 55 FF
    li t0, SAT_X
    li t1, 0x817E007F80007FFF
    sd t1, 0(t0)                 # X = FF 7F 00 80 7F 00 7E 81
    li t1, 0x7F01FFFF01010101
    sd t1, 8(t0)                 # Y = 01 01 01 01 FF FF 01 7F
    li t0, SH_X
    li t1, 0x01AA5500FF808001
    sd t1, 0(t0)                 # SX = 01 80 80 FF 00 55 AA 01
    li t1, 0x0805000402070103
    sd t1, 8(t0)                 # SY = 03 01 07 02 04 00 05 08
    li t0, FF8
    li t1, -1
    sd t1, 0(t0)                 # 8xFF
    li t1, 0x0101010101010101
    sd t1, 8(t0)                 # 8x01
    li t0, MSKF0
    li t1, 0xF0
    sd t1, 0(t0)                 # mask byte F0
    sd zero, 8(t0)               # zeros (compare vd preload)
    li t0, MSKFD
    li t1, 0xFD
    sd t1, 0(t0)
    li t1, 0x02
    sd t1, 8(t0)
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
    # --- phase 0: vl==8 ---
    vsetivli t1, 8, e8, m1, ta, ma
    li t2, 8
    bne t1, t2, failF0
    # load A->v4, B->v5 (reloaded per phase group as needed)
    li t0, CMP_A
    vle8.v v4, (t0)
    li t0, CMP_B
    vle8.v v5, (t0)

    # --- phase 1: vminu.vv -> 005555007F7F0100 ---
    vminu.vv v2, v4, v5
    li t0, DST
    vse8.v v2, (t0)
    li t0, DST
    ld t1, 0(t0)
    li t2, 0x005555007F7F0100
    bne t1, t2, fail10

    # --- phase 2: vmaxu.vv -> FFAA56FF80800101 ---
    vmaxu.vv v2, v4, v5
    li t0, DST
    vse8.v v2, (t0)
    li t0, DST
    ld t1, 0(t0)
    li t2, 0xFFAA56FF80800101
    bne t1, t2, fail12

    # --- phase 3: vmin.vv (signed) -> FFAA55FF80800100 ---
    vmin.vv v2, v4, v5
    li t0, DST
    vse8.v v2, (t0)
    li t0, DST
    ld t1, 0(t0)
    li t2, 0xFFAA55FF80800100
    bne t1, t2, fail14

    # --- phase 4: vmax.vv (signed) -> 005556007F7F0101 ---
    vmax.vv v2, v4, v5
    li t0, DST
    vse8.v v2, (t0)
    li t0, DST
    ld t1, 0(t0)
    li t2, 0x005556007F7F0101
    bne t1, t2, fail16

    # --- saturating phases: X->v4, Y->v5 ---
    li t0, SAT_X
    vle8.v v4, (t0)
    li t0, SAT_Y
    vle8.v v5, (t0)

    # --- phase 5: vsaddu.vv -> FF7FFFFF810180FF ---
    vsaddu.vv v2, v4, v5
    li t0, DST
    vse8.v v2, (t0)
    li t0, DST
    ld t1, 0(t0)
    li t2, 0xFF7FFFFF810180FF
    bne t1, t2, fail18

    # --- phase 6: vsadd.vv (signed) -> 007FFF7E81017F00 ---
    vsadd.vv v2, v4, v5
    li t0, DST
    vse8.v v2, (t0)
    li t0, DST
    ld t1, 0(t0)
    li t2, 0x007FFF7E81017F00
    bne t1, t2, fail1A

    # --- phase 7: vssubu.vv -> 027D00007F007EFE ---
    vssubu.vv v2, v4, v5
    li t0, DST
    vse8.v v2, (t0)
    li t0, DST
    ld t1, 0(t0)
    li t2, 0x027D00007F007EFE
    bne t1, t2, fail1C

    # --- phase 8: vssub.vv (signed) -> 807D017F80FF7EFE ---
    vssub.vv v2, v4, v5
    li t0, DST
    vse8.v v2, (t0)
    li t0, DST
    ld t1, 0(t0)
    li t2, 0x807D017F80FF7EFE
    bne t1, t2, fail1E

    # --- shift phases: SX->v4, SY->v5 ---
    li t0, SH_X
    vle8.v v4, (t0)
    li t0, SH_Y
    vle8.v v5, (t0)

    # --- phase 9: vsll.vv -> 01405500FC000008 ---
    vsll.vv v2, v4, v5
    li t0, DST
    vse8.v v2, (t0)
    li t0, DST
    ld t1, 0(t0)
    li t2, 0x01405500FC000008
    bne t1, t2, fail20

    # --- phase 10: vsrl.vv -> 010555003F014000 ---
    vsrl.vv v2, v4, v5
    li t0, DST
    vse8.v v2, (t0)
    li t0, DST
    ld t1, 0(t0)
    li t2, 0x010555003F014000
    bne t1, t2, fail22

    # --- phase 11: vsra.vv -> 01FD5500FFFFC000 ---
    vsra.vv v2, v4, v5
    li t0, DST
    vse8.v v2, (t0)
    li t0, DST
    ld t1, 0(t0)
    li t2, 0x01FD5500FFFFC000
    bne t1, t2, fail24

    # --- phase 12: vmerge.vvm (mask F0: lo=01, hi=FF) ---
    li t0, FF8
    vle8.v v4, (t0)             # vs2 = FF
    li t0, ONE8
    vle8.v v5, (t0)             # vs1 = 01
    li t0, MSKF0
    vle8.v v0, (t0)             # mask = F0.......
    vmerge.vvm v2, v4, v5, v0
    li t0, DST
    vse8.v v2, (t0)
    li t0, DST
    ld t1, 0(t0)
    li t2, 0xFFFFFFFF01010101
    bne t1, t2, fail26

    # --- compare phases: A->v4, B->v5, zeros->vd ---
    li t0, CMP_A
    vle8.v v4, (t0)
    li t0, CMP_B
    vle8.v v5, (t0)

    # --- phase 13: vmseq.vv -> byte 0x02 ---
    li t0, ZEROS
    vle8.v v6, (t0)
    vmseq.vv v6, v4, v5
    li t0, DST
    vse8.v v6, (t0)
    li t0, DST
    ld t1, 0(t0)
    li t2, 0x02
    bne t1, t2, fail28

    # --- phase 14: vmsne.vv -> byte 0xFD ---
    li t0, ZEROS
    vle8.v v6, (t0)
    vmsne.vv v6, v4, v5
    li t0, DST
    vse8.v v6, (t0)
    li t0, DST
    ld t1, 0(t0)
    li t2, 0xFD
    bne t1, t2, fail2A

    # --- phase 15: vmsltu.vv -> byte 0xA5 ---
    li t0, ZEROS
    vle8.v v6, (t0)
    vmsltu.vv v6, v4, v5
    li t0, DST
    vse8.v v6, (t0)
    li t0, DST
    ld t1, 0(t0)
    li t2, 0xA5
    bne t1, t2, fail2C

    # --- phase 16: vmslt.vv -> byte 0x79 ---
    li t0, ZEROS
    vle8.v v6, (t0)
    vmslt.vv v6, v4, v5
    li t0, DST
    vse8.v v6, (t0)
    li t0, DST
    ld t1, 0(t0)
    li t2, 0x79
    bne t1, t2, fail2E

    # --- phase 17: vmsleu.vv -> byte 0xA7 ---
    li t0, ZEROS
    vle8.v v6, (t0)
    vmsleu.vv v6, v4, v5
    li t0, DST
    vse8.v v6, (t0)
    li t0, DST
    ld t1, 0(t0)
    li t2, 0xA7
    bne t1, t2, fail30

    # --- phase 18: vmsle.vv -> byte 0x7B ---
    li t0, ZEROS
    vle8.v v6, (t0)
    vmsle.vv v6, v4, v5
    li t0, DST
    vse8.v v6, (t0)
    li t0, DST
    ld t1, 0(t0)
    li t2, 0x7B
    bne t1, t2, fail32

    # --- phase 19: masked vmsne (mask FD, vd=0) -> 0xFD ---
    li t0, ZEROS
    vle8.v v6, (t0)
    li t0, MSKFD
    vle8.v v0, (t0)
    vmsne.vv v6, v4, v5, v0.t
    li t0, DST
    vse8.v v6, (t0)
    li t0, DST
    ld t1, 0(t0)
    li t2, 0xFD
    bne t1, t2, fail34

    # --- phase 20: masked vmseq (mask 02, vd=FF) -> 0xFF ---
    li t0, FF8
    vle8.v v6, (t0)
    li t0, MSK02
    vle8.v v0, (t0)
    vmseq.vv v6, v4, v5, v0.t
    li t0, DST
    vse8.v v6, (t0)
    li t0, DST
    ld t1, 0(t0)
    li t2, -1
    bne t1, t2, fail36

    # --- phase 21: back-to-back chain v2=A+B; v3=v2-A; v4=v3^B=0 ---
    li t0, CMP_A
    vle8.v v4, (t0)
    li t0, CMP_B
    vle8.v v5, (t0)
    vadd.vv v2, v4, v5
    vsub.vv v3, v2, v4
    vxor.vv v6, v3, v5
    li t0, DST
    vse8.v v6, (t0)
    li t0, DST
    ld t1, 0(t0)
    bnez t1, fail38

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
fail28: li t3, 0x28; j failT3
fail2A: li t3, 0x2A; j failT3
fail2C: li t3, 0x2C; j failT3
fail2E: li t3, 0x2E; j failT3
fail30: li t3, 0x30; j failT3
fail32: li t3, 0x32; j failT3
fail34: li t3, 0x34; j failT3
fail36: li t3, 0x36; j failT3
fail38: li t3, 0x38; j failT3
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
