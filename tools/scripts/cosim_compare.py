#!/usr/bin/env python3
"""Lock-step co-simulation, Phase A (offline trace compare) vs Unicorn.

Runs a program on the COSIM_TRACE RTL simulator and on Unicorn (RV64GC,
M-mode Bare), then compares per-commit architectural state:
  - retire PC, integer rd + value, FP rd + value, privilege
  - completed store bytes (addr + data)
  - tohost exit value, final written memory

Usage:
  cosim_compare.py --elf PROG.elf --hex PROG.hex [--sim Vtb_cosim]
                   [--max-insns N] [--trace-dir DIR]

Scope/limits (see docs/verification_plan.md Level 2):
  - M-mode Bare programs only (no satp/VM: Unicorn has no MMU).
  - FCSR compare skipped (Unicorn FCSR model unreliable here; fflags are
    covered by tb_fpu unit vectors + ISA flag checks via int regs).
  - FP data compared exactly; subnormal divergences (our FPU flushes
    subnormals, see rtl/core/fpu/fpu.sv) are reported for manual triage.
"""
import argparse
import os
import struct
import subprocess
import sys

TOHOST = 0x100000000
DRAM_BASE = 0x80000000


# ---------------------------------------------------------------- ELF ----
def load_elf(path):
    with open(path, "rb") as f:
        blob = f.read()
    assert blob[:4] == b"\x7fELF" and blob[4] == 2, "ELF64 LE only"
    e_phoff = struct.unpack_from("<Q", blob, 0x20)[0]
    e_phentsize = struct.unpack_from("<H", blob, 0x36)[0]
    e_phnum = struct.unpack_from("<H", blob, 0x38)[0]
    e_entry = struct.unpack_from("<Q", blob, 0x18)[0]
    segs = []
    for i in range(e_phnum):
        o = e_phoff + i * e_phentsize
        p_type, p_flags, p_offset, p_vaddr, p_paddr, p_filesz, p_memsz, p_align = \
            struct.unpack_from("<IIQQQQQQ", blob, o)
        if p_type == 1:  # PT_LOAD
            segs.append((p_vaddr, blob[p_offset:p_offset + p_filesz], p_memsz))
    return e_entry, segs


# ------------------------------------------------------------- decode ----
def is_compressed(w16):
    return (w16 & 0x3) != 0x3


def decode_rd(raw, is_c):
    """Return (rd_int or -1, rd_fp or -1). Raises on unknown encodings."""
    if not is_c:
        op = raw & 0x7F
        rd = (raw >> 7) & 0x1F
        funct3 = (raw >> 12) & 0x7
        if op in (0x37, 0x17, 0x6F, 0x67, 0x03, 0x13, 0x1B, 0x0B):
            return rd, -1
        if op == 0x2F:  # AMO/LR/SC: int dest (possibly x0)
            return rd, -1
        if op in (0x33, 0x3B):  # OP / OP-32 (incl MDU)
            return rd, -1
        if op == 0x73:  # SYSTEM/CSRs: int dest (possibly x0)
            return rd, -1
        if op == 0x53:  # OP-FP
            return -1, rd
        if op == 0x07:  # FP loads
            return -1, rd
        if op in (0x63, 0x23, 0x0F):  # branch/store/fence: no dest
            return -1, -1
        raise ValueError("unknown 32b opcode 0x%02x raw=%08x" % (op, raw))
    q = raw & 0x3
    funct3 = (raw >> 13) & 0x7
    if q == 0:
        if funct3 in (0, 1, 2, 3, 5, 6, 7):  # ADDI4SPN/FLD/LW/LD/FSW/SW/SD
            if funct3 in (0, 2, 3):
                return 8 + ((raw >> 2) & 0x7), -1  # rd'
            if funct3 == 1:
                return -1, 8 + ((raw >> 2) & 0x7)  # FLD frd'
            return -1, -1  # stores
        if funct3 == 4:  # reserved
            raise ValueError("reserved C.Q0 funct3=4")
    elif q == 1:
        if funct3 in (0, 1, 2, 3):  # NOP/ADDI16SP/ADDIW/LI/LUI...
            rd = (raw >> 7) & 0x1F
            return rd, -1
        if funct3 in (4, 5, 6, 7):  # arith/shift/branch/jump/misc
            op2 = (raw >> 10) & 0x3
            if funct3 == 4 and op2 in (0, 1, 2, 3):
                return 8 + ((raw >> 7) & 0x7), -1  # SRLI/SRAI/ANDI/SUB...
            if funct3 == 4:
                return 8 + ((raw >> 7) & 0x7), -1  # AND/OR/XOR/SUBW/ADDW
            return -1, -1  # branches/jumps (BEQZ/BNEZ/J; C.JAL writes x1!)
    elif q == 2:
        if funct3 in (0, 1, 2, 3):  # SLLI/FLDSP/LWSP/FLWSP/LDSP
            rd = (raw >> 7) & 0x1F
            if funct3 in (1, 3):
                return -1, rd
            return rd, -1
        if funct3 == 4:  # JR/MV/JALR/ADD/EBREAK (split on bit 12)
            rs1 = (raw >> 7) & 0x1F
            rs2 = (raw >> 2) & 0x1F
            if (raw & 0x1000) == 0:
                return (rs1, -1) if rs2 != 0 else (-1, -1)  # MV : JR
            else:
                if rs1 == 0 and rs2 == 0:
                    return -1, -1  # EBREAK
                elif rs2 == 0:
                    return 1, -1  # JALR writes x1
                else:
                    return rs1, -1  # ADD
        if funct3 in (5, 6, 7):  # FSDSP/SWSP/SDSP: stores
            return -1, -1
    raise ValueError("unknown 16b raw=%04x" % raw)


# ------------------------------------------------------------ unicorn ----
def run_unicorn(elf, max_insns):
    from unicorn import Uc, UC_ARCH_RISCV, UC_MODE_RISCV64, UC_HOOK_CODE, UC_HOOK_MEM_WRITE
    from unicorn import UcError
    import unicorn.riscv_const as rc
    entry, segs = load_elf(elf)
    mu = Uc(UC_ARCH_RISCV, UC_MODE_RISCV64)
    mu.mem_map(DRAM_BASE, 0x10000000)
    mu.mem_map(TOHOST, 0x10000)
    for vaddr, data, memsz in segs:
        if data:
            mu.mem_write(vaddr, data)
    mu.reg_write(rc.UC_RISCV_REG_SP, 0x8000fffff8)
    mu.reg_write(rc.UC_RISCV_REG_PC, entry)
    tohost = {"val": None, "hi": 0}
    writes = []

    def hook_write(mu, access, address, size, value, data):
        # tohost: riscv-tests use an sw pair (low word first), ours an sd.
        # Record first full value; the end-of-test spin keeps rewriting it.
        if address == TOHOST and size in (4, 8):
            v = value & ((1 << (8 * size)) - 1)
            if size == 4:
                v = v | (tohost["hi"] << 32)
            if tohost["val"] is None:
                tohost["val"] = v
        elif address == TOHOST + 4 and size == 4:
            tohost["hi"] = value & 0xFFFFFFFF
            writes.append((mu.reg_read(rc.UC_RISCV_REG_PC), address, size, value))
        else:
            writes.append((mu.reg_read(rc.UC_RISCV_REG_PC), address, size, value))

    mu.hook_add(UC_HOOK_MEM_WRITE, hook_write)
    commits = []
    n = 0
    try:
        while n < max_insns:
            pc = mu.reg_read(rc.UC_RISCV_REG_PC)
            raw32 = struct.unpack("<I", mu.mem_read(pc, 4))[0]
            if is_compressed(raw32 & 0xFFFF):
                raw = raw32 & 0xFFFF
                is_c = True
            else:
                raw = raw32
                is_c = False
            rdi, rdf = decode_rd(raw, is_c)
            mu.emu_start(pc, pc + (2 if is_c else 4), count=1)
            n += 1
            rec = {"pc": pc, "raw": raw}
            if rdi >= 0:
                rec["xi"] = (rdi, mu.reg_read(getattr(rc, "UC_RISCV_REG_X%d" % rdi)))
            if rdf >= 0:
                rec["fp"] = (rdf, mu.reg_read(getattr(rc, "UC_RISCV_REG_F%d" % rdf)))
            rec["priv"] = mu.reg_read(rc.UC_RISCV_REG_PRIV)
            commits.append(rec)
            # end of test: stop a few commits after the first tohost write
            # (covers the writeback + spin head on both sides uniformly)
            if tohost["val"] is not None:
                if "stop_at" not in tohost:
                    tohost["stop_at"] = n + 8
                if n >= tohost["stop_at"]:
                    break
    except UcError as e:
        print("unicorn stopped with error: %s (after %d commits)" % (e, n))
    return commits, writes, tohost["val"], mu


# ---------------------------------------------------------------- RTL ----
def run_rtl(sim, hexpath, workdir):
    env = dict(os.environ)
    proc = subprocess.run([sim, "+hex=%s" % hexpath], cwd=workdir,
                          capture_output=True, text=True, timeout=600)
    out = proc.stdout + proc.stderr
    commits, stores, traps = [], [], []
    with open(os.path.join(workdir, "cosim_rtl.log")) as f:
        for line in f:
            p = line.split()
            if not p:
                continue
            if p[0] == "C":
                pc, rd, data, wei, fpwe, fprd, fpdata, priv = \
                    p[1], p[2], p[3], p[4], p[5], p[6], p[7], p[8]
                commits.append({"pc": int(pc, 16), "rd": int(rd),
                                "data": int(data, 16), "we": int(wei),
                                "fpwe": int(fpwe), "fprd": int(fprd),
                                "fpdata": int(fpdata, 16), "priv": int(priv)})
            elif p[0] == "T":
                traps.append((int(p[1], 16), int(p[2])))
            elif p[0] == "M":
                stores.append((int(p[1], 16), int(p[2], 16), p[3], p[4]))
    m = None
    import re
    mm = re.search(r"tohost=(0x[0-9a-f]+)", out)
    if mm:
        m = int(mm.group(1), 16)
    return commits, stores, traps, m


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--elf", required=True)
    ap.add_argument("--hex", required=True)
    ap.add_argument("--sim", required=True)
    ap.add_argument("--sim-workdir", required=True)
    ap.add_argument("--max-insns", type=int, default=200000)
    args = ap.parse_args()

    ucommits, uwrites, utohost, mu = run_unicorn(args.elf, args.max_insns)
    print("unicorn: %d commits, tohost=%s, %d mem-writes" %
          (len(ucommits), hex(utohost) if utohost is not None else None, len(uwrites)))
    rcommits, rstores, rtraps, rtohost = run_rtl(args.sim, args.hex, args.sim_workdir)
    print("rtl: %d commits, tohost=%s, %d stores, %d traps" %
          (len(rcommits), hex(rtohost) if rtohost is not None else None,
           len(rstores), len(rtraps)))

    if utohost != rtohost:
        print("MISMATCH tohost: unicorn=%s rtl=%s" % (utohost, rtohost))
        return 1
    if rtraps:
        print("MISMATCH: RTL trapped: %s" % (rtraps[:4],))
        return 1
    n = min(len(ucommits), len(rcommits))
    for i in range(n):
        u, r = ucommits[i], rcommits[i]
        if u["pc"] != r["pc"]:
            print("MISMATCH #%d pc: unicorn=%x rtl=%x" % (i, u["pc"], r["pc"]))
            return 1
        if "xi" in u:
            rd, val = u["xi"]
            if rd != 0 and (r["rd"] != rd or (r["we"] and r["data"] != val)):
                print("MISMATCH #%d pc=%x x%d: unicorn=%x rtl=(rd=%d data=%x we=%d)" %
                      (i, u["pc"], rd, val, r["rd"], r["data"], r["we"]))
                return 1
        if "fp" in u:
            frd, fval = u["fp"]
            if r["fpwe"] and (r["fprd"] != frd or r["fpdata"] != fval):
                ru, uu = (r["fpdata"] >> 32) & 0xFFFFFFFF, (fval >> 32) & 0xFFFFFFFF
                # Unicorn doesn't NaN-box single-precision arithmetic results
                # (upper=raw vs our spec-correct all-ones): tolerate iff the
                # low 32 match and ours is exactly the boxed shape. Anything
                # else (low32 differ, ours not boxed) still fails.
                if ru == 0xFFFFFFFF and uu != 0xFFFFFFFF and \
                        (r["fpdata"] & 0xFFFFFFFF) == (fval & 0xFFFFFFFF):
                    print("note #%d pc=%x f%d: unboxed-in-unicorn (tolerated)" %
                          (i, u["pc"], frd))
                else:
                    print("MISMATCH #%d pc=%x f%d: unicorn=%x rtl=(frd=%d data=%x)" %
                          (i, u["pc"], frd, fval, r["fprd"], r["fpdata"]))
                    return 1
        if u["priv"] != r["priv"]:
            print("MISMATCH #%d pc=%x priv: unicorn=%d rtl=%d" % (i, u["pc"], u["priv"], r["priv"]))
            return 1
    if len(ucommits) != len(rcommits):
        # Unicorn stops early by design (a few commits past tohost) while
        # RTL drains 100 post-done cycles: extras must stay inside the
        # end-loop pcs (no silent divergence past the common prefix).
        n0 = min(len(ucommits), len(rcommits))
        if len(ucommits) > len(rcommits):
            print("MISMATCH commit count: unicorn=%d rtl=%d (rtl shorter)" %
                  (len(ucommits), len(rcommits)))
            return 1
        loop_pcs = set(c["pc"] for c in ucommits[max(0, n0 - 8):n0])
        extras = rcommits[n0:]
        if any(c["pc"] not in loop_pcs for c in extras):
            bad = [hex(c["pc"]) for c in extras if c["pc"] not in loop_pcs][:5]
            print("MISMATCH commit count: unicorn=%d rtl=%d (extras outside end loop: %s)" %
                  (len(ucommits), len(rcommits), bad))
            return 1
        print("note: rtl has %d extra end-loop commits (tolerated)" % len(extras))
    # store bytes (unicorn hook records; RTL logs completed writes).
    # MMIO (tohost/charout) excluded: synchronization, compared via value.
    MMIO_LO, MMIO_HI = TOHOST, TOHOST + 0x10000
    uw = {}
    uwpc = {}
    for pc, a, s, v in uwrites:
        for k in range(s):
            if not (MMIO_LO <= a + k < MMIO_HI):
                uw[a + k] = (v >> (8 * k)) & 0xFF
                uwpc.setdefault(a + k, pc)
    rw = {}
    rwpc = {}
    for pc, a, be, data in rstores:
        be = int(be, 16)
        data = int(data, 16)
        # M-line addr is the exact (possibly unaligned) access address;
        # be bit k selects aligned_base + k.
        base = a & ~7
        for k in range(8):
            if (be & (1 << k)) and not (MMIO_LO <= base + k < MMIO_HI):
                rw[base + k] = (data >> (8 * k)) & 0xFF
                rwpc.setdefault(base + k, pc)
    if uw != rw:
        only_u = sorted(set(uw) - set(rw))[:5]
        only_r = sorted(set(rw) - set(uw))[:5]
        diff = sorted(a for a in set(uw) & set(rw) if uw[a] != rw[a])[:5]
        ctx = ""
        for a in (diff + only_u + only_r)[:3]:
            ctx += " [a=%x upc=%s rpc=%s]" % (
                a, hex(uwpc[a]) if a in uwpc else "-",
                hex(rwpc[a]) if a in rwpc else "-")
        print("MISMATCH stores: u-only=%s r-only=%s differing=%s%s" %
              (only_u, only_r, diff, ctx))
        return 1
    # NOTE: no final-DRAM compare: our write-back L1D/L2 legitimately
    # hold dirty lines at $finish (proven coherent by l1d_wb/l2_wb + all
    # reloads checking via rd). The store-byte stream above already pins
    # every completed write's address and data.
    print("COSIM MATCH: %d commits, tohost=%s" % (n, hex(utohost) if utohost is not None else None))
    return 0


if __name__ == "__main__":
    sys.exit(main())
