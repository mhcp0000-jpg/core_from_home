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
  parameter int unsigned CHECKPOINT_ID_WIDTH = 3,
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
  input  rv_ooo_pkg::reg_class_e [1:0][2:0]    dispatch_src_class_i,
  input  logic [1:0][2:0][PHYS_TAG_WIDTH-1:0]   dispatch_src_phys_i,
  input  logic [1:0][2:0]                       dispatch_src_ready_i,
  input  logic [1:0]                            dispatch_destination_valid_i,
  input  rv_ooo_pkg::reg_class_e [1:0]          dispatch_destination_class_i,
  input  logic [1:0][PHYS_TAG_WIDTH-1:0]        dispatch_destination_phys_i,
  input  logic [1:0][XLEN-1:0]                  dispatch_pc_i,
  input  logic [1:0][31:0]                      dispatch_instruction_i,
  input  rv_ooo_pkg::inst_len_e [1:0]           dispatch_inst_len_i,
  input  rv_ooo_pkg::prediction_meta_t [1:0]    dispatch_prediction_i,
  input  logic [1:0][XLEN-1:0]                  dispatch_immediate_i,
  input  logic [1:0][OP_WIDTH-1:0]              dispatch_operation_i,
  input  logic [1:0]                            dispatch_use_pc_i,
  input  logic [1:0]                            dispatch_use_immediate_i,
  input  logic [1:0]                            dispatch_word_operation_i,
  input  logic [1:0][2:0]                       dispatch_mem_size_i,
  input  logic [1:0]                            dispatch_mem_unsigned_i,
  input  logic [1:0][2:0]                       dispatch_rounding_mode_i,
  input  logic [1:0]                            dispatch_checkpoint_valid_i,
  input  logic [1:0][CHECKPOINT_ID_WIDTH-1:0]   dispatch_checkpoint_id_i,
  input  logic [1:0][LQ_INDEX_WIDTH-1:0]        dispatch_lq_index_i,
  input  logic [1:0][SQ_INDEX_WIDTH-1:0]        dispatch_sq_index_i,

  input  logic [WRITEBACK_PORTS-1:0]            writeback_valid_i,
  input  rv_ooo_pkg::reg_class_e [WRITEBACK_PORTS-1:0]
                                                   writeback_class_i,
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
  output rv_ooo_pkg::reg_class_e [SELECT_WIDTH-1:0][2:0]
                                                   candidate_src_class_o,
  output logic [SELECT_WIDTH-1:0]
                                                   candidate_destination_valid_o,
  output rv_ooo_pkg::reg_class_e [SELECT_WIDTH-1:0]
                                                   candidate_destination_class_o,
  output logic [SELECT_WIDTH-1:0][PHYS_TAG_WIDTH-1:0]
                                                   candidate_destination_phys_o,
  output logic [SELECT_WIDTH-1:0][XLEN-1:0]     candidate_pc_o,
  output logic [SELECT_WIDTH-1:0][31:0]         candidate_instruction_o,
  output rv_ooo_pkg::inst_len_e [SELECT_WIDTH-1:0]
                                                   candidate_inst_len_o,
  output rv_ooo_pkg::prediction_meta_t [SELECT_WIDTH-1:0]
                                                   candidate_prediction_o,
  output logic [SELECT_WIDTH-1:0][XLEN-1:0]     candidate_immediate_o,
  output logic [SELECT_WIDTH-1:0][OP_WIDTH-1:0] candidate_operation_o,
  output logic [SELECT_WIDTH-1:0]               candidate_use_pc_o,
  output logic [SELECT_WIDTH-1:0]               candidate_use_immediate_o,
  output logic [SELECT_WIDTH-1:0]               candidate_word_operation_o,
  output logic [SELECT_WIDTH-1:0][2:0]          candidate_mem_size_o,
  output logic [SELECT_WIDTH-1:0]               candidate_mem_unsigned_o,
  output logic [SELECT_WIDTH-1:0][2:0]          candidate_rounding_mode_o,
  output logic [SELECT_WIDTH-1:0]               candidate_checkpoint_valid_o,
  output logic [SELECT_WIDTH-1:0][CHECKPOINT_ID_WIDTH-1:0]
                                                   candidate_checkpoint_id_o,
  output logic [SELECT_WIDTH-1:0][LQ_INDEX_WIDTH-1:0]
                                                   candidate_lq_index_o,
  output logic [SELECT_WIDTH-1:0][SQ_INDEX_WIDTH-1:0]
                                                   candidate_sq_index_o,
  output logic [SELECT_WIDTH-1:0]
                                                   candidate_store_address_valid_o,
  output logic [SELECT_WIDTH-1:0]
                                                   candidate_store_data_valid_o,

  input  logic                                  flush_all_i,
  input  logic                                  flush_younger_i,
  input  logic [ROB_SEQ_WIDTH-1:0]              flush_sequence_i,
  output logic [COUNT_WIDTH-1:0]                count_o,
  output logic                                  empty_o,
  output logic                                  full_o
);

  import rv_ooo_pkg::*;

  // Parallel arrays avoid tool-specific limitations around variable indexing
  // of packed structs while retaining the same physical entry semantics.
  logic valid_q [0:ENTRIES-1];
  logic [ROB_SEQ_WIDTH-1:0] sequence_q [0:ENTRIES-1];
  fu_class_e fu_q [0:ENTRIES-1];
  logic [EXEC_PORTS-1:0] port_mask_q [0:ENTRIES-1];
  logic [2:0] src_used_q [0:ENTRIES-1];
  reg_class_e src0_class_q [0:ENTRIES-1];
  reg_class_e src1_class_q [0:ENTRIES-1];
  reg_class_e src2_class_q [0:ENTRIES-1];
  logic [2:0][PHYS_TAG_WIDTH-1:0] src_phys_q [0:ENTRIES-1];
  logic [2:0] src_ready_q [0:ENTRIES-1];
  logic destination_valid_q [0:ENTRIES-1];
  reg_class_e destination_class_q [0:ENTRIES-1];
  logic [PHYS_TAG_WIDTH-1:0] destination_phys_q [0:ENTRIES-1];
  logic [XLEN-1:0] pc_q [0:ENTRIES-1];
  logic [31:0] instruction_q [0:ENTRIES-1];
  inst_len_e inst_len_q [0:ENTRIES-1];
  prediction_meta_t prediction_q [0:ENTRIES-1];
  logic [XLEN-1:0] immediate_q [0:ENTRIES-1];
  logic [OP_WIDTH-1:0] operation_q [0:ENTRIES-1];
  logic use_pc_q [0:ENTRIES-1];
  logic use_immediate_q [0:ENTRIES-1];
  logic word_operation_q [0:ENTRIES-1];
  logic [2:0] mem_size_q [0:ENTRIES-1];
  logic mem_unsigned_q [0:ENTRIES-1];
  logic [2:0] rounding_mode_q [0:ENTRIES-1];
  logic checkpoint_valid_q [0:ENTRIES-1];
  logic [CHECKPOINT_ID_WIDTH-1:0] checkpoint_id_q [0:ENTRIES-1];
  logic [LQ_INDEX_WIDTH-1:0] lq_index_q [0:ENTRIES-1];
  logic [SQ_INDEX_WIDTH-1:0] sq_index_q [0:ENTRIES-1];
  // A store may use an LSU port once for address generation and remain in the
  // IQ until its data source becomes ready.  This exposes the older-store
  // address to the LSQ early without making the store architecturally visible.
  logic store_address_issued_q [0:ENTRIES-1];
  logic [2:0] source_ready_now [0:ENTRIES-1];
  logic [ENTRIES-1:0] ready_now;
  logic [ENTRIES-1:0] selected_mask;
  logic [SELECT_WIDTH-1:0] select_found;
  logic [ENTRIES-1:0] available_slots;
  logic [ENTRIES-1:0] allocation_slots_work;
  logic [1:0] allocation_found;
  logic [SELECT_WIDTH-1:0] candidate_final_phase;
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
    input reg_class_e source_class,
    input logic [PHYS_TAG_WIDTH-1:0] tag
  );
    logic wake;
    wake = 1'b0;
    for (int unsigned port = 0; port < WRITEBACK_PORTS; port++)
      wake |= writeback_valid_i[port] &&
              (writeback_class_i[port] == source_class) &&
              (writeback_phys_i[port] == tag);
    return wake;
  endfunction

  always_comb begin
    for (int unsigned entry = 0; entry < ENTRIES; entry++) begin
      for (int unsigned source = 0; source < 3; source++) begin
        source_ready_now[entry][source] = !src_used_q[entry][source];
        case (source)
          0: source_ready_now[entry][source] |=
               src_ready_q[entry][source] ||
               tag_wakes(src0_class_q[entry], src_phys_q[entry][source]);
          1: source_ready_now[entry][source] |=
               src_ready_q[entry][source] ||
               tag_wakes(src1_class_q[entry], src_phys_q[entry][source]);
          default: source_ready_now[entry][source] |=
               src_ready_q[entry][source] ||
               tag_wakes(src2_class_q[entry], src_phys_q[entry][source]);
        endcase
      end
      if (fu_q[entry] == FU_STORE)
        ready_now[entry] = valid_q[entry] &&
          (store_address_issued_q[entry] ? source_ready_now[entry][1] :
                                          source_ready_now[entry][0]);
      else
        ready_now[entry] = valid_q[entry] && (&source_ready_now[entry]);
    end
  end

  always_comb begin
    candidate_valid_o             = '0;
    candidate_index_o             = '0;
    candidate_sequence_o          = '0;
    candidate_fu_o                = '0;
    candidate_port_mask_o         = '0;
    candidate_src_phys_o          = '0;
    candidate_src_class_o         = '0;
    candidate_destination_valid_o = '0;
    candidate_destination_class_o = '0;
    candidate_destination_phys_o  = '0;
    candidate_pc_o                = '0;
    candidate_instruction_o       = '0;
    candidate_inst_len_o          = '0;
    candidate_prediction_o        = '0;
    candidate_immediate_o         = '0;
    candidate_operation_o         = '0;
    candidate_use_pc_o            = '0;
    candidate_use_immediate_o     = '0;
    candidate_word_operation_o    = '0;
    candidate_mem_size_o          = '0;
    candidate_mem_unsigned_o      = '0;
    candidate_rounding_mode_o     = '0;
    candidate_checkpoint_valid_o  = '0;
    candidate_checkpoint_id_o     = '0;
    candidate_lq_index_o          = '0;
    candidate_sq_index_o          = '0;
    candidate_store_address_valid_o = '0;
    candidate_store_data_valid_o  = '0;
    candidate_final_phase         = '0;
    selected_mask                 = '0;
    select_found                  = '0;

    if (!flush_all_i && !flush_younger_i) begin
      for (int unsigned slot = 0; slot < SELECT_WIDTH; slot++) begin
        for (int unsigned entry = 0; entry < ENTRIES; entry++) begin
          if (ready_now[entry] && !selected_mask[entry] &&
              (!select_found[slot] ||
               sequence_before(sequence_q[entry],
                               sequence_q[candidate_index_o[slot]]))) begin
            candidate_index_o[slot] = INDEX_WIDTH'(entry);
            select_found[slot]      = 1'b1;
          end
        end
        if (select_found[slot]) begin
          selected_mask[candidate_index_o[slot]] = 1'b1;
          candidate_valid_o[slot] = 1'b1;
          candidate_sequence_o[slot] =
            sequence_q[candidate_index_o[slot]];
          candidate_fu_o[slot] = fu_q[candidate_index_o[slot]];
          candidate_port_mask_o[slot] =
            port_mask_q[candidate_index_o[slot]];
          candidate_src_phys_o[slot] =
            src_phys_q[candidate_index_o[slot]];
          candidate_src_class_o[slot][0] =
            src0_class_q[candidate_index_o[slot]];
          candidate_src_class_o[slot][1] =
            src1_class_q[candidate_index_o[slot]];
          candidate_src_class_o[slot][2] =
            src2_class_q[candidate_index_o[slot]];
          candidate_destination_valid_o[slot] =
            destination_valid_q[candidate_index_o[slot]];
          candidate_destination_class_o[slot] =
            destination_class_q[candidate_index_o[slot]];
          candidate_destination_phys_o[slot] =
            destination_phys_q[candidate_index_o[slot]];
          candidate_pc_o[slot] = pc_q[candidate_index_o[slot]];
          candidate_instruction_o[slot] =
            instruction_q[candidate_index_o[slot]];
          candidate_inst_len_o[slot] =
            inst_len_q[candidate_index_o[slot]];
          candidate_prediction_o[slot] =
            prediction_q[candidate_index_o[slot]];
          candidate_immediate_o[slot] =
            immediate_q[candidate_index_o[slot]];
          candidate_operation_o[slot] =
            operation_q[candidate_index_o[slot]];
          candidate_use_pc_o[slot] =
            use_pc_q[candidate_index_o[slot]];
          candidate_use_immediate_o[slot] =
            use_immediate_q[candidate_index_o[slot]];
          candidate_word_operation_o[slot] =
            word_operation_q[candidate_index_o[slot]];
          candidate_mem_size_o[slot] =
            mem_size_q[candidate_index_o[slot]];
          candidate_mem_unsigned_o[slot] =
            mem_unsigned_q[candidate_index_o[slot]];
          candidate_rounding_mode_o[slot] =
            rounding_mode_q[candidate_index_o[slot]];
          candidate_checkpoint_valid_o[slot] =
            checkpoint_valid_q[candidate_index_o[slot]];
          candidate_checkpoint_id_o[slot] =
            checkpoint_id_q[candidate_index_o[slot]];
          candidate_lq_index_o[slot] =
            lq_index_q[candidate_index_o[slot]];
          candidate_sq_index_o[slot] =
            sq_index_q[candidate_index_o[slot]];
          candidate_store_address_valid_o[slot] =
            (fu_q[candidate_index_o[slot]] == FU_STORE) &&
            !store_address_issued_q[candidate_index_o[slot]];
          candidate_store_data_valid_o[slot] =
            (fu_q[candidate_index_o[slot]] == FU_STORE) &&
            source_ready_now[candidate_index_o[slot]][1];
          candidate_final_phase[slot] =
            (fu_q[candidate_index_o[slot]] != FU_STORE) ||
            source_ready_now[candidate_index_o[slot]][1];
        end
      end
    end
  end

  always_comb begin
    for (int unsigned entry = 0; entry < ENTRIES; entry++)
      available_slots[entry] = !valid_q[entry];
    for (int unsigned slot = 0; slot < SELECT_WIDTH; slot++) begin
      if (candidate_valid_o[slot] && candidate_accept_i[slot] &&
          candidate_final_phase[slot])
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
      for (int unsigned entry = 0; entry < ENTRIES; entry++) begin
        valid_q[entry] <= 1'b0;
        sequence_q[entry] <= '0;
        fu_q[entry] <= FU_NONE;
        port_mask_q[entry] <= '0;
        src_used_q[entry] <= '0;
        src0_class_q[entry] <= REG_NONE;
        src1_class_q[entry] <= REG_NONE;
        src2_class_q[entry] <= REG_NONE;
        src_phys_q[entry] <= '0;
        src_ready_q[entry] <= '0;
        destination_valid_q[entry] <= 1'b0;
        destination_class_q[entry] <= REG_NONE;
        destination_phys_q[entry] <= '0;
        pc_q[entry] <= '0;
        instruction_q[entry] <= '0;
        inst_len_q[entry] <= INST_LEN_NONE;
        prediction_q[entry] <= '0;
        immediate_q[entry] <= '0;
        operation_q[entry] <= '0;
        use_pc_q[entry] <= 1'b0;
        use_immediate_q[entry] <= 1'b0;
        word_operation_q[entry] <= 1'b0;
        mem_size_q[entry] <= '0;
        mem_unsigned_q[entry] <= 1'b0;
        rounding_mode_q[entry] <= '0;
        checkpoint_valid_q[entry] <= 1'b0;
        checkpoint_id_q[entry] <= '0;
        lq_index_q[entry] <= '0;
        sq_index_q[entry] <= '0;
        store_address_issued_q[entry] <= 1'b0;
      end
    end else if (flush_younger_i) begin
      for (int unsigned entry = 0; entry < ENTRIES; entry++) begin
        if (valid_q[entry] && sequence_after(sequence_q[entry], flush_sequence_i))
          valid_q[entry] <= 1'b0;
        else if (valid_q[entry]) begin
          // Results from older instructions may write back in the same cycle
          // as a younger-branch recovery.  Preserve those wakeups for IQ
          // entries that survive the recovery boundary.
          for (int unsigned source = 0; source < 3; source++) begin
            if (src_used_q[entry][source]) begin
              case (source)
                0: if (tag_wakes(src0_class_q[entry], src_phys_q[entry][source]))
                     src_ready_q[entry][source] <= 1'b1;
                1: if (tag_wakes(src1_class_q[entry], src_phys_q[entry][source]))
                     src_ready_q[entry][source] <= 1'b1;
                default:
                  if (tag_wakes(src2_class_q[entry], src_phys_q[entry][source]))
                    src_ready_q[entry][source] <= 1'b1;
              endcase
            end
          end
        end
      end
    end else begin
      for (int unsigned entry = 0; entry < ENTRIES; entry++) begin
        if (valid_q[entry]) begin
          for (int unsigned source = 0; source < 3; source++) begin
            if (src_used_q[entry][source]) begin
              case (source)
                0: if (tag_wakes(src0_class_q[entry], src_phys_q[entry][source]))
                     src_ready_q[entry][source] <= 1'b1;
                1: if (tag_wakes(src1_class_q[entry], src_phys_q[entry][source]))
                     src_ready_q[entry][source] <= 1'b1;
                default:
                  if (tag_wakes(src2_class_q[entry], src_phys_q[entry][source]))
                    src_ready_q[entry][source] <= 1'b1;
              endcase
            end
          end
        end
      end

      for (int unsigned slot = 0; slot < SELECT_WIDTH; slot++) begin
        if (candidate_valid_o[slot] && candidate_accept_i[slot]) begin
          if (candidate_final_phase[slot])
            valid_q[candidate_index_o[slot]] <= 1'b0;
          else
            store_address_issued_q[candidate_index_o[slot]] <= 1'b1;
        end
      end

      if (dispatch_fire) begin
        for (int unsigned lane = 0; lane < 2; lane++) begin
          if (dispatch_valid_i[lane]) begin
            valid_q[dispatch_index_o[lane]] <= 1'b1;
            sequence_q[dispatch_index_o[lane]] <= dispatch_sequence_i[lane];
            fu_q[dispatch_index_o[lane]] <= dispatch_fu_i[lane];
            port_mask_q[dispatch_index_o[lane]] <= dispatch_port_mask_i[lane];
            src_used_q[dispatch_index_o[lane]] <= dispatch_src_used_i[lane];
            src0_class_q[dispatch_index_o[lane]] <= dispatch_src_class_i[lane][0];
            src1_class_q[dispatch_index_o[lane]] <= dispatch_src_class_i[lane][1];
            src2_class_q[dispatch_index_o[lane]] <= dispatch_src_class_i[lane][2];
            src_phys_q[dispatch_index_o[lane]] <= dispatch_src_phys_i[lane];
            for (int unsigned source = 0; source < 3; source++) begin
              src_ready_q[dispatch_index_o[lane]][source] <=
                !dispatch_src_used_i[lane][source] ||
                dispatch_src_ready_i[lane][source] ||
                ((source == 0) ?
                 tag_wakes(dispatch_src_class_i[lane][0],
                           dispatch_src_phys_i[lane][source]) :
                 ((source == 1) ?
                  tag_wakes(dispatch_src_class_i[lane][1],
                            dispatch_src_phys_i[lane][source]) :
                  tag_wakes(dispatch_src_class_i[lane][2],
                            dispatch_src_phys_i[lane][source])));
            end
            destination_valid_q[dispatch_index_o[lane]] <=
              dispatch_destination_valid_i[lane];
            destination_class_q[dispatch_index_o[lane]] <=
              dispatch_destination_class_i[lane];
            destination_phys_q[dispatch_index_o[lane]] <=
              dispatch_destination_phys_i[lane];
            pc_q[dispatch_index_o[lane]] <= dispatch_pc_i[lane];
            instruction_q[dispatch_index_o[lane]] <= dispatch_instruction_i[lane];
            inst_len_q[dispatch_index_o[lane]] <= dispatch_inst_len_i[lane];
            prediction_q[dispatch_index_o[lane]] <= dispatch_prediction_i[lane];
            immediate_q[dispatch_index_o[lane]] <= dispatch_immediate_i[lane];
            operation_q[dispatch_index_o[lane]] <= dispatch_operation_i[lane];
            use_pc_q[dispatch_index_o[lane]] <= dispatch_use_pc_i[lane];
            use_immediate_q[dispatch_index_o[lane]] <=
              dispatch_use_immediate_i[lane];
            word_operation_q[dispatch_index_o[lane]] <=
              dispatch_word_operation_i[lane];
            mem_size_q[dispatch_index_o[lane]] <= dispatch_mem_size_i[lane];
            mem_unsigned_q[dispatch_index_o[lane]] <=
              dispatch_mem_unsigned_i[lane];
            rounding_mode_q[dispatch_index_o[lane]] <=
              dispatch_rounding_mode_i[lane];
            checkpoint_valid_q[dispatch_index_o[lane]] <=
              dispatch_checkpoint_valid_i[lane];
            checkpoint_id_q[dispatch_index_o[lane]] <=
              dispatch_checkpoint_id_i[lane];
            lq_index_q[dispatch_index_o[lane]] <= dispatch_lq_index_i[lane];
            sq_index_q[dispatch_index_o[lane]] <= dispatch_sq_index_i[lane];
            store_address_issued_q[dispatch_index_o[lane]] <= 1'b0;
          end
        end
      end
    end
  end

  always_comb begin
    count_o = '0;
    for (int unsigned entry = 0; entry < ENTRIES; entry++) begin
      if (valid_q[entry])
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

    property p_partial_store_accept_is_address_only;
      @(posedge clk_i) disable iff (!rst_ni)
        candidate_accept_i[slot] &&
        (candidate_fu_o[slot] == FU_STORE) &&
        !candidate_store_data_valid_o[slot]
        |-> candidate_store_address_valid_o[slot];
    endproperty
    assert property (p_partial_store_accept_is_address_only);
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
    if ((WRITEBACK_PORTS == 0) || (EXEC_PORTS == 0) ||
        (CHECKPOINT_ID_WIDTH == 0))
      $fatal(1, "Issue queue wakeup and execution port counts must be nonzero");
  end

endmodule
