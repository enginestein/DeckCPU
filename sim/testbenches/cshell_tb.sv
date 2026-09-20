// DeckC interactive-console testbench.
//
// Boots the deckc-compiled console image (cdecko_cshell_words.svh, built by
// gen_cshell_image.py) and drives the UART RX with a scripted session. The
// console echoes each typed character (single-latch RX, so each push waits
// for the last echo), then replies per command. After the final "exit" the
// program returns 0 -> mailbox 0, the CPU halts, and we assert the ordered
// transcript, the GPIO side effects (pin0=1, pin2=0) and the mailbox.
//
// The expected output is grounded in the interpreter contract (test_deckc.py,
// gen_cshell_image.py); this run proves the same program drives the real
// UART, TIMER and GPIO peripherals on the netlist.

module cshell_tb
 import deckcpu_pkg::*;
 #(parameter int W = 32);

    logic clk = 1'b0;
    always #5 clk = ~clk;

    logic rst = 1'b1;
    int   fail = 0;

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
    logic        uart_re, uart_we, timer_re, timer_we, gpio_re, gpio_we, spi_re, spi_we;
    logic [3:0]  uart_be, timer_be, gpio_be, spi_be;
    logic [11:0] uart_addr, timer_addr, gpio_addr, spi_addr;
    logic [W-1:0] uart_wdata, timer_wdata, gpio_wdata, spi_wdata;
    logic [W-1:0] uart_rdata, timer_rdata, gpio_rdata, spi_rdata;
    logic        irq_uart_rx, irq_uart_tx, irq_timer, irq_gpio;
    logic        bus_irq_uart_rx, bus_irq_uart_tx, bus_irq_timer, bus_irq_gpio, bus_irq_spi;
    logic        irq_en;

    logic [7:0]  tx_char;
    logic        tx_valid;
    logic [7:0]  rx_byte = '0;
    logic        rx_push = 1'b0;
    logic [31:0] gpio_out;

    state_t      dbg_state;
    logic [W-1:0] dbg_pc, dbg_cycle;
    logic         dbg_halted;

    // ---- captured TX stream ----
    logic [7:0]  caps [0:8191];
    int          cap_n = 0;
    always @(posedge clk)
        if (tx_valid) begin
            if (cap_n < 8191) begin
                caps[cap_n] <= tx_char;
                cap_n       <= cap_n + 1;
            end
        end

    logic [W-1:0] PW [0:8191];
`include "cdecko_cshell_words.svh"

    // ---- mailbox: the program's exit code lands at 0x0000DF00 ----
    logic [W-1:0] mailbox = '0;
    always @(posedge clk)
        if (rst) mailbox <= '0;
        else if (bus_we && bus_addr == 32'h0000DF00)
            mailbox <= bus_wdata;

    cpu #(.W(W), .NREG(16)) core (
        .clk(clk), .rst(rst),
        .bus_re(bus_re), .bus_we(bus_we), .bus_addr(bus_addr),
        .bus_sz(bus_sz), .bus_wdata(bus_wdata), .bus_rdata(bus_rdata),
        .bus_err(bus_err),
        .irq_req(1'b0), .irq_vec(3'd0), .irq_ack(), .irq_en(irq_en),
        .dbg_state(dbg_state), .dbg_pc(dbg_pc), .dbg_regs(), .dbg_ir(),
        .dbg_opcode(), .dbg_rd(), .dbg_rs1(), .dbg_rs2(),
        .dbg_alu_a(), .dbg_alu_b(), .dbg_alu_y(),
        .dbg_sp(), .dbg_flags(), .dbg_mem_addr(), .dbg_mem_re(), .dbg_mem_we(),
        .dbg_mem_wdata(), .dbg_mem_rdata(), .dbg_done(), .dbg_cycle(dbg_cycle),
        .dbg_halted(dbg_halted)
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
        .gpio_irq(irq_gpio), .spi_irq(1'b0),
        .irq_uart_rx(bus_irq_uart_rx), .irq_uart_tx(bus_irq_uart_tx),
        .irq_timer(bus_irq_timer), .irq_gpio(bus_irq_gpio), .irq_spi(bus_irq_spi)
    );

    ram #(.AW(RAM_AW)) u_ram (
        .clk(clk), .rst(rst), .re(ram_re), .we(ram_we), .be(ram_be), .addr(ram_addr),
        .wdata(ram_wdata), .rdata(ram_rdata),
        .boot_we(boot_we), .boot_addr(boot_addr), .boot_data(boot_data)
    );

    uart #(.W(W)) u_uart (
        .clk(clk), .rst(rst),
        .re(uart_re), .we(uart_we), .be(uart_be), .addr(uart_addr),
        .wdata(uart_wdata), .rdata(uart_rdata),
        .tx_char(tx_char), .tx_valid(tx_valid), .tx_busy(),
        .rx_byte(rx_byte), .rx_push(rx_push),
        .irq_rx(irq_uart_rx), .irq_tx(irq_uart_tx)
    );

    timer #(.W(W)) u_timer (
        .clk(clk), .rst(rst),
        .re(timer_re), .we(timer_we), .be(timer_be), .addr(timer_addr),
        .wdata(timer_wdata), .rdata(timer_rdata),
        .irq(irq_timer)
    );

    gpio #(.W(W)) u_gpio (
        .clk(clk), .rst(rst),
        .re(gpio_re), .we(gpio_we), .be(gpio_be), .addr(gpio_addr),
        .wdata(gpio_wdata), .rdata(gpio_rdata),
        .gpio_in(32'd0), .gpio_out(gpio_out),
        .irq(irq_gpio)
    );

    assign spi_rdata = '0;

    // ---- helpers ----
    task check(input int tag, input [W-1:0] got, input [W-1:0] exp);
        begin
            if (got !== exp) begin
                fail = fail + 1;
                $display("FAIL[%0d]: got=%h exp=%h", tag, got, exp);
            end
        end
    endtask : check

    function automatic int find_seek(int from, string needle);
        int n, i;
        automatic bit found = 1'b0;
        n = needle.len();
        if (from < 0) from = 0;
        for (i = from; n > 0 && i + n <= cap_n; i++) begin
            found = 1'b1;
            for (int j = 0; j < n; j++)
                if (caps[i + j] != needle[j])
                    found = 1'b0;
            if (found) return i;
        end
        return -1;
    endfunction : find_seek

    int scan = 0;
    task automatic find_next(int tag, string needle);
        int p;
        p = find_seek(scan, needle);
        if (p < 0) begin
            fail = fail + 1;
            $display("FAIL[seq%0d]: bytes %0d..%0d lack '%s'", tag, scan, cap_n - 1, needle);
        end else
            scan = p + needle.len();
    endtask : find_next

    task automatic wait_cycles(int n);
        repeat (n) @(posedge clk);
    endtask : wait_cycles

    // RX pacing cursor (echo/prompt position); independent of `scan`.
    int mark = 0;

    // RX pacing: the console echoes a typed byte via putchar (single-latch
    // RX), so we only push the next byte after that echo landed in caps. The
    // echo always lands at the current end of the capture buffer (past the
    // prompt/reply bytes), so capture tgt = cap_n before pushing and wait for
    // cap_n to grow.
    task automatic push_raw(input [7:0] b);
        begin
            rx_byte = b;
            rx_push = 1'b1;
            repeat (4) @(posedge clk);
            rx_push = 1'b0;
        end
    endtask : push_raw

    task automatic push_byte(input [7:0] b);
        int tgt;
        int tries;
        begin
            tgt = cap_n;
            push_raw(b);
            tries = 0;
            while (tries < 200000 && cap_n <= tgt) begin
                @(posedge clk);
                tries++;
            end
            if (tries >= 200000) begin
                fail = fail + 1;
                $display("FAIL[rx]: no echo within 200k cycles (want %02x, cap_n=%0d)", b, cap_n);
            end else
                mark = cap_n;        // the echoed byte now sits in caps
        end
    endtask : push_byte

    // Push an entire line's bytes (echo-gated) then, if a reply prompt is
    // expected, wait for the next fresh "deckc> " prompt; otherwise wait for
    // the final HALT (the `exit` line).
    task automatic send_line(string line, bit expect_prompt);
        int i;
        int guard;
        begin
            for (i = 0; i < line.len(); i++)
                push_byte(line[i]);
            push_raw(8'h0D);       // CR: ends read_line (not echoed)
            if (expect_prompt) begin
                guard = 0;
                while (find_seek(mark, "deckc> ") < 0 && !dbg_halted && guard < 1000000) begin
                    @(posedge clk);
                    guard++;
                end
                if (dbg_halted || guard >= 1000000) begin
                    fail = fail + 1;
                    $display("FAIL[rx]: no prompt after CR (halted=%0d, guard=%0d)", dbg_halted, guard);
                end else
                    mark = cap_n;
            end else begin
                guard = 0;
                while (!dbg_halted && guard < 1000000) begin
                    @(posedge clk);
                    guard++;
                end
                if (!dbg_halted) begin
                    fail = fail + 1;
                    $display("FAIL[rx]: machine did not halt after 'exit'");
                end
            end
        end
    endtask : send_line

    initial begin
        integer guard;
        guard = 0;
        boot_we = 0; boot_addr = 0; boot_data = 0;
        repeat (2) @(posedge clk);
        boot_we = 1'b1;
        for (int w = 0; w < CDECKO_CSHELL_NWORDS; w++) begin
            boot_addr = w * 4;
            boot_data = PW[w];
            @(posedge clk);
        end
        boot_we = 1'b0;
        rst = 1'b0;

        // banner, then the first prompt
        guard = 0;
        while (find_seek(0, "deckc> ") < 0 && !dbg_halted && guard < 5000000) begin
            @(posedge clk);
            guard++;
        end
        if (find_seek(0, "deckc> ") < 0) begin
            fail = fail + 1;
            $display("FAIL[boot]: no first prompt (halted=%0d, cap_n=%0d, guard=%0d)", dbg_halted, cap_n, guard);
        end
        mark = find_seek(0, "deckc> ") + 7;

        send_line("help", 1);
        send_line("echo hello world", 1);
        send_line("time", 1);
        send_line("calc 6 * 7", 1);
        send_line("calc 2 + 3", 1);
        send_line("poke f100 cafebeef", 1);
        send_line("peek f100", 1);
        send_line("gpio 0 1", 1);
        send_line("gpio 2 0", 1);
        send_line("clear", 1);

        // final line: exit (no prompt follows)
        send_line("exit", 0);

        guard = 0;
        while (!dbg_halted && guard < 1000000) begin
            @(posedge clk);
            guard++;
        end
        if (!dbg_halted) begin
            fail = fail + 1;
            $display("FAIL: did not halt within 1000000 cycles (cap_n=%0d)", cap_n);
        end
        wait_cycles(10);

        scan = 0;
        check(0, mailbox, 32'h00000000);
        check(1, gpio_out & 32'h1, 32'h1);      // gpio 0 -> 1
        check(2, gpio_out & 32'h4, 32'h0);      // gpio 2 -> 0

        // ---- ordered transcript ----
        find_next(10, "deckc/1.0 DeckCPU console");
        find_next(11, "commands: help echo time gpio peek poke calc clear exit");
        find_next(12, "hello world");
        find_next(13, "t=");
        find_next(14, "0000002a");
        find_next(15, "00000005");
        find_next(16, "cafebeef");
        find_next(17, "cafebeef");              // poke read-back + peek
        find_next(18, "gpio 0 -> 1");
        find_next(19, "gpio 2 -> 0");
        find_next(20, "syslog cleared");
        find_next(21, "bye");

        if (fail == 0)
            $display("cshell_tb: PASS (mailbox=%h, gpio_out=%h, %0d captured chars)",
                     mailbox, gpio_out, cap_n);
        else begin
            $display("cshell_tb: %0d assertion(s) FAILED (mailbox=%h, gpio_out=%h, %0d chars)",
                     fail, mailbox, gpio_out, cap_n);
            for (int i = 0; i < cap_n; i++) begin
                if (caps[i] >= 32 && caps[i] < 127) $write("%c", caps[i]);
                else if (caps[i] == 13) $write("<CR>");
                else if (caps[i] == 10) $write("<LF>");
                else $write("<%02x>", caps[i]);
            end
            $write("\n");
        end
        $finish;
    end

endmodule : cshell_tb