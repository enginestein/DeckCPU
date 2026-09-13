// Decoder testbench.
//
// 1) Golden vectors generated from isa/isa.json (tools/isa_tools.py 'vectors'):
//    for every instruction a canonical word is built on the host and the
//    decoder must extract opcode + operand fields consistently.
// 2) Directed checks on the datapath/control output bits per instruction.
module decoder_tb;
  import deckcpu_pkg::*;

  logic [31:0] instr;
  decoded_instr_t d;
  int fails = 0, checks = 0;
  int cur_i = 0;
  int tag = 0;

  decoder dut (.*);

  `include "decoder_vectors.svh"

  task ck;
    input [31:0] cktag;
    input [31:0] got;
    input [31:0] exp;
    begin
      checks++;
      if (got !== exp) begin
        fails++;
        $display("FAIL tag=%0d: got %h exp %h", cktag, got, exp);
      end
    end
  endtask

  // called once per golden vector by gen_golden_case (defined in the include):
  // `instr` was just set; compare the decoder's fields against the literals.
  task do_check;
    input [7:0]  eop;
    input [3:0]  erd;
    input [3:0]  ers1;
    input [3:0]  ers2;
    input [15:0] eimm;
    begin
      #1;
      checks = checks + 4;
      if (d.op !== eop) begin
        fails++;
        $display("FAIL vec[%0d] op: got %h exp %h", cur_i, d.op, eop);
      end
      if (d.rd !== erd) begin
        fails++;
        $display("FAIL vec[%0d] rd: got %h exp %h", cur_i, d.rd, erd);
      end
      if (d.rs1 !== ers1) begin
        fails++;
        $display("FAIL vec[%0d] rs1: got %h exp %h", cur_i, d.rs1, ers1);
      end
      if (d.rs2 !== ers2) begin
        fails++;
        $display("FAIL vec[%0d] rs2: got %h exp %h", cur_i, d.rs2, ers2);
      end
      if (d.imm !== eimm) begin
        fails++;
        $display("FAIL vec[%0d] imm: got %h exp %h", cur_i, d.imm, eimm);
      end
    end
  endtask

  // Convenience wrappers for directed checks
  task cka;
    input [31:0] got;
    input [31:0] exp;
    begin
      ck(tag, got, exp);
      tag++;
    end
  endtask

  initial begin
    // ---- golden vector sweep ----
    for (int i = 0; i < N_VECS; i++) begin
      cur_i = i;
      gen_golden_case(i);
    end

    // ---- directed control checks (motifs) ----
    // ALU register / flags
    instr = 32'h01213000;  #1;   // ADD
    cka(int'(d.alu_op), int'(ALU_ADD));
    cka(d.reg_we, 32'h1);
    cka(int'(d.wb_src), int'(WB_ALU));
    cka(d.flags_we, 32'h1);
    cka(d.mem_re | d.mem_we, 32'h0);

    instr = 32'h0A013000;  #1;   // CMP
    cka(d.flags_we, 32'h1);
    cka(d.reg_we, 32'h0);

    // immediate ALU
    instr = {8'h11, 4'd2, 4'd1, 16'hFF00};  #1;     // ADDI
    cka(int'(d.alu_op), int'(ALU_ADD));
    cka(d.alu_b_imm, 32'h1);
    cka(d.imm, 16'hFF00);

    // LI / LIH
    instr = {8'h20, 4'd2, 4'h0, 16'h00FF};  #1;     // LI
    cka(d.alu_b_imm_zext, 32'h1);
    cka(d.alu_b_imm, 32'h1);
    cka(int'(d.alu_op), int'(ALU_B));
    instr = {8'h21, 4'd2, 4'h0, 16'h00FF};  #1;     // LIH
    cka(d.alu_b_imm_high, 32'h1);

    // load/store
    instr = {8'h30, 4'd2, 4'd1, 16'h0008};  #1;     // LD
    cka(d.mem_re, 32'h1);
    cka(d.mem_we, 32'h0);
    cka(int'(d.mem_sz), int'(SZ_WORD));
    cka(int'(d.wb_src), int'(WB_MEM));
    cka(d.reg_we, 32'h1);
    instr = {8'h32, 4'd2, 4'd1, 16'h0008};  #1;     // LD.B
    cka(int'(d.mem_sz), int'(SZ_BYTE));
    instr = {8'h34, 4'd3, 4'd1, 16'h0008};  #1;     // ST (data reg in rd field)
    cka(d.mem_we, 32'h1);
    cka(d.mem_re, 32'h0);
    cka(int'(d.mem_sz), int'(SZ_WORD));
    cka(d.rd, 4'd3);

    // branches
    instr = {8'h40, 4'h0, 4'h0, 16'h0040};  #1;     // JMP
    cka(d.branch, 32'h1);
    cka(d.jmp, 32'h1);
    cka(d.alu_a_pc, 32'h1);
    cka(int'(d.alu_op), int'(ALU_ADD));
    instr = {8'h41, 4'h0, 4'h0, 16'h0040};  #1;     // CALL
    cka(d.call, 32'h1);
    cka(d.use_ret_addr, 32'h1);
    cka(d.mem_we, 32'h1);
    cka(d.stack_pop, 32'h0);
    instr = {8'h46, 4'd1, 4'd2, 16'h0040};  #1;     // BLT
    cka(int'(d.cond), int'(BC_LT));
    cka(d.rs1, 4'd1);
    cka(d.rs2, 4'd2);
    cka(d.reg_we, 32'h0);
    instr = {8'h42, 4'h0, 4'h0, 16'h0000};  #1;     // RET
    cka(d.ret, 32'h1);
    cka(d.mem_re, 32'h1);
    cka(d.stack_pop, 32'h1);
    instr = {8'h58, 4'h0, 4'h0, 16'h0000};  #1;     // IRET
    cka(d.iret, 32'h1);

    // stack
    instr = 32'h50030000;  #1;    // PUSH rs=3
    cka(d.stack_op, 32'h1);
    cka(d.stack_pop, 32'h0);
    cka(d.mem_we, 32'h1);
    instr = 32'h51200000;  #1;    // POP rd=2
    cka(d.stack_pop, 32'h1);
    cka(int'(d.wb_src), int'(WB_MEM));
    cka(d.reg_we, 32'h1);

    // csr / system
    instr = 32'h52200000;  #1;    // RDSP
    cka(d.alu_a_sp, 32'h1);
    cka(d.reg_we, 32'h1);
    instr = 32'h53020000;  #1;    // WRSP
    cka(d.wr_sp, 32'h1);
    instr = 32'h54200000;  #1;    // RDFLAG
    cka(d.alu_a_flags, 32'h1);
    instr = 32'h55020000;  #1;    // WRFLAG
    cka(d.wr_flags, 32'h1);
    instr = 32'h56000000;  #1;    // EI
    cka(d.irq_ctl, 32'h1);
    cka(d.irq_set, 32'h1);
    instr = 32'h57000000;  #1;    // DI
    cka(d.irq_set, 32'h0);
    instr = 32'h60000000;  #1;    // HALT
    cka(d.halt, 32'h1);

    // NOP decodes to blank control
    instr = 32'h0;  #1;
    cka(d.op, 8'h00);
    cka(d.reg_we, 32'h0);
    cka(d.flags_we, 32'h0);
    cka(d.mem_re | d.mem_we, 32'h0);
    cka(d.branch, 32'h0);

    // unknown opcode collapses to blank control
    instr = 32'hFE00_0000;  #1;
    cka(d.op, 8'hFE);
    cka(d.reg_we, 32'h0);

    if (fails) begin
      $display("decoder_tb: %0d/%0d FAILED", fails, checks);
      $fatal(1, "decoder_tb failed");
    end
    $display("decoder_tb: %0d checks OK", checks);
    $finish;
  end
endmodule : decoder_tb