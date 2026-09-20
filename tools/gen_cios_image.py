#!/usr/bin/env python3
"""Regenerate the deckc CIOS golden image from the C sources.

CIOS = the verbatim DeckOS kernel/syslog.c compiled by the deckc toolchain.
Pipeline:
  1. deckc compiles the BSP + CIOS main + vendored syslog.c into one .s
  2. the host assembler assembles it (embedding crt0.s)
  3. the interpreter (software/deckc/sim.py) runs it and sanity-checks the
     transcript + exit mailbox
  4. the word image is written as the golden artefacts below

The golden test in software/deckc/test_deckc.py re-runs steps 1-2 and requires
the .hex / .svh to match, and re-runs the step-3 transcript checks, so update
these after ANY deckc toolchain / runtime / BSP / CIOS source change.

DeckOS provenance: sim/programs/cdecko/kernel/syslog.c and
sim/programs/cdecko/include/syslog.h are unmodified copies of
DeckOS/kernel/syslog.c and DeckOS/include/syslog.h.
"""

from __future__ import annotations

import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
BUILD = ROOT / "build" / "gen"
SOFTWARE = ROOT / "software"
DECKC = SOFTWARE / "deckc"
BSP = DECKC / "bsp"
CIOS = ROOT / "sim" / "programs" / "cdecko"
OUT = ROOT / "sim" / "programs"
ISA = ROOT / "isa" / "isa.json"

sys.path.insert(0, str(SOFTWARE))
sys.path.insert(0, str(SOFTWARE / "assembler"))


def sources() -> list[Path]:
    return [BSP / "bsp.c", BSP / "main_deckc.c", CIOS / "kernel" / "syslog.c"]


def include_dirs() -> list[Path]:
    return [BSP, CIOS / "include"]


def build_app(out_s: Path, srcs, incs):
    """deckc-compile any source list and assemble; return (words, prog)."""
    from deckc.deckc import compile_c
    from assembler import Assembler, load_isa

    compile_c([str(s) for s in srcs], [str(d) for d in incs], str(out_s))
    asm = Assembler(load_isa(str(ISA)))
    prog = asm.assemble_file(str(out_s))
    if not prog.ok:
        print("assembly failed:", prog.errors, file=sys.stderr)
        raise SystemExit(1)
    return prog.word_image(), prog


def compile_and_assemble(out_s: Path):
    return build_app(out_s, sources(), include_dirs())


def hex_text(img: list) -> str:
    lines = ["@00000000"]
    lines += [f"{w:08X}" for w in img]
    lines.append("$ERASE(0, 0x10000)")
    return "\n".join(lines) + "\n"


def svh_text(img: list, proto: str = "CDECKO_CIOS_NWORDS",
             tool: str = "tools/gen_cios_image.py") -> str:
    n = len(img)
    body = "\n".join(f"        PW[{i}] = 32'h{img[i]:08X};" for i in range(n))
    return (
        f"// Auto-generated (deckc BSP + main + verbatim DeckOS syslog.c via "
        f"{tool}).\n"
        f"// {n} contiguous words from byte 0 ({n * 4} bytes).\n"
        f"localparam int {proto} = {n};\n"
        f"initial begin : prog_words\n{body}\n    end\n"
    )


def write_artifacts(img: list) -> tuple[Path, Path]:
    out_hex = OUT / "cdecko_cios.hex"
    out_svh = OUT / "cdecko_cios_words.svh"
    out_hex.write_text(hex_text(img))
    out_svh.write_text(svh_text(img))
    return out_hex, out_svh


TRANSCRIPT_NEEDLES = [
    "ring log ready (64 slots)",
    "boot complete",
    "brownout detected",
    "allocation failed",
    "scan started",
    "syslog cleared  (5 total entries discarded)",
    "(log empty)",
]


def verify(img: list[int]) -> list[str]:
    """Run the interpreter over the image and report transcript/mailbox issues."""
    from deckc.sim import run, load_isa, MAILBOX

    isa = load_isa(str(ISA))
    try:
        r = run([(4 * i, w) for i, w in enumerate(img)], isa)
    except RuntimeError as e:
        return [f"interpreter: {e}"]
    mb = int.from_bytes(r['mem'][MAILBOX:MAILBOX + 4], 'little')
    errs = []
    if mb != 5:
        errs.append(f"mailbox {mb:#x} != 5")
    text = bytes(r['out']).decode('utf-8', 'backslashreplace')
    for n in TRANSCRIPT_NEEDLES:
        if n not in text:
            errs.append(f"transcript lacks {n!r}")
    return errs


def main() -> int:
    build = ROOT / "build" / "gen"
    build.mkdir(parents=True, exist_ok=True)
    out_s = build / "cdecko_cios.s"
    img, _prog = compile_and_assemble(out_s)
    print(f"compiled and assembled {out_s} ({len(img)} words)")
    hexf, svhf = write_artifacts(img)
    errs = verify(img)
    if errs:
        print("CIOS sanity FAILED:", file=sys.stderr)
        for e in errs:
            print("  -", e, file=sys.stderr)
        return 1
    print(f"wrote {hexf} ({len(img)} words, {len(img) * 4} bytes)")
    print(f"wrote {svhf}")
    print("CIOS sanity OK (mailbox=5, transcript complete)")
    return 0


if __name__ == "__main__":
    sys.exit(main())