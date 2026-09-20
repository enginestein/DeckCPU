; DeckOS console for DeckCPU.
;
; This is the runnable DeckOS-on-DeckCPU proof point. The DeckOS portable
; core is a polling single-task kernel:
;
;       kernel_init();
;       for (;;)  kernel_run();
;
; called on top of the HAL it requires. DeckCPU has no C compiler backend
; yet, so this file states that loop in DeckCPU assembly: it keeps the same
; structure HAL (hal_dk.s) + a resident shell loop that polls the console,
; line-edits, and dispatches commands through a command table and talks to
; hardware only through the hal_* entry points, exactly as kernel/shell.c
; do on the ESP32/RP2040 ports.
;
; Exercises the DeckCPU HAL contract (see deckos-port/README.md):
;   console init/putchar/getchar/connected, time/sleep ticks, irq
;   disable/restore, gpio set/set_mode/get against the real UART, TIMER
;   and GPIO MMIO devices, verified by sim/testbenches/deckos_tb.sv.
;
; Polled shell: interrupts are never enabled (FLAGS.I stays 0).
;
; Registers (see hal_dk.s for the helper ABI):
;   r7   line write pointer        r12 UART_BASE   r13 TIMER_BASE
;   r14  GPIO_BASE                 r15 line length

.equ MAXLINE, 128

;------------------------------------------------------------------------------
; IVT + boot
;------------------------------------------------------------------------------
        .org 0x0000
        JMP     start                       ; slot 0: reset vector
        HALT                                ; slot 1: TIMER    (never taken: no EI)
        HALT                                ; slot 2: UART_RX
        HALT                                ; slot 3: UART_TX
        HALT                                ; slot 4: GPIO
        HALT                                ; slot 5: SPI
        HALT                                ; slot 6: reserved
        HALT                                ; slot 7: reserved

start:
        ; ---- exercise the critical-section entry points once ----
        CALL    hal_irq_disable             ; r1 = old FLAGS, I cleared
        CALL    hal_irq_restore             ; r1 -> FLAGS (back to 0)
        ; ---- boot the HAL ----
        CALL    hal_console_init            ; UART TX+RX, TIMER enable
        LI      r1, 8
        CALL    hal_sleep_ticks             ; busy-wait the free-running ticker
        ; ---- resident state ----
        LI      r12, 0
        LIH     r12, 0x4000                 ; UART_BASE  = 0x4000_0000
        LIH     r13, 0x4000
        ORI     r13, r13, 0x1000            ; TIMER_BASE = 0x4000_1000
        LIH     r14, 0x4000
        ORI     r14, r14, 0x2000            ; GPIO_BASE  = 0x4000_2000
        LI      r7, LO(LINBUF)
        ; (LINBUF < 0x10000: single LI; LIH would zero the low half)
        LI      r15, 0                      ; line length
        ; ---- banner + first prompt ----
        LI      r10, LO(BANNER)
        ; (BANNER < 0x10000: single LI; LIH would zero the low half)
        CALL    print_str
        CALL    print_prompt

;------------------------------------------------------------------------------
; shell loop: poll the console, line-edit, dispatch
;------------------------------------------------------------------------------
shell_loop:
        CALL    hal_console_getchar         ; r1 = byte, or 0 when idle
        CMPI    r1, 0
        BNE     r0, r0, got_char
        JMP     shell_loop

got_char:
        ; ---- line editing ----
        CMPI    r1, 13                      ; CR
        BEQ     r0, r0, line_enter
        CMPI    r1, 10                      ; LF
        BEQ     r0, r0, line_enter
        CMPI    r1, 8                       ; BS
        BEQ     r0, r0, line_bs
        CMPI    r1, 127                     ; DEL
        BEQ     r0, r0, line_bs
        CMPI    r15, 126                    ; MAXLINE - 2: keep one slot for NUL
        BGE     r0, r0, shell_loop          ; buffer full: drop the char
        ST.B    r1, r7, 0
        ADDI    r7, r7, 1
        ADDI    r15, r15, 1
        CALL    hal_console_putchar         ; echo
        JMP     shell_loop

line_bs:
        CMPI    r15, 0
        BEQ     r0, r0, shell_loop          ; nothing to erase
        SUBI    r7, r7, 1
        SUBI    r15, r15, 1
        LI      r1, 8
        CALL    hal_console_putchar
        LI      r1, 32                      ; overwrite with a space
        CALL    hal_console_putchar
        LI      r1, 8
        CALL    hal_console_putchar
        JMP     shell_loop

line_enter:
        CALL    newline
        LI      r2, 0
        ST.B    r2, r7, 0                   ; NUL-terminate the line
        CALL    line_process
        ; ---- reset the editor ----
        LI      r7, LO(LINBUF)
        ; (LINBUF < 0x10000: single LI; LIH would zero the low half)
        LI      r15, 0
        CALL    print_prompt
        JMP     shell_loop

;------------------------------------------------------------------------------
; line dispatch through the command table
;------------------------------------------------------------------------------
line_process:
        ; blank line: no-op
        LI      r10, LO(LINBUF)
        ; (LINBUF < 0x10000: single LI; LIH would zero the low half)
        LD.B    r2, r10, 0
        CMPI    r2, 0
        BEQ     r0, r0, lp_done
        ; walk: 2-word entries (name ptr, handler); name ptr 0 = end
        LI      r11, LO(CMDTBL)
        ; (CMDTBL < 0x10000: single LI; LIH would zero the low half)
lp_next:
        LD      r2, r11, 0
        CMPI    r2, 0
        BEQ     r0, r0, lp_unknown
        LD      r4, r11, 4                  ; handler
        MOV     r8, r10                     ; line walker
        MOV     r9, r2                      ; table-name walker
lp_cmp:
        LD.B    r5, r9, 0
        CMPI    r5, 0
        BEQ     r0, r0, lp_matched          ; name fully consumed -> gap check
        LD.B    r6, r8, 0
        CMP     r5, r6
        BNE     r0, r0, lp_adv
        ADDI    r8, r8, 1
        ADDI    r9, r9, 1
        JMP     lp_cmp
lp_matched:
        ; the line must continue with a space or NUL
        LD.B    r6, r8, 0
        CMPI    r6, 0
        BEQ     r0, r0, lp_go
        CMPI    r6, 32
        BEQ     r0, r0, lp_go
lp_adv:
        ADDI    r11, r11, 8
        JMP     lp_next
lp_go:
        JMPR    r4                          ; handler's RET returns to the shell
lp_unknown:
        LI      r10, LO(UNK)
        ; (UNK < 0x10000: single LI; LIH would zero the low half)
        CALL    print_str
        LI      r10, LO(LINBUF)
        ; (LINBUF < 0x10000: single LI; LIH would zero the low half)
        CALL    print_str
        CALL    newline
lp_done:
        RET

;------------------------------------------------------------------------------
; commands
;------------------------------------------------------------------------------
cmd_help:
        LI      r10, LO(HELP)
        ; (HELP < 0x10000: single LI; LIH would zero the low half)
        CALL    print_str
        CALL    newline
        RET

cmd_about:
        LI      r10, LO(ABOUT)
        ; (ABOUT < 0x10000: single LI; LIH would zero the low half)
        CALL    print_str
        CALL    newline
        RET

cmd_echo:                                   ; echo <words...>
        LI      r8, LO(LINBUF)
        ; (LINBUF < 0x10000: single LI; LIH would zero the low half)
        ADDI    r8, r8, 4                   ; past "echo"
cn_ce_skip:
        LD.B    r5, r8, 0
        CMPI    r5, 32
        BNE     r0, r0, cn_ce_go
        ADDI    r8, r8, 1
        JMP     cn_ce_skip
cn_ce_go:
        MOV     r10, r8
        CALL    print_str
        CALL    newline
        RET

cmd_time:
        LI      r10, LO(TLAB)
        ; (TLAB < 0x10000: single LI; LIH would zero the low half)
        CALL    print_str                   ; "t="
        CALL    hal_time_ticks
        CALL    print_hex
        CALL    newline
        RET

cmd_gpio:                                   ; gpio <pin 0-31> <0|1>
        LI      r8, LO(LINBUF)
        ; (LINBUF < 0x10000: single LI; LIH would zero the low half)
        ADDI    r8, r8, 4
cn_cg_psk:                                  ; skip space(s) before the pin number
        LD.B    r5, r8, 0
        CMPI    r5, 32
        BNE     r0, r0, cn_cg_par
        ADDI    r8, r8, 1
        JMP     cn_cg_psk
cn_cg_par:
        CALL    parse_dec                   ; r6 = pin, r8 past the digits
cn_cg_skip:
        LD.B    r5, r8, 0
        CMPI    r5, 32
        BNE     r0, r0, cn_cg_val
        ADDI    r8, r8, 1
        JMP     cn_cg_skip
cn_cg_val:
        LD.B    r5, r8, 0                  ; '0' or '1'
        SUBI    r5, r5, 48
        MOV     r7, r5                      ; r7 = value (r3 is print_dec scratch)
        LI      r5, 1
        SHL     r5, r5, r6                  ; r5 = 1 << pin
        LD      r2, r14, 0                  ; DIR
        OR      r2, r2, r5
        ST      r2, r14, 0
        LD      r2, r14, 4                  ; OUT
        CMPI    r7, 1
        BEQ     r0, r0, cn_cg_set
        NOT     r5, r5
        AND     r2, r2, r5
        JMP     cn_cg_write
cn_cg_set:
        OR      r2, r2, r5
cn_cg_write:
        ST      r2, r14, 4
        LI      r10, LO(GPRE)
        ; (GPRE < 0x10000: single LI; LIH would zero the low half)
        CALL    print_str                   ; "gpio "
        MOV     r1, r6
        CALL    print_dec
        LI      r1, 32
        CALL    hal_console_putchar
        LI      r1, 45                     ; '-'
        CALL    hal_console_putchar
        LI      r1, 62                     ; '>'
        CALL    hal_console_putchar
        LI      r1, 32
        CALL    hal_console_putchar
        ADDI    r1, r7, 48                 ; '0'/'1'
        CALL    hal_console_putchar
        CALL    newline
        RET

cmd_peek:                                   ; peek <hexaddr> -> 8 lowercase hex digits
        LI      r8, LO(LINBUF)
        ; (LINBUF < 0x10000: single LI; LIH would zero the low half)
        ADDI    r8, r8, 4
        CALL    skip_sp
        CALL    parse_hex                   ; r6 = addr (any 32-bit address, RAM or MMIO)
        LD      r1, r6, 0                   ; word at addr
        CALL    print_hex
        CALL    newline
        RET

cmd_poke:                                   ; poke <hexaddr> <hexval>; prints value back
        LI      r8, LO(LINBUF)
        ; (LINBUF < 0x10000: single LI; LIH would zero the low half)
        ADDI    r8, r8, 4
        CALL    skip_sp
        CALL    parse_hex                   ; r6 = addr
        MOV     r7, r6                      ; r7 = addr (r3-style scratch is fine too)
        CALL    skip_sp
        CALL    parse_hex                   ; r6 = value
        ST      r6, r7, 0                   ; [addr] = value
        LD      r1, r7, 0                   ; read back to verify the store
        CALL    print_hex
        CALL    newline
        RET

cmd_calc:                                   ; calc <dec> <op> <dec>; prints hex result
        LI      r8, LO(LINBUF)
        ; (LINBUF < 0x10000: single LI; LIH would zero the low half)
        ADDI    r8, r8, 4
        CALL    skip_sp
        CALL    parse_dec                   ; r6 = a
        MOV     r3, r6                      ; r3 = a
        CALL    skip_sp
        LD.B    r7, r8, 0                   ; r7 = op char
        ADDI    r8, r8, 1
        CALL    skip_sp
        CALL    parse_dec                   ; r6 = b
        CMPI    r7, 43                      ; '+'
        BNE     r0, r0, cn_cc_sub
        ADD     r1, r3, r6
        JMP     cn_cc_done
cn_cc_sub:
        CMPI    r7, 45                      ; '-'
        BNE     r0, r0, cn_cc_mul
        SUB     r1, r3, r6
        JMP     cn_cc_done
cn_cc_mul:
        CMPI    r7, 42                      ; '*'
        BNE     r0, r0, cn_cc_and
        MUL     r1, r3, r6
        JMP     cn_cc_done
cn_cc_and:
        CMPI    r7, 38                      ; '&'
        BNE     r0, r0, cn_cc_or
        AND     r1, r3, r6
        JMP     cn_cc_done
cn_cc_or:
        CMPI    r7, 124                     ; '|'
        BNE     r0, r0, cn_cc_xor
        OR      r1, r3, r6
        JMP     cn_cc_done
cn_cc_xor:
        CMPI    r7, 94                      ; '^'
        BNE     r0, r0, cn_cc_done
        XOR     r1, r3, r6
cn_cc_done:
        CALL    print_hex
        CALL    newline
        RET

cmd_sleep:                                  ; sleep <dec ticks>; prints measured elapsed
        LI      r8, LO(LINBUF)
        ; (LINBUF < 0x10000: single LI; LIH would zero the low half)
        ADDI    r8, r8, 5
        CALL    skip_sp
        CALL    parse_dec                   ; r6 = ticks
        LIH     r3, 0x4000
        ORI     r3, r3, 0x1000              ; TIMER base = 0x4000_1000
        LD      r7, r3, 0xC                 ; r7 = before
        MOV     r1, r6
        CALL    hal_sleep_ticks             ; busy-wait r6 ticks (clobbers r1/r2/r3/r8)
        LIH     r3, 0x4000
        ORI     r3, r3, 0x1000
        LD      r2, r3, 0xC                 ; r2 = after
        SUB     r1, r2, r7                  ; r1 = elapsed
        LI      r10, LO(SLEPT)
        ; (SLEPT < 0x10000: single LI; LIH would zero the low half)
        CALL    print_str                   ; "slept 0x"
        CALL    print_hex
        CALL    newline
        RET

cmd_exec:                                   ; exec <hexaddr> : call the code at addr
        LI      r8, LO(LINBUF)
        ; (LINBUF < 0x10000: single LI; LIH would zero the low half)
        ADDI    r8, r8, 4
        CALL    skip_sp
        CALL    parse_hex                   ; r6 = target (32-bit)
        CALL    exec_stub                   ; pushes return addr, jumps to r6
        ; back here as soon as the target code RETs
        LI      r10, LO(RAN)
        ; (RAN < 0x10000: single LI; LIH would zero the low half)
        CALL    print_str                   ; "ran"
        CALL    newline
        RET

exec_stub:                                  ; thunk so `exec` can reach any 32-bit address
        JMPR    r6

cmd_exit:                                   ; exit: HALT the simulated machine
        HALT                                ; tb watches dbg_halted and shuts down

;------------------------------------------------------------------------------
; small helpers
;------------------------------------------------------------------------------
print_str:                                  ; r10 = NUL-terminated string address
cn_ps_again:
        LD.B    r11, r10, 0
        CMPI    r11, 0
        BEQ     r0, r0, cn_ps_done
        MOV     r1, r11
        CALL    hal_console_putchar
        ADDI    r10, r10, 1
        JMP     cn_ps_again
cn_ps_done:
        RET

print_prompt:
        LI      r10, LO(PROMPT)
        ; (PROMPT < 0x10000: single LI; LIH would zero the low half)
        CALL    print_str
        RET

print_hex:                                  ; r1 = 32-bit value, 8 lowercase digits
        MOV     r9, r1
        LI      r11, 28
cn_ph_loop:
        MOV     r2, r9
        SHRI    r2, r2, 28                  ; top nibble 0..15 (logical shift)
        CMPI    r2, 10
        BLT     r0, r0, cn_ph_digit
        ADDI    r2, r2, 0x57                ; 'a'-'f'
        JMP     cn_ph_emit
cn_ph_digit:
        ADDI    r2, r2, 0x30                ; '0'-'9'
cn_ph_emit:
        MOV     r1, r2
        CALL    hal_console_putchar
        SHLI    r9, r9, 4
        SUBI    r11, r11, 4
        CMPI    r11, -4
        BNE     r0, r0, cn_ph_loop
        RET

print_dec:                                  ; r1 = unsigned value 0..31
        LI      r3, 0                       ; tens
cn_nz_loop:
        CMPI    r1, 10
        BLTU    r0, r0, cn_nz_emit
        SUBI    r1, r1, 10
        ADDI    r3, r3, 1
        JMP     cn_nz_loop
cn_nz_emit:
        MOV     r9, r1                      ; stash units (r1 carries the char later)
        ADDI    r2, r3, 48
        MOV     r1, r2
        CALL    hal_console_putchar
        ADDI    r9, r9, 48
        MOV     r1, r9
        CALL    hal_console_putchar
        RET

newline:
        LI      r1, 13
        CALL    hal_console_putchar
        LI      r1, 10
        CALL    hal_console_putchar
        RET

;------------------------------------------------------------------------------
; token helpers
;------------------------------------------------------------------------------
parse_dec:                                  ; r8 -> digits; r6 = value; r8 past digits
        LI      r6, 0
cn_pd_iter:
        LD.B    r5, r8, 0
        SUBI    r5, r5, 48                  ; '0' == 0x30
        CMPI    r5, 10
        BGEU    r0, r0, cn_pd_done          ; unsigned r5 >= 10 (incl. <0 wrapped)
        MOV     r9, r6
        SHLI    r9, r9, 3                   ; acc*8
        SHLI    r6, r6, 1                   ; acc*2
        ADD     r6, r9, r6                  ; acc*10
        ADD     r6, r6, r5                  ; +digit
        ADDI    r8, r8, 1
        JMP     cn_pd_iter
cn_pd_done:
        RET

skip_sp:                                    ; r8 -> ptr; r8 past any spaces
cn_ss_loop:
        LD.B    r5, r8, 0
        CMPI    r5, 32
        BNE     r0, r0, cn_ss_done
        ADDI    r8, r8, 1
        JMP     cn_ss_loop
cn_ss_done:
        RET

parse_hex:                                  ; r8 -> hex digits; r6 = value; r8 past digits
        LI      r6, 0
cn_phx_iter:
        LD.B    r5, r8, 0
        SUBI    r5, r5, 48
        CMPI    r5, 10
        BGEU    r0, r0, cn_phx_ltr          ; not a decimal digit (incl. <0 wrapped)
        SHLI    r6, r6, 4
        ADD     r6, r6, r5
        ADDI    r8, r8, 1
        JMP     cn_phx_iter
cn_phx_ltr:                                 ; 'A'-'F' or 'a'-'f' or stop
        LD.B    r5, r8, 0
        CMPI    r5, 65
        BLT     r0, r0, cn_phx_lo
        CMPI    r5, 71                      ; 'G'
        BGEU    r0, r0, cn_phx_lo
        SUBI    r5, r5, 55                  ; 'A'-'F' -> 10..15
        JMP     cn_phx_dig
cn_phx_lo:
        CMPI    r5, 97
        BLT     r0, r0, cn_phx_done
        CMPI    r5, 103                     ; 'g'
        BGEU    r0, r0, cn_phx_done
        SUBI    r5, r5, 87                  ; 'a'-'f' -> 10..15
cn_phx_dig:
        SHLI    r6, r6, 4
        ADD     r6, r6, r5
        ADDI    r8, r8, 1
        JMP     cn_phx_iter
cn_phx_done:
        RET

;------------------------------------------------------------------------------
; data
;------------------------------------------------------------------------------
.include "hal_dk.s"
; above: DeckCPU HAL, forward-referenced by the shell

BANNER: .asciz "\r\nDeckOS/1.0 DeckCPU console\r\nport: HAL + polled shell\r\n"
PROMPT: .asciz "DeckOS> "
HELP:   .asciz "commands: help about echo time gpio peek poke calc sleep exec exit"
ABOUT:  .asciz "DeckOS/1.0 DeckCPU console"
UNK:    .asciz "Unknown command: "
TLAB:   .asciz "t="
GPRE:   .asciz "gpio "
SLEPT:  .asciz "slept 0x"
RAN:    .asciz "ran"

CMDTBL:
        .word   cmd_help_name
        .word   cmd_help
        .word   cmd_abt_name
        .word   cmd_about
        .word   cmd_ech_name
        .word   cmd_echo
        .word   cmd_tim_name
        .word   cmd_time
        .word   cmd_gpi_name
        .word   cmd_gpio
        .word   cmd_pk_name
        .word   cmd_peek
        .word   cmd_po_name
        .word   cmd_poke
        .word   cmd_ca_name
        .word   cmd_calc
        .word   cmd_sl_name
        .word   cmd_sleep
        .word   cmd_ex_name
        .word   cmd_exec
        .word   cmd_exit_name
        .word   cmd_exit
        .word   0
        .word   0
cmd_help_name: .asciz "help"
cmd_abt_name:  .asciz "about"
cmd_ech_name:  .asciz "echo"
cmd_tim_name:  .asciz "time"
cmd_gpi_name:  .asciz "gpio"
cmd_pk_name:   .asciz "peek"
cmd_po_name:   .asciz "poke"
cmd_ca_name:   .asciz "calc"
cmd_sl_name:   .asciz "sleep"
cmd_ex_name:   .asciz "exec"
cmd_exit_name: .asciz "exit"

LINBUF: ; zero-filled 128-byte line buffer (indices 0..MAXLINE-1)
        .byte 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
        .byte 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
        .byte 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
        .byte 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
        .byte 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
        .byte 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
        .byte 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
        .byte 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
