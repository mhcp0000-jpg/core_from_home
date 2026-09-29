// Randomized equivalence check: rv_issue_arbiter AGE_ORDERED=1 against the
// generic search, for age-ordered candidate pairs (candidate 0 older).
module rv_issue_arbiter_age_tb;
  localparam int unsigned SEQW = 8;
  logic [1:0] valid;
  logic [1:0][SEQW-1:0] seq;
  logic [1:0][4:0] mask;
  logic [4:0] ready;
  logic [1:0] g_a, g_b;
  logic [1:0][2:0] cp_a, cp_b;
  logic [4:0] pv_a, pv_b;
  logic [4:0] pc_a, pc_b;
  logic [1:0] iv_a, iv_b;
  logic [1:0] ic_a, ic_b;
  logic [1:0][2:0] ip_a, ip_b;

  rv_issue_arbiter #(.CANDIDATE_COUNT(2), .EXEC_PORTS(5), .ISSUE_WIDTH(2),
                     .ROB_SEQ_WIDTH(SEQW), .AGE_ORDERED(1'b1)) u_fast (
    .candidate_valid_i(valid), .candidate_sequence_i(seq),
    .candidate_port_mask_i(mask), .port_ready_i(ready),
    .candidate_grant_o(g_a), .candidate_port_o(cp_a), .port_valid_o(pv_a),
    .port_candidate_o(pc_a), .issue_valid_o(iv_a), .issue_candidate_o(ic_a),
    .issue_port_o(ip_a));
  rv_issue_arbiter #(.CANDIDATE_COUNT(2), .EXEC_PORTS(5), .ISSUE_WIDTH(2),
                     .ROB_SEQ_WIDTH(SEQW), .AGE_ORDERED(1'b0)) u_ref (
    .candidate_valid_i(valid), .candidate_sequence_i(seq),
    .candidate_port_mask_i(mask), .port_ready_i(ready),
    .candidate_grant_o(g_b), .candidate_port_o(cp_b), .port_valid_o(pv_b),
    .port_candidate_o(pc_b), .issue_valid_o(iv_b), .issue_candidate_o(ic_b),
    .issue_port_o(ip_b));

  int unsigned seed = 32'h5eed_a9e0, errors = 0, dual = 0;
  initial begin
    for (int n = 0; n < 200000; n++) begin
      valid = 2'($urandom(seed)); seed++;
      seq[0] = SEQW'($urandom(seed)); seed++;
      seq[1] = seq[0] + SEQW'(1 + ($urandom(seed) % 100)); seed++;
      mask[0] = 5'($urandom(seed)); seed++;
      mask[1] = 5'($urandom(seed)); seed++;
      // realistic masks half the time (INT 00011, BR 00001, MUL 00010,
      // MEM 01100, FP 10000), random otherwise
      if ($urandom(seed) % 2) begin
        case ($urandom(seed+7) % 5)
          0: mask[0] = 5'b00011; 1: mask[0] = 5'b00001; 2: mask[0] = 5'b00010;
          3: mask[0] = 5'b01100; default: mask[0] = 5'b10000;
        endcase
        case ($urandom(seed+13) % 5)
          0: mask[1] = 5'b00011; 1: mask[1] = 5'b00001; 2: mask[1] = 5'b00010;
          3: mask[1] = 5'b01100; default: mask[1] = 5'b10000;
        endcase
      end
      seed++;
      ready = (($urandom(seed) % 3) == 0) ? 5'($urandom(seed+1)) : 5'b11111; seed += 2;
      #1;
      if ({g_a, cp_a, pv_a, pc_a, iv_a, ic_a, ip_a} !==
          {g_b, cp_b, pv_b, pc_b, iv_b, ic_b, ip_b}) begin
        errors++;
        if (errors < 5)
          $display("MISMATCH v=%b m0=%b m1=%b rdy=%b fast g=%b p=%p ref g=%b p=%p",
                   valid, mask[0], mask[1], ready, g_a, cp_a, g_b, cp_b);
      end
      if (&iv_b) dual++;
    end
    if (errors == 0) $display("rv_issue_arbiter_age_tb PASS vectors=200000 dual_issue=%0d", dual);
    else $display("rv_issue_arbiter_age_tb FAIL errors=%0d", errors);
    $finish;
  end
endmodule
