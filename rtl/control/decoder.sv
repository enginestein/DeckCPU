// DeckCPU instruction decoder (combinational).
//
// Maps a raw instruction word onto a decoded_instr_t control word.
// Field extraction follows the R/I/B formats from isa/isa.json; the control
// bits encode everything the datapath/FSM needs for this opcode.
//
// Reserved fields (funct, spare) are ignored by the decoder; the assembler is
// responsible for canonical (zero) encodings.

module decoder import deckcpu_pkg::*; (
    input  logic [31:0] instr,
    output decoded_instr_t d,
    output logic sel_add, sel_sub, sel_mul,
    output logic sel_and, sel_or, sel_xor, sel_not,
    output logic sel_shl, sel_shr,
    output logic sel_a, sel_b
);
    always_comb begin
        // zero-control default (NOP-like)
        d = '0;
        d.op = instr[OP_MSB:OP_LSB];

        // ---- operand field extraction by format ----
        unique case (d.op)
            // R format: rd | rs1 | rs2
            OP_ADD, OP_SUB, OP_MUL, OP_AND, OP_OR, OP_XOR, OP_NOT,
            OP_SHL, OP_SHR, OP_CMP, OP_MOV, OP_JMPR, OP_PUSH, OP_POP,
            OP_RDSP, OP_WRSP, OP_RDFLAG, OP_WRFLAG:
                begin
                    d.rd  = instr[RD_MSB:RD_LSB];
                    d.rs1 = instr[R_B_MSB:R_B_LSB];
                    d.rs2 = instr[RS2_MSB:RS2_LSB];
                end

            // I format: rd | rs1 | imm16
            OP_ADDI, OP_SUBI, OP_MULI, OP_ANDI, OP_ORI, OP_XORI,
            OP_SHLI, OP_SHRI, OP_CMPI, OP_LI, OP_LIH,
            OP_LD, OP_LDH, OP_LDB, OP_ST, OP_STH, OP_STB:
                begin
                    d.rd  = instr[RD_MSB:RD_LSB];
                    d.rs1 = instr[R_B_MSB:R_B_LSB];
                    d.imm = instr[IMM_MSB:IMM_LSB];
                end

            // B format: rs1 | rs2 | off16
            OP_JMP, OP_CALL, OP_RET, OP_IRET,
            OP_BEQ, OP_BNE, OP_BLT, OP_BGE, OP_BLTU, OP_BGEU:
                begin
                    d.rs1 = instr[RD_MSB:RD_LSB];
                    d.rs2 = instr[R_B_MSB:R_B_LSB];
                    d.imm = instr[IMM_MSB:IMM_LSB];
                end

            default: ;
        endcase

        // ---- control bits per opcode ----
        unique case (d.op)
            OP_NOP: ;

            OP_ADD: begin d.alu_op=ALU_ADD; d.reg_we=1'b1; d.wb_src=WB_ALU; d.flags_we=1'b1; end
            OP_SUB: begin d.alu_op=ALU_SUB; d.reg_we=1'b1; d.wb_src=WB_ALU; d.flags_we=1'b1; end
            OP_MUL: begin d.alu_op=ALU_MUL; d.reg_we=1'b1; d.wb_src=WB_ALU; d.flags_we=1'b1; end
            OP_AND: begin d.alu_op=ALU_AND; d.reg_we=1'b1; d.wb_src=WB_ALU; d.flags_we=1'b1; end
            OP_OR:  begin d.alu_op=ALU_OR;  d.reg_we=1'b1; d.wb_src=WB_ALU; d.flags_we=1'b1; end
            OP_XOR: begin d.alu_op=ALU_XOR; d.reg_we=1'b1; d.wb_src=WB_ALU; d.flags_we=1'b1; end
            OP_NOT: begin d.alu_op=ALU_NOT; d.reg_we=1'b1; d.wb_src=WB_ALU; d.flags_we=1'b1; end
            OP_SHL: begin d.alu_op=ALU_SHL; d.reg_we=1'b1; d.wb_src=WB_ALU; d.flags_we=1'b1; end
            OP_SHR: begin d.alu_op=ALU_SHR; d.reg_we=1'b1; d.wb_src=WB_ALU; d.flags_we=1'b1; end
            OP_CMP: begin d.alu_op=ALU_SUB; d.flags_we=1'b1; end     // reg_we=0

            OP_ADDI: begin d.alu_op=ALU_ADD; d.alu_b_imm=1'b1; d.reg_we=1'b1; d.wb_src=WB_ALU; d.flags_we=1'b1; end
            OP_SUBI: begin d.alu_op=ALU_SUB; d.alu_b_imm=1'b1; d.reg_we=1'b1; d.wb_src=WB_ALU; d.flags_we=1'b1; end
            OP_MULI: begin d.alu_op=ALU_MUL; d.alu_b_imm=1'b1; d.reg_we=1'b1; d.wb_src=WB_ALU; d.flags_we=1'b1; end
            OP_ANDI: begin d.alu_op=ALU_AND; d.alu_b_imm=1'b1; d.reg_we=1'b1; d.wb_src=WB_ALU; d.flags_we=1'b1; end
            OP_ORI:  begin d.alu_op=ALU_OR;  d.alu_b_imm=1'b1; d.reg_we=1'b1; d.wb_src=WB_ALU; d.flags_we=1'b1; end
            OP_XORI: begin d.alu_op=ALU_XOR; d.alu_b_imm=1'b1; d.reg_we=1'b1; d.wb_src=WB_ALU; d.flags_we=1'b1; end
            OP_SHLI: begin d.alu_op=ALU_SHL; d.alu_b_imm=1'b1; d.reg_we=1'b1; d.wb_src=WB_ALU; d.flags_we=1'b1; end
            OP_SHRI: begin d.alu_op=ALU_SHR; d.alu_b_imm=1'b1; d.reg_we=1'b1; d.wb_src=WB_ALU; d.flags_we=1'b1; end
            OP_CMPI: begin d.alu_op=ALU_SUB; d.alu_b_imm=1'b1; d.flags_we=1'b1; end

            OP_LI:   begin d.alu_op=ALU_B; d.alu_b_imm=1'b1; d.alu_b_imm_zext=1'b1; d.reg_we=1'b1; d.wb_src=WB_ALU; end
            OP_LIH:  begin d.alu_op=ALU_B; d.alu_b_imm=1'b1; d.alu_b_imm_high=1'b1; d.reg_we=1'b1; d.wb_src=WB_ALU; end
            OP_MOV:  begin d.alu_op=ALU_A; d.reg_we=1'b1; d.wb_src=WB_ALU; end

            OP_LD:   begin d.alu_op=ALU_ADD; d.alu_b_imm=1'b1; d.reg_we=1'b1; d.wb_src=WB_MEM; d.mem_re=1'b1; d.mem_sz=SZ_WORD; end
            OP_LDH:  begin d.alu_op=ALU_ADD; d.alu_b_imm=1'b1; d.reg_we=1'b1; d.wb_src=WB_MEM; d.mem_re=1'b1; d.mem_sz=SZ_HALF; end
            OP_LDB:  begin d.alu_op=ALU_ADD; d.alu_b_imm=1'b1; d.reg_we=1'b1; d.wb_src=WB_MEM; d.mem_re=1'b1; d.mem_sz=SZ_BYTE; end
            OP_ST:   begin d.alu_op=ALU_ADD; d.alu_b_imm=1'b1; d.mem_we=1'b1; d.mem_sz=SZ_WORD; end
            OP_STH:  begin d.alu_op=ALU_ADD; d.alu_b_imm=1'b1; d.mem_we=1'b1; d.mem_sz=SZ_HALF; end
            OP_STB:  begin d.alu_op=ALU_ADD; d.alu_b_imm=1'b1; d.mem_we=1'b1; d.mem_sz=SZ_BYTE; end

            OP_JMP:  begin d.branch=1'b1; d.jmp=1'b1; d.alu_op=ALU_ADD; d.alu_a_pc=1'b1; d.alu_b_imm=1'b1; end
            OP_CALL: begin d.branch=1'b1; d.jmp=1'b1; d.call=1'b1; d.use_ret_addr=1'b1;
                              d.alu_op=ALU_ADD; d.alu_a_pc=1'b1; d.alu_b_imm=1'b1;
                              d.mem_we=1'b1; d.mem_sz=SZ_WORD; d.stack_op=1'b1; d.stack_pop=1'b0; end
            OP_RET:  begin d.branch=1'b1; d.ret=1'b1; d.stack_op=1'b1; d.stack_pop=1'b1;
                              d.mem_re=1'b1; d.mem_sz=SZ_WORD; d.alu_op=ALU_ADD; d.alu_a_sp=1'b1; d.alu_b_four=1'b1; end
            OP_JMPR: begin d.branch=1'b1; d.jmp=1'b1; d.alu_op=ALU_A; end

            OP_BEQ:  begin d.branch=1'b1; d.alu_op=ALU_SUB; d.cond=BC_EQ; end
            OP_BNE:  begin d.branch=1'b1; d.alu_op=ALU_SUB; d.cond=BC_NE; end
            OP_BLT:  begin d.branch=1'b1; d.alu_op=ALU_SUB; d.cond=BC_LT; end
            OP_BGE:  begin d.branch=1'b1; d.alu_op=ALU_SUB; d.cond=BC_GE; end
            OP_BLTU: begin d.branch=1'b1; d.alu_op=ALU_SUB; d.cond=BC_LTU; end
            OP_BGEU: begin d.branch=1'b1; d.alu_op=ALU_SUB; d.cond=BC_GEU; end

            OP_PUSH: begin d.stack_op=1'b1; d.stack_pop=1'b0; d.alu_op=ALU_SUB; d.alu_a_sp=1'b1; d.alu_b_four=1'b1;
                              d.mem_we=1'b1; d.mem_sz=SZ_WORD; end
            OP_POP:  begin d.stack_op=1'b1; d.stack_pop=1'b1; d.alu_op=ALU_ADD; d.alu_a_sp=1'b1; d.alu_b_four=1'b1;
                              d.reg_we=1'b1; d.wb_src=WB_MEM; d.mem_re=1'b1; d.mem_sz=SZ_WORD; end

            OP_RDSP:  begin d.alu_op=ALU_A; d.alu_a_sp=1'b1; d.reg_we=1'b1; d.wb_src=WB_ALU; end
            OP_WRSP:  begin d.alu_op=ALU_A; d.wr_sp=1'b1; end
            OP_RDFLAG:begin d.alu_op=ALU_A; d.alu_a_flags=1'b1; d.reg_we=1'b1; d.wb_src=WB_ALU; end
            OP_WRFLAG:begin d.alu_op=ALU_A; d.wr_flags=1'b1; end

            OP_EI:   begin d.irq_ctl=1'b1; d.irq_set=1'b1; end
            OP_DI:   begin d.irq_ctl=1'b1; d.irq_set=1'b0; end
            OP_IRET: begin d.branch=1'b1; d.iret=1'b1; d.stack_op=1'b1; d.stack_pop=1'b1;
                              d.mem_re=1'b1; d.mem_sz=SZ_WORD; d.alu_op=ALU_ADD; d.alu_a_sp=1'b1; d.alu_b_four=1'b1; end

            OP_HALT: begin d.halt=1'b1; end
            default: ;
        endcase
    end

    // one-hot ALU function selects. These LEAVE this module as single-bit
    // scalars (netlist paths) because Icarus 11 delta-storms when a
    // procedural always_comb in the ALU re-evaluates on the multi-bit
    // enum/d.alu_op churn across module boundaries. The alu itself is a
    // continuous-assignment netlist.
    always_comb begin
        sel_add = 1'b0; sel_sub = 1'b0; sel_mul = 1'b0;
        sel_and = 1'b0; sel_or = 1'b0; sel_xor = 1'b0; sel_not = 1'b0;
        sel_shl = 1'b0; sel_shr = 1'b0; sel_a = 1'b0; sel_b = 1'b0;
        case (d.alu_op)
            ALU_ADD: sel_add = 1'b1;
            ALU_SUB: sel_sub = 1'b1;
            ALU_MUL: sel_mul = 1'b1;
            ALU_AND: sel_and = 1'b1;
            ALU_OR:  sel_or  = 1'b1;
            ALU_XOR: sel_xor = 1'b1;
            ALU_NOT: sel_not = 1'b1;
            ALU_SHL: sel_shl = 1'b1;
            ALU_SHR: sel_shr = 1'b1;
            ALU_A:   sel_a   = 1'b1;
            ALU_B:   sel_b   = 1'b1;
            default: ;
        endcase
    end

endmodule : decoder