# DeckCPU Verification

> **Status: interactive console green.** `make test` runs ISA/docs
> cross-checks, Verilator lint on all synthesizable sources, Icarus simulation
> of every testbench (`pkg_smoke`, `alu`, `regfile`, `decoder`, `branch_cond`,
> `cpu_fsm`, `cpu`, `ram`, `bus`, `soc`, `uart`, `timer`, `gpio`, `spi`,
> `irq`, `deckos`, `deckos_term`), the assembler/disassembler pytest
> suite, and the scripted terminal round-trip (`term-check`).

## Regression (`make test`)

Everything below runs from a single command:

- **isa-check** — `tools/isa_tools.py validate` (structural ISA checks) and
  `tools/check_pkg_isa.py` (RTL package opcodes match `isa/isa.json`).
- **docs-check** — regenerates `docs/isa.md` + `docs/memory-map.md` into a
  scratch dir and diffs against the committed copies.
- **lint** — Verilator `--lint-only` gate on RTL + synthesizable testbenches
  (the CPU/bus/SoC testbenches sequence `@(posedge clk)` timing controls that
  Verilator 4.038 cannot schedule, so they are Icarus-only).
- **sim** — Icarus compile + run of every testbench.
- **term-check** — `sim/terminal/deckos_term_test.py` drives
  `build/sim/deckos_term` over the same FIFO path the interactive terminal
  uses, types a session (`help`, `about`, `echo`, `time`, `calc`,
  `poke`/`peek`, `exit`), and asserts on the UART TX responses — a
  deterministic, jammer-free version of a human session.
- **asm-check** — pytest (`software/assembler/test_assembler.py`) on the
  Assembler/disassembler: the `sim/programs/*.s` sources reproduce the
  hand-verified `*.hex` byte images exactly, disasm->reassemble round-trips,
  and canonical encodings are cross-checked against the independent encoder
  in `tools/isa_tools.py`. `deckos_console` is a golden: it must reproduce its
  image byte-for-byte, but is excluded from the disasm round-trip test because
  its data words can decode as valid opcodes (known limitation, noted in the
  test).

## Executing

| Subsystem | Testbench | Approach | Status |
|---|---|---|---|
| ALU | `alu_tb.sv` | directed ops + randomized vectors; flags checked | Pass (4022 checks) |
| Regfile | `regfile_tb.sv` | read ports, write port, reset | Pass |
| Decoder | `decoder_tb.sv` | every opcode decodes to expected control word (golden vectors from `isa.json`); reserved fields ignored | Pass (258 checks) |
| Branch cond | `branch_cond_tb.sv` | 6 conditions × 16 flag combinations vs boolean reference | Pass (96 checks) |
| Control FSM | `cpu_fsm_tb.sv` | cycle counts per class; reset; bus-error halt; HALT park; EI/DI flag | Pass |
| CPU | `cpu_tb.sv` | golden execution of asm program: regs/flags/PC/memory side-effects, CALL/RET/IRET, POP/PUSH, LD/ST | Pass |
| RAM | `ram_tb.sv` | boot-port image loads (multi-burst incl. first-write regression), word/half/byte stores with byte-enable lanes, rotated sub-word reads, top-of-window | Pass (34 checks) |
| Bus | `bus_tb.sv` | byte-enable diamonds (align/unalign), window decode + strobe gating, unmapped -> err, word/half/byte stores to RAM, MMIO traffic through all four peripheral windows (UART CTRL/TX + STS, TIMER count, GPIO OUT/IN/edges/mask irq, SPI BUSY/RX/irq) | Pass (56 checks) |
| SoC | `soc_tb.sv` | end-to-end CPU+bus+RAM netlist: boots the `cpu_fsm` program via the RAM boot port, golden PC/opcode/cycle/regs/flags/HALT | Pass (53 checks) |
| UART | `uart_tb.sv` | TXD/RXD/STS/CTRL/BAUD registers, TX busy window + tx_char/valid, RX push/latch + RXD clear, byte-lane stores, irq_rx/irq_tx levels | Pass (36 checks) |
| TIMER | `timer_tb.sv` | CTRL/PRESCALE/COMPARE/COUNT/IRQ_STS, prescaler divide, one-shot freeze vs periodic, W1C ack, irq level, lane stores | Pass (26 checks) |
| GPIO | `gpio_tb.sv` | DIR/OUT/IN/PULL/IRQ_STS/IRQ_MASK registers, IN passthrough, edge events, W1C, mask-gated irq, lane stores | Pass (34 checks) |
| SPI | `spi_tb.sv` | CTRL/BAUD registers, TX-write start, busy window, spi_out MOSI, RX latch + irq, RX-read ack, ignore-when-busy/disabled | Pass (34 checks) |
| Interrupts | `irq_tb.sv` | cpu+bus+ram netlist + `irq_prio`: reset gating (no entry while `FLAGS.I==0`), entry frame (push PC/FLAGS + clear I + SP), `irq_ack` pulse, vector dispatch to slots 1–5, handler markers, IRET restore and re-enter on a held level source, priority (TIMER > UART_RX), no nesting | Pass (62 checks) |
| DeckOS console | `deckos_tb.sv` | boots the hand-assembled DeckOS HAL+shell (image from `deckos-port/deckcpu/console.s`) via the RAM boot port, then acts as the host terminal: banner/prompt, `help`, `about`, `echo` (with CRLF + fresh prompt), `time` (bounded nonzero COUNT), `gpio` (DIR/OUT effects on the GPIO hardware), `unknown-command`, and the extended command set — `poke`/`peek` word round-trip in scratch RAM (`0xF100`), `calc` arithmetic (results verified to `0x2a`/`0x63`), `sleep` (measured elapsed ticks reported), `exec` running a 4-word subroutine poked into `0xF000` that stores `0x63` to `0xE000` with `peek e000` back-verifying, and a final console-alive check; typed input is pushed as raw bytes over the UART RX path, waiting for each response prompt (the console has a single-latch RX, so the host must not type into a busy console). **The testbench and its golden checks are unchanged** (the deterministic `help` needle remains a valid prefix of the current output) | Pass (41 checks) |
| DeckOS interactive | `deckos_term_tb.sv` + `sim/terminal/deckcpu_terminal.py` | same connected DUT, but the host terminal IS the UART: TX bytes forwarded to stdout; input bytes pushed over the RX path, byte-paced by the UART's RXD-read consumption and echo drain, gated on a fresh `DeckOS> ` prompt. `make run-deckos` attaches the host terminal
(raw-termios bridge); `exit` HALT-decays the sim to `$finish`, Ctrl-C(`0x03`)/
host-EOF detach and kill it. Verified by a scripted session (above) and by an interactive PTY session for both exit and Ctrl-C shutdown paths | Pass (581-char scripted round-trip) |
| Assembler | pytest | golden `sim/programs/*.s` -> exact `*.hex` byte images (the words the TBs execute); words -> disasm -> reassemble round-trips; every instruction encoding cross-checked vs `tools/isa_tools.encode_canonical`; directives/labels/errors; `deckos_console` golden reproduces its image | Pass |

## Reference model

`sim/models/` will hold an instruction-accurate DeckCPU model (Python first,
C later for speed) used two ways:

1. **Golden trace comparison** during RTL sim — the RTL writes `dbg.done`,
   PC, regs, flags, mem traffic to a log; the model replays the program and
   the traces are diffed (`tools/trace_diff.py`).
2. A **host emulator** to boot DeckOS fast during the port effort (fpga-less).

## Tooling

- **Primary sim:** Icarus Verilog 11 (`-g2012`) — fast VCD, richest
  debug/trace integration.
- **Lint gate:** Verilator 4.038 `--lint-only`.
- **Waves:** every testbench dumps `sim_out/<tb>.vcd` for GTKWave.
- SystemVerilog used is restricted to the subset both simulators accept:
  `logic`, `always_ff`/`always_comb`, `typedef enum`, `packed struct`,
  `package`, parameters. No SV `interface`, no classes (Verilator 4.038
  lacks/fails them), no assertion-`bind` shenanigans.