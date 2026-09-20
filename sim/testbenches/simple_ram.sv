// Reference byte-addressed RAM behaviour (what rtl/memory/ram.sv implements).
//
// The cpu testbenches don't use this directly: Icarus 11 delta-loops at t=0
// on a wide combinational read of an unpacked array, so they model memory
// from the testbench instead. Kept as documentation of the intended
// semantics, usable once reads are registered and indexing constrained.

module simple_ram import deckcpu_pkg::*; #(
    parameter int AW      = 16
)(
    input  logic             clk,
    input  logic             rst,
    input  logic             re,
    input  logic             we,
    input  mem_sz_t          sz,
    input  logic [31:0]      addr,
    input  logic [31:0]      wdata,
    output logic [31:0]      rdata
);

    logic [7:0] mem [2**AW + 4];

    // NOTE: no zero-fill loop. Icarus delta-loops at t=0 when a large unpacked
    // array that an always_comb reads is procedurally written many times at
    // start (zero-fill or $readmemh); the TB writes every byte it reads anyway.

    // combinational read: word assembled from bytes at addr..addr+3
    always_comb begin
        rdata = { mem[addr + 3], mem[addr + 2], mem[addr + 1], mem[addr] };
    end

    always_ff @(posedge clk) begin
        if (we) begin
            case (sz)
                SZ_WORD: begin
                    mem[addr + 3] <= wdata[31:24];
                    mem[addr + 2] <= wdata[23:16];
                    mem[addr + 1] <= wdata[15:8];
                    mem[addr]     <= wdata[7:0];
                end
                SZ_HALF: begin
                    mem[addr + 1] <= wdata[15:8];
                    mem[addr]     <= wdata[7:0];
                end
                SZ_BYTE: begin
                    mem[addr]     <= wdata[7:0];
                end
                default: ;
            endcase
        end
    end

endmodule : simple_ram