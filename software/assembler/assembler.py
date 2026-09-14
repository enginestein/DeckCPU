#!/usr/bin/env python3
"""DeckCPU assembler: two-pass, isa/isa.json-driven assembler.

Grammar (line-oriented, one statement per line):

    [label:] [INSN op, op, op] [; comment]

    identifiers  [A-Za-z_][A-Za-z0-9_.]*   (labels and .equ constants)
    registers    r0 .. r15                 (case-insensitive 'r')
    immediates   42  -5  0x1F  $1F  0b101
    high/low     HI(sym)  LO(sym)  select the 16-bit halves of a symbol/value
    self ref     '.' == byte address of the current instruction
    comments     ';' or '#' to end of line

    directive   meaning
    .org  ADDR    set the byte address of the next statement
    .word VAL     emit a 32-bit word (imm16/off16-style immediate or symbol)
    .byte V[,V]   emit raw bytes, packed 4 per word, little-endian (lane b of a
                  word at address A holds the byte at A+b); last word zero-padded
    .asciz "S"    emit a null-terminated quote string, packed like .byte
    .equ  NAME VAL   define a constant; VAL may reference labels and earlier
                    .equ symbols
    .include "F"     splice in the file F (path relative to the current file)
                    at this point; same address space, so relative labels and
                    branch offsets span the include boundary
    .global NAME  mark a label as exported (informational)

Operands map to bit-fields through isa/isa.json (per-instruction operand
'field'/role; immediates live in the format's imm16/off16 field). Branch and
JMPR-family offsets use **target** semantics: `JMP label` lands on label, i.e.
off16 = target - PC. A numeric branch operand is likewise a byte address, never
a raw offset; `.` denotes the current instruction.

Two passes: pass 1 assigns byte addresses and collects labels/.equ symbols,
pass 2 encodes everything and reports errors. Values are range and alignment
checked (off16 multiples of 4; signed/unsigned immediates; shamt 0..31).
"""

import json
import os
import re

num_re = re.compile(r"^[+-]?(?:0x|0b|\$|0)?[0-9a-fA-F]*$")
ident_re = re.compile(r"[A-Za-z_][A-Za-z0-9_.]*$")


class AssemblyError(Exception):
    """Raised on the first hard syntax error (bad line, unsolvable operand)."""


class Program:
    """Assembled output: label table + (byte_addr, word) pairs."""

    def __init__(self, words, labels, exports, errors):
        self.words = sorted(words)          # [(byte_addr, word32), ...]
        self.labels = dict(labels)          # name -> byte address
        self.exports = list(exports)        # exported label names
        self.errors = list(errors)          # [(line_no, message), ...]

    @property
    def ok(self):
        return not self.errors

    def addr_map(self):
        return dict(self.words)

    def word_image(self, origin=0, fill=0):
        """Contiguous 32-bit list from `origin`; holes filled with `fill`, for
        the testbench write-port loader (see tools/gen_programs.py)."""
        if not self.words:
            return []
        last = self.words[-1][0]
        img = [fill] * ((last - origin) // 4 + 1)
        for addr, w in self.words:
            img[(addr - origin) // 4] = w
        return img

    def write_hex(self, path):
        """Write the @-addressed byte hex image (golden-format, see
        tools/gen_programs.py: each word becomes 4 little-endian bytes)."""
        with open(path, "w", encoding="utf-8") as fh:
            for addr, w in self.words:
                for j in range(4):
                    fh.write(f"@{addr + j:08X} {(w >> (24 - 8 * j)) & 0xFF:02X}\n")


def load_isa(path):
    with open(path, "r", encoding="utf-8") as fh:
        return json.load(fh)


def parse_num(tok):
    """Parse a decimal/hex/$hex/binary integer literal, or None."""
    t = tok.strip()
    if not t or not num_re.match(t):
        return None
    neg = False
    if t[0] in "+-":
        neg = t[0] == "-"
        t = t[1:]
    if t.startswith("$"):
        t = "0x" + t[1:]
    base = 16 if t[:2].lower() == "0x" else (2 if t[:2].lower() == "0b" else 10)
    try:
        v = int(t, base)
    except ValueError:
        return None
    return -v if neg else v


def _pack_len(bytes_):
    """Byte count rounded up to a whole number of 32-bit words."""
    return ((len(bytes_) + 3) // 4) * 4


def _pack_bytes(pc, bytes_):
    """Pack bytes little-endianly into words (4 per word, last zero-padded).

    Memory byte order matches the RAM byte-lane model: a byte read at address
    A returns lane A&3 of word A>>2, so lane b of each emitted word holds the
    byte at the word base + b (little-endian within the word).
    """
    items = []
    for i in range(0, len(bytes_), 4):
        chunk = bytes_[i:i + 4]
        if len(chunk) < 4:
            chunk = chunk + [0] * (4 - len(chunk))
        w = 0
        for b, v in enumerate(chunk):
            w |= (v & 0xFF) << (8 * b)
        items.append((pc, w))
        pc += 4
    return items


def read_hex_words(path):
    """Parse an @-addressed byte hex image into [(byte_addr, word32), ...].

    A word exists where all 4 little-endian bytes of an aligned address are
    present. Bytes are ordered big-endian within the word, matching both the
    assembler's write_hex and the golden images in sim/programs/*.hex.
    """
    mem = {}
    with open(path, "r", encoding="utf-8") as fh:
        for raw in fh:
            line = raw.split("//")[0].split(";")[0].strip()
            if not line.startswith("@"):
                continue
            a = int(line[1:9], 16)
            v = int(line[10:].strip(), 16)
            mem[a] = v
    words = []
    for base in sorted(mem):
        if base % 4 or any((base + b) not in mem for b in range(4)):
            continue
        w = 0
        for b in range(4):
            w |= mem[base + b] << (24 - 8 * b)
        words.append((base, w))
    return words


escapes = {"n": 10, "r": 13, "t": 9, "0": 0, "\\": 92, '"': 34, "a": 7, "b": 8, "f": 12}


def parse_str(tok):
    """Parse a double-quoted string token with C escapes into a byte list."""
    s = tok.strip()
    if len(s) < 2 or s[0] != '"' or s[-1] != '"':
        raise ValueError("expected a \"quoted string\"")
    out = []
    i = 1
    while i < len(s) - 1:
        c = s[i]
        if c == "\\":
            if i + 1 >= len(s) - 1:
                raise ValueError("dangling escape")
            nxt = s[i + 1]
            if nxt in escapes:
                out.append(escapes[nxt])
                i += 2
            elif nxt in "x0123456789":
                seq = s[i + 1:i + 3]
                try:
                    out.append(int(seq, 16))
                except ValueError:
                    raise ValueError(f"bad \\x escape '{seq}'")
                i += 3
            else:
                raise ValueError(f"unknown escape '\\{nxt}'")
        else:
            out.append(ord(c))
            i += 1
    return out


class _Statement:
    __slots__ = ("line", "kind", "label", "mnemonic", "operands", "arg")

    def __init__(self, line, kind, label=None, mnemonic=None, operands=None, arg=None):
        self.line = line
        self.kind = kind            # insn|org|word|byte|asciz|equ|global|label
        self.label = label
        self.mnemonic = mnemonic
        self.operands = operands or []
        self.arg = arg


class Assembler:
    def __init__(self, isa):
        self.isa = isa
        self.meta = isa["meta"]
        num_gpr = self.meta["num_gpr"]
        self.max_reg = num_gpr - 1
        self.formats = {n: f["fields"] for n, f in isa["formats"].items()}
        self.instructions = {}
        for ins in isa["instructions"]:
            op = ins["opcode"] if isinstance(ins["opcode"], int) else int(ins["opcode"], 16)
            self.instructions[ins["mnemonic"]] = self._spec(ins)

    # ---- build per-instruction operand->field spec from isa.json ----
    def _spec(self, ins):
        fmt = ins["format"]
        syntax = []
        for o in ins.get("operands", []):
            if o["role"] == "imm":
                fld = "imm16" if "imm16" in self.formats[fmt] else "off16"
                syntax.append({
                    "type": "imm", "field": fld,
                    "sign": o.get("sign", "s"), "width": o.get("width"),
                })
            else:
                fld = o.get("field", o["name"])
                syntax.append({"type": "reg", "field": fld})
        return {
            "mnemonic": ins["mnemonic"],
            "opcode": ins["opcode"] if isinstance(ins["opcode"], int) else int(ins["opcode"], 16),
            "format": fmt,
            "syntax": syntax,
        }

    # ---- lexical pass ----
    def _statements(self, text):
        stmts = []
        for lineno, raw in enumerate(text.splitlines(), 1):
            line = raw.split(";")[0].split("#")[0].strip()
            if not line:
                continue
            label = None
            colon = line.find(":")
            if colon >= 0:
                label = line[:colon].strip()
                if not ident_re.match(label):
                    raise AssemblyError(f"line {lineno}: bad label '{label}'")
                if not ident_re.match(label):
                    raise AssemblyError(f"line {lineno}: label must match {ident_re.pattern}")
                line = line[colon + 1:].strip()
            if not line:
                if label:
                    stmts.append(_Statement(lineno, "label", label=label))
                continue
            if line.startswith("."):
                stmts.append(self._directive(lineno, line, label))
            else:
                toks = line.split()
                mnem = toks[0].upper()
                if mnem not in self.instructions:
                    raise AssemblyError(f"line {lineno}: unknown instruction '{toks[0]}'")
                rest = line[len(toks[0]):].strip()
                operands = [t.strip() for t in rest.split(",")] if rest else []
                stmts.append(_Statement(lineno, "insn", label=label,
                                        mnemonic=mnem, operands=operands))
        return stmts

    def _directive(self, lineno, line, label):
        name, _, rest = line.partition(" ")
        name = name.lower()
        rest = rest.strip()
        if name == ".org":
            v = parse_num(rest)
            if v is None or v < 0:
                raise AssemblyError(f"line {lineno}: .org needs a non-negative number")
            return _Statement(lineno, "org", label=label, arg=v)
        if name == ".word":
            if not rest:
                raise AssemblyError(f"line {lineno}: .word needs a value")
            return _Statement(lineno, "word", label=label, arg=rest)
        if name == ".byte":
            if not rest:
                raise AssemblyError(f"line {lineno}: .byte needs values")
            toks = [t.strip() for t in rest.split(",")]
            vals = []
            for t in toks:
                v = parse_num(t)
                if v is None or not 0 <= v <= 0xFF:
                    raise AssemblyError(f"line {lineno}: bad .byte value '{t}'")
                vals.append(v)
            return _Statement(lineno, "byte", label=label, arg=vals)
        if name in (".asciz", ".string", ".ascii"):
            try:
                bytes_ = parse_str(rest)
            except ValueError as e:
                raise AssemblyError(f"line {lineno}: {e}")
            if name != ".ascii":
                bytes_ = bytes_ + [0]          # null-terminated
            return _Statement(lineno, "byte", label=label, arg=bytes_)
        if name == ".equ":
            m = re.match(r"^([A-Za-z_][A-Za-z0-9_.]*)\s*[,=]\s*(.+)$", rest)
            if not m:
                raise AssemblyError(f"line {lineno}: .equ needs NAME, VALUE or NAME = VALUE")
            return _Statement(lineno, "equ", label=label, arg=(m.group(1), m.group(2)))
        if name == ".global":
            return _Statement(lineno, "global", arg=rest)
        raise AssemblyError(f"line {lineno}: unknown directive '{name}'")

    # ---- symbol resolution (labels + .equ) ----
    def _resolve(self, tok, pc):
        tok = tok.strip()
        if tok == ".":
            return pc
        m = re.fullmatch(r"(?:HI|LO)\(\s*(.+?)\s*\)", tok)
        if m:
            inner = self._resolve(m.group(1), pc)
            return (inner >> 16) & 0xFFFF if tok[:2] == "HI" else inner & 0xFFFF
        v = parse_num(tok)
        if v is not None:
            return v
        if tok in self.symbols:
            return self.symbols[tok]
        raise AssemblyError(f"undefined symbol '{tok}'")

    # ---- pass 1/2 ----
    def assemble(self, text, origin=0):
        try:
            stmts = self._statements(text)
        except AssemblyError as e:
            return Program([], {}, [], [(0, str(e))])
        return self._two_pass(stmts, origin)

    def assemble_file(self, path, origin=0):
        try:
            text = self._expand_file(path)
        except AssemblyError as e:
            return Program([], {}, [], [(0, str(e))])
        return self.assemble(text, origin)

    def _expand_file(self, path, stack=None):
        """Splice .include'd files into one source text (single address space).

        .include "F" resolves F relative to the directory of the including
        file; loops are rejected. Paths must be quoted tokens (no escapes
        beyond the string escapes parse_str accepts).
        """
        apath = os.path.abspath(path)
        stack = stack or []
        if apath in stack:
            raise AssemblyError(f"include loop: {path}")
        stack = stack + [apath]
        chunks = []
        base = os.path.dirname(apath)
        with open(path, "r", encoding="utf-8") as fh:
            for raw in fh:
                if raw.lstrip().startswith(".include"):
                    try:
                        tok = raw.strip().partition(" ")[2].strip()
                        name_bytes = parse_str(tok)
                    except ValueError as e:
                        raise AssemblyError(f"{path}: bad .include ({e})")
                    inc = os.path.join(base, "".join(chr(b) for b in name_bytes))
                    if not os.path.exists(inc):
                        raise AssemblyError(f"{path}: include not found: {inc}")
                    chunks.append(f"; include {os.path.basename(inc)}")
                    chunks.append(self._expand_file(inc, stack))
                    continue
                chunks.append(raw.rstrip("\n"))
        return "\n".join(chunks)

    def _two_pass(self, stmts, origin):
        self.symbols = {}       # name -> value (labels + .equ)
        self.exports = []
        errors = []

        # pass 1: addresses + labels; .equ resolved later against final labels
        pc = origin
        for st in stmts:
            if st.label:
                if st.label in self.symbols:
                    errors.append((st.line, f"duplicate symbol '{st.label}'"))
                self.symbols[st.label] = pc
            if st.kind == "org":
                pc = st.arg
            elif st.kind in ("insn", "word"):
                pc += 4
            elif st.kind == "byte":
                pc += _pack_len(st.arg)

        # .equ constants (may reference any label/earlier equ)
        for st in stmts:
            if st.kind == "equ":
                name, expr = st.arg
                try:
                    self.symbols[name] = self._resolve(expr, pc)
                except AssemblyError as e:
                    errors.append((st.line, str(e)))
                if st.label:
                    errors.append((st.line, "labels cannot precede .equ"))

        # pass 2: encode
        words = []
        pc = origin
        for st in stmts:
            if st.kind == "org":
                pc = st.arg
                continue
            if st.kind == "insn":
                try:
                    words.append((pc, self._encode(st, pc)))
                except AssemblyError as e:
                    errors.append((st.line, str(e)))
                pc += 4
            elif st.kind == "word":
                try:
                    words.append((pc, self._resolve(st.arg, pc) & 0xFFFFFFFF))
                except AssemblyError as e:
                    errors.append((st.line, str(e)))
                pc += 4
            elif st.kind == "byte":
                vals = []
                for t in st.arg:
                    v = self._resolve(t, pc) if isinstance(t, str) else t
                    vals.append(v & 0xFF)
                words.extend(_pack_bytes(pc, vals))
                pc += _pack_len(vals)
            elif st.kind == "global":
                if st.arg not in self.symbols:
                    errors.append((st.line, f".global unknown symbol '{st.arg}'"))
                else:
                    self.exports.append(st.arg)
        return Program(words, self.symbols, self.exports, errors)

    # ---- encoding ----
    def _encode(self, st, pc):
        spec = self.instructions[st.mnemonic]
        opnds = spec["syntax"]
        if len(st.operands) != len(opnds):
            raise AssemblyError(
                f"{st.mnemonic} expects {len(opnds)} operand(s), got {len(st.operands)}")
        fields = {}
        for tok, o in zip(st.operands, opnds):
            if o["type"] == "reg":
                r = self._reg_num(tok)
                if r is None or not (0 <= r <= self.max_reg):
                    raise AssemblyError(f"bad register '{tok}'")
                fields[o["field"]] = r
            else:
                v = self._resolve(tok, pc)
                v = self._range(o, v, pc)
                fields[o["field"]] = v
        word = 0
        for f, fld in self.formats[spec["format"]].items():
            if f == "op":
                bits = spec["opcode"]
            elif f in ("funct", "spare"):
                bits = 0
            else:
                bits = fields.get(f, 0)
            word |= bits << fld["lsb"]
        return word & 0xFFFFFFFF

    def _reg_num(self, tok):
        if re.fullmatch(r"[rR][0-9]+", tok):
            return int(tok[1:])
        return None

    def _range(self, o, v, pc):
        fld = o["field"]
        if fld == "off16":
            off = v - pc                     # target semantics
            if off % 4:
                raise AssemblyError(f"branch offset {off:#x} not a multiple of 4")
            if not -0x8000 <= off <= 0x7FFF:
                raise AssemblyError(f"branch offset {off:#x} out of ±32 KiB")
            return off & 0xFFFF
        if o["width"]:                       # shamt 5-bit
            if not 0 <= v <= (1 << o["width"]) - 1:
                raise AssemblyError(f"immediate {v:#x} out of {o['width']}-bit range")
            return v
        if o["sign"] == "u":
            if not 0 <= v <= 0xFFFF:
                raise AssemblyError(f"unsigned immediate {v:#x} out of 16-bit range")
            return v
        if not -0x8000 <= v <= 0xFFFF:
            raise AssemblyError(f"immediate {v:#x} out of ±16-bit range")
        return v & 0xFFFF