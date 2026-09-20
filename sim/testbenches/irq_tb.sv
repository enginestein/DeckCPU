// DeckCPU interrupt integration testbench: cpu + bus + ram + irq_prio.
//
// Drives the five peripheral IRQ lines through the arbiter and checks the
// interrupt contract against docs/isa.md: entry gated by FLAGS.I (an IRQ
// asserted before EI is held), push PC/FLAGS and vector through the IVT,
// irq_ack on the first push, handler markers + IRET restoring PC/SP/FLAGS
// (so a still-asserted source re-enters), priority by slot index, and no
// nesting while FLAGS.I==0.
//
// Program (tools/gen_programs.py): slots 0..5 JMP to main / H1..H5; main
// does LI r0,0x1000 / DI / EI / spin; Hk stores k at [0x1000+4*(k-1)] then
// IRETs.

module irq_tb
 import deckcpu_pkg::*;
 #(parameter int W = 32);

    logic clk = 1'b0;
    always #5 clk = ~clk;

    logic        rst = 1'b1;
    int          fail = 0;

    // ---- IRQ sources (TB drives the bus irq inputs) ----
    logic        irq_timer, irq_uart_rx, irq_uart_tx, irq_gpio, irq_spi;
    // bus irq passthrough -> arbiter
    logic        bus_irq_timer, bus_irq_uart_rx, bus_irq_uart_tx;
    logic        bus_irq_gpio, bus_irq_spi;
    logic        cpu_irq_req;
    logic [2:0]  cpu_irq_vec;

    // ---- bus nets ----
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
    logic        uart_re, uart_we, timer_re, timer_we, gpio_re, gpio_we, spi_re, spi_we;
    logic [3:0]  uart_be, timer_be, gpio_be, spi_be;
    logic [11:0] uart_addr, timer_addr, gpio_addr, spi_addr;
    logic [W-1:0] uart_wdata, timer_wdata, gpio_wdata, spi_wdata;
    logic [W-1:0] uart_rdata, timer_rdata, gpio_rdata, spi_rdata;

    // ---- cpu debug bundle ----
    state_t      dbg_state;
    logic [W-1:0] dbg_pc, dbg_sp, dbg_ir;
    logic [W*NREG-1:0] dbg_regs;
    logic [4:0]  dbg_flags;
    logic [7:0]  dbg_opcode;
    logic        dbg_done, dbg_halted;
    logic [W-1:0] dbg_cycle;

    // ---- scenario capture state (sampled by the edge monitor) ----
    integer      ack_count;
    logic [W-1:0] ack_pc, ack_sp;
    logic [4:0]  ack_flags;
    logic        gating_viol;         // irq_ack asserted while !irq_en
    logic [W-1:0] push_pc_addr, push_pc_data;      // S_IRQ_PC bus write
    logic [W-1:0] push_fl_addr, push_fl_data;      // S_IRQ_FL bus write
    logic        vec_seen, vec2_seen; // vector fetches (slot PC), in ack order
    logic [W-1:0] vec_pc, vec2_pc;

    // ---- program words ----
    logic [W-1:0] PW [0:31];
`include "irq_tb_prog_words.svh"

    // ---- DUT: the interrupt netlist ----
    cpu #(.W(W), .NREG(16)) core (
        .clk(clk), .rst(rst),
        .bus_re(bus_re), .bus_we(bus_we), .bus_addr(bus_addr),
        .bus_sz(bus_sz), .bus_wdata(bus_wdata), .bus_rdata(bus_rdata),
        .bus_err(bus_err),
        .irq_req(cpu_irq_req), .irq_vec(cpu_irq_vec),
        .irq_ack(irq_ack), .irq_en(irq_en),
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
        .uart_sel(uart_sel), .timer_sel(timer_sel), .gpio_sel(gpio_sel), .spi_sel(spi_sel),
        .uart_re(uart_re), .uart_we(uart_we), .uart_be(uart_be), .uart_addr(uart_addr),
        .uart_wdata(uart_wdata), .uart_rdata(uart_rdata),
        .timer_re(timer_re), .timer_we(timer_we), .timer_be(timer_be), .timer_addr(timer_addr),
        .timer_wdata(timer_wdata), .timer_rdata(timer_rdata),
        .gpio_re(gpio_re), .gpio_we(gpio_we), .gpio_be(gpio_be), .gpio_addr(gpio_addr),
        .gpio_wdata(gpio_wdata), .gpio_rdata(gpio_rdata),
        .spi_re(spi_re), .spi_we(spi_we), .spi_be(spi_be), .spi_addr(spi_addr),
        .spi_wdata(spi_wdata), .spi_rdata(spi_rdata),
        .uart_irq_rx(irq_uart_rx), .uart_irq_tx(irq_uart_tx), .timer_irq(irq_timer),
        .gpio_irq(irq_gpio), .spi_irq(irq_spi),
        .irq_uart_rx(bus_irq_uart_rx), .irq_uart_tx(bus_irq_uart_tx),
        .irq_timer(bus_irq_timer), .irq_gpio(bus_irq_gpio), .irq_spi(bus_irq_spi)
    );

    ram #(.AW(RAM_AW)) u_ram (
        .clk(clk), .rst(rst), .re(ram_re), .we(ram_we), .be(ram_be), .addr(ram_addr),
        .wdata(ram_wdata), .rdata(ram_rdata),
        .boot_we(boot_we), .boot_addr(boot_addr), .boot_data(boot_data)
    );

    irq_prio u_prio (
        .irq_timer(bus_irq_timer), .irq_uart_rx(bus_irq_uart_rx),
        .irq_uart_tx(bus_irq_uart_tx), .irq_gpio(bus_irq_gpio), .irq_spi(bus_irq_spi),
        .irq_req(cpu_irq_req), .irq_vec(cpu_irq_vec)
    );

    // unused MMIO rdata inputs (no MMIO traffic in this program)
    assign uart_rdata = '0;
    assign timer_rdata = '0;
    assign gpio_rdata = '0;
    assign spi_rdata = '0;

    logic        irq_ack, irq_en;

    // ---- edge monitor: capture entry/frame/vector facts at the posedge that
    // ends each cycle (pre-NBA, so combinational bus/state are still valid).
    always @(posedge clk) begin
        if (irq_ack) begin
            ack_count <= ack_count + 1;
            ack_pc    <= dbg_pc;
            ack_sp    <= dbg_sp;
            ack_flags <= dbg_flags;
            if (!irq_en)
                gating_viol <= 1'b1;
        end
        if (bus_we && dbg_state == S_IRQ_PC) begin
            push_pc_addr <= bus_addr;
            push_pc_data <= bus_wdata;
        end
        if (bus_we && dbg_state == S_IRQ_FL) begin
            push_fl_addr <= bus_addr;
            push_fl_data <= bus_wdata;
        end
        // a fetch whose PC is a IVT slot (4..20, i.e. slots 1..5); other code
        // never executes at those addresses, so this is the vector fetch.
        if (dbg_state == S_FETCH && dbg_pc >= 32'h4 && dbg_pc <= 32'h14 && !dbg_pc[1]) begin
            if (!vec_seen) begin
                vec_seen <= 1'b1;
                vec_pc   <= dbg_pc;
            end else begin
                vec2_seen <= 1'b1;
                vec2_pc   <= dbg_pc;
            end
        end
    end

    task check(input int tag, input [W-1:0] got, input [W-1:0] exp);
    begin
        if (got !== exp) begin
            fail = fail + 1;
            $display("FAIL[%0d]: got=%h exp=%h", tag, got, exp);
        end
    end
    endtask : check

    // ---- reset the CPU, clear the marker/trace state, erase the marker band.
    task do_reset;
    begin
        rst = 1'b1;
        irq_timer = 0; irq_uart_rx = 0; irq_uart_tx = 0; irq_gpio = 0; irq_spi = 0;
        ack_count = 0; ack_pc = 0; ack_sp = 0; ack_flags = '0; gating_viol = 0;
        push_pc_addr = 0; push_pc_data = 0; push_fl_addr = 0; push_fl_data = 0;
        vec_seen = 0; vec2_seen = 0; vec_pc = 0; vec2_pc = 0;
        repeat (2) @(posedge clk);
        for (int m = 0; m < 5; m++) begin
            boot_we   = 1'b1;
            boot_addr = 16'h1000 + m*4;
            boot_data = 32'h0;
            @(posedge clk);
        end
        boot_we = 1'b0;
        rst = 1'b0;
        @(posedge clk);
    end
    endtask : do_reset

    task wait_ack(input int maxcyc, input int tag);
        begin
            for (int c = 0; c < maxcyc; c++) begin
                @(posedge clk); #1;
                if (ack_count >= 1) begin
                    // captured
                    c = maxcyc;     // break
                end
            end
            if (ack_count < 1) begin
                fail = fail + 1;
                $display("FAIL[wait_ack %0d]: timeout, ack_count=%0d", tag, ack_count);
            end
        end
    endtask : wait_ack

    task wait_ack2(input int maxcyc, input int tag);
        begin
            for (int c = 0; c < maxcyc; c++) begin
                @(posedge clk); #1;
                if (ack_count >= 2) begin
                    c = maxcyc;
                end
            end
            if (ack_count < 2) begin
                fail = fail + 1;
                $display("FAIL[wait_ack2 %0d]: timeout, ack_count=%0d", tag, ack_count);
            end
        end
    endtask : wait_ack2

    task wait_marker(input [RAM_AW-1:0] addr, input [W-1:0] expv,
                     input int maxcyc, input int tag);
        begin
            for (int c = 0; c < maxcyc; c++) begin
                @(posedge clk); #1;
                if (u_ram.mem[addr*8 +: 32] === expv) begin
                    c = maxcyc;
                end
            end
            if (u_ram.mem[addr*8 +: 32] !== expv) begin
                fail = fail + 1;
                $display("FAIL[wait_marker %0d]: addr=%h exp=%h got=%h",
                         tag, addr, expv, u_ram.mem[addr*8 +: 32]);
            end
        end
    endtask : wait_marker

    // ---- scenario A: reset gating + timer entry + frame + IRET return ----
    task scenario_a;
    begin
        do_reset();
        // assert the timer source before EI: must be held (FLAGS.I==0)
        irq_timer = 1'b1;
        wait_ack(200, 1);
        check( 1, ack_count, 32'h1);
        check( 2, ack_pc,    32'h0000_0024);   // interrupted PC = loop
        check( 3, {27'b0, ack_flags}, 32'h0000_0001);  // I=1 at entry (post-EI)
        check( 4, gating_viol, 32'h0);         // no ack while I==0
        irq_timer = 1'b0;                     // clear source => no re-entry
        repeat (5) @(posedge clk); #1;          // let pushes + vector fetch land
        check(10, push_pc_addr, 32'h0000_FFF8); check(11, push_pc_data, 32'h0000_0024);
        check(12, push_fl_addr, 32'h0000_FFF4); check(13, push_fl_data, 32'h0000_0001);
        check(14, vec_seen, 32'h1);
        check(15, vec_pc,   32'h0000_0004);   // slot 1 (TIMER)
        wait_marker(16'h1000, 32'h1, 200, 6); // H1 stored its id
        repeat (8) @(posedge clk); #1;          // IRET completes, spin at 0x24
        check(20, dbg_pc,    32'h0000_0024);
        check(21, dbg_sp,    32'h0000_FFFC);
        check(22, {27'b0, dbg_flags}, 32'h0000_0001);  // I restored by IRET
        check(23, ack_count, 32'h1);           // no re-entry (source cleared)
        check(24, u_ram.mem[16'h1000*8 +: 32], 32'h1);
    end
    endtask : scenario_a

    // ---- scenario B: vector dispatch for slots 2..5 ----
    // slot k: [0x1004] uart_rx , [0x1008] uart_tx, [0x100C] gpio, [0x1010] spi
    task scenario_b;
    begin
        for (int k = 2; k <= 5; k++) begin
            do_reset();
            case (k)
                2: irq_uart_rx = 1'b1;
                3: irq_uart_tx = 1'b1;
                4: irq_gpio    = 1'b1;
                5: irq_spi     = 1'b1;
            endcase
            wait_ack(200, 100 + k);
            check(101, ack_count, 32'h1);
            check(102, ack_pc,    32'h0000_0024);
            check(103, gating_viol, 32'h0);
            irq_uart_rx = 0; irq_uart_tx = 0; irq_gpio = 0; irq_spi = 0;
            repeat (5) @(posedge clk); #1;
            check(110 + k, vec_seen, 32'h1);
            check(120 + k, vec_pc, 32'h0000_0000 + k*4);
            wait_marker(16'h1000 + (k-1)*4, k, 200, 130 + k);
            repeat (8) @(posedge clk); #1;
            check(140 + k, dbg_pc, 32'h0000_0024);
            check(150 + k, dbg_sp, 32'h0000_FFFC);
            check(160 + k, {27'b0, dbg_flags}, 32'h0000_0001);
            check(170 + k, ack_count, 32'h1);
        end
    end
    endtask : scenario_b

    // ---- scenario C: priority (TIMER > UART_RX) + no nesting ----
    task scenario_c;
    begin
        do_reset();
        irq_timer   = 1'b1;
        irq_uart_rx = 1'b1;                  // both pending before EI
        wait_ack(200, 300);
        check(301, ack_count, 32'h1);
        check(302, ack_pc,    32'h0000_0024);
        check(303, gating_viol, 32'h0);
        repeat (5) @(posedge clk); #1;
        check(304, vec_pc, 32'h0000_0004);   // timer outranks uart_rx
        irq_timer = 1'b0;                    // only uart_rx stays pending
        // while H1 runs FLAGS.I==0, so the pending uart_rx must NOT nest
        wait_marker(16'h1000, 32'h1, 200, 305);
        check(306, ack_count, 32'h1);        // no nest entry during H1
        // H1 IRET restores I=1 => pending uart_rx re-enters immediately
        wait_ack2(200, 310);
        irq_uart_rx = 1'b0;
        repeat (5) @(posedge clk); #1;
        check(311, vec2_seen, 32'h1);
        check(312, vec2_pc,   32'h0000_0008); // slot 2 (UART_RX) dequeued next
        wait_marker(16'h1004, 32'h2, 200, 313);
        repeat (8) @(posedge clk); #1;
        check(320, dbg_pc, 32'h0000_0024);
        check(321, dbg_sp, 32'h0000_FFFC);
        check(322, {27'b0, dbg_flags}, 32'h0000_0001);
        check(323, ack_count, 32'h2);        // exactly two entries
    end
    endtask : scenario_c

    initial begin
        // ---- boot the IVT image + program through the load port ----
        repeat (2) @(posedge clk);
        boot_we = 1'b1;
        for (int w = 0; w < IRQ_TB_PROG_NWORDS; w++) begin
            boot_addr = w*4;
            boot_data = PW[w];
            @(posedge clk);
        end
        boot_we = 1'b0;
        rst = 1'b1;
        repeat (2) @(posedge clk);
        rst = 1'b0;

        scenario_a();
        scenario_b();
        scenario_c();

        $display("irq_tb: %0d failures", fail);
        if (fail == 0)
            $display("irq_tb: ALL CHECKS PASSED");
        $finish;
    end

endmodule : irq_tb