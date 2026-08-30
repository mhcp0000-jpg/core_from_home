module rv_issue_arbiter #(
  parameter int unsigned CANDIDATE_COUNT = 5,
  parameter int unsigned EXEC_PORTS = 5,
  parameter int unsigned ISSUE_WIDTH = 2,
  parameter int unsigned ROB_SEQ_WIDTH = rv_ooo_pkg::ROB_SEQ_WIDTH,
  localparam int unsigned CANDIDATE_INDEX_WIDTH = $clog2(CANDIDATE_COUNT),
  localparam int unsigned PORT_INDEX_WIDTH = $clog2(EXEC_PORTS)
) (
  input  logic [CANDIDATE_COUNT-1:0]                    candidate_valid_i,
  input  logic [CANDIDATE_COUNT-1:0][ROB_SEQ_WIDTH-1:0] candidate_sequence_i,
  input  logic [CANDIDATE_COUNT-1:0][EXEC_PORTS-1:0]   candidate_port_mask_i,
  input  logic [EXEC_PORTS-1:0]                        port_ready_i,

  output logic [CANDIDATE_COUNT-1:0]                   candidate_grant_o,
  output logic [CANDIDATE_COUNT-1:0][PORT_INDEX_WIDTH-1:0]
                                                           candidate_port_o,
  output logic [EXEC_PORTS-1:0]                        port_valid_o,
  output logic [EXEC_PORTS-1:0][CANDIDATE_INDEX_WIDTH-1:0]
                                                           port_candidate_o,
  output logic [ISSUE_WIDTH-1:0]                       issue_valid_o,
  output logic [ISSUE_WIDTH-1:0][CANDIDATE_INDEX_WIDTH-1:0]
                                                           issue_candidate_o,
  output logic [ISSUE_WIDTH-1:0][PORT_INDEX_WIDTH-1:0] issue_port_o
);

  logic [CANDIDATE_COUNT-1:0] candidate_eligible;
  logic first_found;
  logic second_found;
  logic [CANDIDATE_INDEX_WIDTH-1:0] first_candidate;
  logic [CANDIDATE_INDEX_WIDTH-1:0] second_candidate;
  logic [PORT_INDEX_WIDTH-1:0] first_port;
  logic [PORT_INDEX_WIDTH-1:0] second_port;
  logic first_port_found;
  logic first_port_with_pair_found;
  logic second_port_found;
  logic port_allows_pair;

  function automatic logic sequence_before(
    input logic [ROB_SEQ_WIDTH-1:0] lhs,
    input logic [ROB_SEQ_WIDTH-1:0] rhs
  );
    logic signed [ROB_SEQ_WIDTH-1:0] difference;
    difference = $signed(lhs - rhs);
    return difference < 0;
  endfunction

  always_comb begin
    for (int unsigned candidate = 0;
         candidate < CANDIDATE_COUNT; candidate++) begin
      candidate_eligible[candidate] = candidate_valid_i[candidate] &&
        (|(candidate_port_mask_i[candidate] & port_ready_i));
    end

    first_found     = 1'b0;
    first_candidate = '0;
    for (int unsigned candidate = 0;
         candidate < CANDIDATE_COUNT; candidate++) begin
      if (candidate_eligible[candidate] &&
          (!first_found ||
           sequence_before(candidate_sequence_i[candidate],
                           candidate_sequence_i[first_candidate]))) begin
        first_found     = 1'b1;
        first_candidate = CANDIDATE_INDEX_WIDTH'(candidate);
      end
    end

    // Prefer a compatible port that leaves at least one different ready port
    // for another candidate. This preserves dual-issue bandwidth without
    // allowing a younger candidate to displace the oldest eligible uop.
    first_port                 = '0;
    first_port_found           = 1'b0;
    first_port_with_pair_found = 1'b0;
    port_allows_pair           = 1'b0;
    if (first_found) begin
      for (int unsigned port = 0; port < EXEC_PORTS; port++) begin
        if (candidate_port_mask_i[first_candidate][port] &&
            port_ready_i[port]) begin
          port_allows_pair = 1'b0;
          for (int unsigned candidate = 0;
               candidate < CANDIDATE_COUNT; candidate++) begin
            if ((candidate != first_candidate) &&
                candidate_eligible[candidate] &&
                (|(candidate_port_mask_i[candidate] & port_ready_i &
                   ~(EXEC_PORTS'(1'b1) << port))))
              port_allows_pair = 1'b1;
          end
          if (!first_port_found) begin
            first_port       = PORT_INDEX_WIDTH'(port);
            first_port_found = 1'b1;
          end
          if (port_allows_pair && !first_port_with_pair_found) begin
            first_port = PORT_INDEX_WIDTH'(port);
            first_port_with_pair_found = 1'b1;
          end
        end
      end
    end

    second_found     = 1'b0;
    second_candidate = '0;
    if (first_found && first_port_found) begin
      for (int unsigned candidate = 0;
           candidate < CANDIDATE_COUNT; candidate++) begin
        if ((candidate != first_candidate) &&
            candidate_eligible[candidate] &&
            (|(candidate_port_mask_i[candidate] & port_ready_i &
               ~(EXEC_PORTS'(1'b1) << first_port))) &&
            (!second_found ||
             sequence_before(candidate_sequence_i[candidate],
                             candidate_sequence_i[second_candidate]))) begin
          second_found     = 1'b1;
          second_candidate = CANDIDATE_INDEX_WIDTH'(candidate);
        end
      end
    end

    second_port       = '0;
    second_port_found = 1'b0;
    if (second_found) begin
      for (int unsigned port = 0; port < EXEC_PORTS; port++) begin
        if ((port != first_port) &&
            candidate_port_mask_i[second_candidate][port] &&
            port_ready_i[port] && !second_port_found) begin
          second_port       = PORT_INDEX_WIDTH'(port);
          second_port_found = 1'b1;
        end
      end
    end

    candidate_grant_o = '0;
    candidate_port_o  = '0;
    port_valid_o      = '0;
    port_candidate_o  = '0;
    issue_valid_o     = '0;
    issue_candidate_o = '0;
    issue_port_o      = '0;

    if (first_found && first_port_found) begin
      candidate_grant_o[first_candidate] = 1'b1;
      candidate_port_o[first_candidate]  = first_port;
      port_valid_o[first_port]           = 1'b1;
      port_candidate_o[first_port]       = first_candidate;
      issue_valid_o[0]                   = 1'b1;
      issue_candidate_o[0]               = first_candidate;
      issue_port_o[0]                    = first_port;
    end
    if ((ISSUE_WIDTH > 1) && second_found && second_port_found) begin
      candidate_grant_o[second_candidate] = 1'b1;
      candidate_port_o[second_candidate]  = second_port;
      port_valid_o[second_port]           = 1'b1;
      port_candidate_o[second_port]       = second_candidate;
      issue_valid_o[1]                    = 1'b1;
      issue_candidate_o[1]                = second_candidate;
      issue_port_o[1]                     = second_port;
    end
  end

`ifndef SYNTHESIS
  always_comb begin
    assert ($unsigned($countones(candidate_grant_o)) <= ISSUE_WIDTH);
    assert ($unsigned($countones(port_valid_o)) <= ISSUE_WIDTH);
    assert ($countones(candidate_grant_o) == $countones(port_valid_o));
    for (int unsigned candidate = 0;
         candidate < CANDIDATE_COUNT; candidate++) begin
      if (candidate_grant_o[candidate]) begin
        assert (candidate_valid_i[candidate]);
        assert (port_ready_i[candidate_port_o[candidate]]);
        assert (candidate_port_mask_i[candidate][candidate_port_o[candidate]]);
      end
    end
  end
`endif

  initial begin : p_parameter_checks
    if ((CANDIDATE_COUNT < ISSUE_WIDTH) || (EXEC_PORTS < ISSUE_WIDTH))
      $fatal(1, "Issue arbiter needs enough candidates and ports");
    if (ISSUE_WIDTH != 2)
      $fatal(1, "Baseline issue arbiter is specialized for global issue width 2");
    if (ROB_SEQ_WIDTH < 2)
      $fatal(1, "Issue arbiter requires a wrap-aware ROB sequence");
  end

endmodule
