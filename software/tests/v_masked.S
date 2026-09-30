/*
 * v_masked.S -- RVV masked ld/st bring-up (vm=0, v0 mask, via VLSU).
 *
 * Mask layout is RVV LMUL=1: element i active iff bit i of v0 is set.
 * Masked-off elements skip memory (never fault) and leave the
 * destination undisturbed (loads) / memory undisturbed (stores).
 *
 * M setup: HS identity tables (satp Sv39: root/L1/L0a identity + tohost
 * root[4] leaf) plus an L0b remap page (VA 0x80200000 -> PA 0x80020000).
 * L0b[1] (0x80201000) left unmapped as the fault-avoidance probe page.
 *
 * S phase 0 (config): vsetvli e8m1ta_ma -> vl==32.
 * S phase A (masked unit): mask=0x55 (even active); v1=8xAA sentinel;
 *   vle8.v v1,(BASE1),v0.t -> vse8.v v1,(BASE2); even==pattern, odd==AA.
 * S phase B (masked strided): stride=4, same mask; sentinel refill;
 *   vlse8.v v1,(BASE1),4,v0.t -> vsse8.v v1,(BASE2+8),4,v0.t; active
 *   slots==pattern, skipped slots still zero.
 * S phase C (masked indexed, fault avoidance): mask=0xFD (all but
 *   elem1); idx {0,4,0,...}; sentinel refill;
 *   vluxei8.v v1,(0x80200FFC),v2,v0.t must NOT trap even though elem1's
 *   VA (0x80201000) is unmapped; vstart==0; vse8.v to BASE2+16;
 *   [0]==mem[FFC], [1]==AA, [2]==mem[FFC]. Then PASS (no trap expected;
 *   any M trap fails).
 *
 * PASS: tohost = 1. FAIL: tohost = (id << 1) | 1, or (mcause << 1) | 1.
 *
 * Build & run (from repo root):
 *   riscv64-unknown-elf-gcc -march=rv64imafdcv_zicsr_zifencei -mabi=lp64d \
 *     -nostdlib -nostartfiles -static \
 *     -T software/riscv-tests-env/rv64gch/link.ld \
 *     software/tests/v_masked.S -o /tmp/v_masked.elf
 *   python3 tools/scripts/elf2hex.py /tmp/v_masked.elf /tmp/v_masked.hex
 *   ./sim/verilator/obj_dir/Vtb_rv64gch_core +hex=/tmp/v_masked.hex
 */
#define TOHOST_ADDR 0x100000000
#define BASE1       0x80023000
#define BASE2       0x80023100
#define SENT        0x80023030
#define IDX         0x80023038
#define SCRATCH     0x80023200
#define REMAP_VA    0x80200000
.section .text.init, "ax"
.globl _start
_start:
    li sp, 0x8000fffff8
    la t0, m_trap
    csrw mtvec, t0

    # --- HS identity tables + remap page ---
    li t0, 0x80010000
    li t1, 0x20004401            # root[2] -> L1
    sd t1, 16(t0)
    li t1, 0x400000C7            # root[4] 1G leaf -> tohost (VPN2=4)
    sd t1, 32(t0)
    li t0, 0x80011000
    li t1, 0x20004801            # L1[0] -> L0a (identity)
    sd t1, 0(t0)
    li t1, 0x20004C01            # L1[1] -> L0b (remap)
    sd t1, 8(t0)
    li t0, 0x80012000
    li t1, 0x200000CF
    li t2, 36
0:  sd t1, 0(t0)
    addi t1, t1, 0x400
    addi t0, t0, 8
    addi t2, t2, -1
    bnez t2, 0b
    li t0, 0x80013000
    li t1, 0x20008007            # L0b[0]: 0x80200000 -> 0x80020000 V|R|W A=D=0
    sd t1, 0(t0)
    # L0b[1] (0x80201000) left 0 -> fault probe page

    # --- 32B pattern at BASE1, 8xAA sentinel at SENT, zero BASE2 ---
    li t0, BASE1
    li t1, 0x0123456789ABCDEF
    sd t1, 0(t0)
    li t1, 0xFEDCBA9876543210
    sd t1, 8(t0)
    li t1, 0xAAAAAAAAAAAAAAAA
    sd t1, 16(t0)
    li t1, 0x5555555555555555
    sd t1, 24(t0)
    li t0, SENT
    li t1, 0xAAAAAAAAAAAAAAAA
    sd t1, 0(t0)
    li t0, IDX                 # idx {0,4,0,0,0,0,0,0} (phase C)
    sb zero, 0(t0)
    li t1, 4
    sb t1, 1(t0)
    sb zero, 2(t0)
    sb zero, 3(t0)
    sb zero, 4(t0)
    sb zero, 5(t0)
    sb zero, 6(t0)
    sb zero, 7(t0)
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
    # --- phase 0: vsetvli e8m1 ta,ma -> vl==32 ---
    vsetvli t0, zero, e8, m1, ta, ma
    li t1, 32
    bne t0, t1, failC0
    vsetivli zero, 8, e8, m1, ta, ma

    # --- mask 0x55 (even elements active) into v0 ---
    li t0, SCRATCH
    li t1, 0x55
    sb t1, 0(t0)
    vle8.v v0, (t0)

    # --- phase A: masked unit load (sentinel refill first) ---
    li t0, SENT
    vle8.v v1, (t0)             # v1 = 8xAA
    li t0, BASE1
    vle8.v v1, (t0), v0.t       # even=P, odd=AA
    li t0, BASE2
    vse8.v v1, (t0)
    li t0, BASE1
    li t1, BASE2
    lb t2, 0(t0)
    lb t3, 0(t1)
    bne t2, t3, failC2
    lb t3, 1(t1)
    li t4, -86                  # 0xAA sign-extended
    bne t3, t4, failC4
    lb t2, 2(t0)
    lb t3, 2(t1)
    bne t2, t3, failC6
    lb t3, 3(t1)
    bne t3, t4, failC8
    lb t2, 4(t0)
    lb t3, 4(t1)
    bne t2, t3, failCA
    lb t3, 5(t1)
    bne t3, t4, failCC
    lb t2, 6(t0)
    lb t3, 6(t1)
    bne t2, t3, failCE
    lb t3, 7(t1)
    bne t3, t4, failD0

    # --- phase B: masked strided load/store, stride=4 ---
    li t0, SENT
    vle8.v v1, (t0)             # sentinel refill
    li t0, BASE1
    li t1, 4
    vlse8.v v1, (t0), t1, v0.t  # even k: P[k*4], odd: AA
    li t0, BASE2 + 8
    vsse8.v v1, (t0), t1, v0.t  # active slots stored, skipped stay 0
    li t0, BASE1
    li t1, BASE2 + 8
    lb t2, 0(t0)
    lb t3, 0(t1)
    bne t2, t3, failD2
    lb t3, 4(t1)
    bnez t3, failD4
    lb t2, 8(t0)
    lb t3, 8(t1)
    bne t2, t3, failD6
    lb t3, 12(t1)
    bnez t3, failD8
    lb t2, 16(t0)
    lb t3, 16(t1)
    bne t2, t3, failDA
    lb t3, 20(t1)
    bnez t3, failDC
    lb t2, 24(t0)
    lb t3, 24(t1)
    bne t2, t3, failDE
    lb t3, 28(t1)
    bnez t3, failE0

    # --- phase C: masked indexed gather over an unmapped element ---
    li t0, SCRATCH
    li t1, -3                   # 0xFD: all but elem1
    sb t1, 0(t0)
    vle8.v v0, (t0)             # new mask
    li t0, IDX
    vle8.v v2, (t0)             # idx {0,4,0,...}
    li t0, SENT
    vle8.v v1, (t0)             # sentinel refill
    li t0, REMAP_VA + 0xFFC     # elem1 VA 0x80201000 unmapped, masked off
    vluxei8.v v1, (t0), v2, v0.t  # must NOT trap
    csrr t1, vstart
    bnez t1, failE2             # no fault taken, vstart still 0
    li t0, BASE2 + 16
    vse8.v v1, (t0)
    li t0, REMAP_VA + 0xFFC
    lb t2, 0(t0)                # reference: mapped elem0 value
    li t1, BASE2 + 16
    lb t3, 0(t1)
    bne t2, t3, failE4
    lb t3, 1(t1)
    li t4, -86
    bne t3, t4, failE6          # masked-off elem undisturbed (AA)
    lb t3, 2(t1)
    bne t2, t3, failE8          # idx 0 again -> same value

    li t0, TOHOST_ADDR
    li t1, 1
    sd t1, 0(t0)
    j .

failC0: li t3, 0xC0; j failT3
failC2: li t3, 0xC2; j failT3
failC4: li t3, 0xC4; j failT3
failC6: li t3, 0xC6; j failT3
failC8: li t3, 0xC8; j failT3
failCA: li t3, 0xCA; j failT3
failCC: li t3, 0xCC; j failT3
failCE: li t3, 0xCE; j failT3
failD0: li t3, 0xD0; j failT3
failD2: li t3, 0xD2; j failT3
failD4: li t3, 0xD4; j failT3
failD6: li t3, 0xD6; j failT3
failD8: li t3, 0xD8; j failT3
failDA: li t3, 0xDA; j failT3
failDC: li t3, 0xDC; j failT3
failDE: li t3, 0xDE; j failT3
failE0: li t3, 0xE0; j failT3
failE2: li t3, 0xE2; j failT3
failE4: li t3, 0xE4; j failT3
failE6: li t3, 0xE6; j failT3
failE8: li t3, 0xE8; j failT3
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
