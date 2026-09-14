// DeckCPU GPIO block testbench (Icarus-only: sequences @(posedge clk)).
//
// Covers DIR/OUT/PULL/RW registers, IN passthrough, gpio_out
// mirroring, byte-lane stores, input-transition edge events into IRQ_STS,
// IRQ_MASK gating of the irq level, and write-1-to-clear.

module gpio_tb #(parameter int W = 32);

    logic              clk = 1'b0;
    always #5 clk = ~clk;

    logic              rst = 1'b1;
    logic              t_re, t_we;
    logic [3:0]        t_be;
    logic [11:0]       t_addr;
    logic [W-1:0]      t_wdata, t_rdata;
    logic              t_irq;
    logic [31:0]       t_in   = 32'd0;
    logic [31:0]       t_out;
    logic [31:0]       o_out;

    int checks = 0;
    int fails  = 0;

    assign o_out = t_out;

    gpio #(.W(W)) u_gpio (
        .clk(clk), .rst(rst),
        .re(t_re), .we(t_we), .be(t_be), .addr(t_addr),
        .wdata(t_wdata), .rdata(t_rdata),
        .gpio_in(t_in), .gpio_out(t_out),
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

    // drive the input pins AFTER the current posedge so the next posedge
    // samples the transition (changes must hold across a sampling edge).
    task in_set(input [31:0] v);
        begin
            #1;
            t_in = v;
        end
    endtask : in_set

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
        rdn(12'h000); check(t_rdata, 32'h0, "DIR reset");
        rdn(12'h004); check(t_rdata, 32'h0, "OUT reset");
        rdn(12'h008); check(t_rdata, 32'h0, "IN reset");
        rdn(12'h00C); check(t_rdata, 32'h0, "PULL reset");
        rdn(12'h010); check(t_rdata, 32'h0, "IRQ_STS reset");
        rdn(12'h014); check(t_rdata, 32'h0, "IRQ_MASK reset");
        ck(t_irq, 1'b0, "irq off at reset");
        check(o_out, 32'h0, "gpio_out reset");

        // ---- DIR / OUT / PULL writable; gpio_out mirrors OUT ----
        wr(12'h000, 4'hF, 32'h0123_4567); idle();
        rdn(12'h000); check(t_rdata, 32'h0123_4567, "DIR write/read");
        wr(12'h00C, 4'hF, 32'h5A5A_5A5A); idle();
        rdn(12'h00C); check(t_rdata, 32'h5A5A_5A5A, "PULL write/read");
        wr(12'h004, 4'hF, 32'h0A0B_0C0D); idle();
        rdn(12'h004); check(t_rdata, 32'h0A0B_0C0D, "OUT write/read");
        check(o_out, 32'h0A0B_0C0D, "gpio_out == OUT");

        // byte-lane stores (ST.B / ST.H)
        wr(12'h000, 4'b1000, 32'h0000_005A); idle();   // DIR byte3 = 0x5A
        rdn(12'h000); check(t_rdata, 32'h5A23_4567, "DIR byte3 lane store");
        wr(12'h004, 4'b0010, 32'h0000_00FF); idle();   // OUT byte1 = 0xFF
        rdn(12'h004); check(t_rdata, 32'h0A0B_FF0D, "OUT byte1 lane store");
        check(o_out, 32'h0A0B_FF0D, "gpio_out after OUT lane store");

        // ---- IN reads the input port directly ----
        cycle(); in_set(32'hDEAD_BEEF);
        cycle();
        rdn(12'h008); check(t_rdata, 32'hDEAD_BEEF, "IN passthrough");
        // the 0 -> DEADBEEF drive latched a full-width event; clear it so the
        // edge tests below start from a clean IRQ_STS.
        wr(12'h010, 4'hF, 32'hFFFF_FFFF); idle();
        rdn(12'h010); check(t_rdata, 32'h0, "IRQ_STS cleared after IN probe");
        ck(t_irq, 1'b0, "irq off with cleared evt");

        // ---- no input change => no edge events ----
        cycle(); in_set(32'hDEAD_BEEF);   // unchanged
        cycle();
        rdn(12'h010); check(t_rdata, 32'h0, "no events while input stable");
        ck(t_irq, 1'b0, "irq off with no evt/mask");

        // settle to a clean low base and clear the full-width edge it makes
        cycle(); in_set(32'h0);           // DEADBEEF -> 0
        cycle();
        wr(12'h010, 4'hF, 32'hFFFF_FFFF); idle();
        rdn(12'h010); check(t_rdata, 32'h0, "IRQ_STS cleared before edge tests");

        // ---- a rising edge on pins 0,1 latches into IRQ_STS ----
        cycle(); in_set(32'h3);           // 0 -> 0x3
        cycle();                          // sampling edge
        rdn(12'h010); check(t_rdata, 32'h3, "edge 0x3 latched in IRQ_STS");
        ck(t_irq, 1'b0, "irq still off (IRQ_MASK=0)");

        // ---- IRQ_MASK gates the irq level ----
        wr(12'h014, 4'hF, 32'h3); idle();
        ck(t_irq, 1'b1, "irq high with evt & mask");
        // new edge on pin 2: evt=3|4=7, mask=3 -> irq stays high
        cycle(); in_set(32'h7);           // 0x3 -> 0x7 (pin2 rising)
        cycle();
        rdn(12'h010); check(t_rdata, 32'h7, "additional pin2 edge: evt=7");
        ck(t_irq, 1'b1, "irq high with evt=7 mask=3");
        // falling edges back to 0
        cycle(); in_set(32'h0);           // 0x7 -> 0 (pins 0..2 falling)
        cycle();
        rdn(12'h010); check(t_rdata, 32'h7, "falling edges keep latched evt");
        // a mask covering no pending bit drops irq despite evt being set
        wr(12'h014, 4'hF, 32'h8); idle();           // mask only pin3
        ck(t_irq, 1'b0, "irq dropped (pending evt pins 0/1 not covered)");

        // ---- IRQ_STS is write-1-to-clear ----
        wr(12'h010, 4'hF, 32'h7); idle();
        rdn(12'h010); check(t_rdata, 32'h0, "IRQ_STS cleared W1C");
        ck(t_irq, 1'b0, "irq off after W1C");

        // new masked edge re-raises irq only if covered
        cycle(); in_set(32'h1);
        cycle();
        rdn(12'h010); check(t_rdata, 32'h1, "re-latched bit0 edge");
        ck(t_irq, 1'b0, "irq off (mask=8, evt bit0)");

        // ---- unlisted offset: read 0, write ignored ----
        wr(12'h040, 4'hF, 32'hDEAD_BEEF); idle();
        rdn(12'h040); check(t_rdata, 32'h0, "unlisted offset reads 0");
        wr(12'h018, 4'hF, 32'hCAFE); idle();
        rdn(12'h018); check(t_rdata, 32'h0, "unlisted offset writes ignored");

        $display("gpio_tb: %0d checks, %0d failures", checks, fails);
        if (fails == 0)
            $display("gpio_tb: ALL CHECKS PASSED");
        $finish;
    end

endmodule : gpio_tb