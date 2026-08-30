module rv_issue_queue #(
  parameter int unsigned XLEN = 32,
  parameter int unsigned ENTRIES = 24,
  parameter int unsigned PHYS_TAG_WIDTH = 7,
  parameter int unsigned ROB_SEQ_WIDTH = rv_ooo_pkg::ROB_SEQ_WIDTH,
  parameter int unsigned WRITEBACK_PORTS = 4,
  parameter int unsigned SELECT_WIDTH = 2,
  parameter int unsigned EXEC_PORTS = 5,
  parameter int unsigned OP_WIDTH = 16,
  parameter int unsigned LQ_INDEX_WIDTH = 5,
  parameter int unsigned SQ_INDEX_WIDTH = 4,
  localparam int unsigned INDEX_WIDTH = $clog2(ENTRIES),
  localparam int unsigned COUNT_WIDTH = $clog2(ENTRIES + 1)
) (
  input  logic                                  clk_i,
  input  logic                                  rst_ni,

  input  logic [1:0]                            dispatch_valid_i,
  output logic                                  dispatch_ready_o,
  output logic [1:0][INDEX_WIDTH-1:0]           dispatch_index_o,
  input  logic [1:0][ROB_SEQ_WIDTH-1:0]         dispatch_sequence_i,
  input  rv_ooo_pkg::fu_class_e [1:0]           dispatch_fu_i,
  input  logic [1:0][EXEC_PORTS-1:0]            dispatch_port_mask_i,
  input  logic [1:0][2:0]                       dispatch_src_used_i,
  input  logic [1:0][2:0][PHYS_TAG_WIDTH-1:0]   dispatch_src_phys_i,
  input  logic [1:0][2:0]                       dispatch_src_ready_i,
  input  logic [1:0]                            dispatch_destination_valid_i,
  input  logic [1:0][PHYS_TAG_WIDTH-1:0]        dispatch_destination_phys_i,
  input  logic [1:0][XLEN-1:0]                  dispatch_pc_i,
  input  logic [1:0][31:0]                      dispatch_instruction_i,
  input  logic [1:0][XLEN-1:0]                  dispatch_immediate_i,
  input  logic [1:0][OP_WIDTH-1:0]              dispatch_operation_i,
  input  logic [1:0][LQ_INDEX_WIDTH-1:0]        dispatch_lq_index_i,
  input  logic [1:0][SQ_INDEX_WIDTH-1:0]        dispatch_sq_index_i,

  input  logic [WRITEBACK_PORTS-1:0]            writeback_valid_i,
  input  logic [WRITEBACK_PORTS-1:0][PHYS_TAG_WIDTH-1:0]
                                                   writeback_phys_i,

  output logic [SELECT_WIDTH-1:0]               candidate_valid_o,
  input  logic [SELECT_WIDTH-1:0]               candidate_accept_i,
  output logic [SELECT_WIDTH-1:0][INDEX_WIDTH-1:0]
                                                   candidate_index_o,
  output logic [SELECT_WIDTH-1:0][ROB_SEQ_WIDTH-1:0]
                                                   candidate_sequence_o,
  output rv_ooo_pkg::fu_class_e [SELECT_WIDTH-1:0]
                                                   candidate_fu_o,
  output logic [SELECT_WIDTH-1:0][EXEC_PORTS-1:0]
                                                   candidate_port_mask_o,
  output logic [SELECT_WIDTH-1:0][2:0][PHYS_TAG_WIDTH-1:0]
                                                   candidate_src_phys_o,
  output logic [SELECT_WIDTH-1:0]
                                                   candidate_destination_valid_o,
  output logic [SELECT_WIDTH-1:0][PHYS_TAG_WIDTH-1:0]
                                                   candidate_destination_phys_o,
  output logic [SELECT_WIDTH-1:0][XLEN-1:0]     candidate_pc_o,
  output logic [SELECT_WIDTH-1:0][31:0]         candidate_instruction_o,
  output logic [SELECT_WIDTH-1:0][XLEN-1:0]     candidate_immediate_o,
  output logic [SELECT_WIDTH-1:0][OP_WIDTH-1:0] candidate_operation_o,
  output logic [SELECT_WIDTH-1:0][LQ_INDEX_WIDTH-1:0]
                                                   candidate_lq_index_o,
  output logic [SELECT_WIDTH-1:0][SQ_INDEX_WIDTH-1:0]
                                                   candidate_sq_index_o,

  input  logic                                  flush_all_i,
  input  logic                                  flush_younger_i,
  input  logic [ROB_SEQ_WIDTH-1:0]              flush_sequence_i,
  output logic [COUNT_WIDTH-1:0]                count_o,
  output logic                                  empty_o,
  output logic                                  full_o
);

  import rv_ooo_pkg::*;

  typedef struct packed {
    logic                         valid;
    logic [ROB_SEQ_WIDTH-1:0]     sequence_id;
    fu_class_e                    fu;
    logic [EXEC_PORTS-1:0]        port_mask;
    logic [2:0]                   src_used;
    logic [2:0][PHYS_TAG_WIDTH-1:0] src_phys;
    logic [2:0]                   src_ready;
    logic                         destination_valid;
    logic [PHYS_TAG_WIDTH-1:0]    destination_phys;
    logic [XLEN-1:0]              pc;
    logic [31:0]                  instruction;
    logic [XLEN-1:0]              immediate;
    logic [OP_WIDTH-1:0]          operation;
    logic [LQ_INDEX_WIDTH-1:0]    lq_index;
    logic [SQ_INDEX_WIDTH-1:0]    sq_index;
  } issue_entry_t;

  issue_entry_t entries_q [0:ENTRIES-1];
  logic [ENTRIES-1:0] ready_now;
  logic [ENTRIES-1:0] selected_mask;
  logic [SELECT_WIDTH-1:0] select_found;
  logic [ENTRIES-1:0] available_slots;
  logic [ENTRIES-1:0] allocation_slots_work;
  logic [1:0] allocation_found;
  logic [2:0] requested_dispatch_count;
  logic dispatch_fire;

  function automatic logic sequence_before(
    input logic [ROB_SEQ_WIDTH-1:0] lhs,
    input logic [ROB_SEQ_WIDTH-1:0] rhs
  );
    logic signed [ROB_SEQ_WIDTH-1:0] difference;
    difference = $signed(lhs - rhs);
    return difference < 0;
  endfunction

  function automatic logic sequence_after(
    input logic [ROB_SEQ_WIDTH-1:0] lhs,
    input logic [ROB_SEQ_WIDTH-1:0] rhs
  );
    logic signed [ROB_SEQ_WIDTH-1:0] difference;
    difference = $signed(lhs - rhs);
    return difference > 0;
  endfunction

  function automatic logic tag_wakes(
    input logic [PHYS_TAG_WIDTH-1:0] tag
  );
    logic wake;
    wake = 1'b0;
    for (int unsigned port = 0; port < WRITEBACK_PORTS; port++)
      wake |= writeback_valid_i[port] && (writeback_phys_i[port] == tag);
    return wake;
  endfunction

  always_comb begin
    for (int unsigned entry = 0; entry < ENTRIES; entry++) begin
      ready_now[entry] = entries_q[entry].valid;
      for (int unsigned source = 0; source < 3; source++) begin
        if (entries_q[entry].src_used[source])
          ready_now[entry] &= entries_q[entry].src_ready[source] ||
                              tag_wakes(entries_q[entry].src_phys[source]);
      end
    end
  end

  always_comb begin
    candidate_valid_o             = '0;
    candidate_index_o             = '0;
    candidate_sequence_o          = '0;
    candidate_fu_o                = '{default: FU_NONE};
    candidate_port_mask_o         = '0;
    candidate_src_phys_o          = '0;
    candidate_destination_valid_o = '0;
    candidate_destination_phys_o  = '0;
    candidate_pc_o                = '0;
    candidate_instruction_o       = '0;
    candidate_immediate_o         = '0;
    candidate_operation_o         = '0;
    candidate_lq_index_o          = '0;
    candidate_sq_index_o          = '0;
    selected_mask                 = '0;
    select_found                  = '0;

    if (!flush_all_i && !flush_younger_i) begin
      for (int unsigned slot = 0; slot < SELECT_WIDTH; slot++) begin
        for (int unsigned entry = 0; entry < ENTRIES; entry++) begin
          if (ready_now[entry] && !selected_mask[entry] &&
              (!select_found[slot] ||
               sequence_before(entries_q[entry].sequence_id,
                               entries_q[candidate_index_o[slot]].sequence_id))) begin
            candidate_index_o[slot] = INDEX_WIDTH'(entry);
            select_found[slot]      = 1'b1;
          end
        end
        if (select_found[slot]) begin
          selected_mask[candidate_index_o[slot]] = 1'b1;
          candidate_valid_o[slot] = 1'b1;
          candidate_sequence_o[slot] =
            entries_q[candidate_index_o[slot]].sequence_id;
          candidate_fu_o[slot] = entries_q[candidate_index_o[slot]].fu;
          candidate_port_mask_o[slot] =
            entries_q[candidate_index_o[slot]].port_mask;
          candidate_src_phys_o[slot] =
            entries_q[candidate_index_o[slot]].src_phys;
          candidate_destination_valid_o[slot] =
            entries_q[candidate_index_o[slot]].destination_valid;
          candidate_destination_phys_o[slot] =
            entries_q[candidate_index_o[slot]].destination_phys;
          candidate_pc_o[slot] = entries_q[candidate_index_o[slot]].pc;
          candidate_instruction_o[slot] =
            entries_q[candidate_index_o[slot]].instruction;
          candidate_immediate_o[slot] =
            entries_q[candidate_index_o[slot]].immediate;
          candidate_operation_o[slot] =
            entries_q[candidate_index_o[slot]].operation;
          candidate_lq_index_o[slot] =
            entries_q[candidate_index_o[slot]].lq_index;
          candidate_sq_index_o[slot] =
            entries_q[candidate_index_o[slot]].sq_index;
        end
      end
    end
  end

  always_comb begin
    for (int unsigned entry = 0; entry < ENTRIES; entry++)
      available_slots[entry] = !entries_q[entry].valid;
    for (int unsigned slot = 0; slot < SELECT_WIDTH; slot++) begin
      if (candidate_valid_o[slot] && candidate_accept_i[slot])
        available_slots[candidate_index_o[slot]] = 1'b1;
    end

    allocation_slots_work = available_slots;
    allocation_found      = '0;
    dispatch_index_o      = '0;
    for (int unsigned lane = 0; lane < 2; lane++) begin
      if (dispatch_valid_i[lane]) begin
        for (int unsigned entry = 0; entry < ENTRIES; entry++) begin
          if (allocation_slots_work[entry] && !allocation_found[lane]) begin
            dispatch_index_o[lane] = INDEX_WIDTH'(entry);
            allocation_found[lane] = 1'b1;
          end
        end
        if (allocation_found[lane])
          allocation_slots_work[dispatch_index_o[lane]] = 1'b0;
      end else begin
        allocation_found[lane] = 1'b1;
      end
    end

    requested_dispatch_count = {2'b0, dispatch_valid_i[0]} +
                               {2'b0, dispatch_valid_i[1]};
    dispatch_ready_o = (!dispatch_valid_i[1] || dispatch_valid_i[0]) &&
                       (&allocation_found) &&
                       !flush_all_i && !flush_younger_i;
    dispatch_fire = dispatch_ready_o && (requested_dispatch_count != 0);
  end

  always_ff @(posedge clk_i) begin
    if (!rst_ni || flush_all_i) begin
      for (int unsigned entry = 0; entry < ENTRIES; entry++)
        entries_q[entry] <= '0;
    end else if (flush_younger_i) begin
      for (int unsigned entry = 0; entry < ENTRIES; entry++) begin
        if (entries_q[entry].valid &&
            sequence_after(entries_q[entry].sequence_id, flush_sequence_i))
          entries_q[entry].valid <= 1'b0;
      end
    end else begin
      for (int unsigned entry = 0; entry < ENTRIES; entry++) begin
        if (entries_q[entry].valid) begin
          for (int unsigned source = 0; source < 3; source++) begin
            if (entries_q[entry].src_used[source] &&
                tag_wakes(entries_q[entry].src_phys[source]))
              entries_q[entry].src_ready[source] <= 1'b1;
          end
        end
      end

      for (int unsigned slot = 0; slot < SELECT_WIDTH; slot++) begin
        if (candidate_valid_o[slot] && candidate_accept_i[slot])
          entries_q[candidate_index_o[slot]].valid <= 1'b0;
      end

      if (dispatch_fire) begin
        for (int unsigned lane = 0; lane < 2; lane++) begin
          if (dispatch_valid_i[lane]) begin
            entries_q[dispatch_index_o[lane]].valid <= 1'b1;
            entries_q[dispatch_index_o[lane]].sequence_id <=
              dispatch_sequence_i[lane];
            entries_q[dispatch_index_o[lane]].fu <= dispatch_fu_i[lane];
            entries_q[dispatch_index_o[lane]].port_mask <=
              dispatch_port_mask_i[lane];
            entries_q[dispatch_index_o[lane]].src_used <=
              dispatch_src_used_i[lane];
            entries_q[dispatch_index_o[lane]].src_phys <=
              dispatch_src_phys_i[lane];
            for (int unsigned source = 0; source < 3; source++) begin
              entries_q[dispatch_index_o[lane]].src_ready[source] <=
                !dispatch_src_used_i[lane][source] ||
                dispatch_src_ready_i[lane][source] ||
                tag_wakes(dispatch_src_phys_i[lane][source]);
            end
            entries_q[dispatch_index_o[lane]].destination_valid <=
              dispatch_destination_valid_i[lane];
            entries_q[dispatch_index_o[lane]].destination_phys <=
              dispatch_destination_phys_i[lane];
            entries_q[dispatch_index_o[lane]].pc <= dispatch_pc_i[lane];
            entries_q[dispatch_index_o[lane]].instruction <=
              dispatch_instruction_i[lane];
            entries_q[dispatch_index_o[lane]].immediate <=
              dispatch_immediate_i[lane];
            entries_q[dispatch_index_o[lane]].operation <=
              dispatch_operation_i[lane];
            entries_q[dispatch_index_o[lane]].lq_index <=
              dispatch_lq_index_i[lane];
            entries_q[dispatch_index_o[lane]].sq_index <=
              dispatch_sq_index_i[lane];
          end
        end
      end
    end
  end

  always_comb begin
    count_o = '0;
    for (int unsigned entry = 0; entry < ENTRIES; entry++) begin
      if (entries_q[entry].valid)
        count_o = count_o + 1'b1;
    end
    empty_o = (count_o == 0);
    full_o  = (count_o == ENTRIES);
  end

`ifndef SYNTHESIS
  property p_lane1_dispatch_requires_lane0;
    @(posedge clk_i) disable iff (!rst_ni)
      dispatch_valid_i[1] |-> dispatch_valid_i[0];
  endproperty
  assert property (p_lane1_dispatch_requires_lane0);

  for (genvar slot = 0; slot < SELECT_WIDTH; slot++) begin : g_accept_assert
    property p_accept_requires_candidate;
      @(posedge clk_i) disable iff (!rst_ni)
        candidate_accept_i[slot] |-> candidate_valid_o[slot];
    endproperty
    assert property (p_accept_requires_candidate);
  end

  if (SELECT_WIDTH > 1) begin : g_distinct_candidate_assert
    property p_candidate_indices_distinct;
      @(posedge clk_i) disable iff (!rst_ni)
        candidate_valid_o[0] && candidate_valid_o[1]
        |-> candidate_index_o[0] != candidate_index_o[1];
    endproperty
    assert property (p_candidate_indices_distinct);
  end

  property p_count_in_range;
    @(posedge clk_i) disable iff (!rst_ni)
      count_o <= ENTRIES;
  endproperty
  assert property (p_count_in_range);
`endif

  initial begin : p_parameter_checks
    if ((XLEN != 32) && (XLEN != 64))
      $fatal(1, "Issue queue XLEN must be 32 or 64");
    if ((ENTRIES < 2) || (SELECT_WIDTH < 1) || (SELECT_WIDTH > ENTRIES))
      $fatal(1, "Issue queue entries/select width combination is invalid");
    if (ROB_SEQ_WIDTH < 2)
      $fatal(1, "Issue queue requires a wrap-aware ROB sequence");
    if ((WRITEBACK_PORTS == 0) || (EXEC_PORTS == 0))
      $fatal(1, "Issue queue wakeup and execution port counts must be nonzero");
  end

endmodule
