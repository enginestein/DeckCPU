# DeckCPU Architecture

> **Status: Phase 1 (design spec).** No RTL beyond the common package is
> implemented yet. This document describes the target architecture; every
> section is "planned" until its modules exist and pass tests.

## Goal

A custom, completely home-grown 32-bit RISC-like computer, written in
SystemVerilog, that will eventually run a port of
[DeckOS](../deckos-port/README.md). Initially targeted entirely at
simulation on the host (Icarus Verilog), with FPGA synthesis as a stretch goal.

DeckOS targets three backends:

```
DeckOS
  ├── ARM/RP2040 backend     (DeckOS/)
  ├── Xtensa/ESP32 backend   (DeckOS_ESP32/)
  └── DeckCPU backend        (deckos-port/)
```

## Development philosophy

Incremental. Every milestone must leave the tree with:

- compilable/simulatable RTL
- a testbench and automated tests
- observable signals (waveforms)
- documentation
- an explicit statement of what is currently working

Unimplemented features are marked TODO; nothing is faked.

## Machine model

- 32-bit words, 32-bit instructions, little-endian, byte-addressable.
- 16 general-purpose registers `r0`–`r15`, plus dedicated architectural
  registers **PC**, **SP**, **FLAGS** (outside the GPR file).
- Stack: full-descending, grows down from `0x0000FFFC` (top of 64 KiB RAM).
- Reset: `PC = 0x00000000`, `SP = 0x0000FFFC`, `FLAGS = 0` (interrupts disabled).
- No MMU, no cache, single memory bus, single interrupt priority level
  initially. Dual-core is a Phase-14 investigation, not a design constraint now.

## Execution model

Multi-cycle, non-pipelined, deterministic. The control FSM walks five phases
per instruction — `FETCH → DECODE → EXECUTE → MEM → WRITEBACK` — with states
skipped per instruction type. The cycle count per opcode is fixed by the ISA
(`isa/isa.json`, rendered in `docs/isa.md`) so that the host-side emulator is
cycle-accurate.

Planned cycle counts:

| Class | Examples | Cycles |
|---|---|---|
| no-op / interrupt control | `NOP`, `HALT`, `EI`, `DI` | 3 |
| ALU reg / register moves | `ADD`..`CMP`, `MOV`, `LI`, `LIH`, `RDSP`, `WRSP`, `RDFLAG`, `WRFLAG` | 4 |
| ALU immediate | `ADDI`..`CMPI`, shift-immediates | 4 |
| branch/jump | `JMP`, `JMPR`, `CALL`, `Bcc` | 4 |
| store-ish (mem write) | `ST`, `ST.H`, `ST.B`, `PUSH` | 4 |
| load-ish (mem read + wb) | `LD`, `LD.H`, `LD.B`, `POP`, `RET`, `IRET` | 5 |

`HALT` stops the state machine at 3 cycles until reset.

## Planned CPU block diagram

```
              DeckCPU
  ┌────────────────────────────────┐
  │  Control FSM   (state_t)       │
  │  PC / IR                        │
  │  REGFILE r0..r15                │
  │  SP   FLAGS                     │
  │  ALU            (W=32)          │
  └───────────────┬────────────────┘
                  │
        synchronous bus (we / be[3:0] / addr / wdata / rdata / err)
   ┌────────┬────────┬────────┬────────┬────────┐
  RAM      UART    TIMER     GPIO     SPI     (future: I2C, PWM)
```

### Module responsibilities (planned)

| Module | Dir | Responsibility |
|---|---|---|
| `deckcpu_pkg` | `rtl/pkg` | shared types/constants mirroring `isa/isa.json` |
| `alu` | `rtl/alu` | combinational ALU; sets Z/N/C/V; carries C for shifts |
| `regfile` | `rtl/regfile` | r0–r15, 2 read + 1 write, synchronous write |
| `regs_csr` | `rtl/regfile` | PC / SP / FLAGS updates |
| `decoder` | `rtl/control` | instruction → control word (pure comb) |
| `cpu` | `rtl/cpu` | datapath + control FSM, top-level CPU |
| `bus` | `rtl/bus` | address decode, byte enables, fault on unmapped |
| `ram` | `rtl/memory` | 64 KiB synchronous single-port RAM + model |
| `uart` | `rtl/peripherals` | MMIO block, host terminal sink/source |
| `timer` | `rtl/peripherals` | compare timer, IRQ0 |
| `gpio` | `rtl/peripherals` | 32 pins, virtual-peripheral hooks |
| `spi` | `rtl/peripherals` | MMIO block for virtual peripherals |
| `pic` | `rtl/peripherals` | interrupt priority/status logic (Phase 8) |

### Interrupt model (planned)

- IVT at `0x00000000`, 8 slots × 4 bytes; slot 0 is the reset entry
  (reset starts executing there), slots 1–7 are IRQ entry points.
  Each slot holds a `JMP handler`, exactly like MSP430-style vector tables.
- Entry: push `PC`, push `FLAGS`, clear `FLAGS.I`, `PC <- vector slot address`.
- Exit: `IRET` pops `FLAGS`, pops `PC`.
- Priority by slot index (lower index = higher priority); source mask via
  `EI`/`DI` only initially. Per-source masking arrives with the PIC in
  Phase 8.

## Observability

The CPU exposes a debug bundle (planned, fixed names so testbenches and trace
tools can rely on them) driving VCD for GTKWave, plus software prints:

| Signal | Meaning |
|---|---|
| `dbg.clk`, `dbg.rst_n` | clock, reset |
| `dbg.state` | FSM phase (`state_t`) |
| `dbg.pc` | program counter |
| `dbg.ir` | instruction register |
| `dbg.opcode` | decoded opcode (`opcode_t` enum) |
| `dbg.rd` / `dbg.rs1` / `dbg.rs2` | decoded registers |
| `dbg.regs[15:0]` | register file snapshot |
| `dbg.alu_a` / `dbg.alu_b` / `dbg.alu_y` | ALU inputs/output |
| `dbg.mem_addr` / `dbg.mem_rw` / `dbg.mem_wdata` / `dbg.mem_rdata` | memory access |
| `dbg.bus_re` / `dbg.bus_we` / `dbg.bus_err` | bus transaction, fault |
| `dbg.irq_req` / `dbg.irq_ack` / `dbg.irq_en` | interrupt state |
| `dbg.done` | instruction-complete strobe (trace markers) |
| `dbg.cycle` | global cycle counter |
| `dbg.halted` | HALT asserted |

## Boot sequence (planned)

1. Reset: `PC=0`, `SP=0xFFFC`, IRQs off.
2. Slot 0 `JMP reset_handler`; handlers initialise SP, zero `.bss`, copy
   `data`, then call C-style `main`.
3. Monitor initializes console (UART TX), prints banner, enables timer IRQ,
   and starts the shell loop.

## Currently working

- `rtl/pkg/deckcpu_pkg.sv` — package compiles, opcode enum cross-checked
  against `isa/isa.json` by `tools/check_pkg_isa.py`.
- Phase 2 functional blocks, verified standalone against host-side golden
  vectors (`make test` is fully green; Icarus 11 sim + Verilator 4.038 lint):
  - `rtl/alu/alu.sv` — datapath + flags, 4000 randomized checks
  - `rtl/regfile/regfile.sv` — dual-read/single-write + reset
  - `rtl/control/decoder.sv` — all 49 opcodes → `decoded_instr_t` golden-checked
  - `rtl/control/branch_cond.sv` — 6 conditions × 16 flag combos
- Golden decode/control vectors generated by `tools/isa_tools.py` (`vectors`
  subcommand) into `build/gen/decoder_vectors.svh`.
- Everything else in this document is **planned** (see per-module TODO).

## Milestones

1. ✅ Phase 1 — repo, ISA spec, package, docs, Makefile
2. ✅ Phase 2 — decoder/ALU/regfile standalone modules + tests
3. ⬜ Phase 3 — CPU core (fetch/decode/execute/writeback) + core tests
4. ⬜ Phase 4 — RAM model + bus arbitration + memory tests
5. ✅ Phase 5 — Icarus/Verilator regression harness (`make test`)
6. ⬜ Phase 6 — UART/TIMER/GPIO MMIO + peripheral tests
7. ⬜ Phase 7 — interrupts (IVT, EI/DI, IRET) + interrupt tests
8. ⬜ Phase 8 — assembler (Python, driven by `isa/isa.json`)
9. ⬜ Phase 9 — monitor ROM in DeckCPU assembly
10. ⬜ Phase 10 — DeckOS port (`deckos-port/`), virtual peripherals
11. ⬜ (stretch) — FPGA synthesis, dual-core