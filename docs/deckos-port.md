# DeckOS on DeckCPU

> **Status: Phase 1 (plan only).** Nothing in this directory exists yet.
> The DeckOS port is explicitly a Phase-10+ milestone: it starts only after
> the CPU, assembler, RAM, interrupts, timer, UART and basic software
> environment are stable, and the exact scope is negotiated then.

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
| Persistence | `hal_nvs_*`, `hal_spiffs_*`, flash | virtual storage block (Phase 13) |
| Dual core | `multicore_launch_core1` | Phase 14 investigation |

## Porting strategy

1. Implement the DeckCPU HAL in DeckCPU assembly (monitor phase first).
2. Bring over the OS core subset: `kernel.c` loop, `shell`, `commands`,
   `scheduler`, `vfs`, `syslog` — whichever set is agreed at that point.
3. Virtual peripherals (SPI→MPU6050, SSD1306, GPIO) so DeckOS believes it is
   on a real board. All host-side.
4. Gap analysis against `hal.h` — the ESP32 `hal.h` is the target contract;
   unimplemented cameras/WiFi/BT are stubbed or dropped.

## Open decision (gate at Phase 10)

Running the full C core on DeckCPU implies a **C toolchain for DeckCPU**
(compiler or a serious hand-assembly effort). Two options:

- **A:** hand-assemble a micro-DeckOS subset in the DeckCPU assembler.
- **B:** port/build a small C compiler backend for DeckCPU.

Recommended: keep development **A-agnostic** for Phases 2–9, then gate.
The ISA is designed (stack-based CALL/RET, 32-bit data, plenty of opcode
space) so neither choice is blocked later.