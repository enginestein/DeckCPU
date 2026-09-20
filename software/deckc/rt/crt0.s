; ============================================================================
; deckc runtime hand-written DeckCPU assembly (crt0 + mini-libc + helpers).
;
; deckc ABI (must match software/deckc/codegen.py):
;   - every parameter and variadic argument travels on the stack, pushed
;     right-to-left by the caller and read at [FP + 8 + 4*i]
;   - r0 = expression value / return value; r15 = frame pointer (callee
;     saved, restored by absolute caller convention below)
;   - r1..r14 are scratch (caller-saved); functions needing state across a
;     call save it or keep it in a register the callee leaves alone
;   - putchar clobbers only r0..r3 (and r15, balanced); __decko_udivmod
;     clobbers r0..r5 these two contracts are relied on by the format
;     engine below
;
; Interrupts are never used on this target (the CPU model's IRQ inputs stay
; deasserted and EI is never executed), so the irq "lock" helpers only
; toggle FLAGS.I like the DeckOS HAL port.
;
; Memory layout: program image + .bss-style data at the bottom of RAM
; (0x0000_0000 up), stack at the top ending at RESET_SP == 0x0000_FFFC.
; The mailbox word at 0x0000_DF00 receives main()'s return value (the
; testbench's exit-code channel).
; ============================================================================

            .org 0
            JMP   deckc_start
            HALT                    ; IVT slots 1..7 unhandled
            HALT
            HALT
            HALT
            HALT
            HALT
            HALT

deckc_start:
            LI    r2, 0xFFFC         ; SP = top of 64 KiB RAM
            WRSP  r2
            LI    r0, 0              ; main(void)
            CALL  main
            LI    r1, 0xDF00         ; mailbox address
            ST    r0, r1, 0          ; exit code = main() return value
            HALT

; ---------------------------------------------------------------------------
; __decko_uart_init enable UART TX+RX and start the free-running TIMER.
; Mirrors deckos-port/deckcpu/hal_dk.s:hal_console_init.
; ---------------------------------------------------------------------------
__decko_uart_init:
            PUSH  r15
            RDSP  r2
            MOV   r15, r2
            LI    r2, 0
            LIH   r2, 0x4000             ; UART base
            LI    r1, 3                  ; CTRL: TX_EN + RX_EN
            ST    r1, r2, 0xC
            LI    r1, 0
            ORI   r1, r1, 0xFFFF         ; TIMER COMPARE = 0xFFFFFFFF
            ST    r1, r2, 0x1008
            LI    r1, 5                  ; TIMER CTRL: ENABLE + REPEAT
            ST    r1, r2, 0x1000
            MOV   r2, r15
            POP   r15
            RET

; ---------------------------------------------------------------------------
; __decko_uart_getc block until a byte arrives, return it in r0.
; Polls STS.RX_READY (bit1) then reads RXD (+0x04; the RTL clears RX_READY on
; the read). Mirrors deckos-port/deckcpu/hal_dk.s:hal_console_getchar.
; Clobbers r0..r3 (r15 balanced).
; ---------------------------------------------------------------------------
__decko_uart_getc:
            PUSH  r15
            RDSP  r2
            MOV   r15, r2
            LI    r2, 0
            LIH   r2, 0x4000             ; UART base
dc_getc_wait:
            LD    r3, r2, 0x8            ; STS
            ANDI  r3, r3, 2              ; RX_READY
            BEQ   r0, r0, dc_getc_wait
            LD.B  r0, r2, 0x4            ; RXD
            MOV   r2, r15
            POP   r15
            RET

; ---------------------------------------------------------------------------
; __decko_putc clobbers r0..r3; arg must be in r1 (single byte).
; ---------------------------------------------------------------------------
__decko_putc:
            PUSH  r15
            RDSP  r2
            MOV   r15, r2
            LI    r2, 0
            LIH   r2, 0x4000             ; UART base
dc_putc_wait:
            LD    r3, r2, 0x8            ; STS
            ANDI  r3, r3, 1              ; TX_BUSY
            BNE   r0, r0, dc_putc_wait
            ST.B  r1, r2, 0x0            ; TXD
            MOV   r2, r15
            POP   r15
            RET

; ---------------------------------------------------------------------------
; putchar deckc-ABI: putchar(c) -> c. clobbers r0..r3 only.
; ---------------------------------------------------------------------------
putchar:
            PUSH  r15
            RDSP  r2
            MOV   r15, r2
            LD    r1, r15, 8             ; arg c
            ANDI  r1, r1, 0xFF
            LI    r2, 0
            LIH   r2, 0x4000
pc_wait:
            LD    r3, r2, 0x8
            ANDI  r3, r3, 1
            BNE   r0, r0, pc_wait
            ST.B  r1, r2, 0x0
            MOV   r0, r1
            MOV   r2, r15
            POP   r15
            RET

; ---------------------------------------------------------------------------
; irq critical sections (FLAGS.I only no real IRQs on this target).
; ---------------------------------------------------------------------------
__decko_irq_disable:                      ; -> r0 = saved FLAGS (I cleared)
            PUSH  r15
            RDSP  r2
            MOV   r15, r2
            RDFLAG r0
            DI
            MOV   r2, r15
            POP   r15
            RET

__decko_irq_restore:                     ; r0 = saved FLAGS
            PUSH  r15
            RDSP  r2
            MOV   r15, r2
            WRFLAG r0
            MOV   r2, r15
            POP   r15
            RET

; ---------------------------------------------------------------------------
; __decko_time_tick -> r0 = free-running TIMER COUNT (1 tick per clock).
; ---------------------------------------------------------------------------
__decko_time_tick:
            PUSH  r15
            RDSP  r2
            MOV   r15, r2
            LI    r0, 0
            LIH   r0, 0x4000
            ORI   r0, r0, 0x1000         ; TIMER base
            LD    r0, r0, 0xC            ; COUNT
            MOV   r2, r15
            POP   r15
            RET

; ============================================================================
; division restoring algorithm, 32 iterations. No hardware divide on the
; DeckCPU. clobbers r0..r5; args in r0 (dividend) / r1 (divisor) because the
; __decko_div* wrappers pull them off the stack themselves (leaf helpers).
; ============================================================================
__decko_udivmod:                          ; r0=a r1=b -> r0=a/b r2=a%b
            MOV   r4, r0
            LI    r0, 0
            LI    r2, 0
            CMPI  r1, 0
            BEQ   r0, r0, dm_udiv_done
            LI    r3, 32
dm_udiv_loop:
            SHLI  r2, r2, 1
            SHRI  r5, r4, 31
            OR    r2, r2, r5
            SHLI  r4, r4, 1
            SHLI  r0, r0, 1
            CMP   r2, r1
            BLTU  r0, r0, dm_udiv_next
            SUB   r2, r2, r1
            ORI   r0, r0, 1
dm_udiv_next:
            SUBI  r3, r3, 1
            CMPI  r3, 0
            BNE   r0, r0, dm_udiv_loop
dm_udiv_done:
            RET

__decko_udiv:                             ; unsigned a/b -> r0
            PUSH  r15
            RDSP  r2
            MOV   r15, r2
            LD    r0, r15, 8
            LD    r1, r15, 12
            CALL  __decko_udivmod
            MOV   r2, r15
            POP   r15
            RET

__decko_umod:                             ; unsigned a%b -> r0
            PUSH  r15
            RDSP  r2
            MOV   r15, r2
            LD    r0, r15, 8
            LD    r1, r15, 12
            CALL  __decko_udivmod
            MOV   r0, r2
            MOV   r2, r15
            POP   r15
            RET

__decko_div:                              ; signed a/b -> r0
            PUSH  r15
            RDSP  r2
            MOV   r15, r2
            LD    r0, r15, 8
            LD    r1, r15, 12
            PUSH  r0
            PUSH  r1
            XOR   r3, r0, r1             ; sign xor
            CMPI  r0, 0
            BGE   r0, r0, dm_div_aok
            LI    r2, 0
            SUB   r0, r2, r0
dm_div_aok:
            CMPI  r1, 0
            BGE   r0, r0, dm_div_bok
            LI    r2, 0
            SUB   r1, r2, r1
dm_div_bok:
            PUSH  r3
            CALL  __decko_udivmod
            POP   r3
            SHRI  r4, r3, 31
            CMPI  r4, 0
            BEQ   r0, r0, dm_div_ok
            LI    r2, 0
            SUB   r0, r2, r0
dm_div_ok:
            RDSP  r2
            ADDI  r2, r2, 8
            WRSP  r2
            MOV   r2, r15
            POP   r15
            RET

__decko_mod:                              ; signed a%b -> r0 (sign of dividend)
            PUSH  r15
            RDSP  r2
            MOV   r15, r2
            LD    r0, r15, 8
            LD    r1, r15, 12
            PUSH  r0
            PUSH  r1
            SHRI  r3, r0, 31             ; dividend sign
            CMPI  r0, 0
            BGE   r0, r0, dm_mod_aok
            LI    r2, 0
            SUB   r0, r2, r0
dm_mod_aok:
            CMPI  r1, 0
            BGE   r0, r0, dm_mod_bok
            LI    r2, 0
            SUB   r1, r2, r1
dm_mod_bok:
            PUSH  r3
            CALL  __decko_udivmod
            POP   r3
            MOV   r0, r2
            CMPI  r3, 0
            BEQ   r0, r0, dm_mod_ok
            LI    r2, 0
            SUB   r0, r2, r0
dm_mod_ok:
            RDSP  r2
            ADDI  r2, r2, 8
            WRSP  r2
            MOV   r2, r15
            POP   r15
            RET

; ============================================================================
; memory / string primitives. Params from the deckc stack: buf@+8, val@+12,
; n@+16 (they use r0..r3 as temps, saved in a frame like normal functions).
; ============================================================================
memset:                                    ; memset(buf, val, n) -> buf
            PUSH  r15
            RDSP  r2
            MOV   r15, r2
            LD    r0, r15, 8
            LD    r1, r15, 12
            LD    r2, r15, 16
            PUSH  r0
            ANDI  r1, r1, 0xFF
            CMPI  r2, 0
            BEQ   r0, r0, ms_done
ms_loop:
            ST.B  r1, r0, 0
            ADDI  r0, r0, 1
            SUBI  r2, r2, 1
            CMPI  r2, 0
            BNE   r0, r0, ms_loop
ms_done:
            POP   r0
            MOV   r2, r15
            POP   r15
            RET

strncpy:                                   ; strncpy(dst, src, n) -> dst
            PUSH  r15
            RDSP  r2
            MOV   r15, r2
            LD    r0, r15, 8
            LD    r1, r15, 12
            LD    r2, r15, 16
            PUSH  r0
snp_loop:
            CMPI  r2, 0
            BEQ   r0, r0, snp_done
            LD.B  r3, r1, 0
            ST.B  r3, r0, 0
            ADDI  r0, r0, 1
            ADDI  r1, r1, 1
            SUBI  r2, r2, 1
            CMPI  r3, 0
            BNE   r0, r0, snp_loop
snp_pad:
            CMPI  r2, 0
            BEQ   r0, r0, snp_done
            LI    r3, 0
            ST.B  r3, r0, 0
            ADDI  r0, r0, 1
            SUBI  r2, r2, 1
            JMP   snp_pad
snp_done:
            POP   r0
            MOV   r2, r15
            POP   r15
            RET

; ============================================================================
; format engine. Shared by printf (UART sink) and snprintf (buffer sink).
;
; registers:
;   r14 format pointer      r9  width
;   r4  next variadic arg   r10 flags (bit0 left-align, bit1 zero-pad)
;   r5  chars emitted       r11 emit char / working value
;   r6  sink (0=UART)       r12 base
;   r7  buffer remaining    r13 temp / digit count / pad count
;   r8  buffer pointer
;
; putchar clobbers r0..r3 only, so r4..r14 survive every sink emit.
; ============================================================================
ft_engine:                                 ; r14 fmt, r4 vararg, r6 sink,
                                           ; r7 buf-left, r8 buf-ptr -> r5
            LI    r5, 0
ft_main:
            LD.B  r2, r14, 0
            CMPI  r2, 0
            BEQ   r0, r0, ft_done
            ADDI  r14, r14, 1
            CMPI  r2, 37                  ; '%'
            BNE   r0, r0, ft_plain
            LD.B  r2, r14, 0
            LI    r10, 0
            CMPI  r2, 45                  ; '-'
            BNE   r0, r0, ft_nl
            ORI   r10, r10, 1
            ADDI  r14, r14, 1
            LD.B  r2, r14, 0
ft_nl:
            CMPI  r2, 48                  ; '0'
            BNE   r0, r0, ft_nz
            ORI   r10, r10, 2
            ADDI  r14, r14, 1
            LD.B  r2, r14, 0
ft_nz:
            LI    r9, 0
ft_wl:
            SUBI  r3, r2, 48
            CMPI  r3, 10
            BGEU  r0, r0, ft_wd
            MULI  r9, r9, 10
            ADD   r9, r9, r3
            ADDI  r14, r14, 1
            LD.B  r2, r14, 0
            JMP   ft_wl
ft_wd:
            CMPI  r2, 108                 ; 'l'
            BNE   r0, r0, ft_conv
            ADDI  r14, r14, 1
            LD.B  r2, r14, 0
ft_conv:
            CMPI  r2, 115                 ; 's'
            BEQ   r0, r0, ft_str
            CMPI  r2, 100                 ; 'd'
            BEQ   r0, r0, ft_int
            CMPI  r2, 117                 ; 'u'
            BEQ   r0, r0, ft_uint
            CMPI  r2, 120                 ; 'x'
            BEQ   r0, r0, ft_hex
            CMPI  r2, 99                  ; 'c'
            BEQ   r0, r0, ft_chr
            CMPI  r2, 37                  ; '%'
            BEQ   r0, r0, ft_pct
            JMP   ft_main                 ; unknown specifier: skip it

ft_plain:
            MOV   r11, r2
            CALL  ft_emit
            JMP   ft_main
ft_pct:
            LI    r11, 37
            CALL  ft_emit
            JMP   ft_main
ft_chr:
            ADDI  r14, r14, 1
            LD    r1, r4, 0
            ADDI  r4, r4, 4
            ANDI  r11, r1, 0xFF
            CALL  ft_emit
            JMP   ft_main
ft_int:
            ADDI  r14, r14, 1
            LD    r11, r4, 0
            ADDI  r4, r4, 4
            CMPI  r11, 0
            BGE   r0, r0, ft_int_pos
            PUSH  r11
            LI    r11, 45                 ; '-'
            CALL  ft_emit
            POP   r11
            LI    r0, 0
            SUB   r11, r0, r11
ft_int_pos:
            LI    r12, 10
            JMP   ft_uout
ft_uint:
            ADDI  r14, r14, 1
            LD    r11, r4, 0
            ADDI  r4, r4, 4
            LI    r12, 10
            JMP   ft_uout
ft_hex:
            ADDI  r14, r14, 1
            LD    r11, r4, 0
            ADDI  r4, r4, 4
            LI    r12, 16
            JMP   ft_uout
ft_done:
            RET

; ---- unsigned integer out: r11 value, r12 base, r9 width, r10 flags ----
ft_uout:
            LI    r13, 0                   ; digit count
            CMPI  r11, 0
            BEQ   r0, r0, ft_u_zero
ft_u_loop:
            PUSH  r4
            PUSH  r5
            MOV   r0, r11
            MOV   r1, r12
            CALL  __decko_udivmod          ; r0=quot r2=rem
            MOV   r11, r0
            POP   r5
            POP   r4
            ADDI  r2, r2, 48
            CMPI  r2, 58
            BLTU  r0, r0, ft_u_push
            ADDI  r2, r2, 39               ; ':'.. -> 'a'.. for hex
ft_u_push:
            PUSH  r2
            ADDI  r13, r13, 1
            CMPI  r11, 0
            BNE   r0, r0, ft_u_loop
            JMP   ft_u_pad
ft_u_zero:
            LI    r2, 48
            PUSH  r2
            LI    r13, 1
ft_u_pad:
            CMP   r9, r13
            BLTU  r0, r0, ft_u_nopad
            SUB   r2, r9, r13
            JMP   ft_u_have
ft_u_nopad:
            LI    r2, 0
ft_u_have:
            ANDI  r3, r10, 1
            CMPI  r3, 0
            BNE   r0, r0, ft_u_left
            ; right-align: padding then digits
            PUSH  r13
            MOV   r13, r2                  ; pad count
            ANDI  r3, r10, 2
            CMPI  r3, 0
            BEQ   r0, r0, ft_u_rsp
            LI    r3, 48                   ; zero padding
            JMP   ft_u_rhv
ft_u_rsp:
            LI    r3, 32                   ; space padding
ft_u_rhv:
            MOV   r11, r3
ft_u_rpad:
            CMPI  r13, 0
            BEQ   r0, r0, ft_u_rpad_done
            CALL  ft_emit
            SUBI  r13, r13, 1
            JMP   ft_u_rpad
ft_u_rpad_done:
            POP   r13
            JMP   ft_u_emit
ft_u_left:
            PUSH  r2                       ; pad count for later
            JMP   ft_u_emit
ft_u_emit:
            CMPI  r13, 0
            BEQ   r0, r0, ft_u_lpend
            POP   r11
            CALL  ft_emit
            SUBI  r13, r13, 1
            JMP   ft_u_emit
ft_u_lpend:
            ANDI  r3, r10, 1
            CMPI  r3, 0
            BEQ   r0, r0, ft_main
            POP   r13                      ; pad count
            LI    r11, 32
ft_u_lpad:
            CMPI  r13, 0
            BEQ   r0, r0, ft_main
            CALL  ft_emit
            SUBI  r13, r13, 1
            JMP   ft_u_lpad

; ---- string out: r11 str ptr, r9 width, r10 flags ----
ft_str:
            ADDI  r14, r14, 1
            LD    r11, r4, 0
            ADDI  r4, r4, 4
            MOV   r1, r11                  ; r1 = str ptr (survives putchar)
            LI    r2, 0                    ; r2 = len (survives putchar)
ft_str_ln:
            LD.B  r3, r1, 0
            CMPI  r3, 0
            BEQ   r0, r0, ft_str_lndone
            ADDI  r1, r1, 1
            ADDI  r2, r2, 1
            JMP   ft_str_ln
ft_str_lndone:
            MOV   r1, r11                  ; restore start (r11 survived the scan)
            ; r2 = len. pad = max(0, width - len) in r3-agnostic way.
            CMP   r9, r2
            BLTU  r0, r0, ft_str_nopad
            SUB   r3, r9, r2
            MOV   r13, r3                  ; pad count (r13 survives putchar)
            JMP   ft_str_have
ft_str_nopad:
            LI    r13, 0
ft_str_have:
            ANDI  r3, r10, 1
            CMPI  r3, 0
            BNE   r0, r0, ft_str_left
            ; right-align: spaces, then the string
            PUSH  r2
            PUSH  r1
            LI    r11, 32
ft_str_rpad:
            CMPI  r13, 0
            BEQ   r0, r0, ft_str_rpd
            CALL  ft_emit
            SUBI  r13, r13, 1
            JMP   ft_str_rpad
ft_str_rpd:
            POP   r1
            POP   r2
            JMP   ft_str_emit
ft_str_left:
            PUSH  r13                      ; pad count for after the string
            JMP   ft_str_emit
ft_str_emit:                               ; r1=str r2=len
            CMPI  r2, 0
            BEQ   r0, r0, ft_str_emit_dn
            LD.B  r11, r1, 0
            ADDI  r1, r1, 1
            SUBI  r2, r2, 1
            PUSH  r1
            PUSH  r2
            CALL  ft_emit                   ; putchar clobbers r1/r2: keep them
            POP   r2
            POP   r1
            JMP   ft_str_emit
ft_str_emit_dn:
            ANDI  r3, r10, 1
            CMPI  r3, 0
            BEQ   r0, r0, ft_main
            POP   r13
            LI    r11, 32
ft_str_lpad:
            CMPI  r13, 0
            BEQ   r0, r0, ft_main
            CALL  ft_emit
            SUBI  r13, r13, 1
            JMP   ft_str_lpad

; ---- sink: emit r11 ----
ft_emit:
            CMPI  r6, 0
            BNE   r0, r0, ft_emit_buf
            PUSH  r11
            CALL  putchar                   ; putchar reads arg from stack
            POP   r11
            ADDI  r5, r5, 1
            RET
ft_emit_buf:
            CMPI  r7, 0
            BEQ   r0, r0, ft_emit_skip
            ST.B  r11, r8, 0
            ADDI  r8, r8, 1
            SUBI  r7, r7, 1
ft_emit_skip:
            ADDI  r5, r5, 1
            RET

; ============================================================================
; printf / snprintf deckc-ABI wrappers.
; Layout: [FP+4] ret, [FP+8] fmt (printf) / buf (snprintf), [FP+12] next...
; ============================================================================
printf:                                    ; printf(fmt, ...) -> chars
            PUSH  r15
            RDSP  r2
            MOV   r15, r2
            LD    r14, r15, 8
            ADDI  r4, r15, 12
            LI    r6, 0
            CALL  ft_engine
            MOV   r0, r5
            MOV   r2, r15
            POP   r15
            RET

snprintf:                                  ; snprintf(buf, n, fmt, ...) -> chars
            PUSH  r15
            RDSP  r2
            MOV   r15, r2
            LD    r8, r15, 8               ; buf
            LD    r7, r15, 12              ; n
            LD    r14, r15, 16             ; fmt
            ADDI  r4, r15, 20              ; first variadic arg
            LI    r6, 1
            SUBI  r7, r7, 1                ; reserve room for NUL
            CMPI  r7, 0
            BGE   r0, r0, snp_run
            LI    r7, 0
snp_run:
            CALL  ft_engine
            CMPI  r7, 0
            BEQ   r0, r0, snp_ret
            LI    r3, 0
            ST.B  r3, r8, 0
snp_ret:
            MOV   r0, r5
            MOV   r2, r15
            POP   r15
            RET