module soc_tb
 import deckcpu_pkg::*;
 #(parameter int W = 32);

    logic clk = 1'b0;
    always #5 clk = ~clk;

    logic        rst = 1'b1;
    logic        irq_en;
    int          fail = 0;

    // ---- nets ----
    logic        bus_re, bus_we, bus_err;
    logic [3:0]  bus_be;
    logic [W-1:0] bus_addr, bus_wdata, bus_rdata;
    mem_sz_t     bus_sz;
    logic        ram_re, ram_we;
    logic [3:0]  ram_be;
    logic [RAM_AW-1:0] ram_addr;
    logic [W-1:0] ram_wdata, ram_rdata;
    logic        boot_we;
    logic [RAM_AW-1:0] boot_addr;
    logic [W-1:0] boot_data;
    logic        uart_sel, timer_sel, gpio_sel, spi_sel;

    state_t      dbg_state;
    logic [W-1:0] dbg_pc, dbg_sp, dbg_ir;
    logic [W*NREG-1:0] dbg_regs;
    logic [4:0]  dbg_flags;
    logic [7:0]  dbg_opcode;
    logic        dbg_done, dbg_halted;
    logic [W-1:0] dbg_cycle;

    logic [W-1:0] PW [0:14];
`include "cpu_fsm_prog_words.svh"

    logic [W-1:0] EXP_PC [0:13];
    logic [7:0]   EXP_OP [0:12];

    cpu #(.W(W), .NREG(16)) core (
        .clk(clk), .rst(rst),
        .bus_re(bus_re), .bus_we(bus_we), .bus_addr(bus_addr),
        .bus_sz(bus_sz), .bus_wdata(bus_wdata), .bus_rdata(bus_rdata),
        .bus_err(bus_err),
        .irq_req(1'b0), .irq_ack(), .irq_en(irq_en),
        .dbg_state(dbg_state), .dbg_pc(dbg_pc), .dbg_regs(dbg_regs), .dbg_ir(dbg_ir),
        .dbg_opcode(dbg_opcode), .dbg_rd(), .dbg_rs1(), .dbg_rs2(),
        .dbg_alu_a(), .dbg_alu_b(), .dbg_alu_y(),
        .dbg_sp(dbg_sp), .dbg_flags(dbg_flags),
        .dbg_mem_addr(), .dbg_mem_re(), .dbg_mem_we(), .dbg_mem_wdata(),
        .dbg_mem_rdata(), .dbg_done(dbg_done),
        .dbg_cycle(dbg_cycle), .dbg_halted(dbg_halted)
    );

    bus #(.W(W)) u_bus (
        .clk(clk), .rst(rst),
        .re(bus_re), .we(bus_we), .sz(bus_sz), .addr(bus_addr), .wdata(bus_wdata),
        .rdata(bus_rdata), .err(bus_err), .be(bus_be),
        .ram_re(ram_re), .ram_we(ram_we), .ram_be(ram_be), .ram_addr(ram_addr),
        .ram_wdata(ram_wdata), .ram_rdata(ram_rdata),
        .uart_sel(uart_sel), .timer_sel(timer_sel), .gpio_sel(gpio_sel), .spi_sel(spi_sel)
    );

    ram #(.AW(RAM_AW)) u_ram (
        .clk(clk), .rst(rst), .re(ram_re), .we(ram_we), .be(ram_be), .addr(ram_addr),
        .wdata(ram_wdata), .rdata(ram_rdata),
        .boot_we(boot_we), .boot_addr(boot_addr), .boot_data(boot_data)
    );

    task check(input int tag, input [W-1:0] got, input [W-1:0] exp);
        begin
            if (got !== exp) begin
                fail = fail + 1;
                $display("FAIL[%0d]: got=%h exp=%h", tag, got, exp);
            end
        end
    endtask : check

    initial begin
        logic    err_seen;

        EXP_PC[0]  = 32'h0000_0000;  // NOP
        EXP_PC[1]  = 32'h0000_0004;  // EI
        EXP_PC[2]  = 32'h0000_0008;  // DI
        EXP_PC[3]  = 32'h0000_000C;  // ADDI
        EXP_PC[4]  = 32'h0000_0010;  // SUB
        EXP_PC[5]  = 32'h0000_0014;  // JMP
        EXP_PC[6]  = 32'h0000_001C;  // CMP (0x18 skipped)
        EXP_PC[7]  = 32'h0000_0020;  // BEQ
        EXP_PC[8]  = 32'h0000_0028;  // BNE (0x24 skipped)
        EXP_PC[9]  = 32'h0000_002C;  // LI r3,100
        EXP_PC[10] = 32'h0000_0030;  // PUSH
        EXP_PC[11] = 32'h0000_0034;  // POP
        EXP_PC[12] = 32'h0000_0038;  // HALT
        EXP_PC[13] = 32'h0000_0038;  // frozen on halt

        EXP_OP[0]  = 8'h00;  // NOP
        EXP_OP[1]  = 8'h56;  // EI
        EXP_OP[2]  = 8'h57;  // DI
        EXP_OP[3]  = 8'h11;  // ADDI
        EXP_OP[4]  = 8'h02;  // SUB
        EXP_OP[5]  = 8'h40;  // JMP
        EXP_OP[6]  = 8'h0A;  // CMP
        EXP_OP[7]  = 8'h44;  // BEQ
        EXP_OP[8]  = 8'h45;  // BNE
        EXP_OP[9]  = 8'h20;  // LI
        EXP_OP[10] = 8'h50;  // PUSH
        EXP_OP[11] = 8'h51;  // POP
        EXP_OP[12] = 8'h60;  // HALT

        err_seen = 1'b0;
        boot_we = 0; boot_addr = 0; boot_data = 0;

        // ---- reset + image load through the boot port (bus is quiet) ----
        repeat (2) @(posedge clk);
        boot_we = 1'b1;
        for (int w = 0; w < CPU_FSM_PROG_NWORDS; w++) begin
            boot_addr = w*4;
            boot_data = PW[w];
            @(posedge clk);
        end
        boot_we = 1'b0;
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

            exp_idx     = 0;
            got_done    = 0;
            prev_done_b = 0;
            started     = 0;
            start_cyc   = 0;
            cyc_sum     = 0;
            seen_f = 1'b0; seen_d = 1'b0; seen_e = 1'b0; seen_m = 1'b0; seen_w = 1'b0;
            done_halted = 1'b0;

            for (int iter = 0; iter < 600 && !done_halted; iter++) begin
                @(posedge clk);
                if (!started) begin
                    started   = 1;
                    start_cyc = dbg_cycle;
                end
                if (bus_err)
                    err_seen = 1'b1;
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
                    if (exp_idx <= 12) begin
                        check(10 + exp_idx, dbg_opcode, EXP_OP[exp_idx]);
                        check(30 + exp_idx, dbg_pc, EXP_PC[exp_idx + 1]);
                        case (EXP_OP[exp_idx])
                            8'h00, 8'h56, 8'h57: cyc_sum = cyc_sum + 3;
                            8'h60:              cyc_sum = cyc_sum + 3;   // HALT
                            8'h51:              cyc_sum = cyc_sum + 5;   // POP
                            default:            cyc_sum = cyc_sum + 4;
                        endcase
                        if (EXP_OP[exp_idx] == 8'h56 && !irq_en) begin
                            fail = fail + 1; $display("FAIL[EI: irq_en not raised]");
                        end
                        if (EXP_OP[exp_idx] == 8'h57 && irq_en) begin
                            fail = fail + 1; $display("FAIL[DI: irq_en not lowered]");
                        end
                        exp_idx = exp_idx + 1;
                    end
                    got_done = got_done + 1;
                end
                prev_done_b = dbg_done;
                if (dbg_done && dbg_halted)
                    done_halted = 1'b1;
            end

            check(100, {1'b0, dbg_halted}, 32'h1);
            check(101, dbg_pc, 32'h0000_0038);
            check(102, dbg_sp, 32'h0000_FFFC);
            check(103, {27'b0, dbg_flags}, 32'h0000_0002);
            for (int i = 0; i < 16; i++) begin
                rv = dbg_regs[i*32 +: 32];
                case (i)
                    1: check(112, rv, 32'h0000_0008);
                    2: check(113, rv, 32'h0000_0008);
                    3: check(114, rv, 32'h0000_0064);
                    4: check(115, rv, 32'h0000_0008);
                    default: check(130 + i, rv, 32'h0);
                endcase
            end
            check(121, got_done, 13);
            check(122, exp_idx, 13);
            check(123, dbg_cycle - start_cyc, cyc_sum);
            if (err_seen) begin
                fail = fail + 1;
                $display("FAIL[err asserted during the run]");
            end
            if (!(seen_f && seen_d && seen_e && seen_m && seen_w)) begin
                fail = fail + 1;
                $display("FAIL[state walk missing stages: f=%0d d=%0d e=%0d m=%0d w=%0d]",
                         seen_f, seen_d, seen_e, seen_m, seen_w);
            end
        end

        $display("soc_tb: %0d failures", fail);
        if (fail == 0)
            $display("soc_tb: ALL CHECKS PASSED");
        $finish;
    end

endmodule : soc_tb