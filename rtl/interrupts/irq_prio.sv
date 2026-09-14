// DeckCPU interrupt arbiter.
//
// Combines the five peripheral level-asserted IRQ lines into the single
// `irq_req` the CPU polls at instruction boundaries plus the IVT slot of the
// highest-priority source. Priority is by slot index (docs/isa.md): lower
// index = higher priority, so TIMER (slot 1) > UART_RX (2) > UART_TX (3) >
// GPIO (4) > SPI (5). Slot 0 is the reset entry and is never dispatched.
//
// Per-source masking and status logic are planned for the PIC
// (rtl/peripherals), which will take over this role.
//
// The mux is a plain combinational priority chain (no state), so Icarus has
// nothing to delta-loop on and it is synthesizable.

module irq_prio (
    input  logic       irq_timer,     // slot 1 (highest priority)
    input  logic       irq_uart_rx,   // slot 2
    input  logic       irq_uart_tx,   // slot 3
    input  logic       irq_gpio,      // slot 4
    input  logic       irq_spi,       // slot 5 (lowest priority)
    output logic       irq_req,
    output logic [2:0] irq_vec        // slot of the selected source (1..5; 0 = none)
);

    always_comb begin
        if (irq_timer)         irq_vec = 3'd1;
        else if (irq_uart_rx)  irq_vec = 3'd2;
        else if (irq_uart_tx)  irq_vec = 3'd3;
        else if (irq_gpio)     irq_vec = 3'd4;
        else if (irq_spi)      irq_vec = 3'd5;
        else                   irq_vec = 3'd0;
    end

    assign irq_req = irq_timer | irq_uart_rx | irq_uart_tx | irq_gpio | irq_spi;

endmodule : irq_prio