; deckc-generated DeckCPU assembly
; source: bsp.c, main_deckc.c, syslog.c

; ---- runtime ----
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

; ---- program code ----

; ---- function syslog_lock
syslog_lock:
PUSH r15
RDSP r2
MOV r15, r2
RDSP r2
SUBI r2, r2, 4
WRSP r2
CALL __decko_irq_disable
MOV r2, r15
WRSP r2
POP r15
RET
MOV r2, r15
WRSP r2
POP r15
RET

; ---- function syslog_unlock
syslog_unlock:
PUSH r15
RDSP r2
MOV r15, r2
RDSP r2
SUBI r2, r2, 4
WRSP r2
SUBI r0, r15, -8
LD r0, r0, 0
PUSH r0
CALL __decko_irq_restore
RDSP r2
ADDI r2, r2, 4
WRSP r2
MOV r2, r15
WRSP r2
POP r15
RET

; ---- function get_absolute_time
get_absolute_time:
PUSH r15
RDSP r2
MOV r15, r2
RDSP r2
SUBI r2, r2, 4
WRSP r2
CALL __decko_time_tick
MOV r2, r15
WRSP r2
POP r15
RET
MOV r2, r15
WRSP r2
POP r15
RET

; ---- function to_ms_since_boot
to_ms_since_boot:
PUSH r15
RDSP r2
MOV r15, r2
RDSP r2
SUBI r2, r2, 4
WRSP r2
SUBI r0, r15, -8
LD r0, r0, 0
MOV r2, r15
WRSP r2
POP r15
RET
MOV r2, r15
WRSP r2
POP r15
RET

; ---- function bt_log_is_enabled
bt_log_is_enabled:
PUSH r15
RDSP r2
MOV r15, r2
RDSP r2
SUBI r2, r2, 4
WRSP r2
LI r0, 0
MOV r2, r15
WRSP r2
POP r15
RET
MOV r2, r15
WRSP r2
POP r15
RET

; ---- function bt_log_mirror
bt_log_mirror:
PUSH r15
RDSP r2
MOV r15, r2
RDSP r2
SUBI r2, r2, 4
WRSP r2
MOV r2, r15
WRSP r2
POP r15
RET

; ---- function main
main:
PUSH r15
RDSP r2
MOV r15, r2
RDSP r2
SUBI r2, r2, 4
WRSP r2
CALL __decko_uart_init
CALL syslog_init
LI r0, LO(LSTR1)
PUSH r0
LI r0, LO(LSTR2)
PUSH r0
LI r0, 0
PUSH r0
CALL syslog_write
RDSP r2
ADDI r2, r2, 12
WRSP r2
LI r0, LO(LSTR3)
PUSH r0
LI r0, LO(LSTR2)
PUSH r0
LI r0, 2
PUSH r0
CALL syslog_write
RDSP r2
ADDI r2, r2, 12
WRSP r2
LI r0, LO(LSTR4)
PUSH r0
LI r0, LO(LSTR2)
PUSH r0
LI r0, 3
PUSH r0
CALL syslog_write
RDSP r2
ADDI r2, r2, 12
WRSP r2
LI r0, LO(LSTR5)
PUSH r0
LI r0, LO(LSTR2)
PUSH r0
LI r0, 1
PUSH r0
CALL syslog_write
RDSP r2
ADDI r2, r2, 12
WRSP r2
LI r0, 0
PUSH r0
LI r0, 0
PUSH r0
CALL syslog_dump
RDSP r2
ADDI r2, r2, 8
WRSP r2
CALL syslog_clear
LI r0, 0
PUSH r0
LI r0, 0
PUSH r0
CALL syslog_dump
RDSP r2
ADDI r2, r2, 8
WRSP r2
CALL syslog_total
MOV r2, r15
WRSP r2
POP r15
RET
MOV r2, r15
WRSP r2
POP r15
RET

; ---- function level_str
level_str:
PUSH r15
RDSP r2
MOV r15, r2
RDSP r2
SUBI r2, r2, 8
WRSP r2
SUBI r0, r15, -8
LD r0, r0, 0
ST r0, r15, -4
LD r0, r15, -4
LI r1, 0
CMP r0, r1
BEQ r0, r0, Lcase7
LD r0, r15, -4
LI r1, 1
CMP r0, r1
BEQ r0, r0, Lcase8
LD r0, r15, -4
LI r1, 2
CMP r0, r1
BEQ r0, r0, Lcase9
LD r0, r15, -4
LI r1, 3
CMP r0, r1
BEQ r0, r0, Lcase10
JMP Ldflt11
Lcase7:
LI r0, LO(LSTR12)
MOV r2, r15
WRSP r2
POP r15
RET
Lcase8:
LI r0, LO(LSTR13)
MOV r2, r15
WRSP r2
POP r15
RET
Lcase9:
LI r0, LO(LSTR14)
MOV r2, r15
WRSP r2
POP r15
RET
Lcase10:
LI r0, LO(LSTR15)
MOV r2, r15
WRSP r2
POP r15
RET
Ldflt11:
LI r0, LO(LSTR16)
MOV r2, r15
WRSP r2
POP r15
RET
Lswend6:
MOV r2, r15
WRSP r2
POP r15
RET

; ---- function level_color
level_color:
PUSH r15
RDSP r2
MOV r15, r2
RDSP r2
SUBI r2, r2, 8
WRSP r2
SUBI r0, r15, -8
LD r0, r0, 0
ST r0, r15, -4
LD r0, r15, -4
LI r1, 0
CMP r0, r1
BEQ r0, r0, Lcase18
LD r0, r15, -4
LI r1, 1
CMP r0, r1
BEQ r0, r0, Lcase19
LD r0, r15, -4
LI r1, 2
CMP r0, r1
BEQ r0, r0, Lcase20
LD r0, r15, -4
LI r1, 3
CMP r0, r1
BEQ r0, r0, Lcase21
JMP Ldflt22
Lcase18:
LI r0, LO(LSTR23)
MOV r2, r15
WRSP r2
POP r15
RET
Lcase19:
LI r0, LO(LSTR24)
MOV r2, r15
WRSP r2
POP r15
RET
Lcase20:
LI r0, LO(LSTR25)
MOV r2, r15
WRSP r2
POP r15
RET
Lcase21:
LI r0, LO(LSTR26)
MOV r2, r15
WRSP r2
POP r15
RET
Ldflt22:
LI r0, LO(LSTR24)
MOV r2, r15
WRSP r2
POP r15
RET
Lswend17:
MOV r2, r15
WRSP r2
POP r15
RET

; ---- function syslog_init
syslog_init:
PUSH r15
RDSP r2
MOV r15, r2
RDSP r2
SUBI r2, r2, 64
WRSP r2
LI r0, 5376
PUSH r0
LI r0, 0
PUSH r0
LI r0, LO(s_ring)
PUSH r0
CALL memset
RDSP r2
ADDI r2, r2, 12
WRSP r2
LI r0, LO(s_head)
ST r0, r15, -4
LI r0, 0
LD r1, r15, -4
ST r0, r1, 0
LI r0, LO(s_count)
ST r0, r15, -8
LI r0, 0
LD r1, r15, -8
ST r0, r1, 0
LI r0, LO(s_total)
ST r0, r15, -12
LI r0, 0
LD r1, r15, -12
ST r0, r1, 0
LI r0, 64
PUSH r0
LI r0, LO(LSTR27)
PUSH r0
LI r0, 32
PUSH r0
SUBI r0, r15, 32
PUSH r0
CALL snprintf
RDSP r2
ADDI r2, r2, 16
WRSP r2
SUBI r0, r15, 32
PUSH r0
LI r0, LO(LSTR28)
PUSH r0
LI r0, 1
PUSH r0
CALL syslog_write
RDSP r2
ADDI r2, r2, 12
WRSP r2
MOV r2, r15
WRSP r2
POP r15
RET

; ---- function syslog_write
syslog_write:
PUSH r15
RDSP r2
MOV r15, r2
RDSP r2
SUBI r2, r2, 92
WRSP r2
CALL syslog_lock
ST r0, r15, -4
LI r0, LO(s_ring)
ST r0, r15, -12
LI r0, LO(s_head)
LD r0, r0, 0
MOV r1, r0
MULI r1, r1, 84
LD r0, r15, -12
ADD r0, r0, r1
ST r0, r15, -8
SUBI r0, r15, 8
LD r0, r0, 0
ADDI r0, r0, 0
ST r0, r15, -16
CALL get_absolute_time
PUSH r0
CALL to_ms_since_boot
RDSP r2
ADDI r2, r2, 4
WRSP r2
LD r1, r15, -16
ST r0, r1, 0
SUBI r0, r15, 8
LD r0, r0, 0
ADDI r0, r0, 4
ST r0, r15, -20
SUBI r0, r15, -8
LD r0, r0, 0
LD r1, r15, -20
ST r0, r1, 0
LI r0, 12
ST r0, r15, -24
LI r0, 1
MOV r1, r0
LD r0, r15, -24
SUB r0, r0, r1
PUSH r0
SUBI r0, r15, -12
LD r0, r0, 0
CMPI r0, 0
BEQ r0, r0, Lel29
SUBI r0, r15, -12
LD r0, r0, 0
JMP Ldone30
Lel29:
LI r0, LO(LSTR31)
Ldone30:
PUSH r0
SUBI r0, r15, 8
LD r0, r0, 0
ADDI r0, r0, 8
PUSH r0
CALL strncpy
RDSP r2
ADDI r2, r2, 12
WRSP r2
SUBI r0, r15, 8
LD r0, r0, 0
ADDI r0, r0, 8
ST r0, r15, -32
LI r0, 12
ST r0, r15, -36
LI r0, 1
MOV r1, r0
LD r0, r15, -36
SUB r0, r0, r1
MOV r1, r0
LD r0, r15, -32
ADD r0, r0, r1
ST r0, r15, -28
LI r0, 0
LD r1, r15, -28
ST.B r0, r1, 0
LI r0, 64
ST r0, r15, -40
LI r0, 1
MOV r1, r0
LD r0, r15, -40
SUB r0, r0, r1
PUSH r0
SUBI r0, r15, -16
LD r0, r0, 0
CMPI r0, 0
BEQ r0, r0, Lel32
SUBI r0, r15, -16
LD r0, r0, 0
JMP Ldone33
Lel32:
LI r0, LO(LSTR34)
Ldone33:
PUSH r0
SUBI r0, r15, 8
LD r0, r0, 0
ADDI r0, r0, 20
PUSH r0
CALL strncpy
RDSP r2
ADDI r2, r2, 12
WRSP r2
SUBI r0, r15, 8
LD r0, r0, 0
ADDI r0, r0, 20
ST r0, r15, -48
LI r0, 64
ST r0, r15, -52
LI r0, 1
MOV r1, r0
LD r0, r15, -52
SUB r0, r0, r1
MOV r1, r0
LD r0, r15, -48
ADD r0, r0, r1
ST r0, r15, -44
LI r0, 0
LD r1, r15, -44
ST.B r0, r1, 0
LI r0, LO(s_head)
ST r0, r15, -56
LI r0, LO(s_head)
LD r0, r0, 0
ST r0, r15, -68
LI r0, 1
MOV r1, r0
LD r0, r15, -68
ADD r0, r0, r1
ST r0, r15, -60
LI r0, 64
ST r0, r15, -64
LD r0, r15, -64
PUSH r0
LD r0, r15, -60
PUSH r0
CALL __decko_mod
RDSP r2
ADDI r2, r2, 8
WRSP r2
LD r1, r15, -56
ST r0, r1, 0
LI r0, LO(s_count)
LD r0, r0, 0
ST r0, r15, -72
LI r0, 64
MOV r1, r0
LD r0, r15, -72
CMP r0, r1
BGE r0, r0, Lifend35
LI r0, LO(s_count)
ST r0, r15, -76
LD r0, r15, -76
LD r0, r0, 0
ST r0, r15, -80
ADDI r1, r0, 1
LD r2, r15, -76
ST r1, r2, 0
LD r0, r15, -80
Lifend35:
LI r0, LO(s_total)
ST r0, r15, -84
LD r0, r15, -84
LD r0, r0, 0
ST r0, r15, -88
ADDI r1, r0, 1
LD r2, r15, -84
ST r1, r2, 0
LD r0, r15, -88
SUBI r0, r15, 4
LD r0, r0, 0
PUSH r0
CALL syslog_unlock
RDSP r2
ADDI r2, r2, 4
WRSP r2
CALL bt_log_is_enabled
CMPI r0, 0
BEQ r0, r0, Lifend36
CALL get_absolute_time
PUSH r0
CALL to_ms_since_boot
RDSP r2
ADDI r2, r2, 4
WRSP r2
PUSH r0
SUBI r0, r15, -16
LD r0, r0, 0
PUSH r0
SUBI r0, r15, -12
LD r0, r0, 0
PUSH r0
SUBI r0, r15, -8
LD r0, r0, 0
PUSH r0
CALL level_str
RDSP r2
ADDI r2, r2, 4
WRSP r2
PUSH r0
CALL bt_log_mirror
RDSP r2
ADDI r2, r2, 16
WRSP r2
Lifend36:
MOV r2, r15
WRSP r2
POP r15
RET

; ---- function syslog_dump
syslog_dump:
PUSH r15
RDSP r2
MOV r15, r2
RDSP r2
SUBI r2, r2, 10864
WRSP r2
CALL syslog_lock
ST r0, r15, -4
LI r0, LO(s_count)
LD r0, r0, 0
ST r0, r15, -8
LI r0, 0
MOV r1, r0
LD r0, r15, -8
CMP r0, r1
BNE r0, r0, Lifend37
SUBI r0, r15, 4
LD r0, r0, 0
PUSH r0
CALL syslog_unlock
RDSP r2
ADDI r2, r2, 4
WRSP r2
LI r0, LO(LSTR38)
PUSH r0
CALL printf
RDSP r2
ADDI r2, r2, 4
WRSP r2
MOV r2, r15
WRSP r2
POP r15
RET
Lifend37:
SUBI r0, r15, -12
LD r0, r0, 0
ST r0, r15, -16
LI r0, 0
MOV r1, r0
LD r0, r15, -16
CMP r1, r0
BGE r0, r0, Lel39
SUBI r0, r15, -12
LD r0, r0, 0
ST r0, r15, -20
LI r0, LO(s_count)
LD r0, r0, 0
MOV r1, r0
LD r0, r15, -20
CMP r0, r1
BGE r0, r0, Lel39
SUBI r0, r15, -12
LD r0, r0, 0
JMP Ldone40
Lel39:
LI r0, LO(s_count)
LD r0, r0, 0
Ldone40:
ST r0, r15, -12
LI r0, LO(s_head)
LD r0, r0, 0
ST r0, r15, -40
SUBI r0, r15, 12
LD r0, r0, 0
MOV r1, r0
LD r0, r15, -40
SUB r0, r0, r1
ST r0, r15, -36
LI r0, 64
ST r0, r15, -44
LI r0, 2
MOV r1, r0
LD r0, r15, -44
MUL r0, r0, r1
MOV r1, r0
LD r0, r15, -36
ADD r0, r0, r1
ST r0, r15, -28
LI r0, 64
ST r0, r15, -32
LD r0, r15, -32
PUSH r0
LD r0, r15, -28
PUSH r0
CALL __decko_mod
RDSP r2
ADDI r2, r2, 8
WRSP r2
ST r0, r15, -24
LI r0, 0
ST r0, r15, -10752
Lfor41:
SUBI r0, r15, 10752
LD r0, r0, 0
ST r0, r15, -10756
SUBI r0, r15, 12
LD r0, r0, 0
MOV r1, r0
LD r0, r15, -10756
CMP r0, r1
BGE r0, r0, Lfend42
SUBI r0, r15, 5376
ST r0, r15, -10768
SUBI r0, r15, 10752
LD r0, r0, 0
MOV r1, r0
MULI r1, r1, 84
LD r0, r15, -10768
ADD r0, r0, r1
ST r0, r15, -10760
LI r0, LO(s_ring)
ST r0, r15, -10772
SUBI r0, r15, 24
LD r0, r0, 0
ST r0, r15, -10784
SUBI r0, r15, 10752
LD r0, r0, 0
MOV r1, r0
LD r0, r15, -10784
ADD r0, r0, r1
ST r0, r15, -10776
LI r0, 64
ST r0, r15, -10780
LD r0, r15, -10780
PUSH r0
LD r0, r15, -10776
PUSH r0
CALL __decko_mod
RDSP r2
ADDI r2, r2, 8
WRSP r2
MOV r1, r0
MULI r1, r1, 84
LD r0, r15, -10772
ADD r0, r0, r1
ST r0, r15, -10764
LD r1, r15, -10760
LD r2, r15, -10764
LD r0, r2, 0
ST r0, r1, 0
LD r0, r2, 4
ST r0, r1, 4
LD r0, r2, 8
ST r0, r1, 8
LD r0, r2, 12
ST r0, r1, 12
LD r0, r2, 16
ST r0, r1, 16
LD r0, r2, 20
ST r0, r1, 20
LD r0, r2, 24
ST r0, r1, 24
LD r0, r2, 28
ST r0, r1, 28
LD r0, r2, 32
ST r0, r1, 32
LD r0, r2, 36
ST r0, r1, 36
LD r0, r2, 40
ST r0, r1, 40
LD r0, r2, 44
ST r0, r1, 44
LD r0, r2, 48
ST r0, r1, 48
LD r0, r2, 52
ST r0, r1, 52
LD r0, r2, 56
ST r0, r1, 56
LD r0, r2, 60
ST r0, r1, 60
LD r0, r2, 64
ST r0, r1, 64
LD r0, r2, 68
ST r0, r1, 68
LD r0, r2, 72
ST r0, r1, 72
LD r0, r2, 76
ST r0, r1, 76
LD r0, r2, 80
ST r0, r1, 80
LI r0, 0
Lfstep43:
SUBI r0, r15, 10752
ST r0, r15, -10788
LD r0, r15, -10788
LD r0, r0, 0
ST r0, r15, -10792
ADDI r1, r0, 1
LD r2, r15, -10788
ST r1, r2, 0
LD r0, r15, -10792
JMP Lfor41
Lfend42:
SUBI r0, r15, 4
LD r0, r0, 0
PUSH r0
CALL syslog_unlock
RDSP r2
ADDI r2, r2, 4
WRSP r2
LI r0, 0
ST r0, r15, -10796
LI r0, 0
ST r0, r15, -10800
Lfor44:
SUBI r0, r15, 10800
LD r0, r0, 0
ST r0, r15, -10804
SUBI r0, r15, 12
LD r0, r0, 0
MOV r1, r0
LD r0, r15, -10804
CMP r0, r1
BGE r0, r0, Lfend45
SUBI r0, r15, 5376
ST r0, r15, -10812
SUBI r0, r15, 10800
LD r0, r0, 0
MOV r1, r0
MULI r1, r1, 84
LD r0, r15, -10812
ADD r0, r0, r1
ST r0, r15, -10808
SUBI r0, r15, 10808
LD r0, r0, 0
ADDI r0, r0, 4
LD r0, r0, 0
ST r0, r15, -10816
SUBI r0, r15, -8
LD r0, r0, 0
MOV r1, r0
LD r0, r15, -10816
CMP r0, r1
BGE r0, r0, Lifend47
JMP Lfstep46
Lifend47:
SUBI r0, r15, 10808
LD r0, r0, 0
ADDI r0, r0, 0
LD r0, r0, 0
ST r0, r15, -10824
LI r0, 1000
ST r0, r15, -10828
LD r0, r15, -10828
PUSH r0
LD r0, r15, -10824
PUSH r0
CALL __decko_udiv
RDSP r2
ADDI r2, r2, 8
WRSP r2
ST r0, r15, -10820
SUBI r0, r15, 10808
LD r0, r0, 0
ADDI r0, r0, 0
LD r0, r0, 0
ST r0, r15, -10836
LI r0, 1000
ST r0, r15, -10840
LD r0, r15, -10840
PUSH r0
LD r0, r15, -10836
PUSH r0
CALL __decko_umod
RDSP r2
ADDI r2, r2, 8
WRSP r2
ST r0, r15, -10832
SUBI r0, r15, 10808
LD r0, r0, 0
ADDI r0, r0, 20
PUSH r0
SUBI r0, r15, 10808
LD r0, r0, 0
ADDI r0, r0, 8
PUSH r0
SUBI r0, r15, 10808
LD r0, r0, 0
ADDI r0, r0, 4
LD r0, r0, 0
PUSH r0
CALL level_str
RDSP r2
ADDI r2, r2, 4
WRSP r2
PUSH r0
SUBI r0, r15, 10832
LD r0, r0, 0
PUSH r0
SUBI r0, r15, 10820
LD r0, r0, 0
PUSH r0
SUBI r0, r15, 10808
LD r0, r0, 0
ADDI r0, r0, 4
LD r0, r0, 0
PUSH r0
CALL level_color
RDSP r2
ADDI r2, r2, 4
WRSP r2
PUSH r0
LI r0, LO(LSTR48)
PUSH r0
CALL printf
RDSP r2
ADDI r2, r2, 28
WRSP r2
SUBI r0, r15, 10796
ST r0, r15, -10844
LD r0, r15, -10844
LD r0, r0, 0
ST r0, r15, -10848
ADDI r1, r0, 1
LD r2, r15, -10844
ST r1, r2, 0
LD r0, r15, -10848
Lfstep46:
SUBI r0, r15, 10800
ST r0, r15, -10852
LD r0, r15, -10852
LD r0, r0, 0
ST r0, r15, -10856
ADDI r1, r0, 1
LD r2, r15, -10852
ST r1, r2, 0
LD r0, r15, -10856
JMP Lfor44
Lfend45:
SUBI r0, r15, 10796
LD r0, r0, 0
ST r0, r15, -10860
LI r0, 0
MOV r1, r0
LD r0, r15, -10860
CMP r0, r1
BNE r0, r0, Lifend49
LI r0, LO(LSTR50)
PUSH r0
CALL printf
RDSP r2
ADDI r2, r2, 4
WRSP r2
Lifend49:
MOV r2, r15
WRSP r2
POP r15
RET

; ---- function syslog_clear
syslog_clear:
PUSH r15
RDSP r2
MOV r15, r2
RDSP r2
SUBI r2, r2, 20
WRSP r2
CALL syslog_lock
ST r0, r15, -4
LI r0, LO(s_total)
LD r0, r0, 0
ST r0, r15, -8
LI r0, 5376
PUSH r0
LI r0, 0
PUSH r0
LI r0, LO(s_ring)
PUSH r0
CALL memset
RDSP r2
ADDI r2, r2, 12
WRSP r2
LI r0, LO(s_head)
ST r0, r15, -12
LI r0, 0
LD r1, r15, -12
ST r0, r1, 0
LI r0, LO(s_count)
ST r0, r15, -16
LI r0, 0
LD r1, r15, -16
ST r0, r1, 0
SUBI r0, r15, 4
LD r0, r0, 0
PUSH r0
CALL syslog_unlock
RDSP r2
ADDI r2, r2, 4
WRSP r2
SUBI r0, r15, 8
LD r0, r0, 0
PUSH r0
LI r0, LO(LSTR51)
PUSH r0
CALL printf
RDSP r2
ADDI r2, r2, 8
WRSP r2
MOV r2, r15
WRSP r2
POP r15
RET

; ---- function syslog_total
syslog_total:
PUSH r15
RDSP r2
MOV r15, r2
RDSP r2
SUBI r2, r2, 4
WRSP r2
LI r0, LO(s_total)
LD r0, r0, 0
MOV r2, r15
WRSP r2
POP r15
RET
MOV r2, r15
WRSP r2
POP r15
RET

; ---- data ----
s_ring:
.byte 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
.byte 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
.byte 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
.byte 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
.byte 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
.byte 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
.byte 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
.byte 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
.byte 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
.byte 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
.byte 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
.byte 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
.byte 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
.byte 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
.byte 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
.byte 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
.byte 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
.byte 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
.byte 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
.byte 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
.byte 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
.byte 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
.byte 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
.byte 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
.byte 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
.byte 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
.byte 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
.byte 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
.byte 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
.byte 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
.byte 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
.byte 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
.byte 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
.byte 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
.byte 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
.byte 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
.byte 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
.byte 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
.byte 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
.byte 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
.byte 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
.byte 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
.byte 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
.byte 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
.byte 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
.byte 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
.byte 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
.byte 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
.byte 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
.byte 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
.byte 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
.byte 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
.byte 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
.byte 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
.byte 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
.byte 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
.byte 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
.byte 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
.byte 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
.byte 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
.byte 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
.byte 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
.byte 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
.byte 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
.byte 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
.byte 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
.byte 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
.byte 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
.byte 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
.byte 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
.byte 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
.byte 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
.byte 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
.byte 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
.byte 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
.byte 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
.byte 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
.byte 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
.byte 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
.byte 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
.byte 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
.byte 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
.byte 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
.byte 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
.byte 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
.byte 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
.byte 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
.byte 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
.byte 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
.byte 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
.byte 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
.byte 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
.byte 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
.byte 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
.byte 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
.byte 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
.byte 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
.byte 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
.byte 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
.byte 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
.byte 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
.byte 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
.byte 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
.byte 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
.byte 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
.byte 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
.byte 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
.byte 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
.byte 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
.byte 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
.byte 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
.byte 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
.byte 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
.byte 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
.byte 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
.byte 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
.byte 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
.byte 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
.byte 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
.byte 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
.byte 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
.byte 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
.byte 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
.byte 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
.byte 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
.byte 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
.byte 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
.byte 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
.byte 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
.byte 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
.byte 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
.byte 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
.byte 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
.byte 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
.byte 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
.byte 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
.byte 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
.byte 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
.byte 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
.byte 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
.byte 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
.byte 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
.byte 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
.byte 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
.byte 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
.byte 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
.byte 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
.byte 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
.byte 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
.byte 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
.byte 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
.byte 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
.byte 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
.byte 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
.byte 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
.byte 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
.byte 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
.byte 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
.byte 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
.byte 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
.byte 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
.byte 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
.byte 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
.byte 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
.byte 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
.byte 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
.byte 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
.byte 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
.byte 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
.byte 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
.byte 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
.byte 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
.byte 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
.byte 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
.byte 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
.byte 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
.byte 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
.byte 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
.byte 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
.byte 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
.byte 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
.byte 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
.byte 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
.byte 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
.byte 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
.byte 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
.byte 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
.byte 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
.byte 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
.byte 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
.byte 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
.byte 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
.byte 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
.byte 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
.byte 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
.byte 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
.byte 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
.byte 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
.byte 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
.byte 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
.byte 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
.byte 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
.byte 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
.byte 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
.byte 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
.byte 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
.byte 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
.byte 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
.byte 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
.byte 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
.byte 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
.byte 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
.byte 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
.byte 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
.byte 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
.byte 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
.byte 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
.byte 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
.byte 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
.byte 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
.byte 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
.byte 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
.byte 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
.byte 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
.byte 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
.byte 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
.byte 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
.byte 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
.byte 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
.byte 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
.byte 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
.byte 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
.byte 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
.byte 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
.byte 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
.byte 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
.byte 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
.byte 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
.byte 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
.byte 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
.byte 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
.byte 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
.byte 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
.byte 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
.byte 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
.byte 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
.byte 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
.byte 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
.byte 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
.byte 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
.byte 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
.byte 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
.byte 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
.byte 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
.byte 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
.byte 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
.byte 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
.byte 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
.byte 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
.byte 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
.byte 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
.byte 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
.byte 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
.byte 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
.byte 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
.byte 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
.byte 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
.byte 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
.byte 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
.byte 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
.byte 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
.byte 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
.byte 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
.byte 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
.byte 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
.byte 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
.byte 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
.byte 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
.byte 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
.byte 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
.byte 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
.byte 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
.byte 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
.byte 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
.byte 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
.byte 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
.byte 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
.byte 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
.byte 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
.byte 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
.byte 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
.byte 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
.byte 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
.byte 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
.byte 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
.byte 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
.byte 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
.byte 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
.byte 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
.byte 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
.byte 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
.byte 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
.byte 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
.byte 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
.byte 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
.byte 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
.byte 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
.byte 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
.byte 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
.byte 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
.byte 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
.byte 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
.byte 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
.byte 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
.byte 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
.byte 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
.byte 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
.byte 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
.byte 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
.byte 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
.byte 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
.byte 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
.byte 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
.byte 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
.byte 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
.byte 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
.byte 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
.byte 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
.byte 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
.byte 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
.byte 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
.byte 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
.byte 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
.byte 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
.byte 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
.byte 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
s_head:
.word 0
s_count:
.word 0
s_total:
.word 0
LSTR1:
.byte 98, 111, 111, 116, 32, 99, 111, 109, 112, 108, 101, 116, 101, 0
.byte 0, 0
LSTR2:
.byte 100, 101, 99, 107, 99, 0
.byte 0, 0
LSTR3:
.byte 98, 114, 111, 119, 110, 111, 117, 116, 32, 100, 101, 116, 101, 99, 116, 101
.byte 100, 0
.byte 0, 0
LSTR4:
.byte 97, 108, 108, 111, 99, 97, 116, 105, 111, 110, 32, 102, 97, 105, 108, 101
.byte 100, 0
.byte 0, 0
LSTR5:
.byte 115, 99, 97, 110, 32, 115, 116, 97, 114, 116, 101, 100, 0
.byte 0, 0, 0
LSTR12:
.byte 68, 66, 71, 0
LSTR13:
.byte 73, 78, 70, 0
LSTR14:
.byte 87, 82, 78, 0
LSTR15:
.byte 69, 82, 82, 0
LSTR16:
.byte 63, 63, 63, 0
LSTR23:
.byte 27, 91, 57, 48, 109, 0
.byte 0, 0
LSTR24:
.byte 27, 91, 48, 109, 0
.byte 0, 0, 0
LSTR25:
.byte 27, 91, 51, 51, 109, 0
.byte 0, 0
LSTR26:
.byte 27, 91, 51, 49, 109, 0
.byte 0, 0
LSTR27:
.byte 114, 105, 110, 103, 32, 108, 111, 103, 32, 114, 101, 97, 100, 121, 32, 40
.byte 37, 100, 32, 115, 108, 111, 116, 115, 41, 0
.byte 0, 0
LSTR28:
.byte 115, 121, 115, 108, 111, 103, 0
.byte 0
LSTR31:
.byte 63, 0
.byte 0, 0
LSTR34:
.byte 0
.byte 0, 0, 0
LSTR38:
.byte 40, 108, 111, 103, 32, 101, 109, 112, 116, 121, 41, 10, 0
.byte 0, 0, 0
LSTR48:
.byte 37, 115, 91, 37, 52, 108, 117, 46, 37, 48, 51, 108, 117, 93, 32, 91
.byte 37, 115, 93, 32, 91, 37, 45, 49, 48, 115, 93, 32, 37, 115, 27, 91
.byte 48, 109, 10, 0
LSTR50:
.byte 40, 110, 111, 32, 101, 110, 116, 114, 105, 101, 115, 32, 97, 116, 32, 116
.byte 104, 105, 115, 32, 108, 101, 118, 101, 108, 41, 10, 0
LSTR51:
.byte 115, 121, 115, 108, 111, 103, 32, 99, 108, 101, 97, 114, 101, 100, 32, 32
.byte 40, 37, 108, 117, 32, 116, 111, 116, 97, 108, 32, 101, 110, 116, 114, 105
.byte 101, 115, 32, 100, 105, 115, 99, 97, 114, 100, 101, 100, 41, 10, 0
.byte 0

