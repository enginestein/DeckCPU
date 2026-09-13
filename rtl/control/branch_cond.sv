// DeckCPU branch condition evaluation (combinational).
//
// Phase 2. Decides whether a B-format conditional branch is taken based on
// the flags produced by an ALU subtraction (rs1 - rs2). The `en` input
// selects the condition group for Bcc instructions.
//
//   BC_EQ : Z=1       BC_NE : Z=0
//   BC_LT : N!=V      BC_GE : N==V     (signed comparisons)
//   BC_LTU: C=1       BC_GEU: C=0      (unsigned, borrow flag)

module branch_cond import deckcpu_pkg::*; (
    input  branch_cond_t en,
    input  logic         z,
    input  logic         n,
    input  logic         c,
    input  logic         v,
    output logic         taken
);
    always_comb begin
        unique case (en)
            BC_EQ : taken = z;
            BC_NE : taken = ~z;
            BC_LT : taken = (n != v);
            BC_GE : taken = (n == v);
            BC_LTU: taken = c;
            BC_GEU: taken = ~c;
            default: taken = 1'b0;
        endcase
    end

endmodule : branch_cond