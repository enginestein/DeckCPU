; DeckCPU HAL — DeckOS lower-layer subset for the DeckCPU target.
;
; The DeckOS portable core (kernel.c / shell.c / commands.c, etc.) talks to
; hardware exclusively through a HAL whose concrete per-target implementations
; normally live in main/hal/*.c. This file is the DeckCPU implementation of
; that interface for the devices DeckCPU has today (docs/memory-map.md):
;
;   UART  0x4000_0000  TXD +0x0  RXD +0x4  STS +0x8  CTRL +0xC  BAUD +0x10
;   TIMER 0x4000_1000  CTRL +0x0  PRESCALE +0x4  COMPARE +0x8  COUNT +0xC
;   GPIO  0x4000_2000  DIR +0x0  OUT +0x4  IN +0x8
;
; Contract mapping (left: hal.h name in DeckOS_ESP32, right: this file):
;
;   hal_console_init(rx, tx, ...)  -> hal_console_init
;   hal_console_putchar(c)         -> hal_console_putchar
;   hal_console_getchar()          -> hal_console_getchar  (non-blocking, 0 = idle)
;   hal_console_connected()        -> hal_console_connected
;   hal_time_micros() / millis()   -> hal_time_ticks       (TIMER COUNT ticks)
;   hal_sleep_micros(us)           -> hal_sleep_ticks      (busy-wait on COUNT)
;   hal_irq_disable() / restore()  -> hal_irq_disable / hal_irq_restore
;   hal_gpio_set / set_mode / get  -> hal_gpio_set / hal_gpio_set_mode / hal_gpio_get
;
; Informal ABI (this port only):
;   r1  first argument / return value
;   r2  scratch (clobbered)
;   r8  MMIO scratch base (rebuilt here, so always clobbered)
;   All other registers preserved.
;
; The console (console.s) is fully polled: interrupts are never enabled, so
; hal_irq_* only ever toggles FLAGS.I bit 0 (DI/EI).

;------------------------------------------------------------------------------
; console
;------------------------------------------------------------------------------
hal_console_init:               ; power up the UART (TX+RX) and start the TIMER
        LI      r8, 0
        LIH     r8, 0x4000                      ; UART base
        LI      r2, 3                           ; UART CTRL: TX_EN=1, RX_EN=1
        ST      r2, r8, 0x0C
        ; TIMER: COUNT must free-run every clock for hal_time_ticks. The model
        ; freezes in one-shot mode when COUNT == COMPARE, and COMPARE resets to
        ; 0 (which COUNT would equal immediately on enable), so configure a
        ; huge COMPARE with REPEAT mode — the same approach DeckOS's ESP32 HAL
        ; takes (COMPARE = ULONG_MAX). COUNT then just counts upward.
        ; NOTE: LIH zeroes the low half, so LIH-then-ORI (not LI-then-LIH)
        ; builds a full 32-bit constant on this ISA.
        LI      r2, 0
        ORI     r2, r2, 0xFFFF                  ; COMPARE = 0xFFFFFFFF (SEXT imm)
        ST      r2, r8, 0x1008                  ; TIMER base + 0x08 == COMPARE
        LI      r2, 5                           ; TIMER CTRL: ENABLE=1, REPEAT=1
        ST      r2, r8, 0x1000                  ; TIMER base
        RET

hal_console_connected:          ; the UART console is always attached
        LI      r1, 1
        RET

hal_console_putchar:            ; r1 = char to transmit
        LI      r8, 0
        LIH     r8, 0x4000
cn_pt_wait:
        LD      r2, r8, 0x8                     ; STS
        ANDI    r2, r2, 1                       ; TX_BUSY bit 0
        BNE     r0, r0, cn_pt_wait              ; wait for the transmitter idle
        ST.B    r1, r8, 0x0                     ; TXD (starts an 8-tick transfer)
        RET

hal_console_getchar:            ; r1 = pending byte, or 0 if nothing received
        LI      r8, 0
        LIH     r8, 0x4000
        LD      r2, r8, 0x8                     ; STS
        ANDI    r2, r2, 2                       ; RX_READY bit 1
        BNE     r0, r0, cn_gc_ready
        LI      r1, 0
        RET
cn_gc_ready:
        LD.B    r1, r8, 0x4                     ; RXD (read clears RX_READY)
        RET

;------------------------------------------------------------------------------
; time
;------------------------------------------------------------------------------
hal_time_ticks:                 ; r1 = free-running TIMER COUNT (1 tick/clock)
        LIH     r8, 0x4000
        ORI     r8, r8, 0x1000                  ; TIMER base = 0x4000_1000
        LD      r1, r8, 0x0C                    ; COUNT
        RET

hal_sleep_ticks:                ; r1 = ticks to busy-wait (COUNT advances 1/clock)
        LIH     r8, 0x4000
        ORI     r8, r8, 0x1000                  ; TIMER base = 0x4000_1000
        LD      r2, r8, 0x0C
        ADD     r2, r2, r1                      ; target = now + r1
cn_sl_wait:
        LD      r3, r8, 0x0C
        CMP     r3, r2                          ; COUNT < target? (borrow)
        BLTU    r0, r0, cn_sl_wait
        RET

;------------------------------------------------------------------------------
; irq critical sections (FLAGS.I = bit 0)
;------------------------------------------------------------------------------
hal_irq_disable:                ; r1 = previous FLAGS with I cleared (caller keeps)
        RDFLAG  r1
        DI
        RET

hal_irq_restore:                ; r1 = saved FLAGS to write back
        WRFLAG  r1
        RET

;------------------------------------------------------------------------------
; gpio (32-pin MMIO; DIR is stored for the virtual-peripheral layer)
;------------------------------------------------------------------------------
hal_gpio_set_mode:              ; r1 = per-pin DIR bits (1 = output)
        LIH     r8, 0x4000
        ORI     r8, r8, 0x2000
        ST      r1, r8, 0x0                     ; DIR
        RET

hal_gpio_set:                   ; r1 = OUT data
        LIH     r8, 0x4000
        ORI     r8, r8, 0x2000
        ST      r1, r8, 0x4                     ; OUT
        RET

hal_gpio_get:                   ; r1 = current OUT
        LIH     r8, 0x4000
        ORI     r8, r8, 0x2000
        LD      r1, r8, 0x4
        RET