import sys

root = '/home/indresh/embedded/deckcpu'
sys.path.insert(0, root + '/software/assembler')
sys.path.insert(0, root + '/software')
from assembler import Assembler, load_isa

isa = load_isa(root + '/isa/isa.json')
a = Assembler(isa)
p = a.assemble_file('syslog.s')
import simdeck as sd

r = sd.run(p.words, isa)
mem = r['mem']
sbls = [t for t in r['stores'] if t[0] == 'SBL']
it = [t for t in sbls if 0x2b70 <= t[2] <= 0x2c90 or 0xeac0 <= t[2] <= 0xed00]
print('emit-byte reads in literal or snapshot regions:', len(it))
for t in it[:110]:
    pc, addr, val = t[1], t[2], t[3]
    c = chr(val) if 32 <= val < 127 else '.'
    print(f'  pc={pc:#06x} r1={addr:#06x} byte={val:#04x} {c}')