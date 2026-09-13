#!/usr/bin/env python3
"""Cross-check deckcpu_pkg.sv opcode enum against isa/isa.json.

Fails if the RTL package and the ISA specification disagree on any opcode
byte value. This is the Phase-1 guarantee that the authoritative spec
drives the RTL.

Usage:
    python3 tools/check_pkg_isa.py [root]
"""

import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def extract_rtl_opcodes(path):
    """Return {mnemonic: int} from the enum in deckcpu_pkg.sv."""
    out = {}
    pat = re.compile(r"^\s*OP_([A-Z0-9_]+)\s*=\s*8'h([0-9a-fA-F]{2})")
    with open(path, "r", encoding="utf-8") as fh:
        for line in fh:
            m = pat.match(line)
            if m:
                out[m.group(1)] = int(m.group(2), 16)
    return out


def main(argv):
    root = argv[1] if len(argv) > 1 else ROOT
    isa_path = os.path.join(root, "isa", "isa.json")
    pkg_path = os.path.join(root, "rtl", "pkg", "deckcpu_pkg.sv")

    import json
    with open(isa_path, "r", encoding="utf-8") as fh:
        isa = json.load(fh)

    # rtl map keys are bare names without the OP_ prefix: NOP, LDH, ...
    rtl = extract_rtl_opcodes(pkg_path)
    spec = {ins["mnemonic"]: (ins["opcode"] if isinstance(ins["opcode"], int)
                              else int(ins["opcode"], 16))
            for ins in isa["instructions"]}

    def bare(mnemonic):
        return mnemonic.replace(".", "")

    errors = []
    for mnemonic, op in spec.items():
        name = bare(mnemonic)
        if name not in rtl:
            errors.append(f"missing in RTL package: OP_{name}")
            continue
        if rtl[name] != op:
            errors.append(f"opcode mismatch OP_{name}: RTL=0x{rtl[name]:02x} "
                          f"isa.json=0x{op:02x}")

    # RTL must not define opcodes that the spec does not know about.
    known = {bare(ins["mnemonic"]) for ins in isa["instructions"]}
    for name, op in rtl.items():
        if name not in known:
            errors.append(f"RTL has extra opcode OP_{name}=0x{op:02x} not in isa.json")

    if errors:
        print("pkg/isa cross-check FAILED:")
        for e in errors:
            print(f"  - {e}")
        return 1
    print(f"pkg/isa cross-check OK: {len(spec)} opcodes match isa.json")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))