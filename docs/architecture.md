# DeckCPU Architecture

> **Status:** the CPU executes from a 64 KiB
> RAM through a synchronous, byte-enable-strobed bus; the four MMIO
> peripherals (UART, TIMER, GPIO, SPI) are wired in with RAM-mapped register
> windows returning peripheral `rdata` and level `irq` outputs; the core
> takes instruction-boundary interrupts through the IVT (`EI`/`DI`-gated,
> arbitrated by `irq_prio`, exited by `IRET`); a host assembler/
> disassembler (`software/assembler`, driven by `isa/isa.json`) produces the
> exact byte images the testbenches execute; and a hand-assembled DeckOS
> HAL + polled console shell ([`deckos-port/`](../deckos-port/README.md))
> boots on the netlist, serving `help`/`about`/`echo`/`time`/`gpio`/`calc`/
> `exec`/`exit` over the UART under `sim/testbenches/deckos_tb.sv`. An
> **interactive terminal** is also hosted (`make run-deckos`,
> `sim/terminal/deckcpu_terminal.py` + `deckos_term_tb.sv`): input is pushed
> into the RTL's UART RX and the console's TX renders on the screen.
> Sections marked *planned* describe target behaviour for modules not yet
> written.

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


## Machine model

- 32-bit words, 32-bit instructions, little-endian, byte-addressable.
- 16 general-purpose registers `r0`–`r15`, plus dedicated architectural
  registers **PC**, **SP**, **FLAGS** (outside the GPR file).
- Stack: full-descending, grows down from `0x0000FFFC` (top of 64 KiB RAM).
- Reset: `PC = 0x00000000`, `SP = 0x0000FFFC`, `FLAGS = 0` (interrupts disabled).
- No MMU, no cache, single memory bus, single interrupt priority level
  initially. Dual-core is a later investigation, not a design constraint now.

## Execution model

Multi-cycle, non-pipelined, deterministic. The control FSM walks five stages
per instruction — `FETCH -> DECODE -> EXECUTE -> MEM -> WRITEBACK` — with states
skipped per instruction type. The cycle count per opcode is fixed by the ISA
(`isa/isa.json`, rendered in `docs/isa.md`) so that the host-side emulator is
cycle-accurate.

Cycle counts (implemented, verified by `cpu_fsm_tb`/`cpu_tb`):

| Class | Examples | Cycles |
|---|---|---|
| no-op / interrupt control | `NOP`, `HALT`, `EI`, `DI` | 3 |
| ALU reg / register moves | `ADD`..`CMP`, `MOV`, `LI`, `LIH`, `RDSP`, `WRSP`, `RDFLAG`, `WRFLAG` | 4 |
| ALU immediate | `ADDI`..`CMPI`, shift-immediates | 4 |
| branch/jump | `JMP`, `JMPR`, `CALL`, `Bcc` | 4 |
| store-ish (mem write) | `ST`, `ST.H`, `ST.B`, `PUSH` | 4 |
| load-ish (mem read + wb) | `LD`, `LD.H`, `LD.B`, `POP`, `RET` | 5 |
| double-load | `IRET` (pops FLAGS then PC) | 6 |

`HALT` stops the state machine at 3 cycles until reset.

## Planned CPU block diagram

```
              DeckCPU
  ┌────────────────────────────────┐
  │  Control FSM   (state_t)       │
  │  PC / IR                       │
  │  REGFILE r0..r15               │
  │  SP   FLAGS                    │
  │  ALU            (W=32)         │
  └───────────────┬────────────────┘
                  │
        synchronous bus (we / be[3:0] / addr / wdata / rdata / err)
   ┌────────┬────────┬────────┬────────┬────────┐
  RAM      UART    TIMER     GPIO     SPI     (future: I2C, PWM)
```

### Module responsibilities

| Module | Dir | Status | Responsibility |
|---|---|---|---|
| `deckcpu_pkg` | `rtl/pkg` | Done | shared types/constants mirroring `isa/isa.json` |
| `alu` | `rtl/alu` | Done | combinational ALU; sets Z/N/C/V; carries C for shifts |
| `regfile` | `rtl/regfile` | Done | r0–r15, 2 read + 1 write, synchronous write |
| `regs_csr` | `rtl/regfile` | Open | PC / SP / FLAGS updates |
| `decoder` | `rtl/control` | Done | instruction -> control word (pure comb) |
| `cpu` | `rtl/cpu` | Done | datapath + control FSM, top-level CPU |
| `bus` | `rtl/bus` | Done | address decode, byte enables, fault on unmapped |
| `ram` | `rtl/memory` | Done | 64 KiB synchronous single-port RAM + boot/load port |
| `uart` | `rtl/peripherals` | Done | MMIO block, host terminal sink/source, RX/TX irq |
| `timer` | `rtl/peripherals` | Done | compare timer, prescaler, match irq (slot 1) |
| `gpio` | `rtl/peripherals` | Done | 32 pins, edge events + mask irq, virtual-peripheral hooks |
| `spi` | `rtl/peripherals` | Done | MMIO block for virtual peripherals, transfer-complete irq |
| `pic` | `rtl/peripherals` | Planned | interrupt priority/status logic (per-source masking) |
| `irq_prio` | `rtl/interrupts` | Done | 5-input priority arbiter: `irq_req` + `irq_vec` (slot) for the CPU |

### Interrupt model

- IVT at `0x00000000`, 8 slots × 4 bytes; slot 0 is the reset entry
  (reset starts executing there), slots 1–7 are IRQ entry points.
  Each slot holds a `JMP handler`, exactly like MSP430-style vector tables.
- Entry: push `PC`, push `FLAGS`, clear `FLAGS.I`, `PC <- vector slot address`.
- Exit: `IRET` pops `FLAGS`, pops `PC`.
- Priority by slot index (lower index = higher priority); source mask via
  `EI`/`DI` only initially. Per-source masking arrives later with the PIC.

**Interrupts (implemented, verified by `irq_tb`):** the core polls
`irq_en && irq_req` at every instruction boundary (the `S_FETCH` cycle).
On a hit it latches the slot from `irq_vec[2:0]`, walks two dedicated push
states (`S_IRQ_PC` pushes PC at `[SP-4]`, `S_IRQ_FL` pushes FLAGS at
`[SP-8]` and clears `FLAGS.I`), and drives `PC = IVT_BASE + 4*slot`,
so entry costs two cycles above a fetch. `irq_ack` pulses during the first
push. The pushed FLAGS keeps the pre-entry `I` bit, so `IRET` restores it
and a still-asserted level source re-enters after return (the handler must
clear the source). Nesting is naturally disallowed while `FLAGS.I == 0`.
`irq_prio` (`rtl/interrupts`) combines the five peripheral lines into
`irq_req`/`irq_vec` with lowest-slot-highest-priority (TIMER > UART_RX >
UART_TX > GPIO > SPI); slot 0 is never dispatched. A later PIC supersedes it.

## Observability

The CPU exposes a debug bundle (planned, fixed names so testbenches and trace
tools can rely on them) driving VCD for GTKWave, plus software prints:

| Signal | Meaning |
|---|---|
| `dbg.clk`, `dbg.rst_n` | clock, reset |
| `dbg.state` | FSM stage (`state_t`) |
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
- ALU/regfile/decoder/branch-condition functional blocks, verified standalone against host-side golden
  vectors (`make test` is fully green; Icarus 11 sim + Verilator 4.038 lint):
  - `rtl/alu/alu.sv` — datapath + flags, 4000 randomized checks
  - `rtl/regfile/regfile.sv` — dual-read/single-write + reset
  - `rtl/control/decoder.sv` — all 49 opcodes -> `decoded_instr_t` golden-checked
  - `rtl/control/branch_cond.sv` — 6 conditions × 16 flag combos
- Golden decode/control vectors generated by `tools/isa_tools.py` (`vectors`
  subcommand) into `build/gen/decoder_vectors.svh`.
- CPU core (`rtl/cpu/cpu.sv`): five-stage FSM
  (fetch/decode/exec/mem/writeback + `S_HALT` park), PC/IR/SP/FLAGS, regfile
  writeback, the ALU wired through the decoder's one-hot `sel_*` outputs, and
  a comb-read synchronous bus interface (`bus_addr`/`bus_re`/`bus_we`/`bus_sz`/
  `bus_rdata`/`bus_wdata`/`bus_err`). Verified end-to-end by `cpu_fsm_tb`
  (cycle classes, bus-error halt, EI/DI) and `cpu_tb` (golden program
  covering ALU ops, branches, stack, CALL/RET, IRET, LD/ST side-effects).
- Memory system (`rtl/bus/bus.sv`, `rtl/memory/ram.sv`): a 64 KiB
  byte-addressed RAM with a boot/load port and a synchronous bus decoding RAM
  + the four MMIO windows, deriving byte enables and faulting only on
  unmapped addresses. The CPU boots a program image straight into RAM and
  executes it — verified start-to-finish by `soc_tb.sv` (golden
  PC/opcode/cycle/regs/flags/HALT).
- MMIO peripherals (`rtl/peripherals/uart.sv`, `timer.sv`, `gpio.sv`,
  `spi.sv`), wired into the bus: UART TXD/RXD/STS/CTRL/BAUD with a TX busy
  window and RX-ready latch; TIMER with a re-armed prescaler, match latch and
  one-shot/periodic modes; GPIO with input-transition edge events, write-1-to-
  clear IRQ_STS and a mask-gated irq; SPI with TX-write start, a BUSY window,
  MOSI/MISO hooks and a transfer-complete irq. Stores honour the bus
  byte-enable lanes; reads of mapped windows return peripheral `rdata`
  with `err=0`. Each peripheral's `irq` level crosses the bus to the pin
  header (irq_prio inputs). Verified by `uart_tb` (36 checks), `timer_tb`
  (26), `gpio_tb` (34), `spi_tb` (34), and MMIO-through-bus traffic in
  `bus_tb` (56).
- Interrupts: the CPU takes instruction-boundary IRQs (push PC,
  push FLAGS with the pre-entry `I` bit, clear `FLAGS.I`, jump to
  `IVT_BASE + 4*slot`, `irq_ack` pulse), gated by `EI`/`DI`; `IRET` exits.
  `rtl/interrupts/irq_prio.sv` arbitrates the five peripheral IRQ lines into
  `irq_req` + `irq_vec` (lowest slot = highest priority). Verified end to end
  by `irq_tb.sv` (62 checks) over the cpu+bus+ram netlist: reset-gating,
  frame push (PC/FLAGS/SP), vector dispatch to every slot 1–5, handler
  marker stores, IRET restore-and-re-enter on a still-asserted level source,
  priority (TIMER > UART_RX) and no nesting while `FLAGS.I == 0`.
- Assembler/disassembler tooling: `software/assembler/` — a two-pass assembler and a
  disassembler, both driven by `isa/isa.json` (no opcode table duplicated in
  the code). The assembler supports labels, `.org`/`.equ`/`.word`/`.global`
  directives, target-semantics branches (`off16 = target - PC`, `.` =
  self-reference), and range/alignment checks (immediates, shamt 0–31,
  `off16` multiples of 4, registers); it writes the same `@addr byte` hex
  format as `tools/gen_programs.py`. The `sim/programs/*.s` sources
  reproduce the golden `*.hex` images the testbenches execute, verified by
  pytest round-trips (asm -> bytes -> disasm -> bytes) and canonical-encoding
  cross-checks against `tools/isa_tools.py`.
- Everything else in this document is **planned** (see per-module TODO).