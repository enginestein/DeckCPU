# DeckCPU Memory Map

**Status:** Phase 1 - design spec, nothing implemented yet

**This document is generated from `isa/isa.json`. Do not edit directly.**

| Region | Base | Size | Access | Description |
|---|---|---|---|---|
| `RAM` | `0x00000000` | `0x00010000` | rw | 64 KiB byte-addressable SRAM. Holds IVT (0x0-0x1F), code, data, and the stack (grows down from 0x0000FFFC). |
| `UART` | `0x40000000` | `0x00001000` | mmio | Simulated UART. TXD writes produce terminal output on the host. |
| `TIMER` | `0x40001000` | `0x00001000` | mmio | Free-running compare timer with match interrupt. |
| `GPIO` | `0x40002000` | `0x00001000` | mmio | 32 simulated input/output pins. |
| `SPI` | `0x40003000` | `0x00001000` | mmio | Simulated SPI master/slave used by virtual peripherals (e.g. MPU6050). |

Address regions not listed are reserved and produce a **bus error**.
The CPU ignores `off16` / `imm16` sign-extension out of the 32-bit space; any write outside 
a mapped region asserts the `bus_er_r` status bit visible on the debug bus.

## UART registers

| Offset | Name | Access | Description |
|---|---|---|---|
| `+0x00` | `TXD` | WO | transmit byte |
| `+0x04` | `RXD` | RO | received byte |
| `+0x08` | `STS` | RO | bit0 TX_BUSY, bit1 RX_READY, bit2 TX_READY |
| `+0x0C` | `CTRL` | RW | bit0 TX_EN, bit1 RX_EN |
| `+0x10` | `BAUD` | RW | baud divisor for the *model* (host console speed is fixed) |

## TIMER registers

| Offset | Name | Access | Description |
|---|---|---|---|
| `+0x00` | `CTRL` | RW | bit0 ENABLE, bit1 IRQ_EN, bit2 REPEAT (0=one-shot,1=periodic) |
| `+0x04` | `PRESCALE` | RW | clock divider; COUNT ticks when prescaler underflows |
| `+0x08` | `COMPARE` | RW | match value |
| `+0x0C` | `COUNT` | RW | current count (starts at 0) |
| `+0x10` | `IRQ_STS` | RW | bit0 MATCH; write 1 to clear (acknowledge) |

## GPIO registers

| Offset | Name | Access | Description |
|---|---|---|---|
| `+0x00` | `DIR` | RW | bit per pin: 0=input, 1=output |
| `+0x04` | `OUT` | RW | output data |
| `+0x08` | `IN` | RO | input data (driven by virtual peripherals) |
| `+0x0C` | `PULL` | RW | pull config per pin |
| `+0x10` | `IRQ_STS` | RW | edge event bits; write 1 to clear |
| `+0x14` | `IRQ_MASK` | RW | per-pin IRQ enable |

## SPI registers

| Offset | Name | Access | Description |
|---|---|---|---|
| `+0x00` | `CTRL` | RW | bit0 ENABLE, bit1 MODE (0=master,1=slave) |
| `+0x04` | `BAUD` | RW | SCK divisor |
| `+0x08` | `TX` | WO | write = start transfer |
| `+0x0C` | `RX` | RO | shifted-in byte |
| `+0x10` | `STS` | RO | bit0 BUSY |

## Interrupt vector table

| Address | Slot | Source |
|---|---|---|
| `0x00000000` | 0 | RESET |
| `0x00000004` | 1 | TIMER |
| `0x00000008` | 2 | UART_RX |
| `0x0000000c` | 3 | UART_TX |
| `0x00000010` | 4 | GPIO |
| `0x00000014` | 5 | SPI |
| `0x00000018` | 6 | RESERVED |
| `0x0000001c` | 7 | RESERVED |
