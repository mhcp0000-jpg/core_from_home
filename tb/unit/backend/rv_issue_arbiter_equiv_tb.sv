module rv_issue_arbiter_equiv_tb;
  logic [1:0] valid;
  logic [1:0][7:0] sequence_id;
  logic [1:0][4:0] mask;
  logic [4:0] ready;
  typedef struct packed {
    logic [1:0] grant;
    logic [1:0][2:0] candidate_port;
    logic [4:0] port_valid;
    logic [4:0] port_candidate;
    logic [1:0] issue_valid;
    logic [1:0] issue_candidate;
    logic [1:0][2:0] issue_port;
  } result_t;
  result_t result [0:1];
  for (genvar version = 0; version < 2; version++) begin : g_version
    rv_issue_arbiter #(.CANDIDATE_COUNT(2), .EXEC_PORTS(5), .ISSUE_WIDTH(2),
      .ROB_SEQ_WIDTH(8), .AGE_ORDERED(version == 1)) u_dut (
      .candidate_valid_i(valid), .candidate_sequence_i(sequence_id),
      .candidate_port_mask_i(mask), .port_ready_i(ready),
      .candidate_grant_o(result[version].grant),
      .candidate_port_o(result[version].candidate_port),
      .port_valid_o(result[version].port_valid),
      .port_candidate_o(result[version].port_candidate),
      .issue_valid_o(result[version].issue_valid),
      .issue_candidate_o(result[version].issue_candidate),
      .issue_port_o(result[version].issue_port));
  end
  initial begin
    valid = '0; mask = '0; ready = '0; sequence_id = '0;
    // All validity/mask/readiness combinations, both straight and wrapped age.
    for (int wrap = 0; wrap < 2; wrap++) begin
      sequence_id[0] = wrap ? 8'hff : 8'd42;
      sequence_id[1] = wrap ? 8'h00 : 8'd43;
      for (int v = 0; v < 4; v++)
        for (int m0 = 0; m0 < 32; m0++)
          for (int m1 = 0; m1 < 32; m1++)
            for (int r = 0; r < 32; r++) begin
              valid = 2'(v); mask[0] = 5'(m0); mask[1] = 5'(m1); ready = 5'(r);
              #1;
              if (result[0] !== result[1])
                $fatal(1, "Issue arbiter mismatch wrap=%0d valid=%b masks=%h ready=%h", wrap, valid, mask, ready);
            end
    end
    $display("Issue arbiter one-hot vs generic PASS (262144 exhaustive cases)");
    $finish;
  end
endmodule
