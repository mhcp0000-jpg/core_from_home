module rv_branch_arithmetic_case #(parameter int XLEN = 32)(output logic done_o);
  import rv_ooo_pkg::*;
  logic valid, predicted_taken, taken, misaligned, mispredict;
  branch_op_e operation;
  logic [XLEN-1:0] pc, a, b, immediate, predicted_target, target, next_pc, link;
  logic [2:0] bytes;
  logic [63:0] rng;
  int unsigned vectors;
  rv_branch_unit #(.XLEN(XLEN)) dut(
    .valid_i(valid), .operation_i(operation), .pc_i(pc),
    .operand_a_i(a), .operand_b_i(b), .immediate_i(immediate),
    .instruction_bytes_i(bytes), .predicted_taken_i(predicted_taken),
    .predicted_target_i(predicted_target), .taken_o(taken), .target_o(target),
    .next_pc_o(next_pc), .link_value_o(link), .target_misaligned_o(misaligned),
    .mispredict_o(mispredict));
  function automatic logic [63:0] random64();
    rng ^= rng << 13; rng ^= rng >> 7; rng ^= rng << 17;
    return rng;
  endfunction
  task automatic check();
    logic expected_taken, expected_misaligned, expected_mispredict;
    logic [XLEN-1:0] expected_target, expected_next, expected_link;
    #1;
    expected_link = pc + XLEN'(bytes);
    expected_target = pc + immediate;
    case (operation)
      BR_EQ: expected_taken = a == b;
      BR_NE: expected_taken = a != b;
      BR_LT: expected_taken = $signed(a) < $signed(b);
      BR_GE: expected_taken = $signed(a) >= $signed(b);
      BR_LTU: expected_taken = a < b;
      BR_GEU: expected_taken = a >= b;
      BR_JAL: expected_taken = 1;
      BR_JALR: begin
        expected_taken = 1;
        expected_target = (a + immediate) & ~XLEN'(1);
      end
      default: begin expected_taken = 0; expected_target = expected_link; end
    endcase
    expected_next = expected_taken ? expected_target : expected_link;
    expected_misaligned = valid && expected_taken && expected_target[0];
    expected_mispredict = valid && ((predicted_taken != expected_taken) ||
                         (expected_taken && predicted_target != expected_target));
    if ({taken,target,next_pc,link,misaligned,mispredict} !==
        {expected_taken,expected_target,expected_next,expected_link,
         expected_misaligned,expected_mispredict})
      $fatal(1,"BRU mismatch XLEN=%0d op=%0d a=%h b=%h pc=%h imm=%h",
             XLEN,operation,a,b,pc,immediate);
    vectors++;
  endtask
  initial begin
    done_o=0; vectors=0; rng=64'h937d_45ad_a129_07cb;
    valid=1; pc='1; immediate=1; bytes=2; predicted_taken=0; predicted_target=0;
    // All signed byte pairs, sign-extended to the actual architectural width.
    for (int av=0; av<256; av++) for (int bv=0; bv<256; bv++) begin
      a=XLEN'($signed(8'(av))); b=XLEN'($signed(8'(bv)));
      operation=BR_LT; check(); operation=BR_LTU; check();
    end
    for (int vector_id=0; vector_id<100000; vector_id++) begin
      a=XLEN'(random64()); b=XLEN'(random64()); pc=XLEN'(random64());
      immediate=XLEN'(random64()); predicted_target=XLEN'(random64());
      valid=1'(random64()); predicted_taken=1'(random64());
      bytes=vector_id[0] ? 3'd2 : 3'd4;
      if (vector_id%11==0) b=a;
      if (vector_id%13==0) b=~a;
      if (vector_id%17==0) a=XLEN'(1) << (vector_id%XLEN);
      operation=branch_op_e'(vector_id%16);
      // Include correct taken predictions, not only random target mismatches.
      if (vector_id%7==0) begin
        predicted_taken=1;
        predicted_target=(operation==BR_JALR) ?
                         ((a+immediate)&~XLEN'(1)) : (pc+immediate);
      end
      check();
    end
    $display("BRU arithmetic PASS XLEN=%0d (%0d vectors)",XLEN,vectors);
    done_o=1;
  end
endmodule
module rv_branch_arithmetic_tb;
  wire [1:0] done;
  rv_branch_arithmetic_case #(.XLEN(32)) c32(done[0]);
  rv_branch_arithmetic_case #(.XLEN(64)) c64(done[1]);
  initial begin wait (&done); $finish; end
endmodule
