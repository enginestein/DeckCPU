// DeckC CIOS testbench: boots the deckc-compiled image (cdecko_cios_words.svh,
// built by tools/gen_cios_image.py) and checks the syslog UART transcript:
// 5 ring-log entries with real TIMER timestamps, then a full clear + 'log
// empty' run. Every byte the interpreter predicted must arrive in order, and
// the exit code must land in the mailbox at 0x0000DF00 the proof the
// toolchain output runs on the netlist.
//
// Timestamp VALUES aren't asserted (UART TX_BUSY polling adds cycles on the
// RTL vs the interpreter's zero-wait UART), only their shape. Escapes are
// built with %c so iverilog never sees \x1b in a string literal.

module deckos_c_tb
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
`include "cdecko_cios_words.svh"

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
        .dbg_state(dbg_state), .dbg_pc(dbg_pc), .dbg_regs(), .dbg_ir(dbg_ir),
        .dbg_opcode(dbg_opcode), .dbg_rd(), .dbg_rs1(), .dbg_rs2(),
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

    function automatic string esc(string s);
        return $sformatf("%c%s", 8'h1B, s);
    endfunction : esc

    // Advance the ordered-transcript cursor past <needle>, failing if missing.
    int mark = 0;
    task automatic find_next(int tag, string needle);
        int p;
        p = find_seek(mark, needle);
        if (p < 0) begin
            fail = fail + 1;
            $display("FAIL[seq%0d]: bytes %0d..%0d lack '%s'", tag, mark, cap_n - 1, needle);
        end else
            mark = p + needle.len();
    endtask : find_next

    // Assert the timestamp the cursor currently sits on (just after the entry's
    // leading color escape + '[') is <space><digits>.<digits>, with a nonzero
    // value (the free-running TIMER has long since advanced past 0), then leave
    // the cursor past the closing ']'.
    task automatic check_ts(int tag);
        int q;
        automatic int any = 0, dot = 0;
        q = mark;
        while (q < cap_n && caps[q] != "]") begin
            if (caps[q] >= "0" && caps[q] <= "9") begin
                if (caps[q] != "0") any = 1;
            end else if (caps[q] == ".") begin
                dot = 1;
            end else if (caps[q] != " ") begin
                fail = fail + 1;
                $display("FAIL[ts%0d]: bad char %02x inside timestamp at %0d", tag, caps[q], q);
            end
            q++;
        end
        if (q >= cap_n || caps[q] != "]") begin
            fail = fail + 1;
            $display("FAIL[ts%0d]: no ']' closing timestamp (q=%0d cap_n=%0d)", tag, q, cap_n);
        end else if (!dot || !any) begin
            fail = fail + 1;
            $display("FAIL[ts%0d]: timestamp has no nonzero value (dot=%0d any=%0d)", tag, dot, any);
        end
        mark = q + 1;
    endtask : check_ts

    task automatic wait_cycles(int n);
        repeat (n) @(posedge clk);
    endtask : wait_cycles

    initial begin
        integer guard;
        guard = 0;
        boot_we = 0; boot_addr = 0; boot_data = 0;
        repeat (2) @(posedge clk);
        boot_we = 1'b1;
        for (int w = 0; w < CDECKO_CIOS_NWORDS; w++) begin
            boot_addr = w * 4;
            boot_data = PW[w];
            @(posedge clk);
        end
        boot_we = 1'b0;
        rst = 1'b0;

        // ---- run to the final HALT (guard against runaway images) ----
        while (!dbg_halted && guard < 500000) begin
            @(posedge clk);
            guard++;
            if (cap_n > 4090) begin
                fail = fail + 1;
                $display("FAIL: TX stream overran capture buffer");
                guard = 500000;
            end
        end
        if (!dbg_halted) begin
            fail = fail + 1;
            $display("FAIL: did not halt within 500000 cycles (cap_n=%0d)", cap_n);
        end
        wait_cycles(10);
        check(0, mailbox, 32'h00000005);

        // ---- transcript structure, strictly ordered ----
        // 5 color-coded ring-log entries with real timestamps, then the clear.
        // Each entry's cursor walk: color escape + '[' -> timestamp -> ']' ->
        // level/tag -> message. The per-line trailing ESC[0m<NUL> is skipped
        // because its needle ("[0m" + LF) never contains "[0m[".
        find_next(1, esc("[0m["));           // INF is the default level color
        check_ts(2);
        find_next(3, "[INF] [syslog ");
        find_next(4, "ring log ready (64 slots)");

        find_next(5, esc("[90m["));
        check_ts(6);
        find_next(7, "[DBG] [deckc ");
        find_next(8, "boot complete");

        find_next(9, esc("[33m["));
        check_ts(10);
        find_next(11, "[WRN] [deckc ");
        find_next(12, "brownout detected");

        find_next(13, esc("[31m["));
        check_ts(14);
        find_next(15, "[ERR] [deckc ");
        find_next(16, "allocation failed");

        find_next(17, esc("[0m["));          // scanning INF entry
        check_ts(18);
        find_next(19, "[INF] [deckc ");
        find_next(20, "scan started");

        find_next(21, "syslog cleared");
        find_next(22, "5 total entries discarded");
        find_next(23, "(log empty)");

        if (fail == 0)
            $display("deckos_c_tb: PASS (mailbox=%h, %0d captured chars)", mailbox, cap_n);
        else begin
            $display("deckos_c_tb: %0d assertion(s) FAILED (mailbox=%h, %0d captured chars)",
                     fail, mailbox, cap_n);
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

endmodule : deckos_c_tb