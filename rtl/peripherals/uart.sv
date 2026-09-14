// DeckCPU UART — MMIO register block (docs/memory-map.md).
//
// Register map (offsets within the 4 KiB window at 0x4000_0000):
//   +0x00 TXD  (WO)  transmit byte            (reads return 0)
//   +0x04 RXD  (RO)  received byte            (read clears RX_READY)
//   +0x08 STS  (RO)  bit0 TX_BUSY, bit1 RX_READY, bit2 TX_READY
//   +0x0C CTRL (RW)  bit0 TX_EN,    bit1 RX_EN
//   +0x10 BAUD (RW)  baud divisor for the *model* (host console speed fixed)
//
// Host console model: the byte is handed to the host sink as a one-cycle
// tx_valid pulse on tx_char (the "terminal sink"); the
// RTL stays synthesizable, the host prints it. The terminal source feeds
// rx_push/rx_byte (the "terminal source"); a read of RXD returns the byte
// and clears RX_READY. Interrupts are level outputs: RX on
// byte-available + RX_EN, TX on idle + TX_EN.
//
// MMIO stores honour the bus byte-enable lanes, so ST.B/ST.H touch only the
// covered bytes of a register word, exactly like the RAM lane model.
// Unlisted offsets read 0 and ignore writes.

module uart #(
    parameter int W = 32
)(
    input  logic             clk,
    input  logic             rst,

    // MMIO slave port: addressed within this 4 KiB window (addr = offset).
    input  logic             re,
    input  logic             we,
    input  logic [3:0]       be,
    input  logic [11:0]      addr,
    input  logic [W-1:0]     wdata,
    output logic [W-1:0]     rdata,

    // host console sink (byte to print)
    output logic [7:0]       tx_char,
    output logic             tx_valid,
    output logic             tx_busy,

    // host console source (feed a received byte)
    input  logic [7:0]       rx_byte,
    input  logic             rx_push,

    // IRQ level outputs for irq_prio (UART_RX slot 2, UART_TX slot 3)
    output logic             irq_rx,
    output logic             irq_tx
);

    localparam logic [11:0] R_TXD  = 12'h000;
    localparam logic [11:0] R_RXD  = 12'h004;
    localparam logic [11:0] R_STS  = 12'h008;
    localparam logic [11:0] R_CTRL = 12'h00C;
    localparam logic [11:0] R_BAUD = 12'h010;

    logic [31:0]  ctrl_q  = 32'd0;             // CTRL
    logic [31:0]  baud_q  = 32'd0;             // BAUD
    logic [7:0]   tx_byte_q = 8'd0;            // byte being/having been shifted
    logic         tx_ready_q = 1'b1;           // 1 = TX idle
    logic [31:0]  tx_rest_q = 32'd0;           // busy ticks remaining
    logic         tx_pend_q = 1'b0;            // one-cycle tx_valid pulse
    logic [7:0]   rx_latch_q = 8'd0;           // last received byte
    logic         rx_ready_q = 1'b0;           // RX_READY (latched)
    logic [1:0]   lane0;                       // lowest enabled byte lane
    logic [31:0]  wmask;                       // be expanded to a byte mask
    logic [31:0]  wdata_l;                     // write bytes rotated to be lanes

    logic [31:0]  busy_len = 32'd8;            // model busy time in clocks

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

    // model TX duration: 10 bit-times * BAUD divisor, but a fast default when
    // BAUD is unset so programs that never configure BAUD still transmit.
    always_comb begin
        if (baud_q == 32'd0)
            busy_len = 32'd8;
        else
            busy_len = 32'd10 * baud_q;
    end

    // TX path: latch the byte; start a transfer only when CTRL.TX_EN and idle.
    always_ff @(posedge clk) begin
        if (rst) begin
            tx_byte_q  <= 8'd0;
            tx_ready_q <= 1'b1;
            tx_rest_q  <= 32'd0;
            tx_pend_q  <= 1'b0;
        end else begin
            tx_pend_q <= 1'b0;
            if (we && addr == R_TXD) begin
                tx_byte_q  <= wdata[7:0];
                if (ctrl_q[0] && tx_ready_q) begin
                    tx_rest_q <= busy_len;
                    tx_ready_q <= 1'b0;
                    tx_pend_q <= 1'b1;
                end
            end
            if (!tx_ready_q) begin
                if (tx_rest_q == 32'd0)
                    tx_ready_q <= 1'b1;
                else
                    tx_rest_q <= tx_rest_q - 32'd1;
            end
        end
    end

    // RX path: a pushed byte latches and flags RX_READY; reading RXD clears it.
    always_ff @(posedge clk) begin
        if (rst) begin
            rx_latch_q <= 8'd0;
            rx_ready_q <= 1'b0;
        end else begin
            if (rx_push) begin
                rx_latch_q <= rx_byte;
                rx_ready_q <= 1'b1;
            end else if (re && addr == R_RXD) begin
                rx_ready_q <= 1'b0;
            end
        end
    end

    // CTRL / BAUD register file (byte-enable lane stores via mask; Icarus
    // cannot schedule per-byte part-selects inside edge processes).
    always_ff @(posedge clk) begin
        if (rst) begin
            ctrl_q <= 32'd0;
            baud_q <= 32'd0;
        end else begin
            if (we && addr == R_CTRL)
                ctrl_q <= (ctrl_q & ~wmask) | (wdata_l & wmask);
            if (we && addr == R_BAUD)
                baud_q <= (baud_q & ~wmask) | (wdata_l & wmask);
        end
    end

    always_comb begin
        case (addr)
            R_TXD:  rdata = 32'd0;
            R_RXD:  rdata = {24'd0, rx_latch_q};
            R_STS:  rdata = {29'd0, tx_ready_q, rx_ready_q, ~tx_ready_q};
            R_CTRL: rdata = ctrl_q;
            R_BAUD: rdata = baud_q;
            default: rdata = 32'd0;
        endcase
    end

    assign tx_busy  = ~tx_ready_q;
    assign tx_char  = tx_byte_q;
    assign tx_valid = tx_pend_q;
    assign irq_rx   = ctrl_q[1] && rx_ready_q;
    assign irq_tx   = ctrl_q[0] && tx_ready_q;

endmodule : uart