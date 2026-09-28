/*
 * bpred_ras.S -- directed test for branch prediction stage (b).
 *
 * Covers, in M-mode Bare (no traps expected):
 *   - RAS push/pop: nested jal-ra calls (main->f1->f2) with jalr-ra
 *     returns; checks the accumulated value (depth-2 return discipline).
 *   - BTB target update: one jalr site jumping to two different targets
 *     across loop iterations (stale target must not persist).
 *   - Backward-branch loop (BTFN/BTB counter path): 100 iterations.
 *
 * PASS: tohost = 1. FAIL: tohost = (test_id << 1) | 1.
 *
 * Build & run (from repo root):
 *   riscv64-unknown-elf-gcc -march=rv64imafdc_zicsr_zifencei -mabi=lp64d \
 *     -nostdlib -nostartfiles -static \
 *     -T software/riscv-tests-env/rv64gch/link.ld software/tests/bpred_ras.S \
 *     -o /tmp/bpred_ras.elf
 *   python3 tools/scripts/elf2hex.py /tmp/bpred_ras.elf /tmp/bpred_ras.hex
 *   ./sim/verilator/obj_dir/Vtb_rv64gch_core +hex=/tmp/bpred_ras.hex
 */
#define TOHOST_ADDR 0x100000000
.section .text.init, "ax"
.globl _start
_start:
    li sp, 0x8000fffff0
    li s0, 0

    # --- nested calls: main -> f1 -> f2, returns unwind in order ---
    jal ra, f1
    li t5, 11
    bne s0, t5, fail10          # f1(+1) + f2(+10)

    # --- backward loop: 100 iterations ---
    li t4, 100
    li t5, 0
lloop:
    addi t5, t5, 1
    addi t4, t4, -1
    bnez t4, lloop
    li t6, 100
    bne t5, t6, fail20
    bnez t4, fail22             # t4 must be 0

    # --- polymorphic jalr: same site -> tgtA then tgtB ---
    li t4, 2
    la t0, tgtA
    la t1, tgtB
ploop:
    jalr x0, 0(t0)              # iter1 -> tgtA, iter2 -> tgtB
tgtA:
    li t2, 0xA
    mv t0, t1
    addi t4, t4, -1
    bnez t4, ploop
    j fail30                    # iter2 must not land here
tgtB:
    li t2, 0xB
    li t5, 1
    bne t4, t5, fail32          # one iteration consumed
    li t5, 0xB
    bne t2, t5, fail34          # landed on tgtB
    j pass

f1:
    addi s0, s0, 1
    addi sp, sp, -8
    sd ra, 0(sp)
    jal ra, f2
    ld ra, 0(sp)
    addi sp, sp, 8
    jalr x0, 0(ra)              # ret
f2:
    addi s0, s0, 10
    jalr x0, 0(ra)              # ret

pass:
    li t0, TOHOST_ADDR
    li t1, 1
    sd t1, 0(t0)
    j pass
fail10:
    li t0, 10
    j failrep
fail20:
    li t0, 20
    j failrep
fail22:
    li t0, 22
    j failrep
fail30:
    li t0, 30
    j failrep
fail32:
    li t0, 32
    j failrep
fail34:
    li t0, 34
    j failrep
failrep:
    # tohost = (id<<1)|1
    slli t0, t0, 1
    ori t0, t0, 1
    li t1, TOHOST_ADDR
    sd t0, 0(t1)
    j failrep
