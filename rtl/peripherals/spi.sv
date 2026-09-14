// DeckCPU SPI — MMIO serial master/slave model (docs/memory-map.md).
//
// Register map (offsets within the 4 KiB window at 0x4000_3000):
//   +0x00 CTRL (RW) bit0 ENABLE, bit1 MODE (0=master, 1=slave)
//   +0x04 BAUD (RW) SCK divisor (model: bit-time in clocks)
//   +0x08 TX   (WO) write = start a transfer
//   +0x0C RX   (RO) shifted-in byte (public MISO data)
//   +0x10 STS  (RO) bit0 BUSY
//
// Model: a write to TX (while ENABLE, idle) presents the byte on the
// spi_out (MOSI) port, raises BUSY for one bit-time per div (8*BAUD clocks;
// a fast default of 8 clocks when BAUD=0), then latches the byte presented
// on spi_in (MISO) into RX and raises the transfer-complete interrupt.
// Reading RX clears that interrupt. MODE is stored for future virtual
// peripherals; the register-level model transfers identically in both modes.
//
// MMIO stores honour the bus byte-enable lanes; unlisted offsets read 0 and
// ignore writes.

module spi #(
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

    input  logic [7:0]       spi_in,      // MISO, driven by the virtual slave
    output logic [7:0]       spi_out,     // MOSI, byte of the current transfer
    output logic             busy,        // STS bit0, observable for hooks

    output logic             irq          // level to irq_prio (slot 5)
);

    localparam logic [11:0] R_CTRL = 12'h000;
    localparam logic [11:0] R_BAUD = 12'h004;
    localparam logic [11:0] R_TX   = 12'h008;
    localparam logic [11:0] R_RX   = 12'h00C;
    localparam logic [11:0] R_STS  = 12'h010;

    logic [31:0]  ctrl_q  = 32'd0;       // CTRL
    logic [31:0]  baud_q  = 32'd0;       // BAUD
    logic [7:0]   tx_q    = 8'd0;        // MOSI byte in flight
    logic [7:0]   rx_q    = 8'd0;        // RXD latch
    logic         busy_q  = 1'b0;
    logic [31:0]  ticks_q = 32'd0;       // busy ticks remaining
    logic         done_q  = 1'b0;        // transfer-complete latch
    logic [1:0]   lane0;
    logic [31:0]  wmask;                 // be expanded to a byte mask
    logic [31:0]  wdata_l;               // write bytes rotated to be lanes

    logic [31:0]  ticks_init = 32'd8;

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

    // model bit-time = BAUD clocks per SCK bit (8 bits per transfer)
    always_comb begin
        if (baud_q == 32'd0)
            ticks_init = 32'd8;
        else
            ticks_init = 32'd8 * baud_q;
    end

    always_ff @(posedge clk) begin
        if (rst) begin
            ctrl_q  <= 32'd0;
            baud_q  <= 32'd0;
            tx_q    <= 8'd0;
            rx_q    <= 8'd0;
            busy_q  <= 1'b0;
            ticks_q <= 32'd0;
            done_q  <= 1'b0;
        end else begin
            if (we && addr == R_CTRL)
                ctrl_q <= (ctrl_q & ~wmask) | (wdata_l & wmask);
            if (we && addr == R_BAUD)
                baud_q <= (baud_q & ~wmask) | (wdata_l & wmask);

            // TX write starts a transfer
            if (we && addr == R_TX && ctrl_q[0] && !busy_q) begin
                tx_q    <= wdata[7:0];
                busy_q  <= 1'b1;
                ticks_q <= ticks_init;
                done_q  <= 1'b0;
            end

            // transfer in progress: latch MISO when the last bit completes
            if (busy_q) begin
                if (ticks_q == 32'd0) begin
                    busy_q <= 1'b0;
                    rx_q   <= spi_in;
                    done_q <= 1'b1;
                end else begin
                    ticks_q <= ticks_q - 32'd1;
                end
            end

            // reading RX acknowledges the transfer-complete interrupt
            if (re && addr == R_RX)
                done_q <= 1'b0;
        end
    end

    always_comb begin
        case (addr)
            R_CTRL: rdata = ctrl_q;
            R_BAUD: rdata = baud_q;
            R_TX:   rdata = 32'd0;
            R_RX:   rdata = {24'd0, rx_q};
            R_STS:  rdata = {31'd0, busy_q};
            default: rdata = 32'd0;
        endcase
    end

    assign spi_out = tx_q;
    assign busy    = busy_q;
    assign irq     = ctrl_q[0] && done_q;

endmodule : spi