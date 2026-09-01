module rv_issue_arbiter_tb;
  import rv_ooo_pkg::*;

  localparam int unsigned CANDIDATES = 5;
  localparam int unsigned PORTS = 5;
  localparam int unsigned CANDIDATE_INDEX_WIDTH = $clog2(CANDIDATES);
  localparam int unsigned PORT_INDEX_WIDTH = $clog2(PORTS);

  logic [CANDIDATES-1:0] candidate_valid;
  logic [CANDIDATES-1:0][ROB_SEQ_WIDTH-1:0] candidate_sequence;
  logic [CANDIDATES-1:0][PORTS-1:0] candidate_port_mask;
  logic [PORTS-1:0] port_ready;
  logic [CANDIDATES-1:0] candidate_grant;
  logic [CANDIDATES-1:0][PORT_INDEX_WIDTH-1:0] candidate_port;
  logic [PORTS-1:0] port_valid;
  logic [PORTS-1:0][CANDIDATE_INDEX_WIDTH-1:0] port_candidate;
  logic [1:0] issue_valid;
  logic [1:0][CANDIDATE_INDEX_WIDTH-1:0] issue_candidate;
  logic [1:0][PORT_INDEX_WIDTH-1:0] issue_port;

  rv_issue_arbiter u_dut (
    .candidate_valid_i    (candidate_valid),
    .candidate_sequence_i (candidate_sequence),
    .candidate_port_mask_i(candidate_port_mask),
    .port_ready_i         (port_ready),
    .candidate_grant_o    (candidate_grant),
    .candidate_port_o     (candidate_port),
    .port_valid_o         (port_valid),
    .port_candidate_o     (port_candidate),
    .issue_valid_o        (issue_valid),
    .issue_candidate_o    (issue_candidate),
    .issue_port_o         (issue_port)
  );

  task automatic clear_inputs;
    candidate_valid     = '0;
    candidate_sequence  = '0;
    candidate_port_mask = '0;
    port_ready          = '0;
  endtask

  initial begin : p_issue_arbiter_test
    clear_inputs();

    // Oldest candidate0 can use port0/1. Choosing port1 preserves port0 for
    // candidate1 and therefore issues both without violating age priority.
    candidate_valid[0]      = 1'b1;
    candidate_sequence[0]   = 8'd10;
    candidate_port_mask[0]  = 5'b0_0011;
    candidate_valid[1]      = 1'b1;
    candidate_sequence[1]   = 8'd11;
    candidate_port_mask[1]  = 5'b0_0001;
    port_ready              = 5'b0_0011;
    #1;
    if ((candidate_grant[1:0] != 2'b11) ||
        (candidate_port[0] != 1) || (candidate_port[1] != 0) ||
        (issue_candidate[0] != 0) || (issue_candidate[1] != 1))
      $fatal(1, "Issue arbiter failed pair-preserving port choice");

    // Signed modulo comparison: 250 is older than 3 for an active window
    // shorter than half of the 8-bit sequence space.
    clear_inputs();
    candidate_valid[2]      = 1'b1;
    candidate_sequence[2]   = 8'd250;
    candidate_port_mask[2]  = 5'b0_0100;
    candidate_valid[3]      = 1'b1;
    candidate_sequence[3]   = 8'd3;
    candidate_port_mask[3]  = 5'b0_1000;
    port_ready              = 5'b0_1100;
    #1;
    if ((issue_valid != 2'b11) || (issue_candidate[0] != 2) ||
        (issue_candidate[1] != 3))
      $fatal(1, "Issue arbiter wrap-aware age order failed");

    // An older candidate with no ready compatible port is not eligible.
    clear_inputs();
    candidate_valid[0]      = 1'b1;
    candidate_sequence[0]   = 8'd20;
    candidate_port_mask[0]  = 5'b0_0001;
    candidate_valid[1]      = 1'b1;
    candidate_sequence[1]   = 8'd21;
    candidate_port_mask[1]  = 5'b0_0010;
    port_ready              = 5'b0_0010;
    #1;
    if ((issue_valid != 2'b01) || (issue_candidate[0] != 1) ||
        !candidate_grant[1] || candidate_grant[0])
      $fatal(1, "Issue arbiter did not skip an unavailable execution port");

    // Global issue width remains two even with five ready candidates.
    clear_inputs();
    candidate_valid = '1;
    for (int unsigned candidate = 0; candidate < CANDIDATES; candidate++) begin
      candidate_sequence[candidate] = ROB_SEQ_WIDTH'(30 + candidate);
      candidate_port_mask[candidate][candidate] = 1'b1;
    end
    port_ready = '1;
    #1;
    if (($countones(candidate_grant) != 2) ||
        (issue_candidate[0] != 0) || (issue_candidate[1] != 1))
      $fatal(1, "Issue arbiter violated global width or oldest-first order");

    $display("rv_issue_arbiter_tb PASS");
    $finish;
  end
endmodule
