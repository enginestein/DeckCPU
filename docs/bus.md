# DeckCPU Bus

> **Status: implemented.** `rtl/bus/bus.sv` implements this
> contract; `bus_tb.sv` verifies decode, byte enables, fault behaviour, a
> store/read transaction through to `rtl/memory/ram.sv`, and real MMIO
> traffic through all four peripheral windows (UART, TIMER, GPIO, SPI).

## Overview

Single-master, synchronous, no wait states. The CPU is the only master; all
window decodes are combinational over the registered master address. Sub-word
accesses use byte-enable strobes.

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

All signals are sampled/asserted for one cycle during the `MEM` stage of the
control FSM. Peripherals and RAM return `rdata` combinationally on `re`.

Byte enable diamonds:

- word access: `be = 4'b1111`, `addr[1:0] == 2'b00`
- halfword access: `be = 4'b0011` or `4'b1100`, `addr[0] == 0`
- byte access: exactly one `be` bit set

Misaligned accesses are treated as follows (implemented): loads keep their
byte-enable semantics (no fault, documented extension); stores are
byte-enable-masked. The CPU only ever issues naturally-aligned accesses
because the ISA's `LD/ST` address field is a register+offset and the
assembler enforces alignment. A bus error (unmapped address) drives the
control FSM straight to `HALT` (verified by `cpu_fsm_tb`).

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

An address outside every window faults: `err=1`, zero read data, and the CPU
FSM enters `HALT`. A **mapped but unmapped** MMIO window (peripheral with no
handler) is *not* a fault — it decodes a defined slave and returns `err=0`,
`rdata=0`.