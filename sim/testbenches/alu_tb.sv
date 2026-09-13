// ALU testbench: directed edge cases + randomized vectors against an
// independent reference computed inline in the testbench.
module alu_tb;
  import deckcpu_pkg::*;

  logic [31:0] a, b, y, ey;
  logic [31:0] rnd;
  logic        z, n, c, v, ez, en, ec, ev;
  alu_op_t     op;
  int          fails = 0, checks = 0;

  alu #(.W(32)) dut (.*);

  // Compares DUT outputs against the reference just after driving a,b.
  // The selected operation is the module-level enum `op`, set by the caller
  // (Icarus cannot pass enums as task arguments).
  task check_case;
    input [31:0] da;
    input [31:0] db;
    input [31:0] y_ref;
    input [31:0] c_ref;
    input [31:0] v_ref;
    begin
      a = da; b = db;
      #1;
      ey = y_ref; ec = c_ref; ev = v_ref;
      ez = (y_ref == 0); en = y_ref[31];
      checks++;
      if (y !== ey || z !== ez || n !== en || c !== ec || v !== ev) begin
        fails++;
        $display("FAIL op=%h a=%h b=%h y=%h(exp %h) z=%b n=%b c=%b v=%b (exp z=%b n=%b c=%b v=%b)",
                 int'(op), da, db, y, ey, z, n, c, v, ez, en, ec, ev);
      end
    end
  endtask

  // reference computation for randomized vectors: uses module-level `op`
  task check_random;
    input [31:0] ra;
    input [31:0] rb;
    reg [32:0] wide;
    reg [63:0] wide64;
    reg [31:0] ry;
    reg        rc;
    reg        rv;
    reg [4:0]  sh;
    begin
      ry = 0; rc = 0; rv = 0;
      unique case (op)
        ALU_ADD: begin
          wide = {1'b0, ra} + {1'b0, rb};
          ry = wide[31:0]; rc = wide[32];
          rv = (~ra[31] & ~rb[31] & ry[31]) | (ra[31] & rb[31] & ~ry[31]);
        end
        ALU_SUB: begin
          wide = ra - rb;
          ry = wide[31:0];
          rc = (ra < rb);
          rv = (~ra[31] & rb[31] & ry[31]) | (ra[31] & ~rb[31] & ~ry[31]);
        end
        ALU_MUL: begin
          wide64 = ra * rb;
          ry = wide64[31:0];
        end
        ALU_AND: ry = ra & rb;
        ALU_OR:  ry = ra | rb;
        ALU_XOR: ry = ra ^ rb;
        ALU_NOT: ry = ~ra;
        ALU_SHL: begin
          sh = rb[4:0];
          ry = ra << sh;
          rc = (sh == 0) ? 1'b0 : ra[W - sh];
        end
        ALU_SHR: begin
          sh = rb[4:0];
          ry = ra >> sh;
          rc = (sh == 0) ? 1'b0 : ra[sh - 1];
        end
        default: ry = ra;
      endcase
      check_case(ra, rb, ry, rc, rv);
    end
  endtask

  initial begin
    // ---- directed edge cases ----
    op = ALU_ADD; check_case(32'h0000_0001, 32'h0000_0002, 32'h0000_0003, 1'b0, 1'b0);
    check_case(32'hFFFF_FFFF, 32'h0000_0001, 32'h0000_0000, 1'b1, 1'b0); // wrap + carry
    check_case(32'h7FFF_FFFF, 32'h0000_0001, 32'h8000_0000, 1'b0, 1'b1); // signed ovf
    check_case(32'h8000_0000, 32'h8000_0000, 32'h0000_0000, 1'b1, 1'b1);
    op = ALU_SUB; check_case(32'h0000_000A, 32'h0000_0003, 32'h0000_0007, 1'b0, 1'b0);
    check_case(32'h0000_0003, 32'h0000_000A, 32'hFFFF_FFF9, 1'b1, 1'b0); // borrow
    check_case(32'hFFFF_FFFF, 32'h0000_0001, 32'hFFFF_FFFE, 1'b0, 1'b0);
    op = ALU_MUL; check_case(32'h0000_000A, 32'h0000_000A, 32'h0000_0064, 1'b0, 1'b0);
    check_case(32'hFFFF_FFFF, 32'hFFFF_FFFF, 32'h0000_0001, 1'b0, 1'b0);
    op = ALU_AND; check_case(32'h00FF_00FF, 32'hF0F0_F0F0, 32'h00F0_00F0, 1'b0, 1'b0);
    op = ALU_OR;  check_case(32'h0000_FF00, 32'hFF00_0000, 32'hFF00_FF00, 1'b0, 1'b0);
    op = ALU_XOR; check_case(32'h0000_FFFF, 32'hFFFF_0000, 32'hFFFF_FFFF, 1'b0, 1'b0);
    op = ALU_NOT; check_case(32'h0000_0000, 32'h0000_0000, 32'hFFFF_FFFF, 1'b0, 1'b0);
    op = ALU_SHL; check_case(32'h8000_0000, 32'd1,  32'h0000_0000, 1'b1, 1'b0);
    check_case(32'h0000_0001, 32'd31, 32'h8000_0000, 1'b0, 1'b0);
    check_case(32'h0000_0001, 32'd0,  32'h0000_0001, 1'b0, 1'b0);
    check_case(32'h0000_AAAA, 32'd4,  32'h000A_AAA0, 1'b0, 1'b0);
    op = ALU_SHR; check_case(32'h0000_0001, 32'd1,  32'h0000_0000, 1'b1, 1'b0);
    check_case(32'h8000_0000, 32'd31, 32'h0000_0001, 1'b0, 1'b0);
    check_case(32'hFFFF_FFFF, 32'd4,  32'h0FFF_FFFF, 1'b1, 1'b0);
    op = ALU_A;   check_case(32'hDEAD_BEEF, 32'h1234_5678, 32'hDEAD_BEEF, 1'b0, 1'b0);
    op = ALU_B;   check_case(32'hDEAD_BEEF, 32'h1234_5678, 32'h1234_5678, 1'b0, 1'b0);

    // ---- randomized ----
    for (int t = 0; t < 4000; t++) begin
      rnd = 32'($random);
      unique case (rnd % 9)
        0: op = ALU_ADD;
        1: op = ALU_SUB;
        2: op = ALU_MUL;
        3: op = ALU_AND;
        4: op = ALU_OR;
        5: op = ALU_XOR;
        6: op = ALU_NOT;
        7: op = ALU_SHL;
        default: op = ALU_SHR;
      endcase
      check_random($random, $random);
    end

    if (fails) begin
      $display("ALU: %0d/%0d checks FAILED", fails, checks);
      $fatal(1, "alu_tb failed");
    end
    $display("alu_tb: %0d checks OK", checks);
    $finish;
  end
endmodule : alu_tb