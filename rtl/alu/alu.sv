// no hardcore alu

module alu import deckcpu_pkg::*; #(
    parameter int W = 32
)(
    input  logic [W-1:0] a,
    input  logic [W-1:0] b,
    input  logic         sel_add, sel_sub, sel_mul,
    input  logic         sel_and, sel_or, sel_xor, sel_not,
    input  logic         sel_shl, sel_shr,
    input  logic         sel_a, sel_b,
    output logic [W-1:0] y,
    output logic         z,
    output logic         n,
    output logic         c,
    output logic         v
);

    logic [W-1:0] add_y, sub_y, mul_y;
    logic [W-1:0] and_y, or_y, xor_y, not_y;
    logic [W-1:0] shl_y, shr_y, shl_of, shr_of;
    logic         add_c, add_v, sub_c, sub_v, shl_c, shr_c;

    assign add_y = a + b;
    assign sub_y = a - b;
    assign mul_y = a * b;
    assign and_y = a & b;
    assign or_y  = a | b;
    assign xor_y = a ^ b;
    assign not_y = ~a;

    assign shl_y = a << b[4:0];
    assign shr_y = a >> b[4:0];
    assign shl_of = a >> (W - b[4:0]);      // bit W-shamt lands in [0]
    assign shr_of = a >> (b[4:0] - 1);      // bit shamt-1 lands in [0]

    assign add_c = add_y < a;               // carry out (unsigned wraparound)
    assign add_v = (~a[W-1] & ~b[W-1] & add_y[W-1]) |
                   ( a[W-1] &  b[W-1] & ~add_y[W-1]);
    assign sub_c = a < b;                   // borrow
    assign sub_v = (~a[W-1] & b[W-1] & sub_y[W-1]) |
                   ( a[W-1] & ~b[W-1] & ~sub_y[W-1]);
    assign shl_c = (b[4:0] != 0) ? shl_of[0] : 1'b0;
    assign shr_c = (b[4:0] != 0) ? shr_of[0] : 1'b0;

    assign y = ({W{sel_add}} & add_y) |
               ({W{sel_sub}} & sub_y) |
               ({W{sel_mul}} & mul_y) |
               ({W{sel_and}} & and_y) |
               ({W{sel_or}}  & or_y)  |
               ({W{sel_xor}} & xor_y) |
               ({W{sel_not}} & not_y) |
               ({W{sel_shl}} & shl_y) |
               ({W{sel_shr}} & shr_y) |
               ({W{sel_a}}   & a)      |
               ({W{sel_b}}   & b);

    assign z = (y == '0);
    assign n = y[W-1];
    assign c = (sel_add & add_c) | (sel_sub & sub_c) |
               (sel_shl & shl_c)  | (sel_shr & shr_c);
    assign v = (sel_add & add_v) | (sel_sub & sub_v);

endmodule : alu