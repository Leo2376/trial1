#!/usr/bin/env python3
# Merge multiple ASAP7 .lib files (one per cell category) into a single liberty
# file consumable by Yosys (abc / dfflibmap / stat -liberty).
#
# ASAP7 ships each cell category as a separate `library (...)` declaration. Yosys
# `read_liberty` accepts a file containing multiple library blocks, but some
# flows prefer a single consolidated library. This script concatenates them
# and de-duplicates top-level `default_*` directives that would otherwise
# appear once per source file and trigger parser warnings.
#
# Usage: merge_libs.py <lib_dir> <out_lib> <lib1> [<lib2> ...]

import sys
import os
from pathlib import Path


def main(argv: list[str]) -> int:
    if len(argv) < 4:
        sys.stderr.write(
            "usage: merge_libs.py <lib_dir> <out_lib> <lib1> [<lib2> ...]\n"
        )
        return 2

    _lib_dir = Path(argv[1])
    out_lib = Path(argv[2])
    in_libs = [Path(p) for p in argv[3:]]

    out_lib.parent.mkdir(parents=True, exist_ok=True)

    seen_defaults: set[str] = set()
    with out_lib.open("w") as out:
        for lib in in_libs:
            if not lib.exists():
                sys.stderr.write(f"warning: missing lib {lib}\n")
                continue
            with lib.open() as fh:
                for line in fh:
                    stripped = line.strip()
                    # De-duplicate global default_* directives across files.
                    if stripped.startswith("default_"):
                        key = stripped.split(":", 1)[0]
                        if key in seen_defaults:
                            continue
                        seen_defaults.add(key)
                    out.write(line)
                    # Ensure a blank separator between concatenated files.
            out.write("\n")

    sys.stderr.write(f"merged {len(in_libs)} libs -> {out_lib}\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
