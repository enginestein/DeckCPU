// DeckCPU RAM byte-addressed synchronous SRAM over the bus.
//
// Timing matches the bus protocol: writes commit on the posedge that ends the
// cycle (masked by be), reads latch on the mid-cycle negedge and stay valid to
// the end. rdata is rotated so a byte/half load at any address lands in the
// low bits; stores rotate back through the byte enables.

module ram #(
    parameter int AW = 16                  // byte-address bits (2^AW bytes)
)(
    input  logic             clk,
    input  logic             rst,
    input  logic             re,
    input  logic             we,
    input  logic [3:0]       be,
    input  logic [AW-1:0]    addr,
    input  logic [31:0]      wdata,
    output logic [31:0]      rdata,

    // boot/load port: the host drops a full word per clock tick during reset
    // (bus is quiet then) to place the IVT image and code before running.
    input  logic             boot_we,
    input  logic [AW-1:0]    boot_addr,
    input  logic [31:0]      boot_data
);

    localparam int NB = 2**AW * 8;         // packed width: NB bits == 2^AW bytes

logic [NB-1:0]     mem = '0;            // storage (updates once per cycle)
    logic [NB-1:0]     mem_next;           // byte-rotated next-state value
    logic [31:0]       rdata_q = '0;
    logic [1:0]        lane0;              // lowest be-selected byte lane

    // byte lanes are visited in address order starting at the lowest sel.
    always_comb begin
        if (be[0])        lane0 = 2'd0;
        else if (be[1])   lane0 = 2'd1;
        else if (be[2])   lane0 = 2'd2;
        else              lane0 = 2'd3;
    end

    // next-state: current contents, with this cycle's stores rotated into
    // their be-selected positions. Untouched bytes pass through unchanged.
    always_comb begin
        mem_next = mem;
        if (boot_we) begin
            for (int i = 0; i < 4; i++)
                mem_next[(boot_addr + i)*8 +: 8] = boot_data[i*8 +: 8];
        end else if (we) begin
            for (int i = 0; i < 4; i++)
                if (be[i])
                    mem_next[((addr & ~3) + i)*8 +: 8]
                        = wdata[(i - lane0)*8 +: 8];
        end
    end

    always_ff @(posedge clk) begin
        mem <= mem_next;
    end

    // registered read latch, mid-cycle.
    always_ff @(negedge clk) begin
        if (rst)
            rdata_q <= 32'h0;
        else if (re) begin
            rdata_q[7:0]   <= mem[addr*8 +: 8];
            rdata_q[15:8]  <= mem[(addr+1)*8 +: 8];
            rdata_q[23:16] <= mem[(addr+2)*8 +: 8];
            rdata_q[31:24] <= mem[(addr+3)*8 +: 8];
        end
    end

    assign rdata = rdata_q;

endmodule : ram