#!/usr/bin/env python3
"""Regenerate the deckc console ("cshell") golden image from the C sources.

The console is an interactive UART shell written in C (software/deckc/app/
console.c) over the deckc runtime + BSP + the verbatim DeckOS syslog module.
This script deckc-compiles app/console.c + bsp.c + string.c + syslog.c,
assembles the runtime + image, runs the interpreter drive-by (scripted UART RX
session) against it, and writes the golden hex + svh artefacts.

test_deckc.py re-runs those steps, and cshell_tb.sv / cshell_term_tb.sv boot
the svh, so rerun after any toolchain / runtime / BSP / app / syslog change.
"""

from __future__ import annotations

import sys
from pathlib import Path

from gen_cios_image import (BSP, BUILD, CIOS, ISA, OUT,
                            build_app, hex_text, svh_text)

APP = Path(__file__).resolve().parents[1] / "software" / "deckc" / "app"

IMG_HEX = OUT / "cdecko_cshell.hex"
IMG_SVH = OUT / "cdecko_cshell_words.svh"
SVH_PROTO = "CDECKO_CSHELL_NWORDS"
TOOL = "tools/gen_cshell_image.py"

# Scripted UART RX session typed into the console by verify() and the tests.
SESSION = (
    b"help\r"
    b"echo hello world\r"
    b"time\r"
    b"calc 6 * 7\r"
    b"calc 2 + 3\r"
    b"poke f100 cafebeef\r"
    b"peek f100\r"
    b"gpio 0 1\r"
    b"gpio 2 0\r"
    b"clear\r"
    b"exit\r"
)

TRANSCRIPT_NEEDLES_CSH = [
    "deckc/1.0 DeckCPU console",
    "commands: help echo time gpio peek poke calc clear exit",
    "hello world",
    "t=",
    "0000002a",
    "00000005",
    "cafebeef",
    "gpio 0 -> 1",
    "gpio 2 -> 0",
    "syslog cleared",
    "bye",
]


def sources() -> list[Path]:
    return [BSP / "bsp.c", BSP / "string.c", APP / "console.c",
            CIOS / "kernel" / "syslog.c"]


def include_dirs() -> list[Path]:
    return [BSP, CIOS / "include"]


def verify(img: list[int]) -> list[str]:
    from deckc.sim import run, load_isa

    isa = load_isa(str(ISA))
    try:
        r = run([(4 * i, w) for i, w in enumerate(img)], isa,
                uart_in=list(SESSION))
    except RuntimeError as e:
        return [f"interpreter: {e}"]
    errs = []
    mb = int.from_bytes(r['mem'][0xDF00:0xDF04], 'little')
    if mb != 0:
        errs.append(f"mailbox {mb:#x} != 0")
    text = bytes(r['out']).decode('utf-8', 'backslashreplace')
    if text.count("cafebeef") < 2:
        errs.append("expected 'cafebeef' twice (poke + peek)")
    for n in TRANSCRIPT_NEEDLES_CSH:
        if n not in text:
            errs.append(f"transcript lacks {n!r}")
    gpio = r.get('gpio', {})
    if (gpio.get('out', 0) & 1) != 1:
        errs.append("gpio out bit 0 not set")
    if (gpio.get('out', 0) & 4) != 0:
        errs.append("gpio out bit 2 not cleared")
    return errs


def main() -> int:
    build = BUILD  # reuse the shared golden build dir for the assembled .s
    build.mkdir(parents=True, exist_ok=True)
    out_s = build / "cdecko_cshell.s"
    img, _prog = build_app(out_s, sources(), include_dirs())
    print(f"compiled and assembled {out_s} ({len(img)} words)")
    IMG_HEX.write_text(hex_text(img))
    IMG_SVH.write_text(svh_text(img, proto=SVH_PROTO, tool=TOOL))
    errs = verify(img)
    if errs:
        print("cshell sanity FAILED:", file=sys.stderr)
        for e in errs:
            print("  -", e, file=sys.stderr)
        return 1
    print(f"wrote {IMG_HEX} ({len(img)} words, {len(img) * 4} bytes)")
    print(f"wrote {IMG_SVH}")
    print("cshell sanity OK (mailbox=0, driven transcript complete)")
    return 0


if __name__ == "__main__":
    sys.exit(main())