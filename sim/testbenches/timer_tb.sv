// DeckCPU TIMER block testbench (Icarus-only: sequences @(posedge clk)).
//
// Covers register semantics, the prescaler free-run (PRESCALE=3
// divides by 4), COUNT writable, one-shot (REPEAT=0) match + freeze vs
// periodic (REPEAT=1) non-blocking match, IRQ_STS write-1-to-clear, and the
// irq level output.
//
// Sampling convention: COUNT is a free-running register that increments at
// EVERY enabled posedge, so reads must not consume a clock edge. Reads use
// rdn() (combinational rdata sampled mid-cycle with no posedge); counting
// advances only through explicit cycle() calls. Writes still commit at the
// posedge of the idle() that follows them.

module timer_tb #(parameter int W = 32);

    logic              clk = 1'b0;
    always #5 clk = ~clk;

    logic              rst = 1'b1;
    logic              t_re, t_we;
    logic [3:0]        t_be;
    logic [11:0]       t_addr;
    logic [W-1:0]      t_wdata, t_rdata;
    logic              t_irq;

    int checks = 0;
    int fails  = 0;

    timer #(.W(W)) u_timer (
        .clk(clk), .rst(rst),
        .re(t_re), .we(t_we), .be(t_be), .addr(t_addr),
        .wdata(t_wdata), .rdata(t_rdata),
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

    // one clock edge (the only thing that advances COUNT)
    task cycle();
        begin
            @(posedge clk); #1;
        end
    endtask : cycle

    // write cycle begins; commit is the next idle().
    task wr(input [11:0] o, input [3:0] bev, input [W-1:0] wd);
        begin
            cycle();
            t_re = 1'b0; t_we = 1'b1; t_be = bev; t_addr = o; t_wdata = wd;
        end
    endtask : wr

    // commit a pending write (also the end of the idle wait).
    task idle();
        begin
            cycle();
            t_re = 1'b0; t_we = 1'b0; t_be = 4'hF;
        end
    endtask : idle

    // non-edge read: combinational rdata sampled mid-cycle, no clock edge.
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
        cycle();                        // let reset fully settle

        // ---- reset state ----
        rdn(12'h000); check(t_rdata, 32'h0, "CTRL reset");
        rdn(12'h004); check(t_rdata, 32'h0, "PRESCALE reset");
        rdn(12'h008); check(t_rdata, 32'h0, "COMPARE reset");
        rdn(12'h00C); check(t_rdata, 32'h0, "COUNT reset");
        rdn(12'h010); check(t_rdata, 32'h0, "IRQ_STS reset");
        ck(t_irq, 1'b0, "irq off at reset");
        rdn(12'h018); check(t_rdata, 32'h0, "unlisted offset = 0");

        // ---- COUNT writable; disabled timer holds its value ----
        wr(12'h00C, 4'hF, 32'h0000_1234); idle();
        rdn(12'h00C); check(t_rdata, 32'h0000_1234, "COUNT write/read");
        cycle(); cycle(); cycle();
        rdn(12'h00C); check(t_rdata, 32'h0000_1234, "COUNT holds while disabled");

        // ---- ENABLE + PRESCALE=0: COUNT increments every clock ----
        wr(12'h004, 4'hF, 32'h0); idle();          // PRESCALE = 0
        wr(12'h000, 4'hF, 32'h1); idle();          // ENABLE
        cycle(); cycle();
        rdn(12'h00C); check(t_rdata, 32'h0000_1236, "COUNT +2 after 2 cycles");
        cycle();
        rdn(12'h00C); check(t_rdata, 32'h0000_1237, "COUNT +3");
        // disable: the write edge ticks once, the commit edge once more, then
        // COUNT holds 0x1239
        wr(12'h000, 4'hF, 32'h0); idle();
        cycle(); cycle();
        rdn(12'h00C); check(t_rdata, 32'h0000_1239, "COUNT frozen when disabled");

        // ---- PRESCALE=3: one COUNT per 4 clocks; a PRESCALE write re-arms
        //      the divider so the cadence is deterministic ----
        wr(12'h008, 4'hF, 32'hFFFF_FFFF); idle();  // COMPARE = far away
        wr(12'h00C, 4'hF, 32'h0); idle();          // clear COUNT
        wr(12'h004, 4'hF, 32'h3); idle();          // PRESCALE = 3 (arms 3)
        wr(12'h000, 4'hF, 32'h1); idle();          // ENABLE
        cycle();                                    // divider 3->2
        rdn(12'h00C); check(t_rdata, 32'h0, "PRESCALE=3 no count yet");
        cycle(); cycle();                           // 2->1, 1->0
        cycle();                                    // underflow -> COUNT=1
        rdn(12'h00C); check(t_rdata, 32'h1, "PRESCALE=3 first count");
        cycle(); cycle(); cycle();                  // 3->2, 2->1, 1->0
        cycle();                                    // underflow -> COUNT=2
        rdn(12'h00C); check(t_rdata, 32'h2, "PRESCALE=3 second count");
        wr(12'h000, 4'hF, 32'h0); idle();
        wr(12'h00C, 4'hF, 32'h0); idle();
        wr(12'h004, 4'hF, 32'h0); idle();          // PRESCALE = 0 (free-run)
        wr(12'h008, 4'hF, 32'h3); idle();          // COMPARE = 3
        wr(12'h000, 4'hF, 32'h1); idle();          // ENABLE
        cycle(); cycle(); cycle();                  // COUNT 1, 2, 3
        cycle();                                    // tick->4, match fires
        rdn(12'h010); check(t_rdata, 32'h1, "IRQ_STS MATCH one-shot");
        rdn(12'h00C); check(t_rdata, 32'h4, "counted one past compare");
        cycle(); cycle(); cycle();                  // frozen
        rdn(12'h00C); check(t_rdata, 32'h4, "COUNT frozen one-shot");

        // ---- IRQ_EN drives the irq level; W1C clears and un-freezes ----
        wr(12'h000, 4'hF, 32'h3); idle();          // ENABLE | IRQ_EN
        ck(t_irq, 1'b1, "irq high with IRQ_EN + MATCH");
        wr(12'h010, 4'b0001, 32'h1); idle();       // W1C IRQ_STS
        ck(t_irq, 1'b0, "irq dropped after W1C");
        rdn(12'h010); check(t_rdata, 32'h0, "IRQ_STS cleared W1C");
        cycle(); cycle();                           // resumed
        rdn(12'h00C); check(t_rdata, 32'h6, "COUNT resumed after ack");
        wr(12'h000, 4'hF, 32'h0); idle();

        // ---- periodic (REPEAT=1): match does not freeze COUNT ----
        wr(12'h00C, 4'hF, 32'h0); idle();
        wr(12'h004, 4'hF, 32'h0); idle();          // PRESCALE = 0 (free-run)
        wr(12'h008, 4'hF, 32'h2); idle();          // COMPARE = 2
        wr(12'h000, 4'hF, 32'h5); idle();          // ENABLE | REPEAT
        cycle(); cycle();                           // COUNT 1, 2
        cycle();                                    // tick->3, match fires
        rdn(12'h010); check(t_rdata, 32'h1, "IRQ_STS MATCH periodic");
        rdn(12'h00C); check(t_rdata, 32'h3, "COUNT=3 periodic");
        cycle(); cycle();
        rdn(12'h00C); check(t_rdata, 32'h5, "COUNT not frozen periodic");
        wr(12'h000, 4'hF, 32'h0); idle();

        // ---- byte-lane store to COMPARE (keeps byte0 = 0x02) ----
        wr(12'h008, 4'b0100, 32'h0000_00AA); idle();
        rdn(12'h008); check(t_rdata, 32'h00AA_0002, "COMPARE byte2 lane store");

        $display("timer_tb: %0d checks, %0d failures", checks, fails);
        if (fails == 0)
            $display("timer_tb: ALL CHECKS PASSED");
        $finish;
    end

endmodule : timer_tb