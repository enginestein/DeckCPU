# DeckCPU

A custom 32-bit RISC-like computer, implemented in SystemVerilog, built as a
future hardware target for [DeckOS](https://github.com/enginestein/DeckOS).

Development is host-only for now: SystemVerilog RTL -> Icarus Verilog
simulation -> (eventually) host emulator -> DeckOS port -> FPGA.

## Status

**Status:** repository, ISA spec (`isa/isa.json`), shared RTL
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

## Guide docs

- `docs/isa.md` — **generated** instruction set reference
- `docs/memory-map.md` — **generated** address map + register tables