#!/usr/bin/env python3
"""Convert ELF to Verilog $readmemh hex format (64-bit words, little-endian)."""
import sys
import subprocess
import struct

def elf_to_hex(elf_path, output_path, base_addr=0x80000000):
    # Use objcopy to extract .text as binary
    result = subprocess.run([
        'riscv64-unknown-elf-objcopy',
        '-O', 'binary',
        '--only-section=.text',
        '--only-section=.text.init',
        '--only-section=.data',
        '--only-section=.rodata',
        elf_path, '/tmp/elf_bin.bin'
    ], capture_output=True)
    if result.returncode != 0:
        # Try without filtering sections
        result = subprocess.run([
            'riscv64-unknown-elf-objcopy',
            '-O', 'binary',
            elf_path, '/tmp/elf_bin.bin'
        ], capture_output=True)
        if result.returncode != 0:
            print(f"objcopy failed: {result.stderr.decode()}")
            return False

    with open('/tmp/elf_bin.bin', 'rb') as f:
        data = f.read()

    # Pad to 8-byte alignment
    if len(data) % 8 != 0:
        data += b'\x00' * (8 - len(data) % 8)

    # Convert to 64-bit little-endian words
    words = []
    for i in range(0, len(data), 8):
        word = struct.unpack('<Q', data[i:i+8])[0]
        words.append(f"{word:016x}")

    with open(output_path, 'w') as f:
        f.write('\n'.join(words) + '\n')

    print(f"Generated {output_path}: {len(words)} words ({len(data)} bytes)")
    return True

if __name__ == '__main__':
    if len(sys.argv) < 3:
        print("Usage: elf_to_hex.py <elf_file> <output_hex> [base_addr]")
        sys.exit(1)
    elf_path = sys.argv[1]
    output_path = sys.argv[2]
    base_addr = int(sys.argv[3], 0) if len(sys.argv) > 3 else 0x80000000
    elf_to_hex(elf_path, output_path, base_addr)