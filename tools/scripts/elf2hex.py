#!/usr/bin/env python3
import sys, struct, os

def die(msg):
    sys.stderr.write("error: " + msg + "\n")
    sys.exit(1)

if len(sys.argv) != 3:
    die("usage: elf2hex.py <input.elf> <output.vh>")

infile, outfile = sys.argv[1], sys.argv[2]
base = 0x000080000000

with open(infile, "rb") as f:
    blob = f.read()

if len(blob) < 64 or blob[:4] != b"\x7fELF":
    die("not an ELF file: " + infile)
if blob[4] != 2:
    die("only ELF64 supported")
if blob[5] != 1:
    die("only little-endian ELF supported")

is32 = blob[4]  # class already checked
e_shoff = struct.unpack_from("<Q", blob, 0x28)[0]
e_shentsize = struct.unpack_from("<H", blob, 0x3a)[0]
e_shnum    = struct.unpack_from("<H", blob, 0x3c)[0]

sects = []
for i in range(e_shnum):
    off = e_shoff + i * e_shentsize
    (sh_name, sh_type, sh_flags, sh_addr, sh_offset, sh_size) = struct.unpack_from(
        "<IIQQQQ", blob, off)
    if sh_type == 1 and (sh_flags & 0x2) and sh_size > 0:
        sects.append((sh_addr, sh_offset, sh_size))

if not sects:
    die("no loadable PT_LOAD sections found")

mmap = {}
for (sh_addr, sh_offset, sh_size) in sects:
    data = blob[sh_offset:sh_offset + sh_size]
    for i, b in enumerate(data):
        a = sh_addr + i - base
        if a >= 0:
            mmap[a] = b

if not mmap:
    die("no bytes in DRAM window")

maxa = max(mmap.keys())
nwords = (maxa // 8) + 1

with open(outfile, "w") as f:
    for w in range(nwords):
        word = 0
        for b in range(8):
            a = w * 8 + b
            if a in mmap:
                word |= mmap[a] << (b * 8)
        f.write("%016x\n" % word)

print("wrote %d words to %s" % (nwords, outfile))
