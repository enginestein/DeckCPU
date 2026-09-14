; irq_tb golden program — verifies against sim/programs/irq_tb_prog.hex
;
; IVT slots 0..5; main arms FLAGS.I (DI/EI window used by irq_tb's gating
; test) then spins; handlers H1..H5 store their slot id at [0x1000 + 4*(k-1)]
; and IRET, so the testbench can tell which slot ran and that the entry frame
; was restored.
        JMP     main            ; 0x00 slot0 reset entry
        JMP     h1              ; 0x04 slot1 TIMER
        JMP     h2              ; 0x08 slot2 UART_RX
        JMP     h3              ; 0x0C slot3 UART_TX
        JMP     h4              ; 0x10 slot4 GPIO
        JMP     h5              ; 0x14 slot5 SPI
main:
        LI      r1, 0x1000      ; 0x18
        DI                      ; 0x1C
        EI                      ; 0x20
        JMP     .               ; 0x24 spin (self-loop)
h1:
        LI      r2, 0x01        ; 0x28
        ST      r2, r1, 0x00    ; 0x2C
        IRET                    ; 0x30
h2:
        LI      r2, 0x02        ; 0x34
        ST      r2, r1, 0x04    ; 0x38
        IRET                    ; 0x3C
h3:
        LI      r2, 0x03        ; 0x40
        ST      r2, r1, 0x08    ; 0x44
        IRET                    ; 0x48
h4:
        LI      r2, 0x04        ; 0x4C
        ST      r2, r1, 0x0C    ; 0x50
        IRET                    ; 0x54
h5:
        LI      r2, 0x05        ; 0x58
        ST      r2, r1, 0x10    ; 0x5C
        IRET                    ; 0x60