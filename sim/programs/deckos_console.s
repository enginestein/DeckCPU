; Golden-source wrapper: the DeckOS console for DeckCPU lives (with its HAL)
; in deckos-port/deckcpu/. This file exists so the assembler tests can
; reproduce the golden byte image sim/programs/deckos_console.hex (the image
; sim/testbenches/deckos_tb.sv executes) from that single source of truth.
.include "../../deckos-port/deckcpu/console.s"