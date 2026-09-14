#!/usr/bin/env python3
"""DeckCPU assembler / disassembler command line.

Usage:
    python3 -m software.assembler asm  FILE.s [-o OUT.hex] [--origin ADDR]
    python3 -m software.assembler dis  FILE.hex
    python3 -m software.assembler images FILE.s   (print word image)

The .hex format matches tools/gen_programs.py: an @-addressed byte
image (4 little-endian bytes per word), so assembler output is directly
comparable to the golden sim/programs/*.hex files.
"""

import os
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
sys.path.insert(0, ROOT)
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from assembler import Assembler, load_isa, read_hex_words  # noqa: E402
from disasm import Disassembler  # noqa: E402

ISA_PATH = os.path.join(ROOT, "isa", "isa.json")


def main(argv):
    asm = Assembler(load_isa(ISA_PATH))
    dasm = Disassembler(load_isa(ISA_PATH))
    if len(argv) < 2:
        print(__doc__)
        return 1
    cmd, path = argv[1], argv[2]
    if cmd == "asm":
        prog = asm.assemble_file(path)
        if not prog.ok:
            for ln, msg in prog.errors:
                print(f"{os.path.basename(path)}:{ln}: {msg}", file=sys.stderr)
            return 1
        if "-o" in argv:
            prog.write_hex(argv[argv.index("-o") + 1])
        else:
            for a, w in prog.words:
                print(f"0x{a:04X} 0x{w:08X}")
        return 0
    if cmd == "dis":
        for line in dasm.disasm_program(read_hex_words(path), emit_addresses=True):
            print(line)
        return 0
    if cmd == "images":
        prog = asm.assemble_file(path)
        if not prog.ok:
            for ln, msg in prog.errors:
                print(f"{os.path.basename(path)}:{ln}: {msg}", file=sys.stderr)
            return 1
        for i, w in enumerate(prog.word_image()):
            print(f"        PW[{i}] = 32'h{w:08X};")
        return 0
    print(f"unknown command '{cmd}'", file=sys.stderr)
    return 1


if __name__ == "__main__":
    sys.exit(main(sys.argv))