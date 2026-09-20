; cpu_fsm golden program verifies against sim/programs/cpu_fsm_prog.hex
;
; Source-level view of tools/gen_programs.py cpu_fsm_prog. The byte
; image in sim/programs is the executed byte image; this file exists so the
; assembler tests can prove the assembler reproduces it.
        NOP
        EI
        DI
        ADDI    r1, r0, 0x08
        SUB     r2, r1, r0
        JMP     0x1C
        LI      r3, 0x63
        CMP     r1, r1
        BEQ     r0, r0, 0x28
        LI      r3, 0x63
        BNE     r0, r0, 0x30
        LI      r3, 0x64
        PUSH    r1
        POP     r4
        HALT