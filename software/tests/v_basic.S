/*
 * v_basic.S -- RVV v0 skeleton bring-up (vsetvli + vle8/vse8 via VLSU).
 *
 * M setup: HS identity tables (satp Sv39: root/L1/L0a identity + tohost
 * root[4] leaf) plus an L0b remap page (VA 0x80200000 -> PA 0x80020000,
 * A=D=0 to exercise the walker A/D path through the VLSU-driven port).
 *
 * S phase 1 (CSR/config): vsetvli e8m1ta_ma -> vl==32 (VLMAX), vl/vtype
 * CSR readback, mstatus.VS==Dirty; vsetivli 8 -> vl==8; vill vtype
 * (sew16) -> vl==0, vtype.vill==1; vstart CSR RW + vset reset.
 * S phase 2 (movement): 32B scalar pattern -> vle8.v v0 -> vse8.v v0 ->
 * scalar ld compare (4 dwords).
 * S phase 3 (fault/restart): vl=8, vle8.v from 0x80200FFC (4B in the
 * mapped page, element 4 in the unmapped page) -> load page fault to M;
 * M handler checks (mcause==13, vstart==4, mtval==0x80201000) -> PASS.
 *
 * PASS: tohost = 1. FAIL: tohost = (id << 1) | 1, or (mcause << 1) | 1.
 *
 * Build & run (from repo root):
 *   riscv64-unknown-elf-gcc -march=rv64imafdcv_zicsr_zifencei -mabi=lp64d \
 *     -nostdlib -nostartfiles -static \
 *     -T software/riscv-tests-env/rv64gch/link.ld \
 *     software/tests/v_basic.S -o /tmp/v_basic.elf
 *   python3 tools/scripts/elf2hex.py /tmp/v_basic.elf /tmp/v_basic.hex
 *   ./sim/verilator/obj_dir/Vtb_rv64gch_core +hex=/tmp/v_basic.hex
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
    bne t0, t1, fail10
    csrr t0, vl
    bne t0, t1, fail12
    csrr t0, vtype
    li t1, 0xC0
    bne t0, t1, fail14
    csrr t0, mstatus
    andi t0, t0, 0x600
    li t1, 0x600               # VS==Dirty
    bne t0, t1, fail16
    # --- vsetivli 8 -> vl==8, rd==8 ---
    vsetivli t1, 8, e8, m1, ta, ma
    li t2, 8
    bne t1, t2, fail18
    csrr t0, vl
    bne t0, t2, fail1A
    # --- vstart RW + vset reset ---
    li t0, 5
    csrw vstart, t0
    csrr t1, vstart
    li t2, 5
    bne t1, t2, fail1C
    vsetvli t0, zero, e8, m1, ta, ma
    csrr t1, vstart
    bnez t1, fail1E
    li t1, 32
    bne t0, t1, fail1E
    # --- vill vtype (sew16) -> vl==0, vtype[63]==1, then restore ---
    vsetvli t0, zero, e16, m1, ta, ma
    bnez t0, fail20
    csrr t0, vl
    bnez t0, fail20
    csrr t0, vtype
    bltz t0, villok
    j fail20
villok:
    vsetvli t0, zero, e8, m1, ta, ma
    li t1, 32
    bne t0, t1, fail22

    # --- phase 2: vle8 v0,(BASE1); vse8 v0,(BASE2); ld compare ---
    li t0, BASE1
    vle8.v v0, (t0)
    li t0, BASE2
    vse8.v v0, (t0)
    li t0, BASE1
    li t1, BASE2
    ld t2, 0(t0)
    ld t3, 0(t1)
    bne t2, t3, fail30
    ld t2, 8(t0)
    ld t3, 8(t1)
    bne t2, t3, fail32
    ld t2, 16(t0)
    ld t3, 16(t1)
    bne t2, t3, fail34
    ld t2, 24(t0)
    ld t3, 24(t1)
    bne t2, t3, fail36

    # --- phase 3: vl=8, faulting load (element 4 unmapped) ---
    vsetivli zero, 8, e8, m1, ta, ma
    li t0, STATE_ADDR
    li t1, 1
    sd t1, 0(t0)
    li t0, REMAP_VA + 0xFFC     # 0x80200FFC: elems 0..3 mapped, 4 faults
    vle8.v v1, (t0)
    j failFF                    # must trap, never fall through

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
fail30: li t3, 0x30; j failT3
fail32: li t3, 0x32; j failT3
fail34: li t3, 0x34; j failT3
fail36: li t3, 0x36; j failT3
failFF: li t3, 0xFF; j failT3
failT3:
    slli t3, t3, 1
    ori t3, t3, 1
    li t1, TOHOST_ADDR
    sd t3, 0(t1)
    j failT3

.balign 4
m_trap:                         # M-mode: only the phase-3 vector fault
    csrr t0, mcause             # may arrive (cause 13, state==1)
    li t1, 13
    bne t0, t1, failM
    li t0, STATE_ADDR
    ld t1, 0(t0)
    li t2, 1
    bne t1, t2, failMS
    csrr t0, vstart
    li t1, 4
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
