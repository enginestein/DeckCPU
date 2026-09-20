// DeckOS-on-DeckCPU interactive terminal testbench.
//
// The transport behind `make run-deckos`: boots the DeckOS console image,
// forwards every UART TX byte to the host and feeds a named pipe (+rx=<fifo>)
// into the UART RX path. The CPU, bus, RAM and DeckOS program do all the
// work; this module is only the wire between UART and host.
//
// Two iverilog realities shape it: $fgetc blocks the whole simulation, so the
// machine only ever freezes on a byte boundary when the shell has nothing
// left to emit (wait for the fresh prompt / HALT after a CR); and there is no
// non-blocking read, so input stays character-at-a-time and we never push
// while the previous byte sits unread in the single latch (the bus RXD read
// is the "consumed" signal).
//
// Shutdown is clean on three paths: host EOF, Control-C, and `exit` (HALT).

module deckos_term_tb
 import deckcpu_pkg::*;
 #(parameter int W = 32);

    logic clk = 1'b0;
    always #5 clk = ~clk;

    logic rst = 1'b1;

    // ---- nets (same connected DUT as deckos_tb: cpu + bus + ram + peripherals)
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

    // terminal transport
    logic [7:0]  tx_char;
    logic        tx_valid;
    logic [7:0]  rx_byte = '0;
    logic        rx_push = 1'b0;
    logic [31:0] gpio_out;

    logic        dbg_halted;

    // ---- TX: every console byte straight to stdout, flushed so the host
    //      terminal renders it immediately (O_NONBLOCK pipe on the host side).
    localparam int TX_OFF  = 12'h000;      // UART TXD  (not needed here)
    localparam int RXD_OFF = 12'h004;      // UART RXD  (read clears RX_READY)
    localparam int STS_OFF = 12'h008;      // UART STS

    always @(posedge clk)
        if (tx_valid) begin
            $fwrite(1, "%c", tx_char);
            $fflush(1);
        end

    // ---- captured TX stream (used to gate on the shell's fresh prompt) ----
    logic [7:0]  caps [0:65535];
    int          cap_n = 0;
    always @(posedge clk)
        if (tx_valid && cap_n < 65536)
            caps[cap_n] <= tx_char;

    always @(posedge clk)
        if (tx_valid && cap_n < 65536)
            cap_n <= cap_n + 1;

    // ---- RX "consumed" tracking: the shell reads RXD (a bus read of the
    //      UART RXD register) once per byte; until then the byte is still in
    //      the single latch and must not be overwritten.
    logic rxd_busy = 1'b0;
    always @(posedge clk)
        if (rx_push)                    rxd_busy <= 1'b1;
        else if (uart_sel && uart_re && uart_addr == RXD_OFF) rxd_busy <= 1'b0;

    logic [W-1:0] PW [0:4095];
`include "deckos_console_words.svh"

    cpu #(.W(W), .NREG(16)) core (
        .clk(clk), .rst(rst),
        .bus_re(bus_re), .bus_we(bus_we), .bus_addr(bus_addr),
        .bus_sz(bus_sz), .bus_wdata(bus_wdata), .bus_rdata(bus_rdata),
        .bus_err(bus_err),
        .irq_req(1'b0), .irq_vec(3'd0), .irq_ack(), .irq_en(irq_en),
        .dbg_state(), .dbg_pc(), .dbg_regs(), .dbg_ir(),
        .dbg_opcode(), .dbg_rd(), .dbg_rs1(), .dbg_rs2(),
        .dbg_alu_a(), .dbg_alu_b(), .dbg_alu_y(),
        .dbg_sp(), .dbg_flags(), .dbg_mem_addr(), .dbg_mem_re(), .dbg_mem_we(),
        .dbg_mem_wdata(), .dbg_mem_rdata(), .dbg_done(), .dbg_cycle(),
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
    function automatic int find_seek(int from, string needle);
        int n, i;
        automatic bit found = 1'b0;
        n = needle.len();
        if (from < 0) from = 0;
        for (i = from; n > 0 && i < cap_n; i++) begin
            found = 1'b1;
            for (int j = 0; j < n; j++)
                if (cap_n <= i + j || caps[i + j] != needle[j])
                    found = 1'b0;
            if (found) return i;
        end
        return -1;
    endfunction : find_seek

    task automatic wait_tx_idle();
        begin : drain
            int gap;
            gap = 0;
            while (gap < 30) begin
                @(posedge clk);
                if (tx_valid) gap = 0; else gap = gap + 1;
            end
        end
    endtask : wait_tx_idle

    // byte consumed by the shell (RXD read observed).
    task automatic wait_consumed();
        while (rxd_busy) @(posedge clk);
    endtask : wait_consumed

    int push_mark = 0;

    // Push one host byte into the UART RX path without ever overwriting an
    // unread latch, then let the machine act on it and go quiet again:
    //   - the byte must first be consumed (shell read RXD);
    //   - a CR triggers line_enter; wait for the fresh prompt / HALT so the
    //     full response is rendered before the simulation can freeze;
    //   - any other byte only echoes, so wait briefly for its echo to drain.
    task automatic push_byte(input byte b);
        begin : pb
            while (rxd_busy) @(posedge clk);
            @(posedge clk);
            rx_byte = b;
            rx_push = 1'b1;
            @(posedge clk);
            rx_push = 1'b0;
            @(posedge clk);
            wait_consumed();
            if (b == 8'h0D) begin
                while (find_seek(push_mark, "DeckOS> ") < 0 && !dbg_halted)
                    @(posedge clk);
                if (dbg_halted) begin
                    $display("[deckos_term] shell HALTed ('exit') -> shutting down");
                    $finish;
                end
            end else
                wait_tx_idle();
            push_mark = cap_n;
        end
    endtask : push_byte

    // ---- boot: load the image through the RAM write port (as deckos_tb) ----
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
        $display("[deckos_term] DeckCPU image loaded (%0d words); terminal attached.",
                 DECKOS_CONSOLE_NWORDS);
        $display("[deckos_term] type commands; Ctrl-C / host EOF / `exit` to quit.");
        $fflush(1);
    end

    // ---- terminal transport ----
    initial begin
        int fd;
        int c;
        string fifo;
        if (!$value$plusargs("rx=%s", fifo)) begin
            $display("[deckos_term] FATAL: +rx=<fifo> plusarg required");
            $finish;
        end
        fd = $fopen(fifo, "rb");
        if (fd == 0) begin
            $display("[deckos_term] FATAL: cannot open RX fifo %s", fifo);
            $finish;
        end
        // Wait for the machine to finish booting (reset released, first prompt
        // transmitted). Bytes pushed while the UART is still in reset are
        // discarded, which would leave rxd_busy waiting forever for a consume
        // that never comes.
        while (find_seek(0, "DeckOS> ") < 0) @(posedge clk);
        push_mark = cap_n;
        forever begin
            c = $fgetc(fd);
            if ($feof(fd) || c == 32'hFFFFFFFF) begin
                $display("[deckos_term] host closed the terminal -> shutting down");
                $finish;
            end
            if (c == 8'h03) begin                      // Control-C (belt & braces)
                $display("[deckos_term] Control-C -> shutting down");
                $finish;
            end
            if (c == 8'h0A) c = 8'h0D;                 // map LF -> CR (robust hosts)
            push_byte(c[7:0]);
        end
    end

`ifdef DUMPVCD
    initial begin
        $dumpfile("build/sim/deckos_term.vcd");
        // Scoped to the transport + UART + fetch/halt state (a whole-hierarchy
        // dump is ~750 MB per short session; this keeps observability usable).
        $dumpvars(0, deckos_term_tb.tx_char, deckos_term_tb.tx_valid,
                    deckos_term_tb.rx_byte, deckos_term_tb.rx_push,
                    deckos_term_tb.dbg_halted, deckos_term_tb.u_uart.tx_byte_q,
                    deckos_term_tb.u_uart.tx_ready_q, deckos_term_tb.u_uart.tx_pend_q,
                    deckos_term_tb.u_uart.rx_latch_q, deckos_term_tb.u_uart.rx_ready_q,
                    deckos_term_tb.core.pc, deckos_term_tb.core.halted);
        $display("[deckos_term] VCD dump enabled -> build/sim/deckos_term.vcd");
    end
`endif

endmodule : deckos_term_tb