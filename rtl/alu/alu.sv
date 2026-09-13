// DeckCPU ALU — purely combinational.
//
// Phase 2. Single 32-bit ALU performing ADD/SUB/MUL, logic ops, shifts and
// operand pass-throughs. Produces the Z/N/C/V status flags directly.
//
// Flag semantics (see docs/isa.md):
//   ADD: C = carry out, V = signed overflow
//   SUB: C = borrow (1 when a < b unsigned), V = signed overflow
//   MUL/AND/OR/XOR/NOT: C=V=0, Z/N set from result
//   SHL: C = last bit shifted out (bit W-count)
//   SHR: C = last bit shifted out (bit count-1); logical shift
//
// The comparison instructions (CMP/CMPI) reuse ALU_SUB; branches derive
// their condition from the resulting flags.

module alu import deckcpu_pkg::*; #(
    parameter int W = 32
)(
    input  logic [W-1:0] a,
    input  logic [W-1:0] b,
    input  alu_op_t      op,
    output logic [W-1:0] y,
    output logic         z,
    output logic         n,
    output logic         c,
    output logic         v
);

    logic [4:0]          shamt;
    logic [W-1:0]        shl_y;
    logic [W-1:0]        shr_y;
    logic [W-1:0]        add_y;
    logic [W-1:0]        sub_y;
    logic [W-1:0]        mul_y;
    logic                shl_c;
    logic                shr_c;

    always_comb begin
        add_y = a + b;
        sub_y = a - b;
        mul_y = a * b;
    end

    always_comb begin
        shamt = b[4:0];
        shl_y = a << shamt;
        shr_y = a >> shamt;
    end

    // carry from shifts: last bit shifted out
    // (dynamic bit-select; unrolled constant-index loops trip Icarus's
    //  "constant selects" fallback and create a delta loop)
    always_comb begin
        shl_c = (shamt == '0) ? 1'b0 : a[W - shamt];
    end
    always_comb begin
        shr_c = (shamt == '0) ? 1'b0 : a[shamt - 1];
    end

    always_comb begin
        y = '0;
        c = 1'b0;
        v = 1'b0;
        unique case (op)
            ALU_ADD: begin
                y = add_y;
                c = add_y < a;                          // carry out (unsigned wraparound)
                v = (~a[W-1] & ~b[W-1] & add_y[W-1]) |
                    ( a[W-1] &  b[W-1] & ~add_y[W-1]);
            end
            ALU_SUB: begin
                y = sub_y;
                c = a < b;                              // borrow
                v = (~a[W-1] & b[W-1] & sub_y[W-1]) |
                    ( a[W-1] & ~b[W-1] & ~sub_y[W-1]);
            end
            ALU_MUL: begin y = mul_y; end
            ALU_AND: begin y = a & b; end
            ALU_OR:  begin y = a | b; end
            ALU_XOR: begin y = a ^ b; end
            ALU_NOT: begin y = ~a; end
            ALU_SHL: begin y = shl_y; c = shl_c; end
            ALU_SHR: begin y = shr_y; c = shr_c; end
            ALU_A:   begin y = a; end
            ALU_B:   begin y = b; end
            default: ;
        endcase
        z = (y == '0);
        n = y[W-1];
    end

endmodule : alu