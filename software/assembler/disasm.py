#!/usr/bin/env python3
"""DeckCPU disassembler: isa/isa.json-driven word -> assembly text.

Decodes purely from the opcode field (bits 31:24) and the operand metadata in
isa/isa.json; no instruction-history or label inference. Immediates render as
`0x...`; B-format offsets render as the absolute target byte address
(pc + sign-extended off16), which round-trips through the assembler's target
semantics.
"""


class Disassembler:
    def __init__(self, isa):
        self.isa = isa
        self.formats = {n: f["fields"] for n, f in isa["formats"].items()}
        self.opcodes = {}
        for ins in isa["instructions"]:
            op = ins["opcode"] if isinstance(ins["opcode"], int) else int(ins["opcode"], 16)
            self.opcodes[op] = ins

    def _fields(self, fmt, word):
        out = {}
        for f, fld in self.formats[fmt].items():
            out[f] = (word >> fld["lsb"]) & ((1 << (fld["msb"] - fld["lsb"] + 1)) - 1)
        return out

    def disasm(self, word, pc=0):
        op = (word >> 24) & 0xFF
        ins = self.opcodes.get(op)
        if ins is None:
            return f".word 0x{word:08X}"
        fmt = ins["format"]
        fv = self._fields(fmt, word)
        parts = []
        for o in ins.get("operands", []):
            if o["role"] == "imm":
                fld = "imm16" if "imm16" in fv else "off16"
                raw = fv[fld]
                if fld == "off16":
                    sext = raw - 0x10000 if raw & 0x8000 else raw
                    parts.append(f"0x{(pc + sext) & 0xFFFFFFFF:X}")
                else:
                    parts.append(f"0x{raw:X}")
            else:
                fld = o.get("field", o["name"])
                parts.append(f"r{fv[fld]}")
        return f"{ins['mnemonic']} {', '.join(parts)}" if parts else ins["mnemonic"]

    def disasm_program(self, words, emit_addresses=False):
        """words: iterable of (byte_addr, word). Returns list of text lines.

        With emit_addresses each line is prefixed with ``0xADDR ;`` as a
        comment.  Without it, a ``.org`` line is emitted whenever the byte
        address is not contiguous with the previous word so that the output
        round-trips through the assembler faithfully."""
        out = []
        pc = None
        for addr, w in sorted(words):
            if emit_addresses:
                out.append(f"0x{addr:04X} ; {self.disasm(w, addr)}")
                continue
            if pc is None or addr != pc:
                out.append(f".org 0x{addr:X}")
            out.append(self.disasm(w, addr))
            pc = addr + 4
        return out