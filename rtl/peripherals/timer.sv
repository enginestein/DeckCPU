// DeckCPU TIMER MMIO compare timer (docs/memory-map.md).
//
//   +0x00 CTRL      (RW) bit0 ENABLE, bit1 IRQ_EN, bit2 REPEAT (0=one-shot, 1=periodic)
//   +0x04 PRESCALE  (RW) pre-divider; reloaded as COUNT counts up
//   +0x08 COMPARE   (RW) match value
//   +0x0C COUNT     (RW) current count (starts at 0)
//   +0x10 IRQ_STS   (RW) bit0 MATCH; write 1 to clear
//
// While ENABLE a down-counter reloads PRESCALE each clock; on underflow COUNT
// increments (PRESCALE=0 => free-run). COUNT == COMPARE latches MATCH and irq
// asserts while IRQ_EN (feeds slot 1). One-shot freezes until MATCH is
// cleared; periodic keeps counting. Stores honour byte enables; unlisted
// offsets read 0.

module timer #(
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

    output logic             irq        // level to irq_prio (slot 1)
);

    localparam logic [11:0] R_CTRL = 12'h000;
    localparam logic [11:0] R_PRE  = 12'h004;
    localparam logic [11:0] R_CMP  = 12'h008;
    localparam logic [11:0] R_CNT  = 12'h00C;
    localparam logic [11:0] R_IST  = 12'h010;

    logic [31:0]  ctrl_q      = 32'd0;    // CTRL register
    logic [31:0]  presc_cfg_q = 32'd0;    // PRESCALE register (reload value)
    logic [31:0]  compare_q   = 32'd0;    // COMPARE register
    logic [31:0]  count_q     = 32'd0;    // COUNT (free-running, writable)
    logic [31:0]  presc_cnt_q = 32'd0;    // running pre-divider
    logic         match_q     = 1'b0;     // latched match / IRQ_STS bit0
    logic         frozen_q    = 1'b0;     // one-shot freeze until ack
    logic [1:0]   lane0;
    logic [31:0]  wmask;                  // be expanded to a byte mask
    logic [31:0]  wdata_l;                // write bytes rotated to be lanes

    logic         enable_q;               // CTRL bit0, handy alias
    logic         irq_en_q;               // CTRL bit1
    logic         repeat_q;               // CTRL bit2

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

    assign enable_q = ctrl_q[0];
    assign irq_en_q = ctrl_q[1];
    assign repeat_q = ctrl_q[2];

    always_ff @(posedge clk) begin
        if (rst) begin
            ctrl_q <= 32'd0;
            presc_cfg_q <= 32'd0;
            compare_q   <= 32'd0;
            count_q     <= 32'd0;
            presc_cnt_q <= 32'd0;
            match_q     <= 1'b0;
            frozen_q    <= 1'b0;
        end else begin
            // register stores (byte-enable lane merges; Icarus cannot
            // schedule per-byte part-selects inside edge processes)
            if (we && addr == R_CTRL)
                ctrl_q <= (ctrl_q & ~wmask) | (wdata_l & wmask);
            if (we && addr == R_PRE) begin
                presc_cfg_q <= (presc_cfg_q & ~wmask) | (wdata_l & wmask);
                presc_cnt_q <= (presc_cfg_q & ~wmask) | (wdata_l & wmask);
            end
            if (we && addr == R_CMP)
                compare_q <= (compare_q & ~wmask) | (wdata_l & wmask);
            if (we && addr == R_CNT)
                count_q <= (count_q & ~wmask) | (wdata_l & wmask);

            // prescaler free-run (a COUNT store this cycle wins: no tick)
            if (enable_q && !frozen_q && !(we && addr == R_CNT)) begin
                if (presc_cnt_q == 32'd0) begin
                    count_q     <= count_q + 32'd1;
                    presc_cnt_q <= presc_cfg_q;
                end else begin
                    presc_cnt_q <= presc_cnt_q - 32'd1;
                end
            end

            // match detect
            if (enable_q && count_q == compare_q) begin
                match_q  <= 1'b1;
                if (!repeat_q)
                    frozen_q <= 1'b1;
            end

            // write-1-to-clear IRQ_STS.MATCH: resumes counting in one-shot mode
            if (we && addr == R_IST && be[0]) begin
                match_q  <= 1'b0;
                frozen_q <= 1'b0;
            end
        end
    end

    always_comb begin
        case (addr)
            R_CTRL: rdata = ctrl_q;
            R_PRE:  rdata = presc_cfg_q;
            R_CMP:  rdata = compare_q;
            R_CNT:  rdata = count_q;
            R_IST:  rdata = {31'd0, match_q};
            default: rdata = 32'd0;
        endcase
    end

    assign irq = irq_en_q && match_q;

endmodule : timer