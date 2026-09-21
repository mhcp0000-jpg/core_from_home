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

  localparam int unsigned RANK_WIDTH = $clog2(SOURCE_COUNT + 1);
  function automatic logic sequence_before(
    input logic [ROB_SEQ_WIDTH-1:0] lhs,
    input logic [ROB_SEQ_WIDTH-1:0] rhs
  );
    logic signed [ROB_SEQ_WIDTH-1:0] distance;
    distance = $signed(lhs - rhs);
    return distance < 0;
  endfunction

  function automatic logic sequence_after(
    input logic [ROB_SEQ_WIDTH-1:0] lhs,
    input logic [ROB_SEQ_WIDTH-1:0] rhs
  );
    logic signed [ROB_SEQ_WIDTH-1:0] distance;
    distance = $signed(lhs - rhs);
    return distance > 0;
  endfunction

  always_comb begin
    logic [SOURCE_COUNT-1:0] eligible_work;
    logic [SOURCE_COUNT-1:0] discard_work;
    logic [SOURCE_COUNT-1:0] needs_int_work;
    logic [SOURCE_COUNT-1:0] needs_fp_work;
    logic [SOURCE_COUNT-1:0] resource_eligible_work;
    logic [SOURCE_COUNT-1:0] selected_work;
    logic [SOURCE_COUNT-1:0][RANK_WIDTH-1:0] int_rank_work;
    logic [SOURCE_COUNT-1:0][RANK_WIDTH-1:0] fp_rank_work;
    logic [SOURCE_COUNT-1:0][RANK_WIDTH-1:0] complete_rank_work;

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
      for (int unsigned other = 0; other < SOURCE_COUNT; other++) begin
        logic other_precedes;
        other_precedes =
          sequence_before(source_sequence_i[other],
                          source_sequence_i[source]) ||
          ((source_sequence_i[other] == source_sequence_i[source]) &&
           (other < source));
        if (eligible_work[other] && other_precedes) begin
          if (needs_int_work[other])
            int_rank_work[source] = int_rank_work[source] + 1'b1;
          if (needs_fp_work[other])
            fp_rank_work[source] = fp_rank_work[source] + 1'b1;
        end
      end
      resource_eligible_work[source] = eligible_work[source] &&
        (!needs_int_work[source] ||
         (int_rank_work[source] < RANK_WIDTH'(INT_WRITE_PORTS))) &&
        (!needs_fp_work[source] ||
         (fp_rank_work[source] < RANK_WIDTH'(FP_WRITE_PORTS)));
    end

    // Rank the resource-eligible union once.  This replaces four serial
    // oldest-source scans with a comparator/popcount network whose depth does
    // not grow with ROB_COMPLETE_PORTS.
    for (int unsigned source = 0; source < SOURCE_COUNT; source++) begin
      for (int unsigned other = 0; other < SOURCE_COUNT; other++) begin
        logic other_precedes;
        other_precedes =
          sequence_before(source_sequence_i[other],
                          source_sequence_i[source]) ||
          ((source_sequence_i[other] == source_sequence_i[source]) &&
           (other < source));
        if (resource_eligible_work[other] && other_precedes)
          complete_rank_work[source] = complete_rank_work[source] + 1'b1;
      end
      selected_work[source] = resource_eligible_work[source] &&
        (complete_rank_work[source] < RANK_WIDTH'(ROB_COMPLETE_PORTS));
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
      wakeup_class_o[slot] = REG_NONE;
      complete_exception_cause_o[slot] = EXC_ILLEGAL_INSTRUCTION;
    end

    for (int unsigned source = 0; source < SOURCE_COUNT; source++)
      source_ready_o[source] = discard_work[source] || selected_work[source];

    // Compare a source's computed rank against each constant output slot.
    // Constant-indexed assignments avoid a false combinational loop in some
    // synthesis frontends while retaining one parallel payload mux layer.
    for (int unsigned slot = 0; slot < ROB_COMPLETE_PORTS; slot++) begin
      for (int unsigned source = 0; source < SOURCE_COUNT; source++) begin
        if (selected_work[source] &&
            (complete_rank_work[source] == RANK_WIDTH'(slot))) begin
          complete_valid_o[slot] = 1'b1;
          complete_sequence_o[slot] = source_sequence_i[source];
          complete_exception_valid_o[slot] =
            source_exception_valid_i[source];
          complete_exception_cause_o[slot] =
            source_exception_cause_i[source];
          complete_exception_tval_o[slot] = source_exception_tval_i[source];
          complete_branch_mispredict_o[slot] =
            source_branch_mispredict_i[source];
          complete_branch_target_o[slot] = source_branch_target_i[source];
          complete_fflags_o[slot] = source_fflags_i[source];
          if (source_destination_valid_i[source] &&
              !source_exception_valid_i[source] &&
              (source_destination_class_i[source] != REG_NONE)) begin
            wakeup_valid_o[slot] = 1'b1;
            wakeup_class_o[slot] = source_destination_class_i[source];
            wakeup_phys_o[slot] = source_destination_phys_i[source];
          end
        end
      end
    end

    for (int unsigned port = 0; port < INT_WRITE_PORTS; port++) begin
      for (int unsigned source = 0; source < SOURCE_COUNT; source++) begin
        if (selected_work[source] && needs_int_work[source] &&
            (int_rank_work[source] == RANK_WIDTH'(port))) begin
          int_wb_valid_o[port] = 1'b1;
          int_wb_phys_o[port] = source_destination_phys_i[source];
          int_wb_data_o[port] = source_data_i[source];
        end
      end
    end

    for (int unsigned port = 0; port < FP_WRITE_PORTS; port++) begin
      for (int unsigned source = 0; source < SOURCE_COUNT; source++) begin
        if (selected_work[source] && needs_fp_work[source] &&
            (fp_rank_work[source] == RANK_WIDTH'(port))) begin
          fp_wb_valid_o[port] = 1'b1;
          fp_wb_phys_o[port] = source_destination_phys_i[source];
          fp_wb_data_o[port] = 32'(source_data_i[source]);
        end
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
