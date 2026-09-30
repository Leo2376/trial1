/*
 * v_strided.S -- RVV strided ld/st bring-up (vlse8/vsse8 via VLSU).
 *
 * M setup: HS identity tables (satp Sv39: root/L1/L0a identity + tohost
 * root[4] leaf) plus an L0b remap page (VA 0x80200000 -> PA 0x80020000,
 * A=D=0 to exercise the walker A/D path through the VLSU-driven port).
 *
 * S phase 1 (config): vsetvli e8m1ta_ma -> vl==32 (VLMAX).
 * S phase 2 (strided move): 32B scalar pattern at BASE1; vl=8, stride=4:
 *   vlse8.v v0,(BASE1),4 -> vsse8.v v0,(BASE2),4; scalar lb compare of
 *   the 8 gathered bytes.
 * S phase 3 (negative stride): vl=8, vlse8.v v1,(BASE1+7),-1 (reversed
 *   gather) -> vsse8.v v1,(BASE2+16),1; scalar lb compare reversed.
 * S phase 4 (fault/restart): vl=8, stride=4, vlse8.v from 0x80200FFC
 *   (elem 0 mapped, elem 1 at 0x80201000 unmapped) -> load page fault
 *   to M; M handler checks (mcause==13, vstart==1, mtval==0x80201000).
 *
 * PASS: tohost = 1. FAIL: tohost = (id << 1) | 1, or (mcause << 1) | 1.
 *
 * Build & run (from repo root):
 *   riscv64-unknown-elf-gcc -march=rv64imafdcv_zicsr_zifencei -mabi=lp64d \
 *     -nostdlib -nostartfiles -static \
 *     -T software/riscv-tests-env/rv64gch/link.ld \
 *     software/tests/v_strided.S -o /tmp/v_strided.elf
 *   python3 tools/scripts/elf2hex.py /tmp/v_strided.elf /tmp/v_strided.hex
 *   ./sim/verilator/obj_dir/Vtb_rv64gch_core +hex=/tmp/v_strided.hex
 */
#define TOHOST_ADDR 0x100000000
#define STATE_ADDR  0x80023200
#define BASE1       0x80023000
#define BASE2       0x80023100
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

    # --- 32B pattern at BASE1, zero BASE2, state=0 ---
    li t0, BASE1
    li t1, 0x0123456789ABCDEF
    sd t1, 0(t0)
    li t1, 0xFEDCBA9876543210
    sd t1, 8(t0)
    li t1, 0xAAAAAAAAAAAAAAAA
    sd t1, 16(t0)
    li t1, 0x5555555555555555
    sd t1, 24(t0)
    li t0, BASE2
    sd zero, 0(t0)
    sd zero, 8(t0)
    sd zero, 16(t0)
    sd zero, 24(t0)
    li t0, STATE_ADDR
    sd zero, 0(t0)
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
    # --- phase 1: vsetvli e8m1 ta,ma -> vl==32 ---
    vsetvli t0, zero, e8, m1, ta, ma
    li t1, 32
    bne t0, t1, fail40

    # --- phase 2: vl=8, stride=4 gather/scatter round-trip ---
    vsetivli zero, 8, e8, m1, ta, ma
    li t0, BASE1
    li t1, 4
    vlse8.v v0, (t0), t1
    li t0, BASE2
    vsse8.v v0, (t0), t1
    li t0, BASE1
    li t1, BASE2
    lb t2, 0(t0)
    lb t3, 0(t1)
    bne t2, t3, fail42
    lb t2, 4(t0)
    lb t3, 4(t1)
    bne t2, t3, fail44
    lb t2, 8(t0)
    lb t3, 8(t1)
    bne t2, t3, fail46
    lb t2, 12(t0)
    lb t3, 12(t1)
    bne t2, t3, fail48
    lb t2, 16(t0)
    lb t3, 16(t1)
    bne t2, t3, fail4A
    lb t2, 20(t0)
    lb t3, 20(t1)
    bne t2, t3, fail4C
    lb t2, 24(t0)
    lb t3, 24(t1)
    bne t2, t3, fail4E
    lb t2, 28(t0)
    lb t3, 28(t1)
    bne t2, t3, fail50

    # --- phase 2b: stride sourced from a load (load-use hazard) ---
    # t1 is poisoned so a missing stall reads stride 99, not 4.
    li t0, STATE_ADDR + 8
    li t1, 4
    sd t1, 0(t0)
    li t4, BASE1
    li t1, 99               # poison
    ld t1, 0(t0)            # stride producer
    vlse8.v v3, (t4), t1    # consumer: must stall until ld retires
    li t0, BASE2 + 24
    li t1, 1
    vsse8.v v3, (t0), t1
    li t0, BASE1
    li t1, BASE2 + 24
    lb t2, 0(t0)
    lb t3, 0(t1)
    bne t2, t3, fail62
    lb t2, 4(t0)
    lb t3, 1(t1)
    bne t2, t3, fail64
    lb t2, 8(t0)
    lb t3, 2(t1)
    bne t2, t3, fail66
    lb t2, 12(t0)
    lb t3, 3(t1)
    bne t2, t3, fail68
    lb t2, 16(t0)
    lb t3, 4(t1)
    bne t2, t3, fail6A
    lb t2, 20(t0)
    lb t3, 5(t1)
    bne t2, t3, fail6C
    lb t2, 24(t0)
    lb t3, 6(t1)
    bne t2, t3, fail6E
    lb t2, 28(t0)
    lb t3, 7(t1)
    bne t2, t3, fail70

    # --- phase 3: negative stride gather, stride-1 scatter ---
    li t0, BASE1 + 7
    li t1, -1
    vlse8.v v1, (t0), t1
    li t0, BASE2 + 16
    li t1, 1
    vsse8.v v1, (t0), t1
    li t0, BASE1
    li t1, BASE2 + 16
    lb t2, 7(t0)
    lb t3, 0(t1)
    bne t2, t3, fail52
    lb t2, 6(t0)
    lb t3, 1(t1)
    bne t2, t3, fail54
    lb t2, 5(t0)
    lb t3, 2(t1)
    bne t2, t3, fail56
    lb t2, 4(t0)
    lb t3, 3(t1)
    bne t2, t3, fail58
    lb t2, 3(t0)
    lb t3, 4(t1)
    bne t2, t3, fail5A
    lb t2, 2(t0)
    lb t3, 5(t1)
    bne t2, t3, fail5C
    lb t2, 1(t0)
    lb t3, 6(t1)
    bne t2, t3, fail5E
    lb t2, 0(t0)
    lb t3, 7(t1)
    bne t2, t3, fail60

    # --- phase 4: vl=8, stride=4 faulting gather (elem 1 unmapped) ---
    vsetivli zero, 8, e8, m1, ta, ma
    li t0, STATE_ADDR
    li t1, 1
    sd t1, 0(t0)
    li t0, REMAP_VA + 0xFFC     # elem0 @0x80200FFC mapped, elem1 @0x80201000 faults
    li t1, 4
    vlse8.v v2, (t0), t1
    j failFF                    # must trap, never fall through

fail40: li t3, 0x40; j failT3
fail42: li t3, 0x42; j failT3
fail44: li t3, 0x44; j failT3
fail46: li t3, 0x46; j failT3
fail48: li t3, 0x48; j failT3
fail4A: li t3, 0x4A; j failT3
fail4C: li t3, 0x4C; j failT3
fail4E: li t3, 0x4E; j failT3
fail50: li t3, 0x50; j failT3
fail62: li t3, 0x62; j failT3
fail64: li t3, 0x64; j failT3
fail66: li t3, 0x66; j failT3
fail68: li t3, 0x68; j failT3
fail6A: li t3, 0x6A; j failT3
fail6C: li t3, 0x6C; j failT3
fail6E: li t3, 0x6E; j failT3
fail70: li t3, 0x70; j failT3
fail52: li t3, 0x52; j failT3
fail54: li t3, 0x54; j failT3
fail56: li t3, 0x56; j failT3
fail58: li t3, 0x58; j failT3
fail5A: li t3, 0x5A; j failT3
fail5C: li t3, 0x5C; j failT3
fail5E: li t3, 0x5E; j failT3
fail60: li t3, 0x60; j failT3
failFF: li t3, 0xFF; j failT3
failT3:
    slli t3, t3, 1
    ori t3, t3, 1
    li t1, TOHOST_ADDR
    sd t3, 0(t1)
    j failT3

.balign 4
m_trap:                         # M-mode: only the phase-4 vector fault
    csrr t0, mcause             # may arrive (cause 13, state==1)
    li t1, 13
    bne t0, t1, failM
    li t0, STATE_ADDR
    ld t1, 0(t0)
    li t2, 1
    bne t1, t2, failMS
    csrr t0, vstart
    li t1, 1
    bne t0, t1, failMS
    csrr t0, mtval
    li t1, REMAP_VA + 0x1000    # 0x80201000: faulting element VA
    bne t0, t1, failMS
    li t0, TOHOST_ADDR
    li t1, 1
    sd t1, 0(t0)
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
