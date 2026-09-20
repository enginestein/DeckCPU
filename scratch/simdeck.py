"""Minimal DeckCPU interpreter used to validate deckc-generated code.

Semantics mirror rtl/cpu/cpu.sv, rtl/alu/alu.sv, rtl/control/decoder.sv and
rtl/control/branch_cond.sv. Byte-addressed 64 KiB RAM, stack grows down from
0x0000FFFC. Flags register bit positions: I=0 Z=1 N=2 C=3 V=4. Branch target =
pc + sext(off16).
"""
import json
import os
import sys

SZMASK = 0xFFFFFFFF
FLG_Z, FLG_N, FLG_C, FLG_V, FLG_I = 1, 2, 3, 4, 0


def sext16(v):
    v &= 0xFFFF
    return v - 0x10000 if v & 0x8000 else v


def decode_fields(w):
    op = (w >> 24) & 0xFF
    rd = (w >> 20) & 0xF
    rs1 = (w >> 16) & 0xF
    rs2 = (w >> 12) & 0xF
    imm = w & 0xFFFF
    return op, rd, rs1, rs2, imm, sext16(imm)


def build_decode(isa):
    d = {}
    for ins in isa['instructions']:
        d[int(ins['opcode'], 0)] = ins
    return d


def ovf_add(a, b):
    s = (a + b) & SZMASK
    return ((~(a ^ b) & (a ^ s)) & 0x80000000) != 0


def ovf_sub(a, b):
    s = (a - b) & SZMASK
    return (((a ^ b) & (a ^ s)) & 0x80000000) != 0


def run(program, isa, uart_out=None, max_cycles=20_000_000):
    fmt = isa['formats']
    reg = [0] * 16
    pc = 0
    sp = 0x0000FFFC
    fl = 0
    mem = bytearray(65536)
    addr_max = 0
    for a, w in program:
        mem[a:a + 4] = w.to_bytes(4, 'little')
        addr_max = max(addr_max, a + 4)
    uart_out = uart_out if uart_out is not None else []
    timer = {'ctrl': 0, 'prescale': 0, 'compare': 0, 'count': 0}
    d = build_decode(isa)
    trace = os.environ.get('DECKC_TRACE')
    hist = []
    stores = []

    def flags(y, V=False, C=False):
        nonlocal fl
        fl = (fl & 1) | ((1 << FLG_Z) if y == 0 else 0) | \
             ((1 << FLG_N) if (y >> 31) & 1 else 0) | \
             ((1 << FLG_C) if C else 0) | \
             ((1 << FLG_V) if V else 0)

    cycles = 0
    while cycles < max_cycles:
        cycles += 1
        if timer['ctrl'] & 1:
            timer['count'] = (timer['count'] + timer['prescale'] + 1) & SZMASK
        if pc >= addr_max:
            if trace:
                for hpc, hm, hreg, hsp in hist[-24:]:
                    print(f"  {hpc:#08x}: {hm} r={[hreg[i] for i in range(16)]!r}")
                print(f"  regs={[reg[i] for i in range(16)]!r} sp={sp:#x}")
                for a in range(sp - 16, sp + 40, 4):
                    print(f"  mem[{a:#x}..{a+3:#x}] = {int.from_bytes(mem[a:a+4], 'little'):08x}")
                print(f"  {pc:#08x}: (PC out of image)")
            raise RuntimeError(f"PC {pc:#x} out of image (max {addr_max:#x})")
        w = int.from_bytes(mem[pc:pc + 4], 'little')
        op, rd, rs1, rs2, imm, se = decode_fields(w)
        ins = d.get(op)
        if ins is None:
            if trace:
                for hpc, hm, hreg, hsp in hist[-24:]:
                    print(f"  {hpc:#08x}: op={hop:#02x} r={[hreg[i] for i in range(16)]!r}")
                print(f"  {pc:#08x}: op={op:#02x} (BAD)")
            raise RuntimeError(f"unknown opcode {op:#04x} at {pc:#x}")
        m = ins['mnemonic']
        f = fmt[ins['format']]
        ra = reg[rs1]
        rb = reg[rs2]
        target = (pc + se) & SZMASK
        if trace:
            hist.append((pc, m, list(reg), sp))

        def loadu(addr, n, signed=False):
            b = mem[addr:addr + n]
            if len(b) < n:
                b += bytes(n - len(b))
            return int.from_bytes(b, 'little', signed=signed)

        if m == 'CMP':
            y = (ra - rb) & SZMASK
            flags(y, V=ovf_sub(ra, rb), C=(ra < rb))
        elif m == 'CMPI':
            y = (ra - se) & SZMASK
            flags(y, V=ovf_sub(ra, se & SZMASK), C=(ra < (se & SZMASK)))
        elif m == 'ADD':
            y = (ra + rb) & SZMASK
            flags(y, V=ovf_add(ra, rb), C=y < ra)
            reg[rd] = y
        elif m == 'ADDI':
            y = (ra + se) & SZMASK
            flags(y, V=ovf_add(ra, se & SZMASK), C=y < ra)
            reg[rd] = y
        elif m == 'SUB':
            y = (ra - rb) & SZMASK
            flags(y, V=ovf_sub(ra, rb), C=ra < rb)
            reg[rd] = y
        elif m == 'SUBI':
            y = (ra - se) & SZMASK
            flags(y, V=ovf_sub(ra, se & SZMASK), C=ra < (se & SZMASK))
            reg[rd] = y
        elif m == 'MUL':
            y = (ra * rb) & SZMASK
            flags(y)
            reg[rd] = y
        elif m == 'MULI':
            y = (ra * (se & SZMASK)) & SZMASK
            flags(y)
            reg[rd] = y
        elif m == 'AND':
            y = ra & rb
            flags(y)
            reg[rd] = y
        elif m == 'ANDI':
            y = ra & imm
            flags(y)
            reg[rd] = y
        elif m == 'OR':
            y = ra | rb
            flags(y)
            reg[rd] = y
        elif m == 'ORI':
            y = ra | imm
            flags(y)
            reg[rd] = y
        elif m == 'XOR':
            y = ra ^ rb
            flags(y)
            reg[rd] = y
        elif m == 'XORI':
            y = ra ^ imm
            flags(y)
            reg[rd] = y
        elif m == 'NOT':
            y = (~ra) & SZMASK
            flags(y)
            reg[rd] = y
        elif m == 'SHL':
            s = rb & 0x1F
            y = (ra << s) & SZMASK
            c = ((ra >> (32 - s)) & 1) if s else 0
            flags(y, C=c)
            reg[rd] = y
        elif m == 'SHLI':
            s = imm & 0x1F
            y = (ra << s) & SZMASK
            c = ((ra >> (32 - s)) & 1) if s else 0
            flags(y, C=c)
            reg[rd] = y
        elif m == 'SHR':
            s = rb & 0x1F
            y = ra >> s
            c = ((ra >> (s - 1)) & 1) if s else 0
            flags(y, C=c)
            reg[rd] = y
        elif m == 'SHRI':
            s = imm & 0x1F
            y = ra >> s
            c = ((ra >> (s - 1)) & 1) if s else 0
            flags(y, C=c)
            reg[rd] = y
        elif m == 'LI':
            reg[rd] = imm
        elif m == 'LIH':
            reg[rd] = (imm << 16) & SZMASK
        elif m == 'MOV':
            reg[rd] = ra
        elif m == 'RDSP':
            reg[rd] = sp
        elif m == 'WRSP':
            sp = ra
        elif m == 'LD':
            a = (ra + se) & SZMASK
            if a == 0x4000100C:
                y = timer['count']
            elif a == 0x40001000:
                y = timer['ctrl']
            elif a == 0x40001004:
                y = timer['prescale']
            elif a == 0x40001008:
                y = timer['compare']
            else:
                y = loadu(a, 4)
            reg[rd] = y
            if rd == 11 and rs1 == 4 and se == 0:
                stores.append(('ARG', pc, a, y))
        elif m == 'LD.H':
            reg[rd] = loadu((ra + se) & SZMASK, 2)
        elif m == 'LD.B':
            y = loadu((ra + se) & SZMASK, 1)
            reg[rd] = y
            if rd == 11 and rs1 == 1 and se == 0:
                stores.append(('SBL', pc, (ra + se) & SZMASK, y))
        elif m == 'ST':
            a = (ra + se) & SZMASK
            v = reg[rd]
            if a == 0x40000000:
                uart_out.append(v & 0xFF)
            elif a == 0x40001000:
                timer['ctrl'] = v & SZMASK
            elif a == 0x40001004:
                timer['prescale'] = v & SZMASK
            elif a == 0x40001008:
                timer['compare'] = v & SZMASK
            else:
                mem[a:a + 4] = v.to_bytes(4, 'little')
            stores.append((m, a, v))
        elif m == 'ST.H':
            a = (ra + se) & SZMASK
            v = reg[rd]
            if a == 0x40000000:
                uart_out.append(v & 0xFF)
            else:
                mem[a:a + 2] = (v & 0xFFFF).to_bytes(2, 'little')
            stores.append((m, a, v & 0xFFFF))
        elif m == 'ST.B':
            a = (ra + se) & SZMASK
            v = reg[rd]
            if a == 0x40000000:
                uart_out.append(v & 0xFF)
            else:
                mem[a] = v & 0xFF
            stores.append((m, a, v))
        elif m == 'PUSH':
            a = (sp - 4) & SZMASK
            sp = a
            mem[a:a + 4] = ra.to_bytes(4, 'little')
            stores.append(('PUSH', pc, a, ra))
        elif m == 'POP':
            a = sp
            reg[rd] = int.from_bytes(mem[a:a + 4], 'little')
            sp = (sp + 4) & SZMASK
        elif m == 'JMP':
            pc = target
            continue
        elif m == 'JMPR':
            pc = ra
            continue
        elif m == 'CALL':
            a = (sp - 4) & SZMASK
            sp = a
            mem[a:a + 4] = ((pc + 4) & SZMASK).to_bytes(4, 'little')
            pc = target
            continue
        elif m == 'RET':
            a = sp
            pc = int.from_bytes(mem[a:a + 4], 'little')
            sp = (sp + 4) & SZMASK
            continue
        elif m in ('BEQ', 'BNE', 'BLT', 'BGE', 'BLTU', 'BGEU'):
            Z = (fl >> FLG_Z) & 1
            N = (fl >> FLG_N) & 1
            C = (fl >> FLG_C) & 1
            V = (fl >> FLG_V) & 1
            taken = {'BEQ': Z, 'BNE': not Z, 'BLT': N != V,
                     'BGE': N == V, 'BLTU': C, 'BGEU': not C}[m]
            if taken:
                pc = target
                continue
        elif m == 'HALT':
            return {'regs': reg, 'mem': mem, 'out': uart_out,
                    'cycles': cycles, 'pc': pc, 'fl': fl,
                    'stores': stores}
        elif m == 'NOP':
            pass
        elif m in ('EI', 'DI'):
            pass
        elif m == 'IRET':
            raise RuntimeError('IRET not modelled')
        elif m == 'RDFLAG':
            reg[rd] = fl
        elif m == 'WRFLAG':
            fl = ra & 0x1F
        else:
            raise RuntimeError(f"unhandled {m} at {pc:#x}")
        pc = (pc + 4) & SZMASK
    raise RuntimeError(f"did not halt within {max_cycles} cycles (pc={pc:#x})")


def main():
    path = sys.argv[1]
    root = '/home/indresh/embedded/deckcpu'
    sys.path.insert(0, root + '/software/assembler')
    sys.path.insert(0, root + '/software')
    from assembler import Assembler, load_isa
    a = Assembler(load_isa(root + '/isa/isa.json'))
    p = a.assemble_file(path)
    if not p.ok:
        print('ASSEMBLY ERRORS:')
        for e in p.errors:
            print(' ', e)
        raise SystemExit(1)
    print(f"assembled {path}: {len(p.words)} words, {len(p.labels)} labels")
    r = run(p.words, load_isa(root + '/isa/isa.json'))
    mb = r['mem'][0xDF00:0xDF04]
    regs = ', '.join('r%d=%#x' % (i, r['regs'][i]) for i in range(16))
    print(f"halted at pc={r['pc']:#x} after {r['cycles']} cycles, fl={r['fl']:02x}")
    print(f"regs = {regs}")
    print(f"mailbox[0xDF00] = {int.from_bytes(mb, 'little'):#x}")
    u = b''.join(bytes([b]) for b in r['out'])
    print(f"uart bytes({len(r['out'])}): {u!r}")


if __name__ == '__main__':
    main()