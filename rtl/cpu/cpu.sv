// DeckCPU core: datapath + control FSM.
//
// Phase 3. Multi-cycle, non-pipelined, deterministic. The FSM walks
// FETCH -> DECODE -> EXECUTE -> MEM -> WRITEBACK, skipping states per
// instruction class (ISA-mandated cycle counts in isa/isa.json):
//
//   no-op / EI / DI / HALT     3  (FETCH, DECODE, EXEC)
//   ALU reg + immediate,       4  (FETCH, DECODE, EXEC, WB)
//     MOV/LI/LIH/RDSP/WRSP/RDFLAG/WRFLAG
//   branches/jumps, ST, PUSH,  4  (FETCH, DECODE, EXEC, MEM)
//     CALL (store+link)
//   loads, POP, RET            5  (FETCH, DECODE, EXEC, MEM, WB)
//   IRET                       6  (FETCH, DECODE, EXEC, MEM, MEM, WB —
//                                  two sequential word pops over single bus)
//
// Memory interface: a synchronous bus the Phase-4 bus/RAM will match. Reads
// are issued during the FETCH/MEM cycle and the sampled data is latched at
// the clock edge that ends that cycle (read data must track the address
// during the cycle). Writes are combinational address/data + we strobe.
//
// Interrupts: EI/DI control FLAGS.I (irq_en). Context-switch entry/exit is
// Phase 7; irq_ack is therefore parked at 0 here. A bus read error halts the
// core like HALT (Phase 4 refines fault handling).

module cpu import deckcpu_pkg::*; #(
    parameter int W    = 32,
    parameter int NREG = 16
)(
    input  logic                  clk,
    input  logic                  rst,

    // memory bus (to Phase-4 bus / RAM)
    output logic                  bus_re,
    output logic                  bus_we,
    output logic [W-1:0]          bus_addr,
    output mem_sz_t               bus_sz,
    output logic [W-1:0]          bus_wdata,
    input  logic [W-1:0]          bus_rdata,
    input  logic                  bus_err,

    // interrupts (entry logic Phase 7)
    input  logic                  irq_req,
    output logic                  irq_ack,
    output logic                  irq_en,

    // debug bundle (documented in docs/architecture.md)
    output state_t                dbg_state,
    output logic [W-1:0]          dbg_pc,
    output logic [W*NREG-1:0]     dbg_regs,
    output logic [W-1:0]          dbg_ir,
    output logic [7:0]            dbg_opcode,
    output logic [3:0]            dbg_rd,
    output logic [3:0]            dbg_rs1,
    output logic [3:0]            dbg_rs2,
    output logic [W-1:0]          dbg_alu_a,
    output logic [W-1:0]          dbg_alu_b,
    output logic [W-1:0]          dbg_alu_y,
    output logic [W-1:0]          dbg_sp,
    output logic [4:0]            dbg_flags,
    output logic [W-1:0]          dbg_mem_addr,
    output logic                  dbg_mem_re,
    output logic                  dbg_mem_we,
    output logic [W-1:0]          dbg_mem_wdata,
    output logic [W-1:0]          dbg_mem_rdata,
    output logic                  dbg_done,
    output logic [W-1:0]          dbg_cycle,
    output logic                  dbg_halted
);

    localparam int SPDESC = 4;                  // stack adjustment word count
    logic [W-1:0]        seq_pc;                // pc + 4 (fall-through)
    logic [W-1:0]        imm_sext, imm_zext, imm_high;
    logic [W-1:0]        alu_a, alu_b, alu_y;
    logic                alu_z, alu_n, alu_c, alu_v;
    logic                bcc_taken;

    // architectural state
    //
    // NB: every FSM/state register carries a 2-state declaration initializer.
    // Icarus enters a t=0 delta loop when an unpacked array is READ with an
    // index whose value is X (all `reg`s default to X before the first reset
    // edge); leaving ir/pc/sp uninitialized made decoder/regfile indices X and
    // hung the simulation at time 0. Values are re-armed by the reset branch
    // of the always_ff regardless.
    logic [W-1:0]        pc  = RESET_PC;
    logic [W-1:0]        sp  = RESET_SP;
    logic [W-1:0]        ir  = '0;
    decoded_instr_t      d;
    logic [4:0]          fl  = '0;               // I Z N C V
    logic [3:0]          yf  = '0;               // latched ALU flags (Z N C V)

    // pipeline latches
    logic [W-1:0]        y_l = '0;               // EXEC result / address / target
    logic [W-1:0]        rd_l = '0;              // single load pop
    logic [W-1:0]        rd_f = '0;              // IRET: popped FLAGS (first pop)
    logic [W-1:0]        rd_p = '0;              // IRET: popped PC   (second pop)
    logic                mem_phase = 1'b0;       // IRET second word
    logic                done = 1'b0;
    logic                halted = 1'b0;
    logic [W-1:0]        cycle_count = '0;

    // debug register snapshot (mirrors the regfile write port)
    state_t              state = S_FETCH;
    logic [W-1:0]        dbg_rf [NREG];
    logic [W-1:0]        wb_data;
    logic [W-1:0]        ext_rd;
    logic [W-1:0]        rdata_a, rdata_b;

    // regfile write enable taken in module scope: Icarus resolves enum
    // members in port-argument expressions to implicit wires (a scoping quirk),
    // so it is computed here and passed as a plain signal.
    logic rf_we;
    assign rf_we = !halted && state == S_WB && d.reg_we;

    regfile #(.W(W), .N(NREG)) rf_u (
        .clk(clk), .rst(rst),
        .we(rf_we),
        .waddr(d.rd), .wdata(wb_data),
        .raddr_a(d.rs1),
        .raddr_b(d.mem_we ? d.rd : d.rs2),
        .rdata_a(rdata_a), .rdata_b(rdata_b)
    );

    logic d_sel_add, d_sel_sub, d_sel_mul;
    logic d_sel_and, d_sel_or, d_sel_xor, d_sel_not;
    logic d_sel_shl, d_sel_shr, d_sel_a, d_sel_b;

    decoder dec_u (
        .instr(ir), .d(d),
        .sel_add(d_sel_add), .sel_sub(d_sel_sub), .sel_mul(d_sel_mul),
        .sel_and(d_sel_and), .sel_or(d_sel_or), .sel_xor(d_sel_xor), .sel_not(d_sel_not),
        .sel_shl(d_sel_shl), .sel_shr(d_sel_shr), .sel_a(d_sel_a), .sel_b(d_sel_b)
    );

    alu #(.W(W)) alu_u (
        .a(alu_a), .b(alu_b),
        .sel_add(d_sel_add), .sel_sub(d_sel_sub), .sel_mul(d_sel_mul),
        .sel_and(d_sel_and), .sel_or(d_sel_or), .sel_xor(d_sel_xor), .sel_not(d_sel_not),
        .sel_shl(d_sel_shl), .sel_shr(d_sel_shr), .sel_a(d_sel_a), .sel_b(d_sel_b),
        .y(alu_y), .z(alu_z), .n(alu_n), .c(alu_c), .v(alu_v)
    );

    branch_cond bc_u (
        .en(d.cond),
        .z(fl[FLAG_Z]), .n(fl[FLAG_N]), .c(fl[FLAG_C]), .v(fl[FLAG_V]),
        .taken(bcc_taken)
    );

    assign seq_pc = pc + 32'd4;
    assign irq_en = fl[FLAG_I];
    assign irq_ack = 1'b0;                       // interrupt entry is Phase 7

    always_comb begin
        imm_sext = {{16{d.imm[15]}}, d.imm};
        imm_zext = {16'b0, d.imm};
        imm_high = {d.imm, 16'b0};
    end

    // ALU operand muxes
    always_comb begin
        case (1'b1)
            d.alu_a_sp:    alu_a = sp;
            d.alu_a_pc:    alu_a = pc;
            d.alu_a_flags: alu_a = {27'b0, fl};
            default:       alu_a = rdata_a;
        endcase
        case (1'b1)
            d.alu_b_imm_high: alu_b = imm_high;
            d.alu_b_imm_zext: alu_b = imm_zext;
            d.alu_b_imm:      alu_b = imm_sext;
            d.alu_b_four:     alu_b = 32'd4;
            default:          alu_b = rdata_b;
        endcase
    end

    // write-back data: ALU result or (zero-extended) loaded data
    always_comb begin
        case (d.mem_sz)
            SZ_BYTE:  ext_rd = {24'b0, rd_l[7:0]};
            SZ_HALF:  ext_rd = {16'b0, rd_l[15:0]};
            default:  ext_rd = rd_l;
        endcase
        wb_data = (d.wb_src == WB_MEM) ? ext_rd : y_l;
    end

    // memory bus drives (combinational; no transaction outside FETCH/MEM)
    logic [W-1:0] mem_addr_m;
    always_comb begin
        bus_re   = (state == S_FETCH) || (state == S_MEM && d.mem_re);
        bus_we   = (state == S_MEM) && d.mem_we && !d.iret;
        bus_sz   = (state == S_FETCH) ? SZ_WORD : d.mem_sz;
        bus_addr = (state == S_FETCH) ? pc
                 : (state == S_MEM) ? mem_addr_m
                 : pc;
        bus_wdata = (d.call) ? seq_pc
                  : (d.stack_op ? rdata_a : rdata_b);
    end

    always_comb begin
        if (d.iret) begin
            mem_addr_m = mem_phase ? y_l : (y_l - 32'd4);
        end else if (d.stack_pop) begin
            mem_addr_m = y_l - 32'd4;            // POP/RET: old sp
        end else if (d.call) begin
            mem_addr_m = sp - 32'd4;             // CALL: push below sp
        end else if (d.stack_op) begin
            mem_addr_m = y_l;                    // PUSH: sp - 4 (y_l)
        end else begin
            mem_addr_m = y_l;                    // LD/ST base+off
        end
    end

    // debug flat register snapshot: dbg_regs[i*32 +: 32] = r[i]
    genvar gi;
    generate
        for (gi = 0; gi < NREG; gi++) begin : g_dbg_regs
            assign dbg_regs[gi*W +: W] = dbg_rf[gi];
        end
    endgenerate

    always_ff @(posedge clk) begin
        cycle_count <= cycle_count + 32'd1;
        if (rst) begin
            state      <= S_FETCH;
            pc         <= RESET_PC;
            sp         <= RESET_SP;
            fl         <= '0;
            ir         <= '0;
            y_l        <= '0;
            yf         <= '0;
            rd_l       <= '0;
            rd_f       <= '0;
            rd_p       <= '0;
            mem_phase  <= 1'b0;
            done       <= 1'b0;
            halted     <= 1'b0;
            for (int i = 0; i < NREG; i++)
                dbg_rf[i] <= '0;
        end else if (halted) begin
            done <= 1'b0;
        end else begin
            done <= 1'b0;
            case (state)
                S_FETCH: begin
                    mem_phase <= 1'b0;
                    if (bus_err) begin
                        halted <= 1'b1;
                        state  <= S_WB;
                    end else begin
                        ir    <= bus_rdata;
                        state <= S_DECODE;
                    end
                end
                S_DECODE: begin
                    state <= S_EXEC;
                end
                S_EXEC: begin
                    // Bcc computes its (pc-relative) target directly; every
                    // other instruction latches the raw ALU output.
                    if (d.branch && !d.jmp && !d.ret && !d.iret)
                        y_l <= pc + imm_sext;
                    else
                        y_l <= alu_y;
                    yf <= {alu_v, alu_c, alu_n, alu_z};
                    if (d.halt) begin
                        halted <= 1'b1;
                        pc    <= pc;
                        done  <= 1'b1;
                        state <= S_HALT;
                    end else if (d.irq_ctl) begin
                        fl[FLAG_I] <= d.irq_set;
                        pc  <= seq_pc;
                        done <= 1'b1;
                        state <= S_FETCH;
                    end else if (d.branch || d.mem_re || d.mem_we) begin
                        state <= S_MEM;
                    end else if (d.reg_we || d.flags_we || d.wr_sp || d.wr_flags) begin
                        state <= S_WB;
                    end else begin
                        pc  <= seq_pc;
                        done <= 1'b1;
                        state <= S_FETCH;
                    end
                end
                S_MEM: begin
                    if (d.mem_re && bus_err) begin
                        halted <= 1'b1;
                        state  <= S_WB;
                    end else if (d.iret) begin
                        if (!mem_phase) begin
                            rd_f      <= bus_rdata;
                            sp        <= y_l;
                            mem_phase <= 1'b1;
                            state     <= S_MEM;
                        end else begin
                            rd_p  <= bus_rdata;
                            sp    <= y_l + 32'd4;
                            state <= S_WB;
                        end
                    end else if (d.ret) begin
                        rd_l  <= bus_rdata;
                        sp    <= y_l;             // y_l = sp + 4
                        state <= S_WB;
                    end else if (d.mem_re) begin
                        rd_l <= bus_rdata;
                        if (d.stack_pop)
                            sp <= y_l;           // POP
                        state <= S_WB;
                    end else begin
                        // No bus transaction. Update the next PC here so that
                        // pure control-flow instructions (JMP/JMPR/branches)
                        // still advance; stores only advance when mem_we.
                        if (d.mem_we) begin
                            if (d.call)
                                sp <= sp - 32'd4;            // CALL: push below sp
                            else if (d.stack_op)
                                sp <= y_l;                   // PUSH: y_l = sp - 4
                        end
                        if (d.jmp)
                            pc <= y_l;                       // JMP/JMPR target
                        else if (d.branch)
                            pc <= bcc_taken ? y_l : seq_pc;  // Bcc taken?
                        else if (d.call)
                            pc <= y_l;                       // CALL target
                        else
                            pc <= seq_pc;                    // store / fall-through
                        done  <= 1'b1;
                        state <= S_FETCH;
                    end
                end
                S_WB: begin
                    if (d.ret) begin
                        pc <= rd_l;
                    end else if (d.iret) begin
                        pc  <= rd_p;
                    end else begin
                        pc <= seq_pc;
                    end
                    if (d.wr_sp)
                        sp <= y_l;
                    if (d.iret)
                        fl <= rd_f[4:0];
                    else if (d.wr_flags)
                        fl <= y_l[4:0];
                    else if (d.flags_we)
                        fl <= {yf, fl[FLAG_I]};
                    if (d.reg_we)
                        dbg_rf[d.rd] <= wb_data;
                    done  <= 1'b1;
                    state <= S_FETCH;
                end
                default: ;
            endcase
        end
    end

    // ---- debug bundle ----
    assign dbg_state     = state;
    assign dbg_pc        = pc;
    assign dbg_sp        = sp;
    assign dbg_flags     = fl;
    assign dbg_ir        = ir;
    assign dbg_opcode    = d.op;
    assign dbg_rd        = d.rd;
    assign dbg_rs1       = d.rs1;
    assign dbg_rs2       = d.rs2;
    assign dbg_alu_a     = alu_a;
    assign dbg_alu_b     = alu_b;
    assign dbg_alu_y     = alu_y;
    assign dbg_mem_addr  = bus_addr;
    assign dbg_mem_re    = bus_re;
    assign dbg_mem_we    = bus_we;
    assign dbg_mem_wdata = bus_wdata;
    assign dbg_mem_rdata = bus_rdata;
    assign dbg_done      = done;
    assign dbg_cycle     = cycle_count;
    assign dbg_halted    = halted;

endmodule : cpu