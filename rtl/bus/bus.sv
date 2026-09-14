// DeckCPU synchronous bus — single master, combinational window decode.
//
// Implements the bus contract: the CPU (the only
// master) drives re/we/sz/addr/wdata; the bus derives byte-enable strobes
// and returns rdata/err. All window decodes are combinational over the
// registered master address, so the netlist settles once per cycle (no
// Icarus delta loops).
//
// Slaves:
//   - RAM: 0x0000_0000 - 0x0000_FFFF   (rtl/memory/ram.sv)
//   - UART:0x4000_0000 - 0x4000_0FFF   (rtl/peripherals/uart.sv)
//   - TIMER:0x4000_1000 - 0x4000_1FFF  (rtl/peripherals/timer.sv)
//   - GPIO:0x4000_2000 - 0x4000_2FFF   (rtl/peripherals/gpio.sv)
//   - SPI: 0x4000_3000 - 0x4000_3FFF   (rtl/peripherals/spi.sv)
// anything else: err=1, rdata=0.
//
// Strobe policy: only the selected slave receives re/we, and its address is
// clamped to the slave's own width, so a slave never indexes out of range
// while unselected. Peripheral IRQ lines pass straight through the bus to
// the priority arbiter (`irq_prio`). A mapped MMIO window always returns err=0; only an
// address outside every window faults and halts the CPU.

module bus import deckcpu_pkg::*; #(
    parameter int W = 32
)(
    input  logic                clk,
    input  logic                rst,

    // master (CPU)
    input  logic                re,
    input  logic                we,
    input  mem_sz_t             sz,
    input  logic [W-1:0]        addr,
    input  logic [W-1:0]        wdata,
    output logic [W-1:0]        rdata,
    output logic                err,
    output logic [3:0]          be,

    // slave 0: RAM
    output logic                ram_re,
    output logic                ram_we,
    output logic [3:0]          ram_be,
    output logic [RAM_AW-1:0]   ram_addr,
    output logic [W-1:0]        ram_wdata,
    input  logic [W-1:0]        ram_rdata,

    // MMIO window selects (decode; peripherals wired below)
    output logic                uart_sel,
    output logic                timer_sel,
    output logic                gpio_sel,
    output logic                spi_sel,

    // slave 1: UART
    output logic                uart_re,
    output logic                uart_we,
    output logic [3:0]          uart_be,
    output logic [11:0]         uart_addr,
    output logic [W-1:0]        uart_wdata,
    input  logic [W-1:0]        uart_rdata,

    // slave 2: TIMER
    output logic                timer_re,
    output logic                timer_we,
    output logic [3:0]          timer_be,
    output logic [11:0]         timer_addr,
    output logic [W-1:0]        timer_wdata,
    input  logic [W-1:0]        timer_rdata,

    // slave 3: GPIO
    output logic                gpio_re,
    output logic                gpio_we,
    output logic [3:0]          gpio_be,
    output logic [11:0]         gpio_addr,
    output logic [W-1:0]        gpio_wdata,
    input  logic [W-1:0]        gpio_rdata,

    // slave 4: SPI
    output logic                spi_re,
    output logic                spi_we,
    output logic [3:0]          spi_be,
    output logic [11:0]         spi_addr,
    output logic [W-1:0]        spi_wdata,
    input  logic [W-1:0]        spi_rdata,

    // peripheral IRQ inputs from the slaves
    input  logic                uart_irq_rx,
    input  logic                uart_irq_tx,
    input  logic                timer_irq,
    input  logic                gpio_irq,
    input  logic                spi_irq,

    // peripheral IRQ lines, passed through to irq_prio
    output logic                irq_uart_rx,
    output logic                irq_uart_tx,
    output logic                irq_timer,
    output logic                irq_gpio,
    output logic                irq_spi
);

    logic ram_sel;
    logic mmio_sel;

    assign ram_sel   = (addr >= RAM_BASE) && (addr <= RAM_END);
    assign uart_sel  = addr[31:12] == UART_BASE[31:12];
    assign timer_sel = addr[31:12] == TIMER_BASE[31:12];
    assign gpio_sel  = addr[31:12] == GPIO_BASE[31:12];
    assign spi_sel   = addr[31:12] == SPI_BASE[31:12];
    assign mmio_sel  = uart_sel | timer_sel | gpio_sel | spi_sel;

    // only an address outside every window is a fault;
    // a mapped MMIO window returns err=0 with the peripheral's rdata.
    assign err = !(ram_sel | mmio_sel);

    // byte enables from access size + byte address
    always_comb begin
        case (sz)
            SZ_HALF: begin
                if (addr[1]) be = 4'b1100; else be = 4'b0011;
            end
            SZ_BYTE: begin
                case (addr[1:0])
                    2'b00:   be = 4'b0001;
                    2'b01:   be = 4'b0010;
                    2'b10:   be = 4'b0100;
                    default: be = 4'b1000;
                endcase
            end
            default: be = 4'b1111;       // SZ_WORD (fetch + data)
        endcase
    end

    // read data: combinational mux over the selected slave's rdata.
    always_comb begin
        if (ram_sel)
            rdata = ram_rdata;
        else if (uart_sel)
            rdata = uart_rdata;
        else if (timer_sel)
            rdata = timer_rdata;
        else if (gpio_sel)
            rdata = gpio_rdata;
        else if (spi_sel)
            rdata = spi_rdata;
        else
            rdata = {W{1'b0}};
    end

    // master -> RAM slave (strobes gated to the selected window)
    assign ram_re    = re && ram_sel;
    assign ram_we    = we && ram_sel;
    assign ram_be    = be;
    assign ram_addr  = addr[RAM_AW-1:0];
    assign ram_wdata = wdata;

    // master -> MMIO slaves; addr[11:0] is the window offset, strobes gated.
    assign uart_re    = re && uart_sel;
    assign uart_we    = we && uart_sel;
    assign uart_be    = be;
    assign uart_addr  = addr[11:0];
    assign uart_wdata = wdata;

    assign timer_re    = re && timer_sel;
    assign timer_we    = we && timer_sel;
    assign timer_be    = be;
    assign timer_addr  = addr[11:0];
    assign timer_wdata = wdata;

    assign gpio_re    = re && gpio_sel;
    assign gpio_we    = we && gpio_sel;
    assign gpio_be    = be;
    assign gpio_addr  = addr[11:0];
    assign gpio_wdata = wdata;

    assign spi_re    = re && spi_sel;
    assign spi_we    = we && spi_sel;
    assign spi_be    = be;
    assign spi_addr  = addr[11:0];
    assign spi_wdata = wdata;

    // peripheral IRQ lines pass through to irq_prio
    assign irq_uart_rx = uart_irq_rx;
    assign irq_uart_tx = uart_irq_tx;
    assign irq_timer   = timer_irq;
    assign irq_gpio    = gpio_irq;
    assign irq_spi     = spi_irq;

endmodule : bus