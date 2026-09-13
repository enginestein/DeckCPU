// DeckCPU common constants and types.
// Phase 1: package only; mirrors isa/isa.json.
// Keep the opcode enum byte values in lock-step with isa/isa.json.
package deckcpu_pkg;

  // ---- Machine model -----------------------------------------------------
  localparam int W              = 32;       // word width
  localparam int NREG           = 16;       // general-purpose registers
  localparam int REGIDX_W       = 4;        // register index width
  localparam int OPCODE_W       = 8;        // opcode width

  // ---- Format field positions (per isa.json "formats") --------------------
  // R:  op[31:24] rd[23:20] rs1[19:16] rs2[15:12] funct[11:8] spare[7:0]
  // I:  op[31:24] rd[23:20] rs1[19:16] imm16[15:0]
  // B:  op[31:24] rs1[23:20] rs2[19:16] off16[15:0]
  localparam int OP_MSB  = 31;
  localparam int OP_LSB  = 24;
  localparam int RD_MSB  = 23;
  localparam int RD_LSB  = 20;
  localparam int R_A_MSB = 23;              // "A" operand slot (rd for R/I, rs1 for B)
  localparam int R_A_LSB = 20;
  localparam int R_B_MSB = 19;              // "B" operand slot (rs1 for R/I, rs2 for B)
  localparam int R_B_LSB = 16;
  localparam int RS2_MSB = 15;
  localparam int RS2_LSB = 12;
  localparam int IMM_MSB = 15;
  localparam int IMM_LSB = 0;

  // ---- Opcodes (byte values MUST match isa.json) --------------------------
  typedef enum logic [OPCODE_W-1:0] {
    OP_NOP     = 8'h00,
    // ALU R-type
    OP_ADD     = 8'h01,
    OP_SUB     = 8'h02,
    OP_MUL     = 8'h03,
    OP_AND     = 8'h04,
    OP_OR      = 8'h05,
    OP_XOR     = 8'h06,
    OP_NOT     = 8'h07,
    OP_SHL     = 8'h08,
    OP_SHR     = 8'h09,
    OP_CMP     = 8'h0A,
    // ALU I-type
    OP_ADDI    = 8'h11,
    OP_SUBI    = 8'h12,
    OP_MULI    = 8'h13,
    OP_ANDI    = 8'h14,
    OP_ORI     = 8'h15,
    OP_XORI    = 8'h16,
    OP_SHLI    = 8'h17,
    OP_SHRI    = 8'h18,
    OP_CMPI    = 8'h19,
    // Immediate / move
    OP_LI      = 8'h20,
    OP_LIH     = 8'h21,
    OP_MOV     = 8'h22,
    // Memory
    OP_LD      = 8'h30,
    OP_LDH     = 8'h31,
    OP_LDB     = 8'h32,
    OP_ST      = 8'h34,
    OP_STH     = 8'h35,
    OP_STB     = 8'h36,
    // Control
    OP_JMP     = 8'h40,
    OP_CALL    = 8'h41,
    OP_RET     = 8'h42,
    OP_JMPR    = 8'h43,
    OP_BEQ     = 8'h44,
    OP_BNE     = 8'h45,
    OP_BLT     = 8'h46,
    OP_BGE     = 8'h47,
    OP_BLTU    = 8'h48,
    OP_BGEU    = 8'h49,
    // Stack
    OP_PUSH    = 8'h50,
    OP_POP     = 8'h51,
    // Architectural register moves
    OP_RDSP    = 8'h52,
    OP_WRSP    = 8'h53,
    OP_RDFLAG  = 8'h54,
    OP_WRFLAG  = 8'h55,
    // Interrupt control
    OP_EI      = 8'h56,
    OP_DI      = 8'h57,
    OP_IRET    = 8'h58,
    // Misc
    OP_HALT    = 8'h60
  } opcode_t;

  // ---- FLAGS bit positions (per isa.json "flags") -------------------------
  localparam int FLAG_I = 0;   // interrupt enable
  localparam int FLAG_Z = 1;   // zero
  localparam int FLAG_N = 2;   // negative
  localparam int FLAG_C = 3;   // carry/borrow
  localparam int FLAG_V = 4;   // signed overflow

  // ---- Reset vector --------------------------------------------------------
  localparam logic [W-1:0] RESET_PC = 32'h0000_0000;
  localparam logic [W-1:0] RESET_SP = 32'h0000_FFFC;

  // ---- Memory map (per isa.json "memory_map") ------------------------------
  localparam logic [W-1:0] RAM_BASE    = 32'h0000_0000;
  localparam logic [W-1:0] RAM_SIZE    = 32'h0001_0000;   // 64 KiB
  localparam logic [W-1:0] RAM_END     = RAM_BASE + RAM_SIZE - 1;
  localparam logic [W-1:0] UART_BASE   = 32'h4000_0000;
  localparam logic [W-1:0] TIMER_BASE  = 32'h4000_1000;
  localparam logic [W-1:0] GPIO_BASE   = 32'h4000_2000;
  localparam logic [W-1:0] SPI_BASE    = 32'h4000_3000;
  localparam int RAM_AW = 16;                             // byte-address bits

  // ---- Interrupt vector table (per isa.json "interrupts") ------------------
  localparam int IVT_SLOTS  = 8;
  localparam int IVT_BYTES  = 4;
  localparam logic [W-1:0] IVT_BASE = 32'h0000_0000;
  localparam int SPI_NUM    = 8;                          // sources handled (incl reset)

  // ---- Execution FSM states ------------------------------------------------
  typedef enum logic [2:0] {
    S_FETCH,
    S_DECODE,
    S_EXEC,
    S_MEM,
    S_WB,
    S_HALT
  } state_t;

  // ---- Datapath control types (Phase 2) -------------------------------------
  // ALU function select (drives rtl/alu/alu.sv).
  typedef enum logic [3:0] {
    ALU_ADD,
    ALU_SUB,
    ALU_MUL,
    ALU_AND,
    ALU_OR,
    ALU_XOR,
    ALU_NOT,
    ALU_SHL,
    ALU_SHR,
    ALU_A,     // pass operand a through
    ALU_B      // pass operand b through
  } alu_op_t;

  // Memory access width.
  typedef enum logic [1:0] {
    SZ_BYTE = 2'b00,
    SZ_HALF = 2'b01,
    SZ_WORD = 2'b10
  } mem_sz_t;

  // Destination of the register-file write port.
  typedef enum logic {
    WB_ALU = 1'b0,   // ALU result
    WB_MEM = 1'b1    // memory read data
  } wb_src_t;

  // Branch condition select for B-format conditionals.
  typedef enum logic [2:0] {
    BC_EQ,
    BC_NE,
    BC_LT,
    BC_GE,
    BC_LTU,
    BC_GEU
  } branch_cond_t;

  // Decoded instruction (output of rtl/control/decoder.sv). Opcode is kept
  // as a byte; its values match opcode_t but are decoded from the raw word
  // because the simulators cannot cast a variable slice to an enum.
  typedef struct packed {
    logic [7:0]  op;         // opcode (opcode_t value)
    logic [3:0]  rd;         // destination register
    logic [3:0]  rs1;        // source register 1
    logic [3:0]  rs2;        // source register 2
    logic [15:0] imm;        // raw imm16 / off16 field (I and B formats)
    // ALU operand mux selection
    alu_op_t     alu_op;     // ALU function
    logic        alu_a_sp;   // a-input := SP        (stack ops, RDSP)
    logic        alu_a_pc;   // a-input := PC        (branch/jump)
    logic        alu_a_flags;// a-input := FLAGS     (RDFLAG)
    logic        alu_b_imm;  // b-input := immediate
    logic        alu_b_imm_high; // b := {imm, 16'b0} (LIH)
    logic        alu_b_imm_zext; // immediate zero-extended (LI) else sign-extended
    logic        alu_b_four; // b-input := 32'd4     (PUSH/POP adjust)
    // register-file writeback
    logic        reg_we;     // write the GPR write port
    wb_src_t     wb_src;     // GPR write-back source
    logic        wr_sp;      // write SP from ALU result (WRSP)
    logic        wr_flags;   // write FLAGS from ALU result (WRFLAG)
    // status flags update
    logic        flags_we;   // capture ALU flags into FLAGS
    // memory operation
    logic        mem_re;     // read cycle
    logic        mem_we;     // write cycle
    mem_sz_t     mem_sz;     // access width
    // PC control
    logic        branch;     // branch-type instruction (JMP/CALL/Bcc/JMPR/RET/IRET)
    logic        jmp;        // unconditional jump (JMP/CALL/JMPR)
    logic        call;       // CALL: push return address, jump to ALU
    logic        ret;        // RET: PC := pop()
    logic        iret;       // IRET: FLAGS := pop(), PC := pop()
    logic        use_ret_addr; // CALL pushes PC+4 as return address
    branch_cond_t cond;      // conditional select for Bcc
    // stack
    logic        stack_op;   // instruction adjusts SP (PUSH/POP/RET/IRET)
    logic        stack_pop;  // 1 = grow (POP/RET/IRET), 0 = shrink (PUSH/CALL)
    // system control
    logic        halt;       // HALT
    logic        irq_ctl;    // EI or DI
    logic        irq_set;    // EI (1) / DI (0)
  } decoded_instr_t;

endpackage : deckcpu_pkg