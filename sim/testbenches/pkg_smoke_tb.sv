// Package smoke test: verifies deckcpu_pkg.sv compiles and that the
// constant set mirrors isa/isa.json (checked again on the host side by
// tools/check_pkg_isa.py via make test).
module pkg_smoke_tb;
  import deckcpu_pkg::*;

  initial begin
    // Format field arithmetics must produce full 32-bit instruction slices.
    if (OP_MSB - OP_LSB + 1 != 8) $fatal(1, "opcode width");
    if (R_A_MSB - R_A_LSB + 1 != 4) $fatal(1, "field A width");
    if (R_B_MSB - R_B_LSB + 1 != 4) $fatal(1, "field B width");
    if (RS2_MSB - RS2_LSB + 1 != 4) $fatal(1, "field rs2 width");
    if (IMM_MSB - IMM_LSB + 1 != 16) $fatal(1, "imm16 width");

    // enum sanity
    if (OP_NOP != 8'h00) $fatal(1, "NOP");
    if (OP_HALT != 8'h60) $fatal(1, "HALT");
    if (OP_LD != 8'h30 || OP_ST != 8'h34) $fatal(1, "LD/ST opcodes");
    if (OP_BEQ != 8'h44 || OP_IRET != 8'h58) $fatal(1, "branch/iret opcodes");

    // memory map sizes
    if (RAM_SIZE != 32'h0001_0000) $fatal(1, "RAM_SIZE");
    if (UART_BASE > TIMER_BASE) $fatal(1, "peripheral base order");

    // reset state
    if (RESET_SP != 32'h0000_FFFC) $fatal(1, "RESET_SP");
    if (RESET_PC != 32'h0000_0000) $fatal(1, "RESET_PC");

    if (IVT_BASE + IVT_SLOTS * IVT_BYTES != 32'h20) $fatal(1, "IVT size");

    $display("pkg_smoke_tb: OK");
    $finish;
  end
endmodule : pkg_smoke_tb