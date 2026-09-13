#!/usr/bin/env python3
"""Generate a Verilog $readmemh hex file for the rv64gch smoke test.

This script hand-encodes a minimal RV64I program that writes 1 to the
tohost mailbox and loops forever. It produces a $readmemh-compatible
file with one 64-bit word per line (little-endian within each word:
the lower-addressed 32-bit instruction in bits [31:0], the higher in
bits [63:32]).

Usage:
    python3 gen_smoke_hex.py <output_file>

If no output file is given, writes to stdout.
"""
import sys

# Hand-encoded RV64I instructions (32-bit little-endian words)
INSTRS = [
    0x00100093,  # addi  x1, x0, 1      ; x1 = 1
    0x02009093,  # slli  x1, x1, 32     ; x1 = 0x100000000 (HOSTIF_BASE)
    0x00100113,  # addi  x2, x0, 1      ; x2 = 1 (TOHOST_PASS)
    0x0020B023,  # sd    x2, 0(x1)      ; *tohost = 1
    0x00000063,  # beq   x0, x0, 0      ; infinite loop
]


def main():
    out_path = sys.argv[1] if len(sys.argv) > 1 else None
    lines = []
    for i in range(0, len(INSTRS), 2):
        lo = INSTRS[i]
        hi = INSTRS[i + 1] if i + 1 < len(INSTRS) else 0
        word = (hi << 32) | lo
        lines.append(f"{word:016x}")
    text = "\n".join(lines) + "\n"
    if out_path:
        with open(out_path, "w") as f:
            f.write(text)
    else:
        sys.stdout.write(text)


if __name__ == "__main__":
    main()
