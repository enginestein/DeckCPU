"""Assembler / disassembler tests (pytest).

Three layers of evidence:
  1. golden: the sim/programs/*.s sources must assemble to exactly the
     hand-verified byte images in sim/programs/*.hex (the words the core testbenches
     testbenches actually execute).
  2. round-trip: words -> disasm -> reassemble -> same bytes.
  3. encoding: every instruction with canonical operands, cross-checked
     against the independent encoder in tools/isa_tools.py, plus hand-computed
     literal words.
"""

import os
import pathlib
import subprocess
import sys

import pytest

ROOT = pathlib.Path(__file__).resolve().parents[2]
ASM_DIR = pathlib.Path(__file__).resolve().parent
sys.path.insert(0, str(ROOT))
sys.path.insert(0, str(ASM_DIR))
sys.path.insert(0, str(ROOT / "tools"))

import isa_tools  # noqa: E402

from assembler import (  # noqa: E402
    Assembler,
    Disassembler,
    load_isa,
    read_hex_words,
)

PROG_DIR = ROOT / "sim" / "programs"
ISA = load_isa(ROOT / "isa" / "isa.json")

ASM = Assembler(ISA)
DASM = Disassembler(ISA)

GOLDEN_NAMES = ["cpu_fsm_prog", "cpu_tb_prog", "irq_tb_prog", "deckos_console"]
# The disassembler understands code only (no data directives), so a data word
# that decodes to a valid opcode cannot round-trip. Only the pure-code golden
# images participate in the reassembly test; deckos_console's .hex is still
# proven byte-for-byte by test_golden_sources_reproduce_hex_images.
ROUNDTRIP_NAMES = ["cpu_fsm_prog", "cpu_tb_prog", "irq_tb_prog"]


# ---------------------------------------------------------------------------
# golden images
# ---------------------------------------------------------------------------
@pytest.mark.parametrize("name", GOLDEN_NAMES)
def test_golden_sources_reproduce_hex_images(name):
    src = PROG_DIR / f"{name}.s"
    hexp = PROG_DIR / f"{name}.hex"
    assert src.exists(), f"missing source {src}"
    prog = ASM.assemble_file(str(src))
    assert prog.ok, f"{name}: {prog.errors}"
    golden = dict(read_hex_words(str(hexp)))
    assert prog.addr_map() == golden, f"{name} words differ from golden .hex"


def test_golden_word_image_matches_loader_include():
    for name in GOLDEN_NAMES:
        prog = ASM.assemble_file(str(PROG_DIR / f"{name}.s"))
        img = prog.word_image()
        svh = (PROG_DIR / f"{name}_words.svh").read_text()
        assert f"{name.upper()}_NWORDS = {len(img)};" in svh
        for i, w in enumerate(img):
            assert f"PW[{i}] = 32'h{w:08X};" in svh, f"{name}: PW[{i}] mismatch"


# ---------------------------------------------------------------------------
# round-trip: words -> disasm -> reassemble -> words
# ---------------------------------------------------------------------------
@pytest.mark.parametrize("name", ROUNDTRIP_NAMES)
def test_disasm_reassembly_roundtrip(name):
    words = dict(read_hex_words(str(PROG_DIR / f"{name}.hex")))
    text = "\n".join(DASM.disasm_program(list(words.items())))
    rebound = ASM.assemble(text)
    assert rebound.ok, f"{name}: {rebound.errors}"
    assert rebound.addr_map() == words


def test_disasm_known_words():
    assert DASM.disasm(0x11100008, 0x0C) == "ADDI r1, r0, 0x8"
    assert DASM.disasm(0x341B0004, 0x2C) == "ST r1, r11, 0x4"
    assert DASM.disasm(0x4100003C, 0x4C) == "CALL 0x88"   # target == pc + off16
    assert DASM.disasm(0x58000000) == "IRET"
    assert DASM.disasm(0x60000000) == "HALT"
    assert DASM.disasm(0xFF000000, 0).startswith(".word")


def test_disasm_emit_addresses():
    lines = DASM.disasm_program([(0x54, 0x50010000)], emit_addresses=True)
    assert lines == ["0x0054 ; PUSH r1"]


def test_disasm_org_on_gaps():
    lines = DASM.disasm_program([(0x00, 0x60000000), (0x80, 0x60000000)])
    assert lines == [".org 0x0", "HALT", ".org 0x80", "HALT"]


# ---------------------------------------------------------------------------
# encoding cross-check against tools/isa_tools.encode_canonical
# ---------------------------------------------------------------------------
@pytest.mark.parametrize("insn", ISA["instructions"], ids=lambda i: i["mnemonic"])
def test_encoding_matches_isa_tools_canonical(insn):
    fmt = insn["format"]
    has_imm = any(o["role"] == "imm" for o in insn.get("operands", []))
    # tools/isa_tools fills off16 even for branch instructions with no imm
    # operand (RET/IRET), which assembly cannot express; skip those.
    if not has_imm and "off16" in ISA["formats"][fmt]["fields"]:
        pytest.skip("B-format without imm operand is not expressible")
    widths = [o.get("width") for o in insn.get("operands", [])]
    gen_imm = 0x12 if any(widths) else 0x1234   # shamt is 5-bit
    spec = ASM.instructions[insn["mnemonic"]]
    reg_i = 1
    opnds = []
    for o in spec["syntax"]:
        if o["type"] == "reg":
            opnds.append(f"r{reg_i}")
            reg_i += 1
        else:
            opnds.append(f"0x{gen_imm:X}")      # target semantics at origin 0
    text = f"{insn['mnemonic']} " + ", ".join(opnds) if opnds else insn["mnemonic"]
    prog = ASM.assemble(text, origin=0)
    assert prog.ok, f"{text}: {prog.errors}"
    expected = isa_tools.encode_canonical(ISA, insn, imm_val=gen_imm)
    assert prog.addr_map()[0] == expected, f"{text!r}: got {prog.addr_map()[0]:08x}"


# ---------------------------------------------------------------------------
# hand-computed literal encodings
# ---------------------------------------------------------------------------
def encode_line(text, origin=0):
    prog = ASM.assemble(text, origin=origin)
    assert prog.ok, f"{text}: {prog.errors}"
    return prog.addr_map()


def test_literal_encodings():
    cases = [
        ("ADDI r1, r0, 8", 0, 0x11100008),
        ("LI r1, 0x1000", 0, 0x20101000),
        ("ST r3, r10, 4", 0, 0x343A0004),
        ("LD r11, r10, 4", 0, 0x30BA0004),
        ("MOV r14, r3", 0, 0x22E30000),
        ("PUSH r1", 0, 0x50010000),
        ("POP r15", 0, 0x51F00000),
        ("WRSP r4", 0, 0x53040000),
        ("CMP r1, r2", 0, 0x0A012000),
        ("IRET", 0, 0x58000000),
        ("RET", 0, 0x42000000),
        ("JMP 0x1C", 0x14, 0x40000008),
        ("BEQ r0, r0, 0x48", 0x3C, 0x4400000C),
        ("JMP .", 0, 0x40000000),
    ]
    for src, addr, want in cases:
        assert encode_line(src, addr)[addr] == want, src


def test_negative_imm_sign_extension():
    assert encode_line("ADDI r2, r0, -1")[0] == 0x1120FFFF
    assert encode_line("LD r3, r4, -4")[0] == 0x3034FFFC


def test_shamt_is_5bit_canonical():
    assert encode_line("SHLI r1, r2, 31")[0] == 0x1712001F
    bad = ASM.assemble("SHLI r1, r2, 32")
    assert not bad.ok
    assert any("5-bit range" in m for _, m in bad.errors)


# ---------------------------------------------------------------------------
# labels, directives, errors
# ---------------------------------------------------------------------------
def test_labels_forward_and_backward_branches():
    text = """
main:
        LI      r1, 0x1000       ; 0x00
        BEQ     r0, r0, done      ; +0x08 -> 0x0C
        JMP     main              ; back to 0x00 (off = -8)
done:
        HALT
"""
    prog = ASM.assemble(text)
    assert prog.ok, prog.errors
    assert prog.addr_map() == {
        0x00: 0x20101000,
        0x04: 0x44000008,
        0x08: 0x4000FFF8,
        0x0C: 0x60000000,
    }
    assert prog.labels["main"] == 0x00
    assert prog.labels["done"] == 0x0C


def test_equ_org_word_global():
    text = """
.equ base, 0x1000
.org 0x80
start:
        LI      r1, base
        .word   start
        .global start
"""
    prog = ASM.assemble(text)
    assert prog.ok, prog.errors
    words = prog.addr_map()
    assert words[0x80] == 0x20101000        # LI r1, base (base == 0x1000)
    assert words[0x84] == 0x00000080        # .word start
    assert "start" in prog.exports


def test_byte_and_asciz_directives_pack_little_endian():
    text = """
.org 0x200
s1: .asciz "Hi"
s2: .asciz "Hello\\0"
b1: .byte 0xAA, 0x55
b2: .byte 0
"""
    prog = ASM.assemble(text)
    assert prog.ok, prog.errors
    w = prog.addr_map()
    assert w[0x200] == 0x0000_6948      # 'H' at +0, 'i' at +1, NUL pad
    assert w[0x204] == 0x6C6C_6548      # 'H' 'e' 'l' 'l'
    assert w[0x208] == 0x0000_006F      # 'o' NUL pad
    assert w[0x20C] == 0x0000_55AA      # bytes packed LE
    assert w[0x210] == 0x0000_0000      # single 0 byte + pad
    assert prog.labels["s1"] == 0x200
    assert prog.labels["s2"] == 0x204
    assert prog.labels["b1"] == 0x20C
    assert prog.labels["b2"] == 0x210
    assert prog.word_image()[0x200 // 4] == 0x0000_6948


def test_asciz_escapes_and_errors():
    prog = ASM.assemble(r'.asciz "a\n\r\tb"')
    assert prog.ok, prog.errors
    assert prog.addr_map()[0] == 0x090D_0A61   # a \n \r \t
    assert prog.addr_map()[4] == 0x0000_0062   # b NUL pad
    assert not ASM.assemble('.asciz "unterminated').ok
    assert not ASM.assemble(".byte 0x1FF").ok


def test_byte_label_used_by_ld_b_relocatable():
    # the console loads characters from a string one byte at a time; make
    # sure a .asciz label is loadable via LI + LD.B with a raw imm16 offset —
    # memory-access offsets are RAW, unlike the branch/JMPR target semantics.
    text = """
.org 0x40
msg: .asciz "hi"
code:
        LI      r10, msg
        LD.B    r1, r10, 0
        LD.B    r2, r10, 1
"""
    prog = ASM.assemble(text)
    assert prog.ok, prog.errors
    w = prog.addr_map()
    assert w[0x40] == 0x0000_6968
    assert (w[0x44] & 0xFFFF) == 0x0040      # LI r10, msg (0x40) raw
    assert (w[0x48] & 0xFFFF) == 0x0000      # LD.B r1, r10, 0
    assert (w[0x4C] & 0xFFFF) == 0x0001      # LD.B r2, r10, 1


def test_hi_lo_split_load_of_32bit_symbol():
    # LI/LIH are 16-bit; a 32-bit symbol (e.g. an MMIO base or a label above
    # 64 KiB is impossible here, but the mechanism mirrors the DeckOS HAL's
    # use of HI()/LO() to build UART/TIMER/GPIO base addresses.
    text = """
.org 0x1000
buf: .asciz "x"
code:
        LI      r7, LO(buf)
        LIH     r7, HI(buf)
        LI      r8, LO(0x40002000)
        LIH     r8, HI(0x40002000)
"""
    prog = ASM.assemble(text)
    assert prog.ok, prog.errors
    w = prog.addr_map()
    assert (w[0x1004] & 0xFFFF) == 0x1000       # LO(buf)
    assert (w[0x1008] & 0xFFFF) == 0x0000       # HI(buf)
    assert (w[0x100C] & 0xFFFF) == 0x2000       # LO(0x40002000)
    assert (w[0x1010] & 0xFFFF) == 0x4000       # HI(0x40002000)


def test_errors_are_reported():
    bad = [
        "ADD r1, r0",
        "FADD r1, r0, r2",
        "LI r1, 0x10000",
        "ADDI r1, r1, -32769",
        "LI r16, 1",
        "BEQ r0, r0, nomatch",
        "BEQ r0, r0, 3",
    ]
    for src in bad:
        prog = ASM.assemble(src)
        assert not prog.ok, f"expected error for {src!r}"
    # spot-check the messages for the interesting ones
    prog = ASM.assemble("ADD r1, r0")
    assert any("expects 3 operand(s)" in m for _, m in prog.errors)
    prog = ASM.assemble("BEQ r0, r0, 3")
    assert any("not a multiple of 4" in m for _, m in prog.errors)
    prog = ASM.assemble("BEQ r0, r0, nomatch")
    assert any("undefined symbol" in m for _, m in prog.errors)


def test_duplicate_label_rejected():
    prog = ASM.assemble("x:\n  NOP\nx:\n  HALT")
    assert not prog.ok
    assert any("duplicate symbol 'x'" in m for _, m in prog.errors)


def test_bad_syntax_line_reported_not_raised():
    prog = ASM.assemble("this is not an instruction\n  NOP")
    assert not prog.ok
    assert any("unknown instruction" in m for _, m in prog.errors)


# ---------------------------------------------------------------------------
# hex write/read round-trip
# ---------------------------------------------------------------------------
def test_hex_write_read_roundtrip(tmp_path):
    prog = ASM.assemble("LI r1, 0x1234\nCALL 0x40\nHALT")
    out = tmp_path / "t.hex"
    prog.write_hex(str(out))
    assert read_hex_words(str(out)) == prog.words


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------
def test_cli_asm_to_hex(tmp_path):
    out = tmp_path / "out.hex"
    r = subprocess.run(
        [sys.executable, "-m", "software.assembler", "asm",
         str(PROG_DIR / "cpu_fsm_prog.s"), "-o", str(out)],
        cwd=ROOT, capture_output=True, text=True)
    assert r.returncode == 0, r.stdout + r.stderr
    assert read_hex_words(str(out)) == read_hex_words(str(PROG_DIR / "cpu_fsm_prog.hex"))


def test_include_splices_file_same_address_space(tmp_path):
    inc = tmp_path / "hal.inc.s"
    inc.write_text('.asciz "DeckOS\\n"\n')
    src = tmp_path / "main.s"
    src.write_text(f"""
.org 0x40
.include "{inc.name}"
msg2:   .asciz "hi"
bar:
        LI      r7, LO(msg2)
""")
    prog = ASM.assemble_file(str(src))
    assert prog.ok, prog.errors
    w = prog.addr_map()
    assert w[0x40] == 0x6B63_6544        # 'D' 'e' 'c' 'k'
    assert w[0x44] == 0x000A_534F        # 'O' 'S' \n NUL
    assert w[0x48] == 0x0000_6968        # "hi"
    assert prog.labels["bar"] == 0x4C
    assert (w[0x4C] & 0xFFFF) == 0x0048  # LI r7, LO(msg2) == 0x48


def test_include_missing_and_loop_rejected(tmp_path):
    a = tmp_path / "a.s"
    b = tmp_path / "b.s"
    a.write_text('.include "b.s"\nHALT\n')
    b.write_text('.include "a.s"\nHALT\n')
    prog = ASM.assemble_file(str(a))
    assert not prog.ok
    assert any("include loop" in m for _, m in prog.errors)
    a.write_text('.include "nope.s"\nHALT\n')
    prog = ASM.assemble_file(str(a))
    assert not prog.ok
    assert any("include not found" in m for _, m in prog.errors)