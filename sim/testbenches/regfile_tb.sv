// Register file testbench.
module regfile_tb;
  import deckcpu_pkg::*;

  logic clk = 0;
  logic rst = 1;
  logic we;
  logic [3:0] waddr, raddr_a, raddr_b;
  logic [31:0] wdata;
  logic [31:0] rdata_a, rdata_b;

  regfile #(.W(32), .N(16)) dut (.*);

  always #5 clk = ~clk;

  int fails = 0;
  task check;
    input [31:0] tag;
    input [31:0] got;
    input [31:0] exp;
    begin
      if (got !== exp) begin
        fails++;
        $display("FAIL tag=%0d: got %h exp %h", tag, got, exp);
      end
    end
  endtask

  task waitclk;
    // wait for a rising edge without @event control (Verilator lint-safe)
    while (clk === 1'b1) #1;
    while (clk === 1'b0) #1;
    #1;
  endtask

  // tags (readability for FAIL lines)
  localparam int T_RESET = 10, T_WB = 11, T_PORTA = 12, T_PORTB = 13,
               T_BEFORE = 14, T_AFTER = 15, T_NOWRITE = 16,
               T_POSTRESET_A = 17, T_POSTRESET_B = 18;

  initial begin
    #1; // settle
    waitclk;      // reset active: registers cleared
    rst = 1'b0;
    // reset -> all zero
    for (int i = 0; i < 16; i++) begin
      raddr_a = i[3:0];
      #1;
      check(T_RESET + i, rdata_a, 32'h0);
    end

    // write every register, read back on separate ports
    for (int i = 0; i < 16; i++) begin
      waddr = i[3:0];
      wdata = 32'hA000_0000 | i;
      we = 1'b1;
      waitclk;
    end
    we = 1'b0;
    for (int i = 0; i < 16; i++) begin
      raddr_a = i[3:0];
      #1;
      check(T_WB + i, rdata_a, 32'hA000_0000 | i);
    end

    // two read ports are independent
    raddr_a = 4'd2; raddr_b = 4'd9;
    #1;
    check(T_PORTA, rdata_a, 32'hA000_0002);
    check(T_PORTB, rdata_b, 32'hA000_0009);

    // simultaneous write + read of the same address: read shows OLD value
    // until the clock edge commits the write.
    waddr = 4'd5; wdata = 32'hCAFE_CAFE; we = 1'b1;
    raddr_a = 4'd5;
    #1;
    check(T_BEFORE, rdata_a, 32'hA000_0005);
    waitclk;
    we = 1'b0;
    #1;
    check(T_AFTER, rdata_a, 32'hCAFE_CAFE);

    // no write when we=0
    waddr = 4'd5; wdata = 32'h0; we = 1'b0;
    waitclk;
    raddr_a = 4'd5;
    #1;
    check(T_NOWRITE, rdata_a, 32'hCAFE_CAFE);

    // reset clears everything again
    rst = 1'b1;
    waitclk;
    rst = 1'b0;
    raddr_a = 4'd5; raddr_b = 4'd1;
    #1;
    check(T_POSTRESET_A, rdata_a, 32'h0);
    check(T_POSTRESET_B, rdata_b, 32'h0);

    if (fails) begin
      $display("regfile_tb: %0d FAILURES", fails);
      $fatal(1, "regfile_tb failed");
    end
    $display("regfile_tb: OK");
    $finish;
  end
endmodule : regfile_tb