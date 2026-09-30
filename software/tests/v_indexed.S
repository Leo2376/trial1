/*
 * v_indexed.S -- RVV indexed ld/st bring-up (vluxei8/vsuxei8 via VLSU).
 *
 * M setup: HS identity tables (satp Sv39: root/L1/L0a identity + tohost
 * root[4] leaf) plus an L0b remap page (VA 0x80200000 -> PA 0x80020000,
 * A=D=0 to exercise the walker A/D path through the VLSU-driven port).
 *
 * S phase 1 (config): vsetvli e8m1ta_ma -> vl==32 (VLMAX).
 * S phase 2 (gather/scatter): 32B scalar pattern at BASE1, index bytes
 *   {0,4,...,28} at BASE1+32; vl=8: vle8.v v2,(idx) ->
 *   vluxei8.v v0,(BASE1),v2 -> vsuxei8.v v0,(BASE2),v2; scalar lb
 *   compare of the 8 gathered bytes.
 * S phase 3 (reversed indices): idx {7..0} at BASE1+40; gather reversed
 *   -> vse8.v unit store to BASE2+16; scalar lb compare reversed.
 * S phase 4 (load fault): vl=8, idx {0,4,...}, vluxei8.v from
 *   0x80200FFC (elem 0 mapped, elem 1 at 0x80201000 unmapped) -> load
 *   page fault to M (state==1: mcause==13, vstart==1, mtval==0x80201000).
 * S phase 5 (store fault): same indices, vsuxei8.v to 0x80200FFC
 *   (state==2: mcause==15, vstart==1, mtval==0x80201000) -> PASS.
 *
 * PASS: tohost = 1. FAIL: tohost = (id << 1) | 1, or (mcause << 1) | 1.
 *
 * Build & run (from repo root):
 *   riscv64-unknown-elf-gcc -march=rv64imafdcv_zicsr_zifencei -mabi=lp64d \
 *     -nostdlib -nostartfiles -static \
 *     -T software/riscv-tests-env/rv64gch/link.ld \
 *     software/tests/v_indexed.S -o /tmp/v_indexed.elf
 *   python3 tools/scripts/elf2hex.py /tmp/v_indexed.elf /tmp/v_indexed.hex
 *   ./sim/verilator/obj_dir/Vtb_rv64gch_core +hex=/tmp/v_indexed.hex
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

    # --- 32B pattern at BASE1, index bytes at BASE1+32/40, zero rest ---
    li t0, BASE1
    li t1, 0x0123456789ABCDEF
    sd t1, 0(t0)
    li t1, 0xFEDCBA9876543210
    sd t1, 8(t0)
    li t1, 0xAAAAAAAAAAAAAAAA
    sd t1, 16(t0)
    li t1, 0x5555555555555555
    sd t1, 24(t0)
    li t0, BASE1 + 32           # idx {0,4,...,28}
    li t1, 0
    sb t1, 0(t0)
    li t1, 4
    sb t1, 1(t0)
    li t1, 8
    sb t1, 2(t0)
    li t1, 12
    sb t1, 3(t0)
    li t1, 16
    sb t1, 4(t0)
    li t1, 20
    sb t1, 5(t0)
    li t1, 24
    sb t1, 6(t0)
    li t1, 28
    sb t1, 7(t0)
    li t0, BASE1 + 40           # idx {7,6,...,0}
    li t1, 7
    sb t1, 0(t0)
    li t1, 6
    sb t1, 1(t0)
    li t1, 5
    sb t1, 2(t0)
    li t1, 4
    sb t1, 3(t0)
    li t1, 3
    sb t1, 4(t0)
    li t1, 2
    sb t1, 5(t0)
    li t1, 1
    sb t1, 6(t0)
    sb zero, 7(t0)
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
    bne t0, t1, fail80

    # --- phase 2: vl=8 gather/scatter round-trip ---
    vsetivli zero, 8, e8, m1, ta, ma
    li t0, BASE1 + 32
    vle8.v v2, (t0)
    li t0, BASE1
    vluxei8.v v0, (t0), v2
    li t0, BASE2
    vsuxei8.v v0, (t0), v2
    li t0, BASE1
    li t1, BASE2
    lb t2, 0(t0)
    lb t3, 0(t1)
    bne t2, t3, fail82
    lb t2, 4(t0)
    lb t3, 4(t1)
    bne t2, t3, fail84
    lb t2, 8(t0)
    lb t3, 8(t1)
    bne t2, t3, fail86
    lb t2, 12(t0)
    lb t3, 12(t1)
    bne t2, t3, fail88
    lb t2, 16(t0)
    lb t3, 16(t1)
    bne t2, t3, fail8A
    lb t2, 20(t0)
    lb t3, 20(t1)
    bne t2, t3, fail8C
    lb t2, 24(t0)
    lb t3, 24(t1)
    bne t2, t3, fail8E
    lb t2, 28(t0)
    lb t3, 28(t1)
    bne t2, t3, fail90

    # --- phase 3: reversed gather, unit store ---
    li t0, BASE1 + 40
    vle8.v v3, (t0)
    li t0, BASE1
    vluxei8.v v1, (t0), v3
    li t0, BASE2 + 16
    vse8.v v1, (t0)
    li t0, BASE1
    li t1, BASE2 + 16
    lb t2, 7(t0)
    lb t3, 0(t1)
    bne t2, t3, fail92
    lb t2, 6(t0)
    lb t3, 1(t1)
    bne t2, t3, fail94
    lb t2, 5(t0)
    lb t3, 2(t1)
    bne t2, t3, fail96
    lb t2, 4(t0)
    lb t3, 3(t1)
    bne t2, t3, fail98
    lb t2, 3(t0)
    lb t3, 4(t1)
    bne t2, t3, fail9A
    lb t2, 2(t0)
    lb t3, 5(t1)
    bne t2, t3, fail9C
    lb t2, 1(t0)
    lb t3, 6(t1)
    bne t2, t3, fail9E
    lb t2, 0(t0)
    lb t3, 7(t1)
    bne t2, t3, failA0

    # --- phase 4: faulting gather (elem 1 unmapped) ---
    vsetivli zero, 8, e8, m1, ta, ma
    li t0, STATE_ADDR
    li t1, 1
    sd t1, 0(t0)
    li t0, REMAP_VA + 0xFFC     # elem0 @0x80200FFC mapped, elem1 @+4 faults
    vluxei8.v v0, (t0), v2      # v2 still {0,4,...} from phase 2
    j failFF                    # must trap, never fall through

    # --- phase 5 (reached only via handler state machine; see below) ---
phase5:
    vsetivli zero, 8, e8, m1, ta, ma
    li t0, BASE1
    vluxei8.v v0, (t0), v2      # reload data (mapped gather)
    li t0, STATE_ADDR
    li t1, 2
    sd t1, 0(t0)
    li t0, REMAP_VA + 0xFFC
    vsuxei8.v v0, (t0), v2      # elem1 store faults
    j failFF                    # must trap, never fall through

fail80: li t3, 0x80; j failT3
fail82: li t3, 0x82; j failT3
fail84: li t3, 0x84; j failT3
fail86: li t3, 0x86; j failT3
fail88: li t3, 0x88; j failT3
fail8A: li t3, 0x8A; j failT3
fail8C: li t3, 0x8C; j failT3
fail8E: li t3, 0x8E; j failT3
fail90: li t3, 0x90; j failT3
fail92: li t3, 0x92; j failT3
fail94: li t3, 0x94; j failT3
fail96: li t3, 0x96; j failT3
fail98: li t3, 0x98; j failT3
fail9A: li t3, 0x9A; j failT3
fail9C: li t3, 0x9C; j failT3
fail9E: li t3, 0x9E; j failT3
failA0: li t3, 0xA0; j failT3
failFF: li t3, 0xFF; j failT3
failT3:
    slli t3, t3, 1
    ori t3, t3, 1
    li t1, TOHOST_ADDR
    sd t3, 0(t1)
    j failT3

.balign 4
m_trap:                         # M-mode vector-fault state machine
    li t0, STATE_ADDR
    ld t1, 0(t0)
    li t2, 1
    beq t1, t2, check1
    li t2, 2
    beq t1, t2, check2
    j failM                     # unexpected state
check1:                         # load fault: cause 13, vstart 1
    csrr t0, mcause
    li t1, 13
    bne t0, t1, failM
    csrr t0, vstart
    li t1, 1
    bne t0, t1, failMS
    csrr t0, mtval
    li t1, REMAP_VA + 0x1000
    bne t0, t1, failMS
    # resume S at phase5 for the store-fault half (vstart already 1;
    # phase5 re-gathers, so restart is clean)
    csrw vstart, zero
    la t0, phase5
    csrw mepc, t0
    mret
check2:                         # store fault: cause 15, vstart 1
    csrr t0, mcause
    li t1, 15
    bne t0, t1, failM
    csrr t0, vstart
    li t1, 1
    bne t0, t1, failMS
    csrr t0, mtval
    li t1, REMAP_VA + 0x1000
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
    csrr t0, mcause
    slli t0, t0, 1
    ori t0, t0, 1
    li t1, TOHOST_ADDR
    sd t0, 0(t1)
    j failM
