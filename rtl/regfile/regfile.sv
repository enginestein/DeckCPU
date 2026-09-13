// DeckCPU general-purpose register file.
//
// Phase 2. 16 x 32-bit registers r0..r15, two combinational read ports and
// one synchronous write port with synchronous reset to zero.
//
// Note: r0 is a general-purpose register (no RISC-V-style hardwired zero).

module regfile import deckcpu_pkg::*; #(
    parameter int W     = 32,
    parameter int N     = 16
)(
    input  logic                  clk,
    input  logic                  rst,
    input  logic                  we,
    input  logic [$clog2(N)-1:0]  waddr,
    input  logic [W-1:0]          wdata,
    input  logic [$clog2(N)-1:0]  raddr_a,
    input  logic [$clog2(N)-1:0]  raddr_b,
    output logic [W-1:0]          rdata_a,
    output logic [W-1:0]          rdata_b
);
    logic [W-1:0] rf [N];

    always_comb rdata_a = rf[raddr_a];
    always_comb rdata_b = rf[raddr_b];

    always_ff @(posedge clk) begin
        if (rst) begin
            for (int i = 0; i < N; i = i + 1)
                rf[i] <= '0;
        end else if (we) begin
            rf[waddr] <= wdata;
        end
    end

endmodule : regfile