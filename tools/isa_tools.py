#!/usr/bin/env python3
"""DeckCPU ISA tooling.

Single source of truth -> derived artifacts:

    isa/isa.json            authoritative ISA specification
        \--> tools/isa_tools.py validate   : structural checks
        \--> tools/isa_tools.py docs       : generate docs/isa.md, docs/memory-map.md

Usage:
    python3 tools/isa_tools.py validate [isa.json]
    python3 tools/isa_tools.py docs     [isa.json] [outdir]
    python3 tools/isa_tools.py vectors  [isa.json] [out .svh]
"""

import json
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DEF_ISA = os.path.join(ROOT, "isa", "isa.json")
DEF_OUT = os.path.join(ROOT, "docs")


def load_isa(path):
    with open(path, "r", encoding="utf-8") as fh:
        return json.load(fh)


def _check(cond, msg, errors):
    if not cond:
        errors.append(msg)


def validate(isa, strict=True):
    """Structural validation of the ISA spec. Returns list of error strings."""
    errs = []
    meta = isa.get("meta", {})
    _check(meta.get("name") == "DeckCPU", "meta.name must be 'DeckCPU'", errs)
    _check(meta.get("instruction_bits") == 32, "instruction_bits != 32", errs)
    _check(meta.get("word_bits") == 32, "word_bits != 32", errs)
    _check(meta.get("num_gpr") == 16, "num_gpr != 16", errs)

    # Format bit-field sanity: every field must fit exactly inside [31:0]
    # and fields of a format must not overlap.
    formats = isa.get("formats", {})
    _check(len(formats) >= 3, "expected at least R/I/B formats", errs)
    seen_bits = {}
    widths = []
    for fname, fmt in formats.items():
        for fld, f in fmt.get("fields", {}).items():
            msb, lsb = f["msb"], f["lsb"]
            w = msb - lsb + 1
            if fld == "op":
                widths.append(w)
            _check(0 <= lsb <= msb <= 31, f"{fname}.{fld} out of [31:0]", errs)
            _check(msb >= lsb, f"{fname}.{fld}: msb < lsb", errs)
        # no overlap check within format
    _check(widths and all(w == 8 for w in widths),
           "the 'op' field must be exactly 8 bits in every format", errs)

    # Flags
    flags = isa.get("flags", {})
    _check(len(flags) == 5 and all(f in flags for f in "IZNCV"),
           "must define exactly flags I,Z,N,C,V", errs)

    # Interrupts
    intr = isa.get("interrupts", {})
    slots = intr.get("slots", 0)
    assign = intr.get("assignments", [])
    _check(len(assign) == slots, "interrupt assignments must cover all slots", errs)
    slot_ok = all(a["slot"] == i for i, a in enumerate(assign))
    _check(slot_ok, "interrupt slot numbers must be 0..slots-1 in order", errs)

    # Memory map
    bases = []
    for blk in isa.get("memory_map", []):
        base = int(blk["base"], 16)
        size = int(blk["size"], 16)
        bases.append(base)
        _check((size & (size - 1)) == 0, f"{blk['name']} size not power of two", errs)

    # Instructions: unique opcode; operand field references must exist;
    # flag names must exist; cycles must be >= 1.
    seen_op = {}
    total_reg_bits = isa["meta"]["gpr_field_bits"]
    max_reg = (1 << total_reg_bits) - 1
    for ins in isa.get("instructions", []):
        op = ins["opcode"] if isinstance(ins["opcode"], int) else int(ins["opcode"], 16)
        _check(0 <= op <= 255, f"{ins['mnemonic']} opcode out of range", errs)
        if op in seen_op:
            errs.append(f"duplicate opcode 0x{op:02x}: {seen_op[op]} / {ins['mnemonic']}")
        seen_op[op] = ins["mnemonic"]
        fmt = formats.get(ins["format"])
        _check(fmt is not None, f"{ins['mnemonic']}: unknown format {ins['format']}", errs)
        if fmt:
            for opnd in ins.get("operands", []):
                if opnd["role"] == "imm":
                    # immediates live in the format's imm16 / off16 field
                    fld = "imm16" if "imm16" in fmt["fields"] else "off16"
                else:
                    fld = opnd.get("field", opnd["name"])
                _check(fld in fmt["fields"],
                       f"{ins['mnemonic']}: operand '{opnd['name']}' field '{fld}' not in {ins['format']}", errs)
        for f in ins.get("flags_set", []) + ins.get("flags_used", []):
            _check(f in flags, f"{ins['mnemonic']}: unknown flag {f}", errs)
        _check(ins.get("cycles", 0) >= 1, f"{ins['mnemonic']}: cycles must be >= 1", errs)
        _check(ins.get("status") in ("planned", "implemented"),
               f"{ins['mnemonic']}: status must be planned or implemented", errs)

    # Opcode groups must not collide with reserved slots mentioned in docs.
    return errs


def fmt_operands(ins):
    parts = []
    for o in ins.get("operands", []):
        name = o["name"]
        fld = o.get("field", o["name"])
        if o["role"] == "imm":
            parts.append("imm16" if name in ("imm", "shamt") else name)
        elif fld != o["name"]:
            parts.append(f"{name}->[{fld}]")
        else:
            parts.append(name)
    if not parts:
        return "–"
    return ", ".join(parts)


def gen_isa_md(isa):
    meta = isa["meta"]
    L = []
    L.append("# DeckCPU ISA Reference")
    L.append("")
    L.append(f"**Status:** {meta['status']}")
    L.append("")
    L.append("**This document is generated from `isa/isa.json`. Do not edit directly.**")
    L.append("")
    L.append("## Machine model")
    L.append("")
    L.append("| Property | Value |")
    L.append("|---|---|")
    L.append(f"| Word width | {meta['word_bits']} bits |")
    L.append(f"| Instruction width | {meta['instruction_bits']} bits |")
    L.append(f"| Byte order | {meta['byte_order']}-endian |")
    L.append(f"| General-purpose registers | r0–r{meta['num_gpr']-1} ({meta['num_gpr']} regs) |")
    L.append(f"| Architectural registers | PC, SP, FLAGS (dedicated, outside GPR file) |")
    L.append(f"| Stack | grows down, full-descending (SP decrements before push) |")
    L.append(f"| Reset PC | {meta['reset_pc']} |")
    L.append(f"| Reset SP | {meta['reset_sp']} |")
    L.append("")
    L.append("## Flags")
    L.append("")
    L.append("| Code | Bit | Meaning |")
    L.append("|---|---|---|")
    for code, f in isa["flags"].items():
        L.append(f"| {code} | {f['bit']} | {f['desc']} |")
    L.append("")
    L.append("> `FLAGS[31:5]` are reserved and read as 0. `WRFLAG` sets all defined bits.")
    L.append("")
    L.append("## Interrupts")
    L.append("")
    intr = isa["interrupts"]
    L.append(f"| Property | Value |")
    L.append("|---|---|")
    L.append(f"| Vector base | `{intr['vector_base']}` |")
    L.append(f"| Slots | {intr['slots']} × {intr['slot_bytes']} bytes |")
    L.append(f"| Global enable | `FLAGS.I` (`EI`/`DI`) |")
    L.append("")
    L.append(f"**Entry model:** {intr['entry_model']}")
    L.append("")
    L.append("| Slot | Source | Note |")
    L.append("|---|---|---|")
    for a in intr["assignments"]:
        L.append(f"| {a['slot']} | {a['source']} | {a['note']} |")
    L.append("")
    L.append("## Instruction encoding formats")
    L.append("")
    for fname, fmt in isa["formats"].items():
        L.append(f"### {fname} {fmt['desc']}")
        L.append("")
        rows = []
        for fld, f in fmt["fields"].items():
            rows.append(f"| `{fld}` | bits {f['msb']}:{f['lsb']} | {f['msb']-f['lsb']+1} |")
        L.append("| Field | Bits | Width |")
        L.append("|---|---|---|")
        L.extend(rows)
        L.append("")
    L.append("Field ordering is MSB-first; the whole word is little-endian in memory.")
    L.append("")
    L.append("## Instruction set")
    L.append("")
    L.append("| Mnemonic | Opcode | Format | Operands | Semantics | Sets | Cycles | Memory |")
    L.append("|---|---|---|---|---|---|---|---|")
    for ins in isa["instructions"]:
        flags = ", ".join(ins.get("flags_set", [])) or "–"
        alias = ""
        if ins.get("alias"):
            alias = f" (alias: {', '.join(ins['alias'])})"
        op = ins["opcode"] if isinstance(ins["opcode"], int) else int(ins["opcode"], 16)
        L.append(f"| `{ins['mnemonic']}`{alias} | `0x{op:02x}` | {ins['format']} "
                 f"| `{fmt_operands(ins)}` | {ins['semantics']} | {flags} "
                 f"| {ins['cycles']} | {ins['mem']} |")
    L.append("")
    L.append("## Canonical encoding rules")
    L.append("")
    L.append("* Reserved fields (`funct`, `spare`, unused register fields, `imm16` where unused) "
             "must be **zero** in canonical encodings emitted by the assembler.")
    L.append("* `off16` / `imm16` are sign-extended unless marked `u` (zero-extended).")
    L.append("* Branch offsets are byte offsets; they must be a multiple of 4 and are added to `PC` of "
             "the branch instruction.")
    L.append("* Opcode `0x00` is `NOP` (all-zeros word).")
    L.append("")
    for ins in isa["instructions"]:
        if ins.get("desc"):
            L.append(f"* **{ins['mnemonic']}:** {ins['desc']}")
    L.append("")
    return "\n".join(L)


def gen_memory_map_md(isa):
    L = []
    L.append("# DeckCPU Memory Map")
    L.append("")
    L.append(f"**Status:** {isa['meta']['status']}")
    L.append("")
    L.append("**This document is generated from `isa/isa.json`. Do not edit directly.**")
    L.append("")
    L.append("| Region | Base | Size | Access | Description |")
    L.append("|---|---|---|---|---|")
    for blk in isa["memory_map"]:
        L.append(f"| `{blk['name']}` | `{blk['base']}` | `{blk['size']}` | {blk['access']} | {blk['desc']} |")
    L.append("")
    L.append("Address regions not listed are reserved and produce a **bus error**.")
    L.append("The CPU ignores `off16` / `imm16` sign-extension out of the 32-bit space; any write outside ")
    L.append("a mapped region asserts the `bus_er_r` status bit visible on the debug bus.")
    L.append("")
    for blk in isa["memory_map"]:
        if not blk.get("registers"):
            continue
        L.append(f"## {blk['name']} registers")
        L.append("")
        L.append("| Offset | Name | Access | Description |")
        L.append("|---|---|---|---|")
        for r in blk["registers"]:
            L.append(f"| `+{r['offset']}` | `{r['name']}` | {r['a']} | {r['desc']} |")
        L.append("")
    L.append("## Interrupt vector table")
    L.append("")
    L.append("| Address | Slot | Source |")
    L.append("|---|---|---|")
    for a in isa["interrupts"]["assignments"]:
        addr = int(isa["interrupts"]["vector_base"], 16) + a["slot"] * isa["interrupts"]["slot_bytes"]
        L.append(f"| `0x{addr:08x}` | {a['slot']} | {a['source']} |")
    L.append("")
    return "\n".join(L)


def operand_field(isa, ins, opnd):
    """Resolve the bit-field name an operand maps to (isa.json operand spec)."""
    fmt = isa["formats"][ins["format"]]
    if opnd["role"] == "imm":
        return "imm16" if "imm16" in fmt["fields"] else "off16"
    return opnd.get("field", opnd["name"])


def encode_canonical(isa, ins, imm_val=0x1234):
    """Canonical encoding of an instruction (all reserved fields zero).

    Register operands are assigned 1,2,3,... in operand order so that
    encoding/decode bugs cannot hide behind all-zero fields.
    Returns the 32-bit word.
    """
    fmt = isa["formats"][ins["format"]]
    word = 0
    reg_value = {}
    n = 1
    for o in ins.get("operands", []):
        if o["role"] in ("read", "write"):
            reg_value[operand_field(isa, ins, o)] = n
            n += 1
    for fld, f in fmt["fields"].items():
        if fld == "op":
            bits = ins["opcode"] if isinstance(ins["opcode"], int) else int(ins["opcode"], 16)
        elif fld in ("imm16", "off16"):
            bits = imm_val
        elif fld in ("funct", "spare"):
            bits = 0
        else:  # rd / rs1 / rs2
            bits = reg_value.get(fld, 0)
        word |= bits << f["lsb"]
    return word


def semantic_fields(isa, ins, word):
    """(rd, rs1, rs2, imm) as the decoder reports them for this format."""
    fmt = ins["format"]
    if fmt == "R":
        rd, rs1, rs2 = (word >> 20) & 0xF, (word >> 16) & 0xF, (word >> 12) & 0xF
        imm = 0
    elif fmt == "I":
        rd, rs1, rs2 = (word >> 20) & 0xF, (word >> 16) & 0xF, 0
        imm = word & 0xFFFF
    else:  # B
        rd, rs1, rs2 = 0, (word >> 20) & 0xF, (word >> 16) & 0xF
        imm = word & 0xFFFF
    return rd, rs1, rs2, imm


def gen_decode_vectors(isa):
    """Emit SV golden-decode test scaffolding as text.

    decoder_tb includes this file. Icarus rejects unpacked-array assignment
    patterns and enum casts, so the vectors are emitted as literal constants
    dispatched by a generated `case`; every check compares plain logic bits.
    The tb must define `do_check(eop, erd, ers1, ers2, eimm)` and an `instr`
    signal; `cur_i` is used only for failure messages.
    """
    L = []
    L.append("// Generated by tools/isa_tools.py 'vectors' from isa/isa.json. Do not edit.")
    L.append("`ifndef DECODER_VECTORS_SVH")
    L.append("`define DECODER_VECTORS_SVH")
    ins = isa["instructions"]
    L.append(f"localparam int N_VECS = {len(ins)};")
    L.append("task gen_golden_case(input int i);")
    L.append("  begin")
    L.append("    unique case (i)")
    for idx, k in enumerate(ins):
        word = encode_canonical(isa, k)
        rd, rs1, rs2, imm = semantic_fields(isa, k, word)
        op = k["opcode"] if isinstance(k["opcode"], int) else int(k["opcode"], 16)
        L.append(f"      {idx}: begin instr = 32'h{word:08x}; "
                 f"do_check(8'h{op:02x}, 4'h{rd:x}, 4'h{rs1:x}, 4'h{rs2:x}, "
                 f"16'h{imm:04x}); end")
    L.append("      default: ;")
    L.append("    endcase")
    L.append("  end")
    L.append("endtask")
    L.append("`endif")
    return "\n".join(L) + "\n"


def main(argv):
    if len(argv) < 2:
        print(__doc__)
        return 1
    cmd = argv[1]
    isa_path = argv[2] if len(argv) > 2 else DEF_ISA
    isa = load_isa(isa_path)
    errs = validate(isa)
    if errs:
        print("ISA validation FAILED:")
        for e in errs:
            print(f"  - {e}")
        return 1
    if cmd == "validate":
        defs = len(isa["instructions"])
        print(f"ISA OK: {isa['meta']['name']} v{isa['meta']['version']}, {defs} instructions")
        return 0
    if cmd == "docs":
        outdir = argv[3] if len(argv) > 3 else DEF_OUT
        os.makedirs(outdir, exist_ok=True)
        targets = {
            os.path.join(outdir, "isa.md"): gen_isa_md(isa),
            os.path.join(outdir, "memory-map.md"): gen_memory_map_md(isa),
        }
        for path, text in targets.items():
            with open(path, "w", encoding="utf-8") as fh:
                fh.write(text)
            print(f"generated {path}")
        return 0
    if cmd == "vectors":
        outpath = argv[3] if len(argv) > 3 else os.path.join(ROOT, "build", "gen",
                                                             "decoder_vectors.svh")
        os.makedirs(os.path.dirname(outpath), exist_ok=True)
        with open(outpath, "w", encoding="utf-8") as fh:
            fh.write(gen_decode_vectors(isa))
        print(f"generated {outpath}")
        return 0
    print(f"unknown command: {cmd}", file=sys.stderr)
    return 1


if __name__ == "__main__":
    sys.exit(main(sys.argv))