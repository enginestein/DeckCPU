// DeckOS-on-DeckCPU testbench.
//
// Boots the DeckOS console program (sim/programs/deckos_console_words.svh,
// a 531-word image assembled from deckos-port/deckcpu/console.s), then acts
// as the host terminal: it pushes bytes into the UART's host-console source
// (rx_push/rx_byte) and captures the TX side (tx_valid/tx_char), asserting
// on the shell's responses (help/about/echo/time/gpio plus the peek/poke/
// calc/sleep/exec command set) and on the GPIO side effect of `gpio`.
//
// This is the RTL-level proof that the hand-assembled DeckOS HAL + polled
// shell communicate with the DeckCPU MMIO devices (UART/TIMER/GPIO), and
// that the shell can poke/read RAM and execute poked-in code (a stored-
// program machine) — i.e. that the DeckCPU netlist can host the DeckOS
// console port.
//
// No interrupts are involved: the console is polled (hal_console_getchar).
//
// The console's RX path is a single latch (a push into a still-unread slot
// silently replaces it), and commands like `sleep` pause output for long busy
// waits, so before pushing each line the testbench waits for the previous
// line's fresh "DeckOS> " prompt and for the UART TX to go quiet.

module deckos_tb
 import deckcpu_pkg::*;
 #(parameter int W = 32);

    logic clk = 1'b0;
    always #5 clk = ~clk;

    logic rst = 1'b1;
    int   fail = 0;
    localparam int PACE = 250;

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

    // console host terminal
    logic [7:0]  tx_char;
    logic        tx_valid;
    logic [7:0]  rx_byte = '0;
    logic        rx_push = 1'b0;
    logic [31:0] gpio_out;

    state_t      dbg_state;
    logic [W-1:0] dbg_pc;
    logic [W-1:0] dbg_cycle;
    logic [W-1:0] dbg_ir;
    logic         dbg_halted;
    logic [7:0]   dbg_opcode;

    // ---- captured TX stream ----
    logic [7:0]  caps [0:4095];
    int          cap_n = 0;
    always @(posedge clk)
        if (tx_valid) begin
            caps[cap_n] <= tx_char;
            cap_n       <= cap_n + 1;
        end

    logic [W-1:0] PW [0:4095];
`include "deckos_console_words.svh"

    cpu #(.W(W), .NREG(16)) core (
        .clk(clk), .rst(rst),
        .bus_re(bus_re), .bus_we(bus_we), .bus_addr(bus_addr),
        .bus_sz(bus_sz), .bus_wdata(bus_wdata), .bus_rdata(bus_rdata),
        .bus_err(bus_err),
        .irq_req(1'b0), .irq_vec(3'd0), .irq_ack(), .irq_en(irq_en),
        .dbg_state(dbg_state), .dbg_pc(dbg_pc), .dbg_regs(), .dbg_ir(dbg_ir),
        .dbg_opcode(dbg_opcode), .dbg_rd(), .dbg_rs1(), .dbg_rs2(),
        .dbg_alu_a(), .dbg_alu_b(), .dbg_alu_y(),
        .dbg_sp(), .dbg_flags(dbg_flags), .dbg_mem_addr(), .dbg_mem_re(), .dbg_mem_we(),
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

    task automatic check_seq(int tag, int mark, string needle);
        if (find_seek(mark, needle) < 0) begin
            fail = fail + 1;
            $display("FAIL[seq%0d]: bytes %0d..%0d lack '%s'", tag, mark, cap_n - 1, needle);
        end
    endtask : check_seq

    function automatic int is_hex(int c);
        return (c >= "0" && c <= "9") || (c >= "a" && c <= "f");
    endfunction : is_hex

    // `time` printed "t=" + 8 hex digits; require the digits to be present
    // and not all-zero (the free-running TIMER has advanced past 0 by then).
    task automatic check_time(int tag, int mark);
        int p;
        p = find_seek(mark, "t=");
        if (p < 0) begin
            fail = fail + 1;
            $display("FAIL[time%0d]: no 't=' in bytes %0d..%0d", tag, mark, cap_n - 1);
        end else begin
            automatic int any = 0;
            for (int j = 0; j < 8; j++) begin
                if (!is_hex(caps[p + 2 + j])) begin
                    fail = fail + 1;
                    $display("FAIL[time%0d]: non-hex digit at +%0d", tag, j);
                end
                if (caps[p + 2 + j] != "0") any = 1;
            end
            if (!any) begin
                fail = fail + 1;
                $display("FAIL[time%0d]: printed 0x00000000", tag);
            end
        end
    endtask : check_time

    // Assert that <prefix> is followed by 8 hex digits, at least one nonzero.
    task automatic check_hexsuffix(int tag, int mark, string prefix);
        int p, n, any;
        automatic bit cut = 1'b0;
        p = find_seek(mark, prefix);
        if (p < 0) begin
            fail = fail + 1;
            $display("FAIL[hexs%0d]: bytes %0d..%0d lack '%s'", tag, mark, cap_n - 1, prefix);
        end else begin
            n = prefix.len();
            any = 0;
            for (int j = 0; j < 8 && !cut; j++) begin
                if (p + n + j >= cap_n) begin
                    fail = fail + 1;
                    $display("FAIL[hexs%0d]: hex truncated at +%0d", tag, j);
                    cut = 1'b1;
                end else begin
                    if (!is_hex(caps[p + n + j])) begin
                        fail = fail + 1;
                        $display("FAIL[hexs%0d]: non-hex digit at +%0d", tag, j);
                    end
                    if (caps[p + n + j] != "0") any = 1;
                end
            end
            if (!cut && !any) begin
                fail = fail + 1;
                $display("FAIL[hexs%0d]: printed all-zero", tag);
            end
        end
    endtask : check_hexsuffix

    task automatic push_byte(byte b);
        @(posedge clk);                 // advance clear of any pending edge
        rx_byte = b;
        rx_push = 1'b1;
        @(posedge clk);                 // UART latches push=1 at THIS edge
        rx_push = 1'b0;
        repeat (PACE) @(posedge clk);
    endtask : push_byte

    // iverilog does not process \r escapes inside string literals, so command
    // lines are pushed as their printable ASCII followed by an explicit CR.
    task automatic wait_tx_idle();
        begin : drain
            int gap;
            gap = 0;
            while (gap < 60) begin
                @(posedge clk);
                if (tx_valid) gap = 0; else gap = gap + 1;
            end
        end
    endtask : wait_tx_idle

    // push a command line only once the console is ready for it: the previous
    // command's fresh "DeckOS> " prompt must have appeared and the UART gone
    // quiet. Commands that busy-wait (e.g. `sleep`) have long no-TX stretches,
    // so TX-idle alone is not enough -- typing into a console that has not yet
    // returned to its poll loop silently drops bytes (single-latch RX).
    int prev_mark = 0;
    task automatic push_line(string s);
        begin : ready
            int p;
            p = find_seek(prev_mark, "DeckOS> ");
            while (p < 0) begin
                @(posedge clk);
                p = find_seek(prev_mark, "DeckOS> ");
            end
            wait_tx_idle();
            prev_mark = cap_n;
        end
        for (int i = 0; i < s.len(); i++)
            push_byte(s[i]);
        push_byte(8'h0D);
    endtask : push_line

    task automatic wait_cycles(int n);
        repeat (n) @(posedge clk);
    endtask : wait_cycles

    // ---- stimulus ----
    int mark;
    initial begin
        boot_we = 0; boot_addr = 0; boot_data = 0;
        repeat (2) @(posedge clk);
        boot_we = 1'b1;
        for (int w = 0; w < DECKOS_CONSOLE_NWORDS; w++) begin
            boot_addr = w * 4;
            boot_data = PW[w];
            @(posedge clk);
        end
        boot_we = 1'b0;
        rst = 1'b0;

        // ---- warm-up: banner + first prompt ----
        wait_cycles(5000);
        check_seq(1, 0, "DeckOS/1.0 DeckCPU console");
        check_seq(2, 0, "DeckOS> ");

        // ---- help ----
        mark = cap_n;
        push_line("help");
        wait_cycles(4000);
        check_seq(3, mark, "commands: help about echo time gpio");

        // ---- about ----
        mark = cap_n;
        push_line("about");
        wait_cycles(3000);
        check_seq(4, mark, "DeckOS/1.0 DeckCPU console");

        // ---- echo one two  (assert "one two" is followed by CR LF and then
        //      a fresh prompt; the typed echo already reprints the line, so
        //      check the byte sequence after ANY "one two" match) ----
        mark = cap_n;
        push_line("echo one two");
        wait_cycles(3000);
        begin : chk_echo
            int q;
            q = find_seek(mark, "one two");
            if (q < 0) begin
                fail = fail + 1;
                $display("FAIL[seq5]: no 'one two' in bytes %0d..%0d", mark, cap_n - 1);
            end else begin
                if (!(q + 8 <= cap_n && caps[q + 7] == 8'h0D && caps[q + 8] == 8'h0A)) begin
                    fail = fail + 1;
                    $display("FAIL[seq5]: 'one two' not followed by CR LF at %0d", q);
                end
                if (find_seek(mark, "DeckOS> ") < 0) begin
                    fail = fail + 1;
                    $display("FAIL[seq5]: no fresh prompt after echo");
                end
            end
        end

        // ---- time  (t=<8 hex digits>, value nonzero) ----
        mark = cap_n;
        push_line("time");
        wait_cycles(3000);
        check_time(6, mark);

        // ---- gpio 0 1  (OUT bit 0 on the real GPIO device) ----
        mark = cap_n;
        push_line("gpio 0 1");
        wait_cycles(3000);
        check_seq(7, mark, "gpio 00 -> 1");
        check(80, {31'b0, gpio_out[0]}, 32'h1);
        check(81, {31'b0, gpio_out[1]}, 32'h0);

        // ---- gpio 3 1 (a second pin) ----
        mark = cap_n;
        push_line("gpio 3 1");
        wait_cycles(3000);
        check_seq(8, mark, "gpio 03 -> 1");
        check(82, {31'b0, gpio_out[3]}, 32'h1);
        check(83, {31'b0, gpio_out[0]}, 32'h1);   // bit 0 stays set

        // ---- unknown command ----
        mark = cap_n;
        push_line("foobar");
        wait_cycles(3000);
        check_seq(9, mark, "Unknown command: foobar");

        // ---- poke / peek: word store + read-back in RAM (poke echoes value).
        //     0xF100 is scratch RAM clear of the program image (ends at 0x83C)
        //     and clear of the stack (0xFFF8 down), so it is safe to poke. ----
        mark = cap_n;
        push_line("poke f100 cafebeef");
        wait_cycles(3000);
        check_seq(10, mark, "cafebeef");
        mark = cap_n;
        push_line("peek f100");
        wait_cycles(3000);
        check_seq(11, mark, "cafebeef");

        // ---- calc: ALU arithmetic, result printed as hex ----
        mark = cap_n;
        push_line("calc 6 * 7");
        wait_cycles(3000);
        check_seq(12, mark, "0000002a");
        mark = cap_n;
        push_line("calc 40 + 2");
        wait_cycles(3000);
        check_seq(13, mark, "0000002a");
        mark = cap_n;
        push_line("calc 100 - 1");
        wait_cycles(3000);
        check_seq(14, mark, "00000063");

        // ---- sleep: busy-wait and report the measured elapsed ticks ----
        mark = cap_n;
        push_line("sleep 1000");
        wait_cycles(8000);
        check_seq(15, mark, "slept 0x");
        check_hexsuffix(16, mark, "slept 0x");

        // ---- exec: run position-independent code poked into RAM ----
        // The 4-word snippet at 0xF000 is:
        //   LI r6,0xE000 ; LI r7,0x63 ; ST r7,r6,0 ; RET
        // (encodings 2060e000 20700063 34760000 42000000) and writes 0x63 to
        // 0xE000 -- a stored-program proof for the DeckOS idea.
        mark = cap_n;
        push_line("poke f000 2060e000");
        wait_cycles(2500);
        check_seq(17, mark, "2060e000");
        mark = cap_n;
        push_line("poke f004 20700063");
        wait_cycles(2500);
        check_seq(18, mark, "20700063");
        mark = cap_n;
        push_line("poke f008 34760000");
        wait_cycles(2500);
        check_seq(19, mark, "34760000");
        mark = cap_n;
        push_line("poke f00c 42000000");
        wait_cycles(2500);
        check_seq(20, mark, "42000000");

        mark = cap_n;
        push_line("exec f000");
        wait_cycles(3500);
        check_seq(21, mark, "ran");

        mark = cap_n;
        push_line("peek e000");
        wait_cycles(2500);
        check_seq(22, mark, "00000063");

        // ---- console is still alive at a fresh prompt ----
        check_seq(23, cap_n - 256, "DeckOS> ");

        if (fail == 0)
            $display("deckos_tb: PASS (%0d captured chars)", cap_n);
        else begin
            $display("deckos_tb: %0d assertion(s) FAILED (%0d captured chars)", fail, cap_n);
            for (int i = 0; i < cap_n && i < 200; i++)
                $write("%c", caps[i]);
            $write("\n==== TRANSCRIPT DUMP ====\n");
            for (int i = 0; i < cap_n; i++) begin
                if (caps[i] >= 32 && caps[i] < 127) $write("%c", caps[i]);
                else if (caps[i] == 13) $write("<CR>");
                else if (caps[i] == 10) $write("<LF>");
                else if (caps[i] == 8) $write("<BS>");
                else $write("<%02x>", caps[i]);
            end
            $write("\n");
        end
        $finish;
    end

endmodule : deckos_tb