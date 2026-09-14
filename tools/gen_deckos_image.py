#!/usr/bin/env python3
"""Regenerate the DeckOS console golden images from the single source of truth.

Reassembles deckos-port/deckcpu/console.s (which includes its HAL) with the
the host assembler and rewrites:
  - sim/programs/deckos_console.hex         @-addressed byte image (golden)
  - sim/programs/deckos_console_words.svh   word include the testbench pokes
                                            into RAM through the write port

The golden test in software/assembler/test_assembler.py re-assembles
sim/programs/deckos_console.s (a wrapper that .includes the same source) and
requires those two files to match, so run this after ANY console.s/HAL change,
then re-run `make test`.
"""

import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / "sim" / "programs"
SRC = ROOT / "deckos-port" / "deckcpu" / "console.s"
ISA = ROOT / "isa" / "isa.json"

sys.path.insert(0, str(ROOT / "software" / "assembler"))
sys.path.insert(0, str(ROOT / "tools"))

from assembler import Assembler, load_isa  # noqa: E402


def main() -> int:
    asm = Assembler(load_isa(str(ISA)))
    prog = asm.assemble_file(str(SRC))
    if not prog.ok:
        print("assembly failed:", prog.errors, file=sys.stderr)
        return 1

    img = prog.word_image()
    out_hex = OUT / "deckos_console.hex"
    out_svh = OUT / "deckos_console_words.svh"

    prog.write_hex(out_hex)

    n = len(img)
    body = "\n".join(f"        PW[{i}] = 32'h{img[i]:08X};" for i in range(n))
    inc = (
        "// Auto-generated (from deckos-port/deckcpu/console.s via "
        "software/assembler).\n"
        f"// {n} contiguous words from byte 0 ({n * 4} bytes).\n"
        f"localparam int DECKOS_CONSOLE_NWORDS = {n};\n"
        f"initial begin : prog_words\n{body}\n    end\n"
    )
    out_svh.write_text(inc)

    print(f"wrote {out_hex} ({n} words, {n * 4} bytes)")
    print(f"wrote {out_svh}")
    return 0


if __name__ == "__main__":
    sys.exit(main())