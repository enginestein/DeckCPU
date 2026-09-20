// DeckCPU GPIO 32-pin MMIO model (docs/memory-map.md).
//
//   +0x00 DIR      (RW) bit per pin: 0=input, 1=output
//   +0x04 OUT      (RW) output data (mirrored on the gpio_out port)
//   +0x08 IN       (RO) input data, read from the gpio_in port
//   +0x0C PULL     (RW) stored for virtual peripherals
//   +0x10 IRQ_STS  (RW) edge events; write 1 to clear
//   +0x14 IRQ_MASK (RW) per-pin IRQ enable
//
// Any gpio_in transition (rising or falling) latches its IRQ_STS bit; irq is
// level while (IRQ_STS & IRQ_MASK) bites, feeding IVT slot 4. DIR is stored
// only it gates a real IO cell's direction, not this register-level model.
// Stores honour byte enables; unlisted offsets read 0.

module gpio #(
    parameter int W = 32
)(
    input  logic             clk,
    input  logic             rst,

    input  logic             re,
    input  logic             we,
    input  logic [3:0]       be,
    input  logic [11:0]      addr,
    input  logic [W-1:0]     wdata,
    output logic [W-1:0]     rdata,

    input  logic [31:0]      gpio_in,     // driven by virtual peripherals / TB
    output logic [31:0]      gpio_out,    // OUT register, observable on pins

    output logic             irq          // level to irq_prio (slot 4)
);

    localparam logic [11:0] R_DIR  = 12'h000;
    localparam logic [11:0] R_OUT  = 12'h004;
    localparam logic [11:0] R_IN   = 12'h008;
    localparam logic [11:0] R_PULL = 12'h00C;
    localparam logic [11:0] R_STS  = 12'h010;
    localparam logic [11:0] R_MASK = 12'h014;

    logic [31:0] dir_q    = 32'd0;
    logic [31:0] out_q    = 32'd0;
    logic [31:0] pull_q   = 32'd0;
    logic [31:0] evt_q    = 32'd0;
    logic [31:0] mask_q   = 32'd0;
    logic [31:0] in_d1_q  = 32'd0;    // delayed input for edge detection
    logic [1:0]  lane0;
    logic [31:0]  wmask;             // be expanded to a byte mask
    logic [31:0]  wdata_l;           // write bytes rotated to be lanes

    always_comb begin
        if (be[0])        lane0 = 2'd0;
        else if (be[1])   lane0 = 2'd1;
        else if (be[2])   lane0 = 2'd2;
        else              lane0 = 2'd3;
        wmask   = 32'd0;
        for (int b = 0; b < 4; b++)
            if (be[b])
                wmask = wmask | (32'hFF << (8 * b));
        wdata_l = wdata << (8 * lane0);
    end

    always_ff @(posedge clk) begin
        if (rst) begin
            dir_q  <= 32'd0;
            out_q  <= 32'd0;
            pull_q <= 32'd0;
            evt_q  <= 32'd0;
            mask_q <= 32'd0;
            in_d1_q <= 32'd0;
        end else begin
            // register stores (byte-enable lane merges; Icarus cannot
            // schedule per-byte part-selects inside edge processes)
            if (we && addr == R_DIR)
                dir_q <= (dir_q & ~wmask) | (wdata_l & wmask);
            if (we && addr == R_OUT)
                out_q <= (out_q & ~wmask) | (wdata_l & wmask);
            if (we && addr == R_PULL)
                pull_q <= (pull_q & ~wmask) | (wdata_l & wmask);
            if (we && addr == R_MASK)
                mask_q <= (mask_q & ~wmask) | (wdata_l & wmask);

            // latch any new input transition (rising or falling)
            if (gpio_in[31:0] != in_d1_q[31:0])
                evt_q <= evt_q | (gpio_in[31:0] ^ in_d1_q[31:0]);
            in_d1_q[31:0] <= gpio_in[31:0];

            // IRQ_STS is write-1-to-clear; applied last (a simultaneous
            // edge and clear is resolved in favour of the clear)
            if (we && addr == R_STS)
                evt_q <= (evt_q & ~wmask) | 32'd0;
        end
    end

    always_comb begin
        case (addr)
            R_DIR:  rdata = dir_q;
            R_OUT:  rdata = out_q;
            R_IN:   rdata = gpio_in;
            R_PULL: rdata = pull_q;
            R_STS:  rdata = evt_q;
            R_MASK: rdata = mask_q;
            default: rdata = 32'd0;
        endcase
    end

    assign gpio_out = out_q;
    assign irq      = |(evt_q & mask_q);

endmodule : gpio