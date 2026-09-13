module cpu_tb
 import deckcpu_pkg::*;
 #(parameter int W = 32);

    logic clk = 1'b0;
    always #5 clk = ~clk;

    logic        rst = 1'b1;
    logic        irq_en;
    int          fail = 0;

    logic        bus_re, bus_we;
    logic [W-1:0] bus_addr, bus_wdata, bus_rdata;
    mem_sz_t     bus_sz;
    logic        bus_err = 1'b0;

    // tb-side memory model; see cpu_fsm_tb.sv header for why (Icarus delta
    // loops forbid $readmemh / comb array reads on wide indices here).
    logic [31:0] MM [0:65535];

    logic [31:0] PW [0:35];
`include "cpu_tb_prog_words.svh"

    state_t      dbg_state;
    logic [W-1:0] dbg_pc, dbg_sp, dbg_ir;
    logic [W*NREG-1:0] dbg_regs;
    logic [4:0]  dbg_flags;
    logic [7:0]  dbg_opcode;
    logic [3:0]  dbg_rd, dbg_rs1, dbg_rs2;
    logic [W-1:0] dbg_alu_a, dbg_alu_b, dbg_alu_y;
    logic [W-1:0] dbg_mem_addr, dbg_mem_wdata, dbg_mem_rdata;
    logic        dbg_mem_re, dbg_mem_we;
    logic        dbg_done, dbg_halted;
    logic [W-1:0] dbg_cycle;

    // executed pc sequence over the whole run program (32 entries incl. HALT)
    logic [W-1:0] EXP_PC [0:32];
    // retired opcode observed on each done pulse (31 entries)
    logic [7:0]   EXP_OP [0:31];

    cpu #(.W(W), .NREG(16)) core (
        .clk(clk), .rst(rst),
        .bus_re(bus_re), .bus_we(bus_we), .bus_addr(bus_addr),
        .bus_sz(bus_sz), .bus_wdata(bus_wdata), .bus_rdata(bus_rdata),
        .bus_err(bus_err),
        .irq_req(1'b0), .irq_ack(), .irq_en(irq_en),
        .dbg_state(dbg_state), .dbg_pc(dbg_pc), .dbg_regs(dbg_regs), .dbg_ir(dbg_ir),
        .dbg_opcode(dbg_opcode), .dbg_rd(dbg_rd), .dbg_rs1(dbg_rs1), .dbg_rs2(dbg_rs2),
        .dbg_alu_a(dbg_alu_a), .dbg_alu_b(dbg_alu_b), .dbg_alu_y(dbg_alu_y),
        .dbg_sp(dbg_sp), .dbg_flags(dbg_flags),
        .dbg_mem_addr(dbg_mem_addr), .dbg_mem_re(dbg_mem_re),
        .dbg_mem_we(dbg_mem_we), .dbg_mem_wdata(dbg_mem_wdata),
        .dbg_mem_rdata(dbg_mem_rdata), .dbg_done(dbg_done),
        .dbg_cycle(dbg_cycle), .dbg_halted(dbg_halted)
    );

    task check(input int tag, input [W-1:0] got, input [W-1:0] exp);
        begin
            if (got !== exp) begin
                fail = fail + 1;
                $display("FAIL[%0d]: got=%h exp=%h", tag, got, exp);
            end
        end
    endtask : check

    // tb-side memory model. Clocked on the clock's NEGEDGE so that the
    // presented read word and committed store both use the bus address AFTER
    // the CPU's NBA updates at posedge (a posedge-region read would sample
    // the previous cycle's addr and corrupt fetches).
    always @(negedge clk) begin
        if (!rst && bus_we)
            MM[bus_addr >> 2] = bus_wdata;
        bus_rdata = MM[bus_addr >> 2];
    end

    initial begin
        EXP_PC[0]  = 32'h0000_0000;  EXP_PC[1]  = 32'h0000_0004;
        EXP_PC[2]  = 32'h0000_0008;  EXP_PC[3]  = 32'h0000_000C;
        EXP_PC[4]  = 32'h0000_0010;  EXP_PC[5]  = 32'h0000_0014;
        EXP_PC[6]  = 32'h0000_0018;  EXP_PC[7]  = 32'h0000_001C;
        EXP_PC[8]  = 32'h0000_0020;  EXP_PC[9]  = 32'h0000_0024;
        EXP_PC[10] = 32'h0000_0028;  EXP_PC[11] = 32'h0000_002C;
        EXP_PC[12] = 32'h0000_0030;  EXP_PC[13] = 32'h0000_0034;
        EXP_PC[14] = 32'h0000_0038;  EXP_PC[15] = 32'h0000_003C;
        EXP_PC[16] = 32'h0000_0048;  EXP_PC[17] = 32'h0000_004C;  // 0x40/0x44 skipped
        EXP_PC[18] = 32'h0000_0088;  EXP_PC[19] = 32'h0000_008C;  // CALL target / RET
        EXP_PC[20] = 32'h0000_0050;  EXP_PC[21] = 32'h0000_0054;
        EXP_PC[22] = 32'h0000_0058;  EXP_PC[23] = 32'h0000_005C;
        EXP_PC[24] = 32'h0000_0060;  EXP_PC[25] = 32'h0000_0064;
        EXP_PC[26] = 32'h0000_0068;  EXP_PC[27] = 32'h0000_006C;
        EXP_PC[28] = 32'h0000_0070;  EXP_PC[29] = 32'h0000_0074;
        EXP_PC[30] = 32'h0000_0080;  EXP_PC[31] = 32'h0000_0084;  // HALT
        EXP_PC[32] = 32'h0000_0084;  // frozen on halt

        EXP_OP[0]  = 8'h20;  EXP_OP[1]  = 8'h20;
        EXP_OP[2]  = 8'h01;  EXP_OP[3]  = 8'h02;
        EXP_OP[4]  = 8'h0A;  EXP_OP[5]  = 8'h04;
        EXP_OP[6]  = 8'h05;  EXP_OP[7]  = 8'h06;
        EXP_OP[8]  = 8'h07;  EXP_OP[9]  = 8'h03;
        EXP_OP[10] = 8'h20;  EXP_OP[11] = 8'h34;   // ST
        EXP_OP[12] = 8'h30;  EXP_OP[13] = 8'h11;   // LD / ADDI
        EXP_OP[14] = 8'h0A;  EXP_OP[15] = 8'h44;   // CMP / BEQ
        EXP_OP[16] = 8'h22;  EXP_OP[17] = 8'h41;   // MOV / CALL
        EXP_OP[18] = 8'h20;  EXP_OP[19] = 8'h42;   // sub LI / RET
        EXP_OP[20] = 8'h20;  EXP_OP[21] = 8'h50;   // LI r13,7 / PUSH
        EXP_OP[22] = 8'h51;  EXP_OP[23] = 8'h20;   // POP / LI r4
        EXP_OP[24] = 8'h20;  EXP_OP[25] = 8'h34;   // LI r5 / ST
        EXP_OP[26] = 8'h20;  EXP_OP[27] = 8'h34;   // LI r6 / ST
        EXP_OP[28] = 8'h53;  EXP_OP[29] = 8'h58;   // WRSP / IRET
        EXP_OP[30] = 8'h20;                        // LI r7,77
        EXP_OP[31] = 8'h60;                        // HALT

        repeat (2) @(posedge clk);   // reset flush
        begin : load_mm
            for (int w = 0; w < CPU_TB_PROG_NWORDS; w++)
                MM[w] = PW[w];
        end
        bus_rdata = MM[0];
        rst = 1'b0;

        begin
            int      exp_idx;
            int      got_done;
            int      prev_done_b;
            int      started;
            logic [W-1:0] start_cyc;
            int      cyc_sum;
            logic    done_halted;
            logic    seen_f, seen_d, seen_e, seen_m, seen_w;
            logic [W-1:0] rv;

            exp_idx = 0; got_done = 0; prev_done_b = 0; started = 0;
            cyc_sum = 0;
            seen_f = 1'b0; seen_d = 1'b0; seen_e = 1'b0; seen_m = 1'b0; seen_w = 1'b0;
            done_halted = 1'b0;

            // bounded sampling window: the program runs well under 600 cycles
            for (int iter = 0; iter < 600 && !done_halted; iter++) begin
                @(posedge clk);
                if (!started) begin
                    started   = 1;
                    start_cyc = dbg_cycle;
                end
                case (dbg_state)
                    S_FETCH:  seen_f = 1'b1;
                    S_DECODE: seen_d = 1'b1;
                    S_EXEC:   seen_e = 1'b1;
                    S_MEM:    seen_m = 1'b1;
                    S_WB:     seen_w = 1'b1;
                    default:  ;
                endcase

                if (dbg_done) begin
                    if (prev_done_b) begin
                        fail = fail + 1;
                        $display("FAIL[double-done]");
                    end
                    if (exp_idx <= 31) begin
                        check(10 + exp_idx,     dbg_opcode, EXP_OP[exp_idx]);
                        check(50 + exp_idx,     dbg_pc,     EXP_PC[exp_idx + 1]);
                        case (EXP_OP[exp_idx])
                            8'h60:              cyc_sum = cyc_sum + 3;
                            8'h30, 8'h31, 8'h32,
                            8'h51, 8'h42:        cyc_sum = cyc_sum + 5;
                            8'h58:              cyc_sum = cyc_sum + 6;
                            default:            cyc_sum = cyc_sum + 4;
                        endcase
                        // spot-check retired decoded reg fields
                        if (EXP_OP[exp_idx] == 8'h34 && exp_idx == 11) check(90, {28'b0, dbg_rd}, 32'h3);
                        if (EXP_OP[exp_idx] == 8'h30 && exp_idx == 12) check(91, {28'b0, dbg_rd}, 32'hB);
                        if (EXP_OP[exp_idx] == 8'h41 && exp_idx == 17) check(92, {28'b0, dbg_rs2}, 32'h0);
                        exp_idx = exp_idx + 1;
                    end
                    got_done = got_done + 1;
                end
                prev_done_b = dbg_done;
                if (dbg_done && dbg_halted)
                    done_halted = 1'b1;
            end

            // ---- end-state checks ----
            check(100, dbg_halted ? 32'h1 : 32'h0, 32'h1);
            check(101, dbg_pc,  32'h0000_0084);
            check(102, dbg_sp,  32'h0000_2008);      // IRET final sp
            check(103, {27'b0, dbg_flags}, 32'h0000_000A);  // fl = 0x2A[4:0] = Z|C

            rv = dbg_regs[32*0  +: 32]; check(200, rv, 32'h0);          // r0
            rv = dbg_regs[32*1  +: 32]; check(201, rv, 32'h5);          // r1
            rv = dbg_regs[32*2  +: 32]; check(202, rv, 32'h7);          // r2
            rv = dbg_regs[32*3  +: 32]; check(203, rv, 32'hC);          // r3 = 5+7
            rv = dbg_regs[32*4  +: 32]; check(204, rv, 32'h2000);       // r4 = IRET base
            rv = dbg_regs[32*5  +: 32]; check(205, rv, 32'h2A);         // r5 = saved FLAGS word
            rv = dbg_regs[32*6  +: 32]; check(206, rv, 32'h80);         // r6 = saved PC word
            rv = dbg_regs[32*7  +: 32]; check(207, rv, 32'h4D);         // r7 = 77 after IRET
            rv = dbg_regs[32*8  +: 32]; check(208, rv, 32'hFFFF_FFFA);  // r8 = ~5
            rv = dbg_regs[32*9  +: 32]; check(209, rv, 32'h23);         // r9 = 5*7
            rv = dbg_regs[32*10 +: 32]; check(210, rv, 32'h1000);       // r10
            rv = dbg_regs[32*11 +: 32]; check(211, rv, 32'hC);          // r11 = LD read back
            rv = dbg_regs[32*12 +: 32]; check(212, rv, 32'hF);          // r12 = 5+10
            rv = dbg_regs[32*13 +: 32]; check(213, rv, 32'h7);          // r13 (sub overwritten)
            rv = dbg_regs[32*14 +: 32]; check(214, rv, 32'hC);          // r14 = MOV r3
            rv = dbg_regs[32*15 +: 32]; check(215, rv, 32'h5);          // r15 = POP r1

            // memory side-effects (word-oriented model)
            check(220, MM[1025], 32'hC);     // ST r3 at 0x1004
            check(221, MM[2048], 32'h2A);    // saved FLAGS
            check(222, MM[2049], 32'h80);    // saved PC
            check(223, MM[16382], 32'h5);    // PUSH r1 landed then POP

            // IRET consumed exactly the saved words and advanced sp by 8
            check(230, dbg_cycle - start_cyc, cyc_sum);       // HALT counted in cyc_sum
            check(231, got_done, 32);
            check(232, exp_idx, 32);
            if (!(seen_f && seen_d && seen_e && seen_m && seen_w)) begin
                fail = fail + 1;
                $display("FAIL[state walk missing phases: f=%0d d=%0d e=%0d m=%0d w=%0d]",
                         seen_f, seen_d, seen_e, seen_m, seen_w);
            end

            // halted: pc/sp frozen, bus quiet
            @(posedge clk);
            check(240, dbg_pc, 32'h0000_0084);
            check(241, dbg_sp, 32'h0000_2008);
            check(242, {31'b0, dbg_mem_re}, 32'h0);
        end

        $display("cpu_tb: %0d failures", fail);
        if (fail == 0)
            $display("cpu_tb: ALL CHECKS PASSED");
        $finish;
    end

endmodule : cpu_tb