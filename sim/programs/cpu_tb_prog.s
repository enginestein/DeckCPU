; cpu_tb golden program — verifies against sim/programs/cpu_tb_prog.hex
;
; Exercises the whole integer ALU (ADD..MUL), load/store with offsets,
; immediate, compare, branch (skip over the never-executed path), call/ret,
; push/pop, SP/FLAGS access and IRET. The .org at byte 0x80 leaves the two
; NOP holes at 0x78/0x7C that the golden word-load image fills.
start:
        LI      r1, 0x05
        LI      r2, 0x07
        ADD     r3, r1, r2
        SUB     r4, r1, r2
        CMP     r1, r2
        AND     r5, r1, r2
        OR      r6, r1, r2
        XOR     r7, r1, r2
        NOT     r8, r1
        MUL     r9, r1, r2
        LI      r10, 0x1000
        ST      r3, r10, 0x04
        LD      r11, r10, 0x04
        ADDI    r12, r1, 0x0A
        CMP     r1, r1
        BEQ     r0, r0, mov_r14
        LI      r13, 0x64
        LI      r14, 0xC8
mov_r14:
        MOV     r14, r3
        CALL    sub
        LI      r13, 0x07
        PUSH    r1
        POP     r15
        LI      r4, 0x2000
        LI      r5, 0x2A
        ST      r5, r4, 0x00
        LI      r6, 0x80
        ST      r6, r4, 0x04
        WRSP    r4
        IRET
        .org    0x80
        LI      r7, 0x4D
        HALT
sub:
        LI      r13, 0x2A
        RET