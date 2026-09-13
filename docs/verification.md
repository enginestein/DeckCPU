# DeckCPU Verification

> **Status: Phase 2 green.** `make test` runs ISA/docs cross-checks, Verilator
> lint on all sources, and Icarus simulation of every testbench
> (`pkg_smoke`, `alu`, `regfile`, `decoder`, `branch_cond`).

## Regression (`make test`)

Everything below runs from a single command. Phase 1 already wires up:

- **isa-check** — `tools/isa_tools.py validate` (structural ISA checks) and
  `tools/check_pkg_isa.py` (RTL package opcodes match `isa/isa.json`).
- **docs-check** — regenerates `docs/isa.md` + `docs/memory-map.md` into a
  scratch dir and diffs against the committed copies.
- **lint** — Verilator `--lint-only` gate on all RTL + testbench sources.
- **sim** — Icarus compile + run of every testbench.

## Executing

| Subsystem | Testbench | Approach | Status |
|---|---|---|---|
| ALU | `alu_tb.sv` | directed ops + randomized vectors; flags checked | ✅ 4022 checks |
| Regfile | `regfile_tb.sv` | read ports, write port, reset | ✅ |
| Decoder | `decoder_tb.sv` | every opcode decodes to expected control word (golden vectors from `isa.json`); reserved fields ignored | ✅ 258 checks |
| Branch cond | `branch_cond_tb.sv` | 6 conditions × 16 flag combinations vs boolean reference | ✅ 96 checks |
| Control FSM | `cpu_fsm_tb.sv` | cycle counts per class; reset; HALT; interrupt entry | ⬜ Phase 3 |
| CPU | `cpu_tb.sv` | golden execution of small asm programs; register/flag/PC traces | ⬜ Phase 3 |
| RAM | `ram_tb.sv` | byte/halfword/word, alignment, unwritable addresses | ⬜ Phase 4 |
| Bus | `bus_tb.sv` | decode windows, byte enables, unmapped → err | ⬜ Phase 4 |
| Peripherals | `peripheral_tb.sv` per block | register semantics, IRQ strobes | ⬜ Phase 6 |
| Interrupts | `irq_tb.sv` | entry/exit, masking, nesting restriction, priority | ⬜ Phase 7 |
| Assembler | pytest | round-trips: asm → bytes → disasm; encoding golden tests | ⬜ Phase 8 |

## Reference model

`sim/models/` will hold an instruction-accurate DeckCPU model (Python first,
C later for speed) used two ways:

1. **Golden trace comparison** during RTL sim — the RTL writes `dbg.done`,
   PC, regs, flags, mem traffic to a log; the model replays the program and
   the traces are diffed (`tools/trace_diff.py`).
2. A **host emulator** to boot DeckOS fast during the port phase (fpga-less).

## Tooling

- **Primary sim:** Icarus Verilog 11 (`-g2012`) — fast VCD, richest
  debug/trace integration.
- **Lint gate:** Verilator 4.038 `--lint-only`.
- **Waves:** every testbench dumps `sim_out/<tb>.vcd` for GTKWave.
- SystemVerilog used is restricted to the subset both simulators accept:
  `logic`, `always_ff`/`always_comb`, `typedef enum`, `packed struct`,
  `package`, parameters. No SV `interface`, no classes (Verilator 4.038
  lacks/fails them), no assertion-`bind` shenanigans.