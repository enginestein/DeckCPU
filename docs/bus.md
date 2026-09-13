# DeckCPU Bus

> **Status: Phase 1 (design spec).** The bus does not exist yet; this
> document is the contract the RAM and peripheral modules will implement.

## Overview

Single-master, synchronous, no wait states. The CPU is the only master; all
window decodes are combinational. Sub-word accesses use byte-enable strobes.

## Signalling

| Signal | Dir (from CPU) | Width | Meaning |
|---|---|---|---|
| `addr` | out | 32 | byte address |
| `wdata` | out | 32 | write data |
| `rdata` | in | 32 | read data (valid when `re`) |
| `be` | out | 4 | byte enables for writes |
| `we` | out | 1 | write strobe |
| `re` | out | 1 | read strobe |
| `err` | in | 1 | bus error (unmapped / forbidden) |

All signals are sampled/asserted for one cycle during the `MEM` phase of the
control FSM. Peripherals and RAM return `rdata` combinationally on `re`.

Byte enable diamonds:

- word access: `be = 4'b1111`, `addr[1:0] == 2'b00`
- halfword access: `be = 4'b0011` or `4'b1100`, `addr[0] == 0`
- byte access: exactly one `be` bit set

Misaligned accesses are treated as follows (planned): loads keep their
byte-enable semantics (no fault, documented extension); stores are
byte-enable-masked. The initial CPU only ever issues naturally-aligned
accesses because the ISA's `LD/ST` address field is a register+offset and the
assembler enforces alignment. A **fault policy** (trap vs `HALT`) is a
Phase-4 TODO.

## Decode

| Address window | Target |
|---|---|
| `0x00000000 – 0x0000FFFF` | RAM |
| `0x40000000 – 0x40000FFF` | UART |
| `0x40001000 – 0x40001FFF` | TIMER |
| `0x40002000 – 0x40002FFF` | GPIO |
| `0x40003000 – 0x40003FFF` | SPI |
| anything else | `err = 1`, `rdata = 0` |

## Error handling

An unmapped address asserts `err=1` and returns zero read data. The CPU (Phase
4 TODO) will latch this and either trap to the IVT or halt. For Phase 1 the
error is merely observable on `dbg.bus_err`.