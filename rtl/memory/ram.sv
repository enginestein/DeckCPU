// DeckCPU RAM — byte-addressed SRAM model.
//
// 64 KiB (parameterizable) byte-addressed memory behind the
// synchronous bus.
//
// I/O timing (matches the CPU's synchronous bus protocol):
//   - WRITE: asserted during a write cycle (we=1, addr/wdata/be stable from
//     the master); committed at the POSEDGE clock edge that ends that cycle.
//     Bytes are masked by be[3:0] so sub-word stores only touch their lanes.
//   - READ: the master drives re=1 + addr during a read cycle and samples
//     rdata at the posedge that ends it. The read word is therefore latched
//     at the NEGEDGE of that cycle (address is registered output from the
//     CPU, settled well before the mid-cycle edge). Latching the read on the
//     negedge keeps the word valid across the second half of the cycle and
//     avoids combinational array selects, which Icarus 11 delta-loops at t=0
//     (see sim/testbenches/simple_ram.sv). A registered read is standard
//     single-port SRAM behaviour and settles the mux once per cycle.
//
// The read is assembled by ROTATION from the bytes at addr..addr+3, so a
// byte load at any byte address returns that byte in rdata[7:0] and a half
// load at an even address returns that half in rdata[15:0]. Word loads are
// naturally word-aligned by the ISA. The store path is the inverse: the
// master drives the unshifted register value (low bits), and the RAM rotates
// that value's bytes into the be-selected byte positions of the word at
// (addr & ~3). With be=4'b1111 this degenerates to the straight word copy.
//
// Icarus 11 note: the first edge-triggered element write into an
// unpacked array (and, with more varied failure, dynamic bit/part-select
// writes and packed part-select NBA stores) is silently dropped or partially
// applied. To stay correct we never index the store vector dynamically: the
// memory is a packed vector and EVERY write cycle rebuilds the full vector
// from the previous value masked through the byte enables. A whole-vector
// assignment is a plain variable write (not a select), which Icarus applies
// consistently, so boot and demand stores all land.

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