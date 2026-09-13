// Branch condition testbench: exhaustive over all 6 conditions with all
// 16 flag combinations against an independent boolean reference.
module branch_cond_tb;
  import deckcpu_pkg::*;

  branch_cond_t en;
  logic z, n, c, v, taken;
  int fails = 0, checks = 0;

  branch_cond dut (.*);

  task check;
    logic exp;
    begin
      case (en)
        BC_EQ : exp =  z;
        BC_NE : exp = ~z;
        BC_LT : exp = (n != v);
        BC_GE : exp = (n == v);
        BC_LTU: exp =  c;
        BC_GEU: exp = ~c;
        default: exp = 1'b0;
      endcase
      checks++;
      if (taken !== exp) begin
        fails++;
        $display("FAIL cond=%h flags z=%b n=%b c=%b v=%b taken=%b exp=%b",
                 int'(en), z, n, c, v, taken, exp);
      end
    end
  endtask

  initial begin
    for (int ci = 0; ci < 6; ci++) begin
      unique case (ci[2:0])
        0: en = BC_EQ;
        1: en = BC_NE;
        2: en = BC_LT;
        3: en = BC_GE;
        4: en = BC_LTU;
        default: en = BC_GEU;
      endcase
      for (int fv = 0; fv < 16; fv++) begin
        z = fv[0]; n = fv[1]; c = fv[2]; v = fv[3];
        #1;
        check();
      end
    end
    if (fails) begin
      $display("branch_cond_tb: %0d/%0d FAILED", fails, checks);
      $fatal(1, "branch_cond_tb failed");
    end
    $display("branch_cond_tb: %0d checks OK", checks);
    $finish;
  end
endmodule : branch_cond_tb