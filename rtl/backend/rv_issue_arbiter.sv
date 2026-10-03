module rv_issue_arbiter #(
  parameter int unsigned CANDIDATE_COUNT = 5,
  parameter int unsigned EXEC_PORTS = 5,
  parameter int unsigned ISSUE_WIDTH = 2,
  parameter int unsigned ROB_SEQ_WIDTH = rv_ooo_pkg::ROB_SEQ_WIDTH,
  // AGE_ORDERED=1 (two candidates only): the caller guarantees candidate 0
  // is older than candidate 1 whenever both are valid (the IQ's oldest /
  // second-oldest outputs).  The sequence comparisons fold away and the
  // port choice becomes a few parallel 5-bit terms.  Grants equal the
  // generic search under that guarantee; simulation checks both.
  parameter bit          AGE_ORDERED = 1'b0,
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

  logic [CANDIDATE_COUNT-1:0] gen_candidate_grant, fo_candidate_grant;
  logic [CANDIDATE_COUNT-1:0][PORT_INDEX_WIDTH-1:0] gen_candidate_port,
                                                    fo_candidate_port;
  logic [EXEC_PORTS-1:0] gen_port_valid, fo_port_valid;
  logic [EXEC_PORTS-1:0][CANDIDATE_INDEX_WIDTH-1:0] gen_port_candidate,
                                                    fo_port_candidate;
  logic [ISSUE_WIDTH-1:0] gen_issue_valid, fo_issue_valid;
  logic [ISSUE_WIDTH-1:0][CANDIDATE_INDEX_WIDTH-1:0] gen_issue_candidate,
                                                     fo_issue_candidate;
  logic [ISSUE_WIDTH-1:0][PORT_INDEX_WIDTH-1:0] gen_issue_port, fo_issue_port;
  logic [EXEC_PORTS-1:0] fm0, fm1, fallow, fpair, fm1_rest;
  logic [EXEC_PORTS-1:0] fm0_hot, fm1_hot, fpair_hot,
                          fm0_choice_hot, first_hot, second_hot;
  logic [EXEC_PORTS-1:0][EXEC_PORTS-1:0] fm1_except_hot;
  logic fe0, fe1, fgrant2;
  logic [PORT_INDEX_WIDTH-1:0] fp_first, fp_second;

  function automatic logic [PORT_INDEX_WIDTH-1:0] lowest_port(
    input logic [EXEC_PORTS-1:0] mask
  );
    lowest_port = '0;
    for (int port = EXEC_PORTS - 1; port >= 0; port--)
      if (mask[port]) lowest_port = PORT_INDEX_WIDTH'(port);
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

    gen_candidate_grant = '0;
    gen_candidate_port  = '0;
    gen_port_valid      = '0;
    gen_port_candidate  = '0;
    gen_issue_valid     = '0;
    gen_issue_candidate = '0;
    gen_issue_port      = '0;

    if (first_found && first_port_found) begin
      gen_candidate_grant[first_candidate] = 1'b1;
      gen_candidate_port[first_candidate]  = first_port;
      gen_port_valid[first_port]           = 1'b1;
      gen_port_candidate[first_port]       = first_candidate;
      gen_issue_valid[0]                   = 1'b1;
      gen_issue_candidate[0]               = first_candidate;
      gen_issue_port[0]                    = first_port;
    end
    if ((ISSUE_WIDTH > 1) && second_found && second_port_found) begin
      gen_candidate_grant[second_candidate] = 1'b1;
      gen_candidate_port[second_candidate]  = second_port;
      gen_port_valid[second_port]           = 1'b1;
      gen_port_candidate[second_port]       = second_candidate;
      gen_issue_valid[1]                    = 1'b1;
      gen_issue_candidate[1]                = second_candidate;
      gen_issue_port[1]                     = second_port;
    end

    // ---- age-ordered two-candidate fast path ----
    fo_candidate_grant = '0;
    fo_candidate_port  = '0;
    fo_port_valid      = '0;
    fo_port_candidate  = '0;
    fo_issue_valid     = '0;
    fo_issue_candidate = '0;
    fo_issue_port      = '0;
    if (CANDIDATE_COUNT == 2) begin
      fm0 = candidate_port_mask_i[0] & port_ready_i;
      fm1 = candidate_port_mask_i[CANDIDATE_COUNT-1] & port_ready_i;
      fe0 = candidate_valid_i[0] && (|fm0);
      fe1 = candidate_valid_i[CANDIDATE_COUNT-1] && (|fm1);
      for (int unsigned port = 0; port < EXEC_PORTS; port++)
        fallow[port] = fe1 && (|(fm1 & ~(EXEC_PORTS'(1) << port)));
      fpair = fm0 & fallow;
      // Keep selected ports one-hot through exclusion and port-valid decode.
      // Encoding is only for exported port numbers, not fed back into the
      // second choice. The generic search below remains the equality oracle.
      for (int unsigned port = 0; port < EXEC_PORTS; port++) begin
        fm0_hot[port] = fm0[port] && !(|(fm0 & ((EXEC_PORTS'(1) << port) - 1)));
        fm1_hot[port] = fm1[port] && !(|(fm1 & ((EXEC_PORTS'(1) << port) - 1)));
        fpair_hot[port] = fpair[port] && !(|(fpair & ((EXEC_PORTS'(1) << port) - 1)));
      end
      fm0_choice_hot = (|fpair) ? fpair_hot : fm0_hot;
      first_hot = fe0 ? fm0_choice_hot : fm1_hot;
      fp_first = lowest_port(first_hot);
      // Candidate1 may issue only with fe0. Its alternative can therefore be
      // computed before the late fe0 decision, independently of first_hot.
      // Precompute the younger candidate's lowest port for EACH possible
      // older port, in parallel. Late oldest selection only gates/ORs these
      // terms; it no longer feeds another priority encoder via fm1_rest.
      fm1_rest = fm1 & ~fm0_choice_hot; // debug alias, not in selection
      second_hot = '0;
      for (int unsigned older_port = 0; older_port < EXEC_PORTS; older_port++)
        for (int unsigned port = 0; port < EXEC_PORTS; port++) begin
          fm1_except_hot[older_port][port] = (port != older_port) &&
            fm1[port] && !(|(fm1 & ((EXEC_PORTS'(1) << port) - 1) &
                            ~(EXEC_PORTS'(1) << older_port)));
          second_hot[port] |= fpair_hot[older_port] &&
                              fm1_except_hot[older_port][port];
        end
      fgrant2 = fe0 && fe1 && (|fpair);
      fp_second = lowest_port(second_hot);
      if (fe0 || fe1) begin
        fo_candidate_grant[fe0 ? 0 : 1] = 1'b1;
        fo_candidate_port[fe0 ? 0 : 1]  = fp_first;
        fo_issue_valid[0]               = 1'b1;
        fo_issue_candidate[0]           = fe0 ? '0 : CANDIDATE_INDEX_WIDTH'(1);
        fo_issue_port[0]                = fp_first;
      end
      if (fgrant2) begin
        fo_candidate_grant[1]       = 1'b1;
        fo_candidate_port[1]        = fp_second;
        fo_issue_valid[1]           = 1'b1;
        fo_issue_candidate[1]       = CANDIDATE_INDEX_WIDTH'(1);
        fo_issue_port[1]            = fp_second;
      end
      for (int unsigned port = 0; port < EXEC_PORTS; port++) begin
        fo_port_valid[port] = ((fe0 || fe1) && first_hot[port]) ||
                             (fgrant2 && second_hot[port]);
        if (((fe0 || fe1) && first_hot[port] && !fe0) ||
            (fgrant2 && second_hot[port]))
          fo_port_candidate[port] = CANDIDATE_INDEX_WIDTH'(1);
      end
    end

    if (AGE_ORDERED && (CANDIDATE_COUNT == 2)) begin
      candidate_grant_o = fo_candidate_grant;
      candidate_port_o  = fo_candidate_port;
      port_valid_o      = fo_port_valid;
      port_candidate_o  = fo_port_candidate;
      issue_valid_o     = fo_issue_valid;
      issue_candidate_o = fo_issue_candidate;
      issue_port_o      = fo_issue_port;
    end else begin
      candidate_grant_o = gen_candidate_grant;
      candidate_port_o  = gen_candidate_port;
      port_valid_o      = gen_port_valid;
      port_candidate_o  = gen_port_candidate;
      issue_valid_o     = gen_issue_valid;
      issue_candidate_o = gen_issue_candidate;
      issue_port_o      = gen_issue_port;
    end
`ifndef SYNTHESIS
    if (AGE_ORDERED && (CANDIDATE_COUNT == 2) &&
        !$isunknown({candidate_valid_i, candidate_sequence_i,
                     candidate_port_mask_i, port_ready_i})) begin
      if (candidate_valid_i[0] && candidate_valid_i[CANDIDATE_COUNT-1])
        assert (!sequence_before(candidate_sequence_i[CANDIDATE_COUNT-1],
                                 candidate_sequence_i[0]))
          else $error("AGE_ORDERED arbiter: candidate 1 older than candidate 0");
      assert ({fo_candidate_grant, fo_candidate_port, fo_port_valid,
               fo_port_candidate, fo_issue_valid, fo_issue_candidate,
               fo_issue_port} ==
              {gen_candidate_grant, gen_candidate_port, gen_port_valid,
               gen_port_candidate, gen_issue_valid, gen_issue_candidate,
               gen_issue_port})
        else $error("AGE_ORDERED arbiter differs from generic search");
    end
`endif
`ifndef SYNTHESIS
    // Keep immediate checks in the producer process.  A separate always_comb
    // can run before this block after upstream candidate changes and compare
    // the previous grant against the new valid/mask, producing false Xcelium
    // ASRTST failures during an ordinary delta-cycle settle.
    if (!$isunknown({candidate_valid_i, candidate_sequence_i,
                     candidate_port_mask_i, port_ready_i})) begin
      assert ($unsigned($countones(candidate_grant_o)) <= ISSUE_WIDTH);
      assert ($unsigned($countones(port_valid_o)) <= ISSUE_WIDTH);
      assert ($countones(candidate_grant_o) == $countones(port_valid_o));
      for (int unsigned candidate = 0;
           candidate < CANDIDATE_COUNT; candidate++) begin
        if (candidate_grant_o[candidate]) begin
          assert (candidate_valid_i[candidate]);
          assert (port_ready_i[candidate_port_o[candidate]]);
          assert (candidate_port_mask_i[candidate]
                                            [candidate_port_o[candidate]]);
        end
      end
    end
`endif
  end

  initial begin : p_parameter_checks
    if ((CANDIDATE_COUNT < ISSUE_WIDTH) || (EXEC_PORTS < ISSUE_WIDTH))
      $fatal(1, "Issue arbiter needs enough candidates and ports");
    if (ISSUE_WIDTH != 2)
      $fatal(1, "Baseline issue arbiter is specialized for global issue width 2");
    if (ROB_SEQ_WIDTH < 2)
      $fatal(1, "Issue arbiter requires a wrap-aware ROB sequence");
  end

endmodule
