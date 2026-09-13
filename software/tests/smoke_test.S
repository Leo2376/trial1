/*
 * rv64gch smoke test - hand-assembled RV64I program
 *
 * Boots from 0x800000000 (DRAM_BASE), writes 1 to the tohost
 * mailbox at 0x100000000 (HOSTIF_BASE), then loops forever.
 * The testbench detects tohost != 0 and reports TEST PASSED.
 *
 * Encoding is little-endian; each 64-bit DRAM word holds two
 * 32-bit instructions (low half = lower address, high half = upper).
 */
    .org 0x800000000

    addi  x1, x0, 1          # x1 = 1
    slli  x1, x1, 32         # x1 = 0x100000000 (HOSTIF_BASE)
    addi  x2, x0, 1          # x2 = 1 (TOHOST_PASS)
    sd    x2, 0(x1)          # *tohost = 1
    beq   x0, x0, 0          # infinite loop
