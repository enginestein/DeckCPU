module ram_tb
 import deckcpu_pkg::*;
 #(parameter int W = 32);

    logic clk = 1'b0;
    always #5 clk = ~clk;

    logic         rst = 1'b1;
    logic         re, we, boot_we;
    logic [3:0]   be;
    logic [RAM_AW-1:0] addr, boot_addr;
    logic [W-1:0] wdata, boot_data, rdata;
    logic [W-1:0] fw [4];
    int           fail = 0;

    ram #(.AW(RAM_AW)) u_ram (
        .clk(clk), .rst(rst), .re(re), .we(we), .be(be), .addr(addr),
        .wdata(wdata), .rdata(rdata),
        .boot_we(boot_we), .boot_addr(boot_addr), .boot_data(boot_data)
    );

    task check(input int tag, input [W-1:0] got, input [W-1:0] exp);
        begin
            if (got !== exp) begin
                fail = fail + 1;
                $display("FAIL[%0d]: got=%h exp=%h", tag, got, exp);
            end
        end
    endtask : check

    // read bus as the CPU would: issue re/addr after a clock edge, sample
    // rdata (negedge-refreshed) at the end of that cycle.
    task do_read(input int tag, input [W-1:0] r_addr, input [W-1:0] exp);
        begin
            @(posedge clk);
            re = 1'b1; addr = r_addr;
            @(posedge clk);
            re = 1'b0;
            check(tag, rdata, exp);
        end
    endtask : do_read

    // write bus as the CPU would: one store cycle commits at the posedge.
    task do_write(input int tag, input [W-1:0] w_addr, input [3:0] w_be,
                  input [W-1:0] w_data);
        begin
            @(posedge clk);
            we = 1'b1; addr = w_addr; be = w_be; wdata = w_data;
            @(posedge clk);
            we = 1'b0;
        end
    endtask : do_write

    initial begin
        int tt;
        re = 0; we = 0; be = 4'b0; addr = 0; wdata = 0;
        boot_we = 0; boot_addr = 0; boot_data = 0;

        // ---- reset: rdata idle at 0, never-written bytes are 0 ----
        repeat (2) @(posedge clk);
        rst = 1'b0;
        @(posedge clk);
        check(0, rdata, 32'h0);
        do_read(1, 32'h10, 32'h0);          // never written

        // ---- boot port while rst is high (SoC image load), first-fetch
        //      regression: the first word of the first burst MUST land ----
        rst = 1'b1;
        repeat (2) @(posedge clk);
        begin : boot_img_reset
            fw[0] = 32'h00000000; fw[1] = 32'h55667788;
            fw[2] = 32'h99AABBCC; fw[3] = 32'hDDEEFF00;
            boot_we = 1'b1;
            for (int w = 0; w < 4; w++) begin
                boot_addr = 32'h0 + w*4;
                boot_data = fw[w];
                @(posedge clk);
            end
        end
        boot_we = 1'b0;
        rst = 1'b0;
        do_read(2, 32'h000, 32'h00000000);
        do_read(3, 32'h004, 32'h55667788);
        do_read(4, 32'h008, 32'h99AABBCC);
        do_read(5, 32'h00C, 32'hDDEEFF00);

        // ---- second burst (post-reset): first word must land too ----
        begin : boot_img
            fw[0] = 32'h11223344; fw[1] = 32'h55667788;
            fw[2] = 32'h99AABBCC; fw[3] = 32'hDDEEFF00;
            boot_we = 1'b1;
            for (int w = 0; w < 4; w++) begin
                boot_addr = 32'h100 + w*4;
                boot_data = fw[w];
                @(posedge clk);
            end
        end
        boot_we = 1'b0;
        do_read(10, 32'h100, 32'h11223344);
        do_read(11, 32'h108, 32'h99AABBCC);
        do_read(12, 32'h10C, 32'hDDEEFF00);

        // ---- word store overwrites all four bytes ----
        do_write(20, 32'h0F0, 4'b1111, 32'hA5A5A5A5);
        do_read(21, 32'h0F0, 32'hA5A5A5A5);
        do_read(22, 32'h0F3, 32'h000000A5); // byte at 0xf3, rest unwritten

        // ---- half store on lanes 0-1 leaves lanes 2-3 alone ----
        do_write(30, 32'h104, 4'b0011, 32'h00001234);
        do_read(31, 32'h104, 32'h55661234);  // lanes 2-3 kept their 0x55 0x66

        // ---- half store on lanes 2-3 (addr[1:0]=10): the value's bytes must
        //      land in 0x106/0x107 (inverse of the rotated read) ----
        do_write(32, 32'h106, 4'b1100, 32'h00009ABC);
        do_read(33, 32'h104, 32'h9ABC1234);

        // ---- byte stores at every byte offset ----
        do_write(40, 32'h108, 4'b0001, 32'h0000007E);
        do_read(41, 32'h108, 32'h99AABB7E);
        do_write(42, 32'h109, 4'b0010, 32'h00000071);
        do_read(43, 32'h108, 32'h99AA717E);
        do_write(44, 32'h10A, 4'b0100, 32'h00000072);
        do_read(45, 32'h108, 32'h9972717E);
        do_write(46, 32'h10B, 4'b1000, 32'h00000073);
        do_read(47, 32'h108, 32'h7372717E);

        // ---- word store at the very top of the window ----
        do_write(50, 32'hFFFC, 4'b1111, 32'h0BADBEEF);
        do_read(51, 32'hFFFC, 32'h0BADBEEF);

        // ---- sole byte at the last byte address flips that one lane ----
        do_write(52, 32'hFFFF, 4'b1000, 32'h000000BB);
        do_read(53, 32'hFFFC, 32'hBBADBEEF);
        do_write(54, 32'hFFFC, 4'b1111, 32'h00000000);
        do_read(55, 32'hFFFC, 32'h00000000); // word store clobbers the byte lane
        do_write(56, 32'hFFFF, 4'b1000, 32'h000000BB);
        do_read(57, 32'hFFFC, 32'hBB000000); // 0xffff is the word's high byte

        // ---- read hold: rdata stays valid while re is deasserted ----
        do_read(60, 32'h108, 32'h7372717E);
        for (tt = 0; tt < 4; tt++) @(posedge clk);
        check(61, rdata, 32'h7372717E);

        $display("ram_tb: %0d failures", fail);
        if (fail == 0)
            $display("ram_tb: ALL CHECKS PASSED");
        $finish;
    end

endmodule : ram_tb