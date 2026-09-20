#!/usr/bin/env python3
"""deckc driver: preprocess + parse + codegen a set of C files into one
DeckCPU assembly image.

Usage:
    python3 -m deckc.deckc -I INC_DIR... -o out.s file.c...

The sources (kernel syslog.c, BSP shims, test main) are preprocessed with a
single Preprocessor (shared #define state) and parsed with a single Parser
(shared typedef/enum/struct state). The resulting AST is lowered to one
flat .s file that also embeds the hand-written runtime (crt0 + libc shims)
via a textual header, so the assembler resolves every symbol in one address
space.
"""

from __future__ import annotations

import os
import sys

from .pp import Preprocessor
from .parser import parse_tokens
from .codegen import emit_program

DEFAULT_RT = os.path.join(os.path.dirname(__file__), "rt")


def _cat(path):
    with open(path, "r", encoding="utf-8") as fh:
        return fh.read()


def compile_c(files, include_dirs, out_s, rt_dir=DEFAULT_RT):
    pp = Preprocessor(include_dirs)
    toks = []
    for f in files:
        ft = pp.process_file(f)
        if not ft:
            print(f"warn: no tokens from {f}", file=sys.stderr)
        toks.extend(ft)
    decls, globals_, _typedefs, _enums, _structs = parse_tokens(toks)
    code, data = emit_program(decls, globals_)

    lines = []
    lines.append("; deckc-generated DeckCPU assembly")
    lines.append("; source: " + ", ".join(os.path.basename(f) for f in files))
    lines.append("")
    lines.append('; ---- runtime ----')
    rt_main = os.path.join(rt_dir, "crt0.s")
    if os.path.exists(rt_main):
        lines.append(_cat(rt_main).rstrip())
    lines.append("")
    lines.append('; ---- program code ----')
    lines.extend(code)
    lines.append("")
    lines.append('; ---- data ----')
    lines.extend(data)
    lines.append("")
    out = "\n".join(lines) + "\n"

    with open(out_s, "w", encoding="utf-8") as fh:
        fh.write(out)
    return out_s


def main():
    files, include_dirs = [], []
    out = None
    rt_dir = DEFAULT_RT
    argv = sys.argv[1:]
    i = 0
    while i < len(argv):
        a = argv[i]
        if a in ("-I", "--include"):
            i += 1
            include_dirs.append(argv[i])
        elif a in ("-o", "--out"):
            i += 1
            out = argv[i]
        elif a == "--rt":
            i += 1
            rt_dir = argv[i]
        else:
            files.append(a)
        i += 1
    if not files:
        print("usage: deckc -I INC... -o out.s file.c...", file=sys.stderr)
        return 1
    if out is None:
        out = files[0].replace(".c", "") + ".s"
    compile_c(files, include_dirs, out, rt_dir)
    print(f"wrote {out} ({sum(1 for _ in open(out))} lines)")
    return 0


if __name__ == "__main__":
    sys.exit(main())