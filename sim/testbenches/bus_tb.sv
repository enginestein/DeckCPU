module bus_tb
 import deckcpu_pkg::*;
 #(parameter int W = 32);

    logic clk = 1'b0;
    always #5 clk = ~clk;

    logic         rst = 1'b1;
    logic         m_re, m_we;
    mem_sz_t      m_sz;
    logic [W-1:0] m_addr, m_wdata, m_rdata;
    logic         m_err;
    logic [3:0]   m_be;

    logic         ram_re, ram_we;
    logic [3:0]   ram_be;
    logic [RAM_AW-1:0] ram_addr;
    logic [W-1:0] ram_wdata, ram_rdata;

    logic         uart_sel, timer_sel, gpio_sel, spi_sel;
    logic         boot_we;
    logic [RAM_AW-1:0] boot_addr;
    logic [W-1:0] boot_data;
    int           fail = 0;

    // ---- MMIO slave wiring ----
    logic              uart_re, uart_we, timer_re, timer_we;
    logic              gpio_re, gpio_we, spi_re, spi_we;
    logic [3:0]        uart_be, timer_be, gpio_be, spi_be;
    logic [11:0]       uart_addr, timer_addr, gpio_addr, spi_addr;
    logic [W-1:0]      uart_wdata, timer_wdata, gpio_wdata, spi_wdata;
    logic [W-1:0]      uart_rdata, timer_rdata, gpio_rdata, spi_rdata;
    logic [7:0]        uart_tx_char;
    logic              uart_tx_valid, uart_tx_busy;
    logic [7:0]        uart_rx_byte = 8'h00;
    logic              uart_rx_push = 1'b0;
    logic              uart_irq_rx, uart_irq_tx, timer_irq, gpio_irq, spi_irq;
    logic              irq_uart_rx, irq_uart_tx, irq_timer, irq_gpio, irq_spi;
    logic [31:0]       gpio_in = 32'd0, gpio_out;
    logic [7:0]        spi_in = 8'h5C, spi_out;
    logic              spi_busy;

    bus #(.W(W)) u_bus (
        .clk(clk), .rst(rst),
        .re(m_re), .we(m_we), .sz(m_sz), .addr(m_addr), .wdata(m_wdata),
        .rdata(m_rdata), .err(m_err), .be(m_be),
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
        .uart_irq_rx(uart_irq_rx), .uart_irq_tx(uart_irq_tx),
        .timer_irq(timer_irq), .gpio_irq(gpio_irq), .spi_irq(spi_irq),
        .irq_uart_rx(irq_uart_rx), .irq_uart_tx(irq_uart_tx),
        .irq_timer(irq_timer), .irq_gpio(irq_gpio), .irq_spi(irq_spi)
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
        .tx_char(uart_tx_char), .tx_valid(uart_tx_valid), .tx_busy(uart_tx_busy),
        .rx_byte(uart_rx_byte), .rx_push(uart_rx_push),
        .irq_rx(uart_irq_rx), .irq_tx(uart_irq_tx)
    );

    timer #(.W(W)) u_timer (
        .clk(clk), .rst(rst),
        .re(timer_re), .we(timer_we), .be(timer_be), .addr(timer_addr),
        .wdata(timer_wdata), .rdata(timer_rdata),
        .irq(timer_irq)
    );

    gpio #(.W(W)) u_gpio (
        .clk(clk), .rst(rst),
        .re(gpio_re), .we(gpio_we), .be(gpio_be), .addr(gpio_addr),
        .wdata(gpio_wdata), .rdata(gpio_rdata),
        .gpio_in(gpio_in), .gpio_out(gpio_out),
        .irq(gpio_irq)
    );

    spi #(.W(W)) u_spi (
        .clk(clk), .rst(rst),
        .re(spi_re), .we(spi_we), .be(spi_be), .addr(spi_addr),
        .wdata(spi_wdata), .rdata(spi_rdata),
        .spi_in(spi_in), .spi_out(spi_out),
        .busy(spi_busy),
        .irq(spi_irq)
    );

    task check(input int tag, input [W-1:0] got, input [W-1:0] exp);
        begin
            if (got !== exp) begin
                fail = fail + 1;
                $display("FAIL[%0d]: got=%h exp=%h", tag, got, exp);
            end
        end
    endtask : check

    task ck(input int tag, input bit g, input bit e);
        begin
            if (g !== e) begin
                fail = fail + 1;
                $display("FAIL[%0d]: got=%b exp=%b", tag, g, e);
            end
        end
    endtask : ck

    task issue_m(input bit re_v, input bit we_v, input mem_sz_t sz_v,
                 input [W-1:0] a, input [W-1:0] wd);
        begin
            @(posedge clk);
            m_re = re_v; m_we = we_v; m_sz = sz_v; m_addr = a; m_wdata = wd;
        end
    endtask : issue_m

    initial begin
        m_re = 0; m_we = 0; m_sz = SZ_WORD; m_addr = 0; m_wdata = 0;
        boot_we = 0; boot_addr = 0; boot_data = 0;

        repeat (2) @(posedge clk);
        rst = 1'b0;
        @(posedge clk);

        // ---- byte-enable diamond derivation ----
        issue_m(0, 0, SZ_WORD, 32'h0000, 0);
        @(posedge clk);
        check(0, m_be, 32'hF);
        issue_m(0, 0, SZ_HALF, 32'h0004, 0);
        @(posedge clk);
        check(1, m_be, 32'h3);
        issue_m(0, 0, SZ_HALF, 32'h0006, 0);
        @(posedge clk);
        check(2, m_be, 32'hC);
        for (int k = 0; k < 4; k++) begin
            issue_m(0, 0, SZ_BYTE, 32'h10 + k, 0);
            @(posedge clk);
            check(3 + k, m_be, (W'(1) << k));
        end

        // ---- window decode: RAM inside, fault outside ----
        issue_m(1, 0, SZ_WORD, 32'h0000, 0);
        @(posedge clk);
        ck(10, ram_re, 1'b1); ck(11, m_err, 1'b0);
        issue_m(1, 0, SZ_WORD, 32'hFFFC, 0);
        @(posedge clk);
        ck(12, ram_re, 1'b1); ck(13, m_err, 1'b0);
        issue_m(1, 0, SZ_WORD, 32'h10000, 0);           // just past RAM
        @(posedge clk);
        ck(14, ram_re, 1'b0); ck(15, m_err, 1'b1);
        check(16, m_rdata, 32'h0);                      // fault returns zero
        issue_m(1, 0, SZ_WORD, 32'hDEAD_0000, 0);       // deep unmapped
        @(posedge clk);
        ck(17, ram_re, 1'b0); ck(18, m_err, 1'b1);

        // ---- MMIO windows decode: selects true, mapped window err=0;
        //      reads return the peripheral's real rdata (all zero at reset) ----
        issue_m(1, 0, SZ_WORD, 32'h4000_0000, 0);
        @(posedge clk);
        ck(20, uart_sel, 1'b1); ck(21, m_err, 1'b0); check(121, m_rdata, 32'h0);
        issue_m(1, 0, SZ_WORD, 32'h4000_1FFC, 0);
        @(posedge clk);
        ck(22, timer_sel, 1'b1); ck(23, m_err, 1'b0); check(123, m_rdata, 32'h0);
        issue_m(1, 0, SZ_WORD, 32'h4000_2ABC, 0);
        @(posedge clk);
        ck(24, gpio_sel, 1'b1); ck(25, m_err, 1'b0); check(125, m_rdata, 32'h0);
        issue_m(1, 0, SZ_WORD, 32'h4000_3777, 0);
        @(posedge clk);
        ck(26, spi_sel, 1'b1); ck(27, m_err, 1'b0); check(127, m_rdata, 32'h0);

        // ---- external windows never strobe the RAM ----
        issue_m(0, 1, SZ_WORD, 32'h4000_0000, 32'h12345678);
        @(posedge clk);
        ck(28, ram_we, 1'b0);
        issue_m(0, 1, SZ_WORD, 32'hDEAD_0000, 32'h12345678);
        @(posedge clk);
        ck(29, ram_we, 1'b0);

        // ---- real bus transaction through to RAM ----
        issue_m(0, 1, SZ_WORD, 32'h200, 32'hDEADBEEF);
        @(posedge clk);
        ck(30, ram_we, 1'b1);
        issue_m(1, 0, SZ_WORD, 32'h200, 0);
        @(posedge clk);
        check(31, m_rdata, 32'hDEADBEEF);
        // half store on lanes 2-3 (addr[1:0]=10): value bytes must land in
        // 0x206/0x207, i.e. the top half of the word at 0x204
        issue_m(0, 1, SZ_WORD, 32'h204, 32'h11112222);
        @(posedge clk);
        issue_m(0, 1, SZ_HALF, 32'h206, 32'h00005A5A);
        @(posedge clk);
        issue_m(1, 0, SZ_WORD, 32'h204, 0);
        @(posedge clk);
        check(32, m_rdata, 32'h5A5A2222);

        // ---- traffic through the bus to the peripherals ----
        // UART: CTRL write/read, TXD starts a transfer. Peripheral register
        // commits are NBA; the #1 after a posedge makes them observable.
        issue_m(0, 1, SZ_WORD, 32'h4000_000C, 32'h3);   // CTRL REN|TXEN
        @(posedge clk); #1;
        issue_m(1, 0, SZ_WORD, 32'h4000_000C, 0);
        @(posedge clk); #1;
        check(40, m_rdata, 32'h3);
        issue_m(0, 1, SZ_BYTE, 32'h4000_0000, 32'h0000_0041); // TXD 'A'
        @(posedge clk); #1;                             // commit: busy starts
        check(41, uart_tx_char, 8'h41);
        ck(42, uart_tx_valid, 1'b1);
        ck(43, uart_tx_busy, 1'b1);
        issue_m(1, 0, SZ_WORD, 32'h4000_0008, 0);       // STS
        @(posedge clk); #1;
        check(44, m_rdata, 32'h1);                      // busy=1, ready=0
        ck(45, uart_tx_valid, 1'b0);                    // one-cycle pulse over
        issue_m(0, 0, SZ_WORD, 32'h4000_0000, 0);
        repeat (7) @(posedge clk);                      // wait out the 8-clock TX
        ck(46, uart_tx_busy, 1'b0);
        ck(47, irq_uart_tx, 1'b1);                      // TX_READY re-raised
        issue_m(1, 0, SZ_WORD, 32'h4000_0008, 0);       // STS: ready back
        @(posedge clk); #1;
        check(48, m_rdata, 32'h4);

        // TIMER: COUNT increments through the bus; disable then read exact
        issue_m(0, 1, SZ_WORD, 32'h4000_100C, 32'h1234_5678); // COUNT
        @(posedge clk); #1;
        issue_m(0, 1, SZ_WORD, 32'h4000_1000, 32'h1);        // ENABLE
        @(posedge clk); #1;
        repeat (2) @(posedge clk);                            // +2 ticks
        issue_m(0, 1, SZ_WORD, 32'h4000_1000, 32'h0);        // disable (2 edges tick)
        @(posedge clk); #1;
        issue_m(1, 0, SZ_WORD, 32'h4000_100C, 0);            // read COUNT
        @(posedge clk); #1;
        check(50, m_rdata, 32'h1234_567C);                   // +2 run +2 disable edges
        ck(51, irq_timer, 1'b0);

        // GPIO: OUT write/read, IN passthrough, edge evt + irq passthrough
        issue_m(0, 1, SZ_WORD, 32'h4000_2004, 32'h0000_ABCD); // OUT
        @(posedge clk); #1;
        issue_m(1, 0, SZ_WORD, 32'h4000_2004, 0);            // read OUT
        @(posedge clk); #1;
        check(60, m_rdata, 32'h0000_ABCD);
        check(61, gpio_out, 32'h0000_ABCD);
        #1; gpio_in = 32'h8000_0000;                         // pin 31 rising edge
        @(posedge clk);
        @(posedge clk);                                      // edge latched
        issue_m(1, 0, SZ_WORD, 32'h4000_2010, 0);            // IRQ_STS
        @(posedge clk); #1;
        check(62, m_rdata, 32'h8000_0000);
        issue_m(1, 0, SZ_WORD, 32'h4000_2008, 0);            // IN
        @(posedge clk); #1;
        check(63, m_rdata, 32'h8000_0000);
        issue_m(0, 1, SZ_WORD, 32'h4000_2014, 32'h8000_0000); // IRQ_MASK
        @(posedge clk); #1;
        ck(64, irq_gpio, 1'b1);

        // SPI: ENABLE, TX start, BUSY window, RX latch + irq passthrough
        issue_m(0, 1, SZ_WORD, 32'h4000_3000, 32'h1);        // ENABLE
        @(posedge clk); #1;
        issue_m(0, 1, SZ_BYTE, 32'h4000_3008, 32'h0000_00A5); // TX
        @(posedge clk); #1;                                  // commit: busy starts
        check(70, spi_out, 8'hA5);
        issue_m(1, 0, SZ_WORD, 32'h4000_3010, 0);            // STS
        @(posedge clk); #1;
        check(71, m_rdata, 32'h1);                           // BUSY
        repeat (7) @(posedge clk);                           // E6..E12 completion
        #1;
        ck(72, irq_spi, 1'b1);
        issue_m(1, 0, SZ_WORD, 32'h4000_300C, 0);            // RX (acknowledge)
        @(posedge clk); #1;
        check(73, m_rdata, 32'h5C);
        ck(74, irq_spi, 1'b0);

        // ---- word access read fault halts nothing here; rdata=0 ----
        issue_m(1, 0, SZ_WORD, 32'hCAFE_0000, 0);
        @(posedge clk);
        ck(33, m_err, 1'b1);
        check(34, m_rdata, 32'h0);

        $display("bus_tb: %0d failures", fail);
        if (fail == 0)
            $display("bus_tb: ALL CHECKS PASSED");
        $finish;
    end

endmodule : bus_tb