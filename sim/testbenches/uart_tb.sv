// DeckCPU UART block testbench (Icarus-only: sequences @(posedge clk)).
//
// Covers register semantics (RO/WO/RW), the host-console TX model
// (tx_char strobe + TX_BUSY window, no re-start while busy), the RX latch
// (RX_READY set on push, cleared by reading RXD), IRQ level outputs, and
// byte-enable lane sub-word stores. MMIO rdata is combinational during the
// read cycle; write commits land at the posedge that ends the write cycle.

module uart_tb #(parameter int W = 32);

    logic              clk = 1'b0;
    always #5 clk = ~clk;

    logic              rst = 1'b1;
    logic              u_re, u_we;
    logic [3:0]        u_be;
    logic [11:0]       u_addr;
    logic [W-1:0]      u_wdata, u_rdata;
    logic [7:0]        u_tx_char;
    logic              u_tx_valid, u_tx_busy, u_irq_rx, u_irq_tx;
    logic [7:0]        u_rx_byte = 8'd0;
    logic              u_rx_push = 1'b0;

    int checks = 0;
    int fails  = 0;

    uart #(.W(W)) u_uart (
        .clk(clk), .rst(rst),
        .re(u_re), .we(u_we), .be(u_be), .addr(u_addr),
        .wdata(u_wdata), .rdata(u_rdata),
        .tx_char(u_tx_char), .tx_valid(u_tx_valid), .tx_busy(u_tx_busy),
        .rx_byte(u_rx_byte), .rx_push(u_rx_push),
        .irq_rx(u_irq_rx), .irq_tx(u_irq_tx)
    );

    task check(input [W-1:0] got, input [W-1:0] exp, input string what);
        begin
            checks = checks + 1;
            if (got !== exp) begin
                fails = fails + 1;
                $display("FAIL: %s got=%h exp=%h", what, got, exp);
            end
        end
    endtask : check

    task ck(input bit g, input bit e, input string what);
        begin
            checks = checks + 1;
            if (g !== e) begin
                fails = fails + 1;
                $display("FAIL: %s got=%b exp=%b", what, g, e);
            end
        end
    endtask : ck

    // write cycle begins; byte-enable explicit. Commit is the next posedge.
    task wr(input [11:0] o, input [3:0] bev, input [W-1:0] wd);
        begin
            @(posedge clk); #1;
            u_re = 1'b0; u_we = 1'b1; u_be = bev; u_addr = o; u_wdata = wd;
        end
    endtask : wr

    // read cycle begins; rdata is combinational, settled by the trailing #1.
    task rd(input [11:0] o);
        begin
            @(posedge clk); #1;
            u_re = 1'b1; u_we = 1'b0; u_addr = o;
            #1;
        end
    endtask : rd

    // one quiet cycle (commit/advance strobes).
    task idle();
        begin
            @(posedge clk); #1;
            u_re = 1'b0; u_we = 1'b0; u_be = 4'hF;
        end
    endtask : idle

    // wait until TX finishes (bounded).
    task wait_tx_ready();
        int cyc;
        begin
            cyc = 0;
            while (u_tx_busy && cyc < 128) begin
                @(posedge clk); #1;
                cyc = cyc + 1;
            end
        end
    endtask : wait_tx_ready

    initial begin
        u_re = 0; u_we = 0; u_be = 4'hF; u_addr = 0; u_wdata = 0;

        repeat (2) @(posedge clk);
        rst = 1'b0;
        @(posedge clk);

        // ---- reset state ----
        rd(12'h00C); check(u_rdata, 32'h0, "CTRL reset");
        rd(12'h010); check(u_rdata, 32'h0, "BAUD reset");
        rd(12'h004); check(u_rdata, 32'h0, "RXD reset");
        rd(12'h008); check(u_rdata, 32'h4, "STS reset (TX_READY)");
        rd(12'h000); check(u_rdata, 32'h0, "TXD read = 0");
        rd(12'h018); check(u_rdata, 32'h0, "unlisted offset = 0");
        ck(u_irq_rx, 1'b0, "irq_rx off at reset");
        ck(u_irq_tx, 1'b0, "irq_tx off at reset");

        // ---- CTRL RW + irq_tx when enabled and idle ----
        wr(12'h00C, 4'hF, 32'h0000_0001);  idle();
        rd(12'h00C); check(u_rdata, 32'h0000_0001, "CTRL write/read");
        ck(u_irq_tx, 1'b1, "irq_tx high (TX_EN, idle)");

        // ---- TXD: tx_char strobe, busy window, no re-start while busy ----
        wr(12'h000, 4'hF, 32'h0000_0041);   // 'A'
        idle();                             // commit: transfer starts
        ck(u_tx_valid, 1'b1, "tx_valid pulse on TXD");
        check({1'b0, u_tx_char}, 9'h041, "tx_char = 'A'");
        ck(u_tx_busy, 1'b1, "TX_BUSY right after write");
        ck(u_irq_tx, 1'b0, "irq_tx low while busy");
        idle();
        ck(u_tx_valid, 1'b0, "tx_valid deasserted next cycle");
        wr(12'h000, 4'hF, 32'h0000_0042);   // 'B' while busy: byte latches,
        idle();                             // transfer does NOT re-start
        ck(u_tx_valid, 1'b0, "no re-start strobe while busy");
        check({1'b0, u_tx_char}, 9'h042, "tx_char latches 'B'");
        ck(u_tx_busy, 1'b1, "still busy after ignored write");
        wait_tx_ready();
        ck(u_tx_busy, 1'b0, "TX finished (default busy_len)");
        rd(12'h008); check(u_rdata, 32'h4, "STS TX_READY set");
        ck(u_irq_tx, 1'b1, "irq_tx high again");

        // ---- BAUD = 2 extends the busy window ----
        wr(12'h010, 4'hF, 32'h2); idle();
        rd(12'h010); check(u_rdata, 32'h2, "BAUD write/read");
        wr(12'h000, 4'hF, 32'h0000_0055); idle();
        ck(u_tx_valid, 1'b1, "second byte starts");
        ck(u_tx_busy, 1'b1, "busy with BAUD=2");
        wait_tx_ready();
        ck(u_tx_busy, 1'b0, "TX done with BAUD=2");
        rd(12'h008); check(u_rdata, 32'h4, "STS ready after BAUD=2");

        // ---- RX: push sets RX_READY, RXD read clears; irq_rx ----
        wr(12'h00C, 4'hF, 32'h0000_0003); idle();   // TX_EN | RX_EN
        rd(12'h00C); check(u_rdata, 32'h0000_0003, "CTRL RX_EN set");
        @(posedge clk);                             // push 0xAB
        u_rx_push = 1'b1; u_rx_byte = 8'hAB;
        idle();
        u_rx_push = 1'b0;
        ck(u_irq_rx, 1'b1, "irq_rx high after push");
        rd(12'h008); check(u_rdata, 32'h6, "STS RX_READY set (0x6)");
        rd(12'h004); check(u_rdata, 32'h0000_00AB, "RXD returns 0xAB");
        idle();                                     // commit RX_READY clear
        rd(12'h008); check(u_rdata, 32'h4, "STS RX_READY cleared");
        ck(u_irq_rx, 1'b0, "irq_rx dropped after RXD read");
        // push overwrites an unread byte (latest wins)
        @(posedge clk);
        u_rx_push = 1'b1; u_rx_byte = 8'hCD;
        @(posedge clk);
        u_rx_push = 1'b0;
        @(posedge clk);
        rd(12'h004); check(u_rdata, 32'h0000_00CD, "RXD overwrite (0xCD)");

        // ---- byte-enable lane sub-word stores to CTRL ----
        // CTRL currently 0x3 (TX_EN|RX_EN from the RX test); be=0010 at
        // offset 0x0C overwrites only byte1 from wdata[7:0], byte0 stays 0x3
        wr(12'h00C, 4'b0010, 32'h0000_0040); idle();
        rd(12'h00C); check(u_rdata, 32'h0000_4003, "CTRL byte1 lane store");
        // be=0001 writes byte0 from wdata[7:0]
        wr(12'h00C, 4'b0001, 32'h0000_00FF); idle();
        rd(12'h00C); check(u_rdata, 32'h0000_40FF, "CTRL byte0 lane store");
        // WO lane: be=0100 to TXD has no effect on reads (still 0)
        wr(12'h000, 4'b0100, 32'h0000_00AA); idle();
        rd(12'h000); check(u_rdata, 32'h0, "TXD WO still reads 0");

        $display("uart_tb: %0d checks, %0d failures", checks, fails);
        if (fails == 0)
            $display("uart_tb: ALL CHECKS PASSED");
        $finish;
    end

endmodule : uart_tb