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
| CPU / ALU / RAM / peripherals | implemented + simulated (see `make test`) |
| `deckcpu_pkg` (opcodes, map, flags) | implemented, cross-checked vs `isa.json` |
| ISA + memory-map docs | generated from `isa.json` |
| deckc C toolchain | compiles/assembles/runs on the CPU sim (see `deckos-port/README.md`) |
| `make test` | runs isa-check, docs-check, verilator lint, iverilog sim, asm/deckc pytest |

## Build & test

```sh
make test     # full regression
make sim      # run testbenches
make docs     # regenerate ISA/memory-map docs
make gtkwave  # (arrives with first CPU tb) open saved waveforms
```

The `deckc` C toolchain compiles the vendored DeckOS `kernel/syslog.c` plus the
deckc BSP and a test main into one image that boots on the CPU testbench
(`deckos_c_tb.sv`), prints a colour-coded, TIMER-timestamped syslog transcript
to the UART, and exits with mailbox code 5. The golden `.hex`/`.svh` artefacts
are regenerated automatically and pinned by `make deckc-check`.

There is also an interactive deckc-compiled console (`software/deckc/app/
console.c`, built by `tools/gen_cshell_image.py`) that drives the real UART RX
line editor and the TIMER/GPIO devices. It is exercised end-to-end on the RTL
(`cshell_tb.sv`) and as a live terminal:

```sh
make run-cshell-term      # attach the host terminal to the cshell netlist
make run-cshell-term-vcd  # same, with a VCD dump
make term-check-cshell    # deterministic scripted UART session (part of make test)
```

## Guide docs

- `docs/isa.md` **generated** instruction set reference
- `docs/memory-map.md` **generated** address map + register tables