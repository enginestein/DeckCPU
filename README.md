# DeckCPU

A custom 32-bit RISC-like computer, implemented in SystemVerilog, built as a
future hardware target for [DeckOS](https://github.com/enginestein/DeckOS).

```
DeckOS
  ├── ARM/RP2040 backend     DeckOS/
  ├── Xtensa/ESP32 backend   DeckOS_ESP32/
  └── DeckCPU backend        deckos-port/        ← this project's reason to exist
```

Development is host-only for now: SystemVerilog RTL → Icarus Verilog
simulation → (eventually) host emulator → DeckOS port → FPGA.

## Layout

```
isa/            isa.json — single source of truth (ISA + memory map)
rtl/            SystemVerilog sources (pkg, cpu, alu, regfile, control,
                bus, memory, peripherals)
sim/            testbenches, test programs, reference models
software/       assembler, monitor, programs (host-side tooling)
tools/          ISA validation, doc generation, trace tools
docs/           architecture, isa (generated), memory-map (generated),
                bus, verification, deckos-port
deckos-port/    future DeckCPU HAL + ported DeckOS subset
```

## Status

**Phase 1 complete** — repository, ISA spec (`isa/isa.json`), shared RTL
`deckcpu_pkg`, docs, build/test plumbing.

| Area | Status |
|---|---|
| CPU / ALU / RAM / peripherals | planned (no RTL yet) |
| `deckcpu_pkg` (opcodes, map, flags) | implemented, cross-checked vs `isa.json` |
| ISA + memory-map docs | generated from `isa.json` |
| `make test` | runs isa-check, docs-check, verilator lint, iverilog sim |

## Build & test

```sh
make test     # full regression
make sim      # run testbenches
make docs     # regenerate ISA/memory-map docs
make gtkwave  # (arrives with first CPU tb) open saved waveforms
```

## Verification policy

Every milestone ships: compilable RTL + a testbench + automated tests +
observable signals + documentation + a statement of what actually works.
Unimplemented features are marked TODO — never faked. See
`docs/verification.md`.

## Guide docs

- `docs/architecture.md` — design plan, block diagram, milestones
- `docs/isa.md` — **generated** instruction set reference
- `docs/memory-map.md` — **generated** address map + register tables
- `docs/bus.md` — bus contract
- `docs/deckos-port.md` — how DeckCPU will host DeckOS