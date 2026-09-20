#!/usr/bin/env python3
"""Reference DeckCPU interpreter for deckc images.

Executes an assembled deckc program (a list of (address, word) pairs as
produced by the assembler) and models the MMIO devices the deckc runtime
uses - UART TX at 0x40000000 and the TIMER at 0x40001000 - with the same
semantics as the RTL:

  - one instruction retires per clock cycle (UART TX instantaneous, no wait
    states); IMEM/RAM loads take one cycle
  - TIMER COUNT at +0x0C increments by (PRESCALE + 1) every clock while
    CTRL.ENABLE (bit0) is set; PRESCALE defaults to 0 so COUNT free-runs
    at one tick per clock, matching rtl/peripherals/timer.sv
  - HALT stops execution and returns the final machine state

Instruction decode/ALU/branch semantics mirror scratch/simdeck.py, which in
turn mirrors rtl/cpu, rtl/alu and rtl/control. Flags: I=0 Z=1 N=2 C=3 V=4.
Interrupts are never used on this target: EI/DI are no-ops, IRET raises.

Run standalone:
    python3 -m deckc.sim path.s          # assemble + run + print transcript
"""

from __future__ import annotations

import os
import sys
from pathlib import Path

SZMASK = 0xFFFFFFFF
FLG_Z, FLG_N, FLG_C, FLG_V, FLG_I = 1, 2, 3, 4, 0
MAILBOX = 0x0000DF00
UART_BASE = 0x40000000
TIMER_BASE = 0x40001000
GPIO_BASE = 0x40002000
MEM_SIZE = 65536

ROOT = Path(__file__).resolve().parents[2]
ISA_JSON = ROOT / "isa" / "isa.json"


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


def load_isa(path):
    import json
    with open(path) as fh:
        return json.load(fh)


def ovf_add(a, b):
    s = (a + b) & SZMASK
    return ((~(a ^ b) & (a ^ s)) & 0x80000000) != 0


def ovf_sub(a, b):
    s = (a - b) & SZMASK
    return (((a ^ b) & (a ^ s)) & 0x80000000) != 0


def run(program, isa, uart_out=None, uart_in=None, max_cycles=20_000_000):
    fmt = isa['formats']
    reg = [0] * 16
    pc = 0
    sp = 0x0000FFFC
    fl = 0
    mem = bytearray(MEM_SIZE)
    addr_max = 0
    for a, w in program:
        mem[a:a + 4] = w.to_bytes(4, 'little')
        addr_max = max(addr_max, a + 4)
    uart_out = uart_out if uart_out is not None else []
    uart = {'ctrl': 3, 'baud': 0}
    timer = {'ctrl': 0, 'prescale': 0, 'compare': 0, 'count': 0}
    gpio = {'dir': 0, 'out': 0, 'in': 0}
    rx_fifo = list(uart_in) if uart_in is not None else []
    d = build_decode(isa)
    trace = os.environ.get('DECKC_TRACE')
    hist = []

    def flags(y, V=False, C=False):
        nonlocal fl
        fl = (fl & 1) | ((1 << FLG_Z) if y == 0 else 0) | \
             ((1 << FLG_N) if (y >> 31) & 1 else 0) | \
             ((1 << FLG_C) if C else 0) | \
             ((1 << FLG_V) if V else 0)

    def loadu(addr, n, signed=False):
        b = mem[addr:addr + n]
        if len(b) < n:
            b += bytes(n - len(b))
        return int.from_bytes(b, 'little', signed=signed)

    def mmio_ld(a, n):
        val = None
        if UART_BASE <= a < UART_BASE + 0x14:
            off = (a - UART_BASE) & ~3
            lane = (a - UART_BASE) & 3
            if off == 0:
                val = 0
            elif off == 0x04:              # RXD; read clears RX_READY
                val = rx_fifo.pop(0) if rx_fifo else 0
            elif off == 0x08:              # STS: TXB_BUSY|RX_READY|TX_READY
                val = 4 | (2 if rx_fifo else 0)
            elif off == 0x0C:
                val = uart['ctrl']
            elif off == 0x10:
                val = uart['baud']
            else:
                val = 0
        elif TIMER_BASE <= a < TIMER_BASE + 0x14:
            off = (a - TIMER_BASE) & ~3
            lane = (a - TIMER_BASE) & 3
            val = {0x00: timer['ctrl'], 0x04: timer['prescale'],
                   0x08: timer['compare'], 0x0C: timer['count']}.get(off, 0)
        elif GPIO_BASE <= a < GPIO_BASE + 0x18:
            off = (a - GPIO_BASE) & ~3
            lane = (a - GPIO_BASE) & 3
            val = {0x00: gpio['dir'], 0x04: gpio['out'],
                   0x08: gpio['in']}.get(off, 0)
        else:
            return None
        return (val >> (8 * lane)) & ((1 << (8 * n)) - 1)

    def mmio_st(a, v, n):
        m = (1 << (8 * n)) - 1
        if UART_BASE <= a < UART_BASE + 0x14:
            off = (a - UART_BASE) & ~3
            if off == 0:
                uart_out.append(v & 0xFF)
            elif off == 0x0C:
                uart['ctrl'] = v
            elif off == 0x10:
                uart['baud'] = v
            return True
        if TIMER_BASE <= a < TIMER_BASE + 0x14:
            off = (a - TIMER_BASE) & ~3
            lane = (a - TIMER_BASE) & 3
            sh = 8 * lane
            cur = {0x00: 'ctrl', 0x04: 'prescale', 0x08: 'compare'}.get(off)
            if cur is not None:
                timer[cur] = (timer[cur] & ~(m << sh)) | ((v & m) << sh)
                timer[cur] &= SZMASK
            return True
        if GPIO_BASE <= a < GPIO_BASE + 0x18:
            off = (a - GPIO_BASE) & ~3
            lane = (a - GPIO_BASE) & 3
            sh = 8 * lane
            key = {0x00: 'dir', 0x04: 'out', 0x08: 'in'}.get(off)
            if key is not None:
                gpio[key] = (gpio[key] & ~(m << sh)) | ((v & m) << sh)
                gpio[key] &= SZMASK
            return True
        return False

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
            raise RuntimeError(f"PC {pc:#x} out of image (max {addr_max:#x})")
        w = int.from_bytes(mem[pc:pc + 4], 'little')
        op, rd, rs1, rs2, imm, se = decode_fields(w)
        ins = d.get(op)
        if ins is None:
            if trace:
                for hpc, hm, hreg, hsp in hist[-24:]:
                    print(f"  {hpc:#08x}: r={[hreg[i] for i in range(16)]!r}")
            raise RuntimeError(f"unknown opcode {op:#04x} at {pc:#x}")
        m = ins['mnemonic']
        f = fmt[ins['format']]
        del f
        ra = reg[rs1]
        rb = reg[rs2]
        target = (pc + se) & SZMASK
        if trace:
            hist.append((pc, m, list(reg), sp))

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
            y = mmio_ld(a, 4)
            reg[rd] = y if y is not None else loadu(a, 4)
        elif m == 'LD.H':
            a = (ra + se) & SZMASK
            y = mmio_ld(a, 2)
            reg[rd] = y if y is not None else loadu(a, 2)
        elif m == 'LD.B':
            a = (ra + se) & SZMASK
            y = mmio_ld(a, 1)
            reg[rd] = y if y is not None else loadu(a, 1)
        elif m == 'ST':
            a = (ra + se) & SZMASK
            v = reg[rd]
            if not mmio_st(a, v, 4):
                mem[a:a + 4] = v.to_bytes(4, 'little')
        elif m == 'ST.H':
            a = (ra + se) & SZMASK
            v = reg[rd]
            if not mmio_st(a, v, 2):
                mem[a:a + 2] = (v & 0xFFFF).to_bytes(2, 'little')
        elif m == 'ST.B':
            a = (ra + se) & SZMASK
            v = reg[rd]
            if not mmio_st(a, v, 1):
                mem[a] = v & 0xFF
        elif m == 'PUSH':
            a = (sp - 4) & SZMASK
            sp = a
            mem[a:a + 4] = ra.to_bytes(4, 'little')
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
                    'cycles': cycles, 'pc': pc, 'fl': fl, 'gpio': gpio}
        elif m in ('NOP', 'EI', 'DI'):
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


def assemble_image(asm_path, isa):
    from assembler import Assembler
    a = Assembler(isa)
    p = a.assemble_file(str(asm_path))
    if not p.ok:
        for e in p.errors:
            print('  ', e, file=sys.stderr)
        raise SystemExit(f"assembly of {asm_path} failed")
    return p.words, p


def read_mailbox(r):
    return int.from_bytes(r['mem'][MAILBOX:MAILBOX + 4], 'little')


def main():
    path = sys.argv[1]
    isa = load_isa(str(ISA_JSON))
    words, p = assemble_image(path, isa)
    print(f"assembled {path}: {len(words)} words, {len(p.labels)} labels")
    r = run(words, isa)
    print(f"halted at pc={r['pc']:#x} after {r['cycles']} cycles, fl={r['fl']:02x}")
    print(f"mailbox[0xDF00] = {read_mailbox(r):#x}")
    print(f"uart bytes({len(r['out'])}): {bytes(r['out'])!r}")


if __name__ == '__main__':
    sys.exit(main())