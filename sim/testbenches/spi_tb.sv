// DeckCPU SPI block testbench (Icarus-only: sequences @(posedge clk)).
//
// Covers CTRL/BAUD RW, TX write-to-start, BUSY window
// (8 clocks per 8-bit transfer at BAUD=0), MOSI byte on spi_out, MISO latch
// into RX, the transfer-complete irq level, RX-read acknowledgment, and
// write-while-disabled / write-while-busy being ignored.

module spi_tb #(parameter int W = 32);

    logic              clk = 1'b0;
    always #5 clk = ~clk;

    logic              rst = 1'b1;
    logic              t_re, t_we;
    logic [3:0]        t_be;
    logic [11:0]       t_addr;
    logic [W-1:0]      t_wdata, t_rdata;
    logic              t_irq, t_busy;
    logic [7:0]        t_in = 8'h5C;    // public MISO byte
    logic [7:0]        t_out;

    int checks = 0;
    int fails  = 0;

    spi #(.W(W)) u_spi (
        .clk(clk), .rst(rst),
        .re(t_re), .we(t_we), .be(t_be), .addr(t_addr),
        .wdata(t_wdata), .rdata(t_rdata),
        .spi_in(t_in), .spi_out(t_out),
        .busy(t_busy),
        .irq(t_irq)
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

    task cycle();
        begin
            @(posedge clk); #1;
        end
    endtask : cycle

    task wr(input [11:0] o, input [3:0] bev, input [W-1:0] wd);
        begin
            cycle();
            t_re = 1'b0; t_we = 1'b1; t_be = bev; t_addr = o; t_wdata = wd;
        end
    endtask : wr

    task idle();
        begin
            cycle();
            t_re = 1'b0; t_we = 1'b0; t_be = 4'hF;
        end
    endtask : idle

    // posedge-sampled read (RX reads must present re across a clock edge to
    // trigger the acknowledge clear); call cycle(); then drive re; idle().
    task rd(input [11:0] o);
        begin
            cycle();
            t_re = 1'b1; t_we = 1'b0; t_addr = o;
        end
    endtask : rd

    task rdn(input [11:0] o);
        begin
            #1;
            t_re = 1'b1; t_we = 1'b0; t_addr = o;
            #1;
        end
    endtask : rdn

    initial begin
        t_re = 0; t_we = 0; t_be = 4'hF; t_addr = 0; t_wdata = 0;

        repeat (2) @(posedge clk); #1;
        rst = 1'b0;
        @(posedge clk); #1;
        cycle();

        // ---- reset state ----
        rdn(12'h000); check(t_rdata, 32'h0, "CTRL reset");
        rdn(12'h004); check(t_rdata, 32'h0, "BAUD reset");
        rdn(12'h008); check(t_rdata, 32'h0, "TX read as 0 (WO)");
        rdn(12'h00C); check(t_rdata, 32'h0, "RX reset");
        rdn(12'h010); check(t_rdata, 32'h0, "STS reset");
        ck(t_busy, 1'b0, "busy low at reset");
        check(t_out, 8'h0, "spi_out reset");
        ck(t_irq, 1'b0, "irq off at reset");

        // ---- CTRL / BAUD writable (byte-lane store to BAUD) ----
        wr(12'h000, 4'hF, 32'h2); idle();          // MODE=1
        rdn(12'h000); check(t_rdata, 32'h2, "CTRL write/read");
        wr(12'h004, 4'hF, 32'hA5A5_1234); idle();
        rdn(12'h004); check(t_rdata, 32'hA5A5_1234, "BAUD write/read");
        wr(12'h004, 4'b0010, 32'h0000_00BB); idle(); // BAUD byte1 = 0xBB
        rdn(12'h004); check(t_rdata, 32'hA5A5_BB34, "BAUD byte1 lane store");
        wr(12'h004, 4'hF, 32'h0); idle();           // back to fast default

        // ---- TX write while disabled does not start a transfer ----
        wr(12'h008, 4'b0001, 32'h0000_00AB); idle();
        rdn(12'h010); check(t_rdata, 32'h0, "no BUSY when disabled");
        ck(t_busy, 1'b0, "busy low when disabled");
        ck(t_irq, 1'b0, "irq off when disabled");
        cycle(); cycle();
        rdn(12'h010); check(t_rdata, 32'h0, "no transfer starts disabled");

        // ---- enable + TX write starts the transfer ----
        wr(12'h000, 4'hF, 32'h1); idle();          // ENABLE
        wr(12'h008, 4'b0001, 32'h0000_00AB); idle(); // start, MOSI=0xAB
        rdn(12'h010); check(t_rdata, 32'h1, "BUSY after TX write");
        ck(t_busy, 1'b1, "busy port high");
        check(t_out, 8'hAB, "spi_out == MOSI byte");
        ck(t_irq, 1'b0, "irq not set mid-transfer");
        rdn(12'h00C); check(t_rdata, 32'h0, "RX not latched mid-transfer");
        rdn(12'h008); check(t_rdata, 32'h0, "TX reads 0");

        // write while busy is ignored (MOSI keeps the in-flight byte);
        // the two commit edges consume ticks 8->6, we are still mid-flight
        wr(12'h008, 4'b0001, 32'h0000_005A); idle();
        rdn(12'h010); check(t_rdata, 32'h1, "BUSY persists with late TX write");
        check(t_out, 8'hAB, "late TX write ignored");

        // ---- transfer completes at the 9th edge after start; irq asserts ----
        repeat (7) cycle();                 // edges E3..E9
        rdn(12'h010); check(t_rdata, 32'h0, "BUSY clear after transfer");
        rdn(12'h00C); check(t_rdata, 32'h5C, "RX latched MISO byte");
        ck(t_irq, 1'b1, "irq high on transfer complete");

        // reading RX acknowledges and drops irq
        rd(12'h00C);                        // re driven, commit in idle
        idle();
        ck(t_irq, 1'b0, "irq dropped after reading RX");
        rdn(12'h00C); check(t_rdata, 32'h5C, "RX value retained after ack");

        // ---- second transfer, then disable while idle ----
        wr(12'h008, 4'b0001, 32'h0000_0033); idle(); // start 0x33
        rdn(12'h010); check(t_rdata, 32'h1, "BUSY on second transfer");
        repeat (7) cycle();                  // edges E1..E7, ticks->1
        rdn(12'h010); check(t_rdata, 32'h1, "BUSY one tick before end");
        cycle();                             // E8: ticks->0 (still running)
        cycle();                             // E9: completion
        rdn(12'h00C); check(t_rdata, 32'h5C, "second RX latched");
        ck(t_irq, 1'b1, "irq re-asserted on second completion");

        wr(12'h000, 4'hF, 32'h0); idle();           // ENABLE -> 0
        ck(t_irq, 1'b0, "irq drops with ENABLE cleared");
        // done latched persists but irq = ENABLE && done -> off
        rd(12'h00C); idle();
        ck(t_irq, 1'b0, "irq off after RX ack while disabled");

        $display("spi_tb: %0d checks, %0d failures", checks, fails);
        if (fails == 0)
            $display("spi_tb: ALL CHECKS PASSED");
        $finish;
    end

endmodule : spi_tb