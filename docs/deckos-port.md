# DeckOS on DeckCPU

> **Status:** the HAL + polled console shell now run as a
> live interactive terminal.** `deckos-port/deckcpu/` holds a DeckCPU-assembly
> HAL (`hal_dk.s`) and a polled shell (`console.s`) that boots on the real
> cpu+bus+RAM+UART+TIMER+GPIO netlist (Icarus). `make run-deckos` attaches the
> host terminal to the simulated UART (input driven into RTL, output rendered
> from TX — nothing on the host is emulated); the deterministic regression
> stays in `sim/testbenches/deckos_tb.sv` under `make run-deckos-tb`, with a
> scripted terminal round-trip in `make term-check`. The full C core and
> virtual peripherals remain gated on a DeckCPU C toolchain (see Open decision).

## Where DeckOS actually lives on real hardware

- **RP2040 port (`DeckOS/`):** bare-metal C directly on the Pico SDK
  (`pico/stdlib.h`, `pio_`/, `multicore_launch_core1`, `tud_task`, ...).
  No HAL layer — the SDK *is* the hardware abstraction.
- **ESP32 port (`DeckOS_ESP32/`):** FreeRTOS + a clean HAL contract,
  `DeckOS_ESP32/main/hal/hal.h`. This is the interface DeckCPU should
  mirror, because it already decouples the OS core from the chip.

## What the OS actually needs

Studying both ports, the portable core (shell, commands, modules/events,
dscript, vfs, scheduler, editor, tone/morse, bench) is ordinary C whose true
hardware dependencies reduce to:

| Need | DeckOS call | DeckCPU equivalent |
|---|---|---|
| Console output | `printf` / `hal_console_putchar` | UART `TXD` (MMIO `0x40000000`) |
| Console input | `getchar_timeout_us` / `hal_console_getchar` | UART `RXD`, polled initially, IRQ later |
| Time | `time_us_64()` / `hal_time_us` | TIMER `COUNT` (`0x40001000`) |
| Sleep | `sleep_ms` / `hal_sleep_ms` | busy-wait on TIMER (later: timer IRQ) |
| Interrupts | `hal_irq_disable/restore` | `DI`/`EI` + `FLAGS.I` (with save/restore) |
| Scheduler tick | timer-driven | TIMER IRQ0 via IVT slot 1 |
| GPIO-ish pins | `hal_gpio_*` / `hardware/gpio.h` | GPIO MMIO (`0x40002000`) |
| Peripheral buses | `hal_spi_*`, `hal_i2c_*` | SPI MMIO; I2C base reserved |
| Persistence | `hal_nvs_*`, `hal_spiffs_*`, flash | virtual storage block (future) |
| Dual core | `multicore_launch_core1` | investigation pending |

## Porting strategy

1. Implement the DeckCPU HAL in DeckCPU assembly (monitor ROM first).
2. Bring over the OS core subset: `kernel.c` loop, `shell`, `commands`,
   `scheduler`, `vfs`, `syslog` — whichever set is agreed at that point.
3. Virtual peripherals (SPI->MPU6050, SSD1306, GPIO) so DeckOS believes it is
   on a real board. All host-side.
4. Gap analysis against `hal.h` — the ESP32 `hal.h` is the target contract;
   unimplemented cameras/WiFi/BT are stubbed or dropped.

## Open decision

Running the full C core on DeckCPU implies a **C toolchain for DeckCPU**
(compiler or a serious hand-assembly effort). Two options:

- **A:** hand-assemble a micro-DeckOS subset in the DeckCPU assembler.
- **B:** port/build a small C compiler backend for DeckCPU.

**Decision taken:** option A was chosen for the port scope — the
HAL + polled console shell are complete and verified (`make test`). The
OS core subset (kernel loop, scheduler, dscript, vfs, virtual peripherals)
stays open; option B remains a live gate for anything beyond hand-assembly.
The ISA was designed (stack CALL/RET, 32-bit data, opcode space) so neither
choice is blocked.

## What is working

| Piece | Location | Verified by |
|---|---|---|
| HAL (console I/O, time, sleep, gpio, irq save/restore) | `deckos-port/deckcpu/hal_dk.s` | `deckos_tb.sv` checks |
| Polled shell (editor, dispatch, banner, prompt) | `deckos-port/deckcpu/console.s` | `deckos_tb.sv` checks |
| Commands help/about/echo/time/gpio + unknown | `console.s` | transcript assertions (PASS) |
| Commands peek/poke/calc/sleep/exec (hex parse + RAM poke & exec) | `console.s` | `deckos_tb.sv` seq checks (PASS) |
| Assembly golden record | `sim/programs/deckos_console.{s,hex,_words.svh}` | pytest golden suite |
| Command `exit` (HALT + sim shutdown) | `console.s` + `deckos_term_tb.sv` | `term-check` / interactive `make run-deckos` |
| End-to-end netlist sim | `sim/testbenches/deckos_tb.sv` | `make run-deckos-tb` / `make test` |
| Interactive UART terminal | `deckos_term_tb.sv` + `sim/terminal/deckcpu_terminal.py` | `make run-deckos` / `make term-check` |

See `deckos-port/README.md` for the HAL contract, command list, known quirks,
and the gated scope.