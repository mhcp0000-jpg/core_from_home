module rv_writeback_arbiter #(
  parameter int unsigned XLEN               = 32,
  parameter int unsigned SOURCE_COUNT       = 8,
  parameter int unsigned PHYS_TAG_WIDTH     = 7,
  parameter int unsigned ROB_SEQ_WIDTH      = rv_ooo_pkg::ROB_SEQ_WIDTH,
  parameter int unsigned INT_WRITE_PORTS    = 2,
  parameter int unsigned FP_WRITE_PORTS     = 2,
  parameter int unsigned ROB_COMPLETE_PORTS = 4
) (
  input  logic [SOURCE_COUNT-1:0]                       source_valid_i,
  output logic [SOURCE_COUNT-1:0]                       source_ready_o,
  input  logic [SOURCE_COUNT-1:0]                       source_live_i,
  input  logic [SOURCE_COUNT-1:0][ROB_SEQ_WIDTH-1:0]    source_sequence_i,
  input  logic [SOURCE_COUNT-1:0]                       source_destination_valid_i,
  input  rv_ooo_pkg::reg_class_e [SOURCE_COUNT-1:0]     source_destination_class_i,
  input  logic [SOURCE_COUNT-1:0][PHYS_TAG_WIDTH-1:0]   source_destination_phys_i,
  input  logic [SOURCE_COUNT-1:0][XLEN-1:0]             source_data_i,
  input  logic [SOURCE_COUNT-1:0]                       source_exception_valid_i,
  input  rv_ooo_pkg::exception_code_e [SOURCE_COUNT-1:0]
                                                          source_exception_cause_i,
  input  logic [SOURCE_COUNT-1:0][XLEN-1:0]             source_exception_tval_i,
  input  logic [SOURCE_COUNT-1:0]                       source_branch_mispredict_i,
  input  logic [SOURCE_COUNT-1:0][XLEN-1:0]             source_branch_target_i,
  input  logic [SOURCE_COUNT-1:0][4:0]                  source_fflags_i,

  input  logic                                           flush_valid_i,
  input  logic                                           flush_all_i,
  input  logic [ROB_SEQ_WIDTH-1:0]                      flush_sequence_i,

  output logic [INT_WRITE_PORTS-1:0]                    int_wb_valid_o,
  output logic [INT_WRITE_PORTS-1:0][PHYS_TAG_WIDTH-1:0]int_wb_phys_o,
  output logic [INT_WRITE_PORTS-1:0][XLEN-1:0]          int_wb_data_o,
  output logic [FP_WRITE_PORTS-1:0]                     fp_wb_valid_o,
  output logic [FP_WRITE_PORTS-1:0][PHYS_TAG_WIDTH-1:0] fp_wb_phys_o,
  output logic [FP_WRITE_PORTS-1:0][31:0]               fp_wb_data_o,

  output logic [ROB_COMPLETE_PORTS-1:0]                 wakeup_valid_o,
  output rv_ooo_pkg::reg_class_e [ROB_COMPLETE_PORTS-1:0]
                                                          wakeup_class_o,
  output logic [ROB_COMPLETE_PORTS-1:0][PHYS_TAG_WIDTH-1:0]
                                                          wakeup_phys_o,

  output logic [ROB_COMPLETE_PORTS-1:0]                 complete_valid_o,
  output logic [ROB_COMPLETE_PORTS-1:0][ROB_SEQ_WIDTH-1:0]
                                                          complete_sequence_o,
  output logic [ROB_COMPLETE_PORTS-1:0]                 complete_exception_valid_o,
  output rv_ooo_pkg::exception_code_e [ROB_COMPLETE_PORTS-1:0]
                                                          complete_exception_cause_o,
  output logic [ROB_COMPLETE_PORTS-1:0][XLEN-1:0]       complete_exception_tval_o,
  output logic [ROB_COMPLETE_PORTS-1:0]                 complete_branch_mispredict_o,
  output logic [ROB_COMPLETE_PORTS-1:0][XLEN-1:0]       complete_branch_target_o,
  output logic [ROB_COMPLETE_PORTS-1:0][4:0]            complete_fflags_o
);

  import rv_ooo_pkg::*;

  localparam int unsigned POPCOUNT_LEAVES = 1 << $clog2(SOURCE_COUNT);
  localparam int unsigned MAX_PORTS =
    (ROB_COMPLETE_PORTS > INT_WRITE_PORTS) ?
      ((ROB_COMPLETE_PORTS > FP_WRITE_PORTS) ? ROB_COMPLETE_PORTS : FP_WRITE_PORTS) :
      ((INT_WRITE_PORTS > FP_WRITE_PORTS) ? INT_WRITE_PORTS : FP_WRITE_PORTS);
  localparam int unsigned RANK_LIMIT = (MAX_PORTS < SOURCE_COUNT) ? MAX_PORTS : SOURCE_COUNT;
  logic [ROB_COMPLETE_PORTS-1:0][2:0] wakeup_class_bits;
  logic [ROB_COMPLETE_PORTS-1:0][5:0] complete_cause_bits;
  assign wakeup_class_o = wakeup_class_bits;
  assign complete_exception_cause_o = complete_cause_bits;

  // Unary, saturated age rank: bit k means at least k+1 older contenders.
  // Arbitration only needs ranks below the available 2/2/4 ports; a binary
  // population count computes unnecessary high bits and inserts carry/compare
  // chains on late source_live -> ready.  This balanced AND/OR merge has no
  // carry propagation and preserves every age/tie-break/grant decision.
  function automatic logic [RANK_LIMIT-1:0] bounded_age_count(
    input logic [SOURCE_COUNT-1:0] mask
  );
    logic [RANK_LIMIT-1:0] tree [0:2*POPCOUNT_LEAVES-1];
    tree[0] = '0;
    for (int leaf = 0; leaf < POPCOUNT_LEAVES; leaf++) begin
      tree[POPCOUNT_LEAVES+leaf] = '0;
      if (leaf < SOURCE_COUNT)
        tree[POPCOUNT_LEAVES+leaf][0] = mask[leaf];
    end
    for (int node = POPCOUNT_LEAVES-1; node > 0; node--) begin
      tree[node] = tree[node*2] | tree[node*2+1];
      for (int rank = 1; rank < RANK_LIMIT; rank++)
        for (int left = 1; left <= rank; left++)
          tree[node][rank] |= tree[node*2][left-1] &
                              tree[node*2+1][rank-left];
    end
    return tree[1];
  endfunction
  function automatic logic rank_fits(
    input logic [RANK_LIMIT-1:0] rank, input int unsigned ports
  );
    if (ports > RANK_LIMIT) return 1'b1;
    return !rank[ports-1];
  endfunction
  function automatic logic rank_equals(
    input logic [RANK_LIMIT-1:0] rank, input int unsigned slot
  );
    if (slot >= RANK_LIMIT) return 1'b0;
    if (slot == 0) return !rank[0];
    return rank[slot-1] && !rank[slot];
  endfunction
  function automatic logic sequence_before(
    input logic [ROB_SEQ_WIDTH-1:0] lhs,
    input logic [ROB_SEQ_WIDTH-1:0] rhs
  );
    // The MSB of modulo subtraction is sign XOR low-bit borrow.  Age only
    // needs that bit: do not build a full subtractor and signed comparator.
    // Preserve the exact half-range boundary (including wrap), not unsigned
    // numerical ordering.  No ROB cohort assumption is needed for equality.
    if (ROB_SEQ_WIDTH == 1) return lhs != rhs;
    return (lhs[ROB_SEQ_WIDTH-1] ^ rhs[ROB_SEQ_WIDTH-1]) ^
           ($unsigned(lhs[ROB_SEQ_WIDTH-2:0]) < $unsigned(rhs[ROB_SEQ_WIDTH-2:0]));
  endfunction

  function automatic logic sequence_after(
    input logic [ROB_SEQ_WIDTH-1:0] lhs,
    input logic [ROB_SEQ_WIDTH-1:0] rhs
  );
    return !sequence_before(lhs, rhs) && (lhs != rhs);
  endfunction

  always_comb begin
    logic [SOURCE_COUNT-1:0] eligible_work;
    logic [SOURCE_COUNT-1:0] discard_work;
    logic [SOURCE_COUNT-1:0] needs_int_work;
    logic [SOURCE_COUNT-1:0] needs_fp_work;
    logic [SOURCE_COUNT-1:0] resource_eligible_work;
    logic [SOURCE_COUNT-1:0] selected_work;
    logic [SOURCE_COUNT-1:0][RANK_LIMIT-1:0] int_rank_work;
    logic [SOURCE_COUNT-1:0][RANK_LIMIT-1:0] fp_rank_work;
    logic [SOURCE_COUNT-1:0][RANK_LIMIT-1:0] complete_rank_work;

    source_ready_o = '0;
    eligible_work = '0;
    discard_work = '0;
    needs_int_work = '0;
    needs_fp_work = '0;
    resource_eligible_work = '0;
    selected_work = '0;
    int_rank_work = '0;
    fp_rank_work = '0;
    complete_rank_work = '0;

    // First classify every producer independently.  Invalidated results are
    // consumed immediately, while live results enter the age-rank network.
    for (int unsigned source = 0; source < SOURCE_COUNT; source++) begin
      discard_work[source] = source_valid_i[source] &&
        (!source_live_i[source] ||
         (flush_valid_i &&
          (flush_all_i || sequence_after(source_sequence_i[source],
                                         flush_sequence_i))));
      eligible_work[source] = source_valid_i[source] &&
                              source_live_i[source] &&
                              !discard_work[source];
      needs_int_work[source] =
        source_destination_valid_i[source] &&
        !source_exception_valid_i[source] &&
        (source_destination_class_i[source] == REG_INT);
      needs_fp_work[source] =
        source_destination_valid_i[source] &&
        !source_exception_valid_i[source] &&
        (source_destination_class_i[source] == REG_FP);
      source_ready_o[source] = discard_work[source];
    end

    // Rank integer and FP writers in parallel.  A lower source number is the
    // deterministic tie break, matching the former forward scan for the
    // otherwise-invalid case of duplicate live ROB sequence numbers.
    for (int unsigned source = 0; source < SOURCE_COUNT; source++) begin
      logic [SOURCE_COUNT-1:0] older_int, older_fp;
      older_int = '0;
      older_fp = '0;
      for (int unsigned other = 0; other < SOURCE_COUNT; other++) begin
        logic other_precedes;
        other_precedes =
          sequence_before(source_sequence_i[other],
                          source_sequence_i[source]) ||
          ((source_sequence_i[other] == source_sequence_i[source]) &&
           (other < source));
        older_int[other] = eligible_work[other] && other_precedes &&
                           needs_int_work[other];
        older_fp[other] = eligible_work[other] && other_precedes &&
                          needs_fp_work[other];
      end
      int_rank_work[source] = bounded_age_count(older_int);
      fp_rank_work[source] = bounded_age_count(older_fp);
      resource_eligible_work[source] = eligible_work[source] &&
        (!needs_int_work[source] ||
         rank_fits(int_rank_work[source], INT_WRITE_PORTS)) &&
        (!needs_fp_work[source] ||
         rank_fits(fp_rank_work[source], FP_WRITE_PORTS));
    end

    // Rank the resource-eligible union once.  This replaces four serial
    // oldest-source scans with a comparator/popcount network whose depth does
    // not grow with ROB_COMPLETE_PORTS.
    for (int unsigned source = 0; source < SOURCE_COUNT; source++) begin
      logic [SOURCE_COUNT-1:0] older_complete;
      older_complete = '0;
      for (int unsigned other = 0; other < SOURCE_COUNT; other++) begin
        logic other_precedes;
        other_precedes =
          sequence_before(source_sequence_i[other],
                          source_sequence_i[source]) ||
          ((source_sequence_i[other] == source_sequence_i[source]) &&
           (other < source));
        older_complete[other] = resource_eligible_work[other] && other_precedes;
      end
      complete_rank_work[source] = bounded_age_count(older_complete);
      selected_work[source] = resource_eligible_work[source] &&
        rank_fits(complete_rank_work[source], ROB_COMPLETE_PORTS);
    end

    int_wb_valid_o = '0;
    int_wb_phys_o = '0;
    int_wb_data_o = '0;
    fp_wb_valid_o = '0;
    fp_wb_phys_o = '0;
    fp_wb_data_o = '0;
    wakeup_valid_o = '0;
    wakeup_phys_o = '0;
    complete_valid_o = '0;
    complete_sequence_o = '0;
    complete_exception_valid_o = '0;
    complete_exception_tval_o = '0;
    complete_branch_mispredict_o = '0;
    complete_branch_target_o = '0;
    complete_fflags_o = '0;
    for (int unsigned slot = 0; slot < ROB_COMPLETE_PORTS; slot++) begin
      wakeup_class_bits[slot] = 3'(REG_NONE);
      complete_cause_bits[slot] = 6'(EXC_ILLEGAL_INSTRUCTION);
    end

    for (int unsigned source = 0; source < SOURCE_COUNT; source++)
      source_ready_o[source] = discard_work[source] || selected_work[source];

    // Equal rank selects at most one source. Explicit masked reductions give
    // the mapper parallel data selection instead of SOURCE_COUNT serial muxes.
    for (int unsigned slot = 0; slot < ROB_COMPLETE_PORTS; slot++) begin
      logic [SOURCE_COUNT-1:0] slot_hit;
      logic [5:0] cause_bits;
      logic [2:0] class_bits;
      slot_hit = '0;
      cause_bits = '0;
      class_bits = '0;
      for (int unsigned source = 0; source < SOURCE_COUNT; source++) begin
        logic wake_hit;
        slot_hit[source] = selected_work[source] &&
          rank_equals(complete_rank_work[source], slot);
        wake_hit = slot_hit[source] && source_destination_valid_i[source] &&
          !source_exception_valid_i[source] &&
          (source_destination_class_i[source] != REG_NONE);
        complete_valid_o[slot] |= slot_hit[source];
        complete_sequence_o[slot] |= source_sequence_i[source] &
          {ROB_SEQ_WIDTH{slot_hit[source]}};
        complete_exception_valid_o[slot] |=
          source_exception_valid_i[source] && slot_hit[source];
        cause_bits |= 6'(source_exception_cause_i[source]) &
          {6{slot_hit[source]}};
        complete_exception_tval_o[slot] |= source_exception_tval_i[source] &
          {XLEN{slot_hit[source]}};
        complete_branch_mispredict_o[slot] |=
          source_branch_mispredict_i[source] && slot_hit[source];
        complete_branch_target_o[slot] |= source_branch_target_i[source] &
          {XLEN{slot_hit[source]}};
        complete_fflags_o[slot] |= source_fflags_i[source] &
          {5{slot_hit[source]}};
        wakeup_valid_o[slot] |= wake_hit;
        class_bits |= 3'(source_destination_class_i[source]) & {3{wake_hit}};
        wakeup_phys_o[slot] |= source_destination_phys_i[source] &
          {PHYS_TAG_WIDTH{wake_hit}};
      end
      complete_cause_bits[slot] = (|slot_hit) ?
        cause_bits : 6'(EXC_ILLEGAL_INSTRUCTION);
      wakeup_class_bits[slot] = class_bits;
    end

    for (int unsigned port = 0; port < INT_WRITE_PORTS; port++) begin
      for (int unsigned source = 0; source < SOURCE_COUNT; source++) begin
        logic hit;
        hit = selected_work[source] && needs_int_work[source] &&
          rank_equals(int_rank_work[source], port);
        int_wb_valid_o[port] |= hit;
        int_wb_phys_o[port] |= source_destination_phys_i[source] &
          {PHYS_TAG_WIDTH{hit}};
        int_wb_data_o[port] |= source_data_i[source] & {XLEN{hit}};
      end
    end

    for (int unsigned port = 0; port < FP_WRITE_PORTS; port++) begin
      for (int unsigned source = 0; source < SOURCE_COUNT; source++) begin
        logic hit;
        hit = selected_work[source] && needs_fp_work[source] &&
          rank_equals(fp_rank_work[source], port);
        fp_wb_valid_o[port] |= hit;
        fp_wb_phys_o[port] |= source_destination_phys_i[source] &
          {PHYS_TAG_WIDTH{hit}};
        fp_wb_data_o[port] |= 32'(source_data_i[source]) & {32{hit}};
      end
    end
  end

`ifndef SYNTHESIS
  always_comb begin
    assert ($unsigned($countones(complete_valid_o)) <= ROB_COMPLETE_PORTS);
    assert ($unsigned($countones(int_wb_valid_o)) <= INT_WRITE_PORTS);
    assert ($unsigned($countones(fp_wb_valid_o)) <= FP_WRITE_PORTS);
    for (int unsigned lhs = 0; lhs < INT_WRITE_PORTS; lhs++) begin
      for (int unsigned rhs = lhs + 1; rhs < INT_WRITE_PORTS; rhs++) begin
        if (int_wb_valid_o[lhs] && int_wb_valid_o[rhs])
          assert (int_wb_phys_o[lhs] != int_wb_phys_o[rhs]);
      end
    end
    for (int unsigned lhs = 0; lhs < FP_WRITE_PORTS; lhs++) begin
      for (int unsigned rhs = lhs + 1; rhs < FP_WRITE_PORTS; rhs++) begin
        if (fp_wb_valid_o[lhs] && fp_wb_valid_o[rhs])
          assert (fp_wb_phys_o[lhs] != fp_wb_phys_o[rhs]);
      end
    end
  end
`endif

  initial begin : p_parameter_checks
    if ((XLEN != 32) && (XLEN != 64))
      $fatal(1, "Writeback arbiter XLEN must be 32 or 64");
    if ((SOURCE_COUNT < 2) || (ROB_COMPLETE_PORTS < 2) ||
        (INT_WRITE_PORTS == 0) || (FP_WRITE_PORTS == 0))
      $fatal(1, "Writeback arbiter resource dimensions are invalid");
    if (ROB_SEQ_WIDTH < 2)
      $fatal(1, "Writeback arbiter requires wrap-aware sequences");
  end

endmodule
