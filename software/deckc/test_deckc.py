"""Golden tests for the deckc CIOS + console images.

These pin the deckc toolchain + runtime + BSP behaviour:

  - the interpreter's transcript for the CIOS main (5 color-coded, timed
    syslog ring-log entries, then a full clear + "(log empty)") must match
    exactly -- including the TIMER-derived timestamps,
  - the committed golden artifacts (sim/programs/cdecko_cios.hex and
    cdecko_cios_words.svh) must match what the current toolchain generates,
    so any change that shifts machine code breaks here until the golden
    artefacts are regenerated (python3 tools/gen_cios_image.py),
  - the interactive C console (cdecko_cshell.hex) must both be byte-identical
    to the committed golden artifacts and answer a scripted UART RX session
    with the expected command replies, a mailbox of 0, and the GPIO effect.

Run:  python3 -m pytest -q software/deckc/test_deckc.py
"""

from __future__ import annotations

import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "tools"))
sys.path.insert(0, str(ROOT / "software"))

import gen_cios_image
import gen_cshell_image
from deckc.sim import MAILBOX, load_isa, run

# Exact interpreter transcript (deterministic: zero-wait UART model).
GOLDEN_TRANSCRIPT = (
    "\x1b[0m[  28.215] [INF] [syslog    ] ring log ready (64 slots)\x1b[0m\n"
    "\x1b[90m[  29.456] [DBG] [deckc     ] boot complete\x1b[0m\n"
    "\x1b[33m[  30.667] [WRN] [deckc     ] brownout detected\x1b[0m\n"
    "\x1b[31m[  31.886] [ERR] [deckc     ] allocation failed\x1b[0m\n"
    "\x1b[0m[  33.105] [INF] [deckc     ] scan started\x1b[0m\n"
    "syslog cleared  (5 total entries discarded)\n"
    "(log empty)\n"
)


def _image():
    return gen_cios_image.compile_and_assemble(ROOT / "build" / "gen" / "cdecko_cios.s")


def _transcript(img):
    r = run([(4 * i, w) for i, w in enumerate(img)], load_isa(str(gen_cios_image.ISA)))
    return r, bytes(r["out"]).decode("utf-8", "backslashreplace")


def test_interpreter_transcript_matches_golden():
    img, _prog = _image()
    r, text = _transcript(img)
    assert text == GOLDEN_TRANSCRIPT
    mb = int.from_bytes(r["mem"][MAILBOX:MAILBOX + 4], "little")
    assert mb == 5
    assert r["cycles"] < 200_000


def test_committed_hex_matches_current_toolchain():
    img, _prog = _image()
    committed = gen_cios_image.OUT / "cdecko_cios.hex"
    assert committed.exists()
    assert committed.read_text() == gen_cios_image.hex_text(img)


def test_committed_svh_matches_current_toolchain():
    img, _prog = _image()
    committed = gen_cios_image.OUT / "cdecko_cios_words.svh"
    assert committed.exists()
    assert committed.read_text() == gen_cios_image.svh_text(img)
    assert "CDECKO_CIOS_NWORDS" in committed.read_text()


def test_sanity_verify_passes():
    img, _prog = _image()
    assert gen_cios_image.verify(img) == []


def _cshell_image():
    return gen_cshell_image.build_app(
        ROOT / "build" / "gen" / "cdecko_cshell.s",
        gen_cshell_image.sources(),
        gen_cshell_image.include_dirs())


def test_console_driven_transcript_and_effect():
    img, _prog = _cshell_image()
    r = run([(4 * i, w) for i, w in enumerate(img)],
            load_isa(str(gen_cios_image.ISA)),
            uart_in=list(gen_cshell_image.SESSION))
    mb = int.from_bytes(r["mem"][MAILBOX:MAILBOX + 4], "little")
    assert mb == 0
    assert r["cycles"] < 2_000_000
    text = bytes(r["out"]).decode("utf-8", "backslashreplace")
    for n in gen_cshell_image.TRANSCRIPT_NEEDLES_CSH:
        assert n in text, f"console transcript lacks {n!r}"
    assert text.count("cafebeef") >= 2          # poke + peek read-back
    assert text.count("deckc> ") == gen_cshell_image.SESSION.count(b"\r")
    assert r["gpio"]["out"] & 1 == 1            # gpio 0 -> 1
    assert r["gpio"]["out"] & 4 == 0            # gpio 2 -> 0
    assert r["gpio"]["dir"] & 5 == 5


def test_console_committed_artifacts_match_current_toolchain():
    img, _prog = _cshell_image()
    out_hex = gen_cshell_image.OUT / "cdecko_cshell.hex"
    out_svh = gen_cshell_image.OUT / "cdecko_cshell_words.svh"
    assert out_hex.exists()
    assert out_svh.exists()
    assert out_hex.read_text() == gen_cios_image.hex_text(img)
    assert out_svh.read_text() == gen_cios_image.svh_text(
        img, proto=gen_cshell_image.SVH_PROTO, tool=gen_cshell_image.TOOL)
    assert gen_cshell_image.SVH_PROTO in out_svh.read_text()