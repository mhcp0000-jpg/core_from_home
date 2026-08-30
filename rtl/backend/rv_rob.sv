module rv_rob #(
  parameter int unsigned XLEN            = 32,
  parameter int unsigned ROB_ENTRIES     = 48,
  parameter int unsigned SEQ_WIDTH       = rv_ooo_pkg::ROB_SEQ_WIDTH,
  parameter int unsigned PHYS_TAG_WIDTH  = 7,
  parameter int unsigned LQ_INDEX_WIDTH  = 5,
  parameter int unsigned SQ_INDEX_WIDTH  = 4,
  parameter int unsigned COMPLETE_PORTS  = 4,
  parameter int unsigned LIVE_QUERY_PORTS = 8,
  localparam int unsigned ROB_INDEX_WIDTH = $clog2(ROB_ENTRIES),
  localparam int unsigned ROB_COUNT_WIDTH = $clog2(ROB_ENTRIES + 1)
) (
  input  logic                                  clk_i,
  input  logic                                  rst_ni,

  input  logic [1:0]                            alloc_valid_i,
  output logic                                  alloc_ready_o,
  output logic [1:0][ROB_INDEX_WIDTH-1:0]       alloc_index_o,
  output logic [1:0][SEQ_WIDTH-1:0]             alloc_sequence_o,
  input  logic [1:0][XLEN-1:0]                  alloc_pc_i,
  input  logic [1:0][31:0]                      alloc_instruction_i,
  input  logic [1:0][1:0]                       alloc_instruction_length_i,
  input  logic [1:0]                            alloc_complete_i,
  input  logic [1:0]                            alloc_writes_destination_i,
  input  rv_ooo_pkg::reg_class_e [1:0]          alloc_destination_class_i,
  input  logic [1:0][4:0]                       alloc_destination_arch_i,
  input  logic [1:0][PHYS_TAG_WIDTH-1:0]        alloc_destination_phys_i,
  input  logic [1:0][PHYS_TAG_WIDTH-1:0]        alloc_stale_phys_i,
  input  logic [1:0][PHYS_TAG_WIDTH-1:0]        alloc_source0_phys_i,
  input  logic [1:0]                            alloc_is_store_i,
  input  logic [1:0]                            alloc_is_load_i,
  input  logic [1:0][LQ_INDEX_WIDTH-1:0]        alloc_lq_index_i,
  input  logic [1:0][SQ_INDEX_WIDTH-1:0]        alloc_sq_index_i,
  input  logic [1:0]                            alloc_is_branch_i,
  input  logic [1:0]                            alloc_serializing_i,
  input  logic [1:0]                            alloc_exception_valid_i,
  input  rv_ooo_pkg::exception_code_e [1:0]     alloc_exception_cause_i,
  input  logic [1:0][XLEN-1:0]                  alloc_exception_tval_i,

  input  logic [COMPLETE_PORTS-1:0]             complete_valid_i,
  input  logic [COMPLETE_PORTS-1:0][SEQ_WIDTH-1:0]
                                                   complete_sequence_i,
  input  logic [COMPLETE_PORTS-1:0]             complete_exception_valid_i,
  input  rv_ooo_pkg::exception_code_e [COMPLETE_PORTS-1:0]
                                                   complete_exception_cause_i,
  input  logic [COMPLETE_PORTS-1:0][XLEN-1:0]   complete_exception_tval_i,
  input  logic [COMPLETE_PORTS-1:0]             complete_branch_mispredict_i,
  input  logic [COMPLETE_PORTS-1:0][XLEN-1:0]   complete_branch_target_i,

  // Completion sources and recovery logic must prove that a sequence still
  // names a live ROB generation before updating the PRF or architectural
  // state. Queries are combinational and account for an active flush.
  input  logic [LIVE_QUERY_PORTS-1:0][SEQ_WIDTH-1:0]
                                                   live_query_sequence_i,
  output logic [LIVE_QUERY_PORTS-1:0]            live_query_valid_o,

  output logic [1:0]                            retire_valid_o,
  input  logic [1:0]                            retire_ready_i,
  output logic [1:0][SEQ_WIDTH-1:0]             retire_sequence_o,
  output logic [1:0][XLEN-1:0]                  retire_pc_o,
  output logic [1:0][31:0]                      retire_instruction_o,
  output logic [1:0][1:0]                       retire_instruction_length_o,
  output logic [1:0][XLEN-1:0]                  retire_next_pc_o,
  output logic [1:0]                            retire_writes_destination_o,
  output rv_ooo_pkg::reg_class_e [1:0]          retire_destination_class_o,
  output logic [1:0][4:0]                       retire_destination_arch_o,
  output logic [1:0][PHYS_TAG_WIDTH-1:0]        retire_destination_phys_o,
  output logic [1:0][PHYS_TAG_WIDTH-1:0]        retire_stale_phys_o,
  output logic [1:0]                            retire_is_store_o,
  output logic [1:0]                            retire_is_load_o,
  output logic [1:0][LQ_INDEX_WIDTH-1:0]        retire_lq_index_o,
  output logic [1:0][SQ_INDEX_WIDTH-1:0]        retire_sq_index_o,

  output logic                                  head_valid_o,
  output logic                                  head_complete_o,
  output logic [SEQ_WIDTH-1:0]                  head_sequence_o,
  output logic [XLEN-1:0]                       head_pc_o,
  output logic [31:0]                           head_instruction_o,
  output logic [1:0]                            head_instruction_length_o,
  output logic                                  head_writes_destination_o,
  output rv_ooo_pkg::reg_class_e                head_destination_class_o,
  output logic [PHYS_TAG_WIDTH-1:0]             head_destination_phys_o,
  output logic [PHYS_TAG_WIDTH-1:0]             head_source0_phys_o,

  output logic                                  trap_valid_o,
  input  logic                                  trap_ready_i,
  output logic [SEQ_WIDTH-1:0]                  trap_sequence_o,
  output logic [XLEN-1:0]                       trap_pc_o,
  output rv_ooo_pkg::exception_code_e           trap_cause_o,
  output logic [XLEN-1:0]                       trap_tval_o,

  input  logic                                  flush_all_i,
  input  logic                                  flush_younger_i,
  input  logic [SEQ_WIDTH-1:0]                  flush_sequence_i,

  output logic [ROB_COUNT_WIDTH-1:0]            count_o,
  output logic                                  empty_o,
  output logic                                  full_o
);

  import rv_ooo_pkg::*;

  typedef struct packed {
    logic                         valid;
    logic                         complete;
    logic [SEQ_WIDTH-1:0]         sequence_id;
    logic [XLEN-1:0]              pc;
    logic [31:0]                  instruction;
    logic [1:0]                   instruction_length;
    logic                         writes_destination;
    reg_class_e                   destination_class;
    logic [4:0]                   destination_arch;
    logic [PHYS_TAG_WIDTH-1:0]    destination_phys;
    logic [PHYS_TAG_WIDTH-1:0]    stale_phys;
    logic [PHYS_TAG_WIDTH-1:0]    source0_phys;
    logic                         is_store;
    logic                         is_load;
    logic [LQ_INDEX_WIDTH-1:0]    lq_index;
    logic [SQ_INDEX_WIDTH-1:0]    sq_index;
    logic                         is_branch;
    logic                         serializing;
    logic                         exception_valid;
    exception_code_e              exception_cause;
    logic [XLEN-1:0]              exception_tval;
    logic                         branch_mispredict;
    logic [XLEN-1:0]              branch_target;
  } rob_entry_t;

  rob_entry_t entries_q [0:ROB_ENTRIES-1];
  logic [ROB_INDEX_WIDTH-1:0] head_q;
  logic [ROB_INDEX_WIDTH-1:0] tail_q;
  logic [ROB_COUNT_WIDTH-1:0] count_q;
  logic [SEQ_WIDTH-1:0] next_sequence_q;
  logic [ROB_INDEX_WIDTH-1:0] head_plus_one;
  logic [1:0] retire_fire;
  logic [1:0] requested_alloc_count;
  logic [1:0] accepted_alloc_count;
  logic [1:0] retire_count;
  logic [ROB_COUNT_WIDTH:0] available_with_retire;
  logic flush_boundary_found;
  logic [ROB_INDEX_WIDTH-1:0] flush_tail;
  logic [ROB_COUNT_WIDTH-1:0] flush_kept_count;
  localparam logic [ROB_COUNT_WIDTH:0] ROB_CAPACITY = ROB_ENTRIES;

  function automatic logic [ROB_INDEX_WIDTH-1:0] increment_index(
    input logic [ROB_INDEX_WIDTH-1:0] index,
    input logic [1:0] amount
  );
    logic [ROB_INDEX_WIDTH:0] sum;
    sum = {1'b0, index} + {{(ROB_INDEX_WIDTH-1){1'b0}}, amount};
    if (sum >= ROB_ENTRIES)
      sum = sum - ROB_ENTRIES;
    return sum[ROB_INDEX_WIDTH-1:0];
  endfunction

  function automatic logic sequence_after(
    input logic [SEQ_WIDTH-1:0] lhs,
    input logic [SEQ_WIDTH-1:0] rhs
  );
    logic signed [SEQ_WIDTH-1:0] difference;
    difference = $signed(lhs - rhs);
    return difference > 0;
  endfunction

  always_comb begin
    head_plus_one = increment_index(head_q, 1);
    retire_valid_o = '0;
    if ((count_q != 0) && entries_q[head_q].valid &&
        entries_q[head_q].complete &&
        !entries_q[head_q].exception_valid)
      retire_valid_o[0] = 1'b1;

    if ((count_q > 1) && retire_valid_o[0] &&
        !entries_q[head_q].serializing &&
        entries_q[head_plus_one].valid &&
        entries_q[head_plus_one].complete &&
        !entries_q[head_plus_one].exception_valid &&
        !entries_q[head_plus_one].serializing)
      retire_valid_o[1] = 1'b1;

    retire_fire[0] = retire_valid_o[0] && retire_ready_i[0];
    retire_fire[1] = retire_valid_o[1] && retire_ready_i[1] &&
                     retire_fire[0];
    retire_count = {1'b0, retire_fire[0]} + {1'b0, retire_fire[1]};

    requested_alloc_count = {1'b0, alloc_valid_i[0]} +
                            {1'b0, alloc_valid_i[1]};
    available_with_retire = ROB_CAPACITY - {1'b0, count_q} +
                            {{(ROB_COUNT_WIDTH-1){1'b0}}, retire_count};
    alloc_ready_o = !flush_all_i && !flush_younger_i &&
                    !(alloc_valid_i[1] && !alloc_valid_i[0]) &&
                    (available_with_retire >= requested_alloc_count);
    accepted_alloc_count = alloc_ready_o ? requested_alloc_count : '0;
    alloc_index_o[0]    = tail_q;
    alloc_index_o[1]    = increment_index(tail_q, 1);
    alloc_sequence_o[0] = next_sequence_q;
    alloc_sequence_o[1] = next_sequence_q + 1'b1;

  end

  always_comb begin
    live_query_valid_o = '0;
    for (int unsigned query = 0; query < LIVE_QUERY_PORTS; query++) begin
      for (int unsigned entry = 0; entry < ROB_ENTRIES; entry++) begin
        if (entries_q[entry].valid &&
            (entries_q[entry].sequence_id == live_query_sequence_i[query]))
          live_query_valid_o[query] = 1'b1;
      end
    end
  end

  always_comb begin
    retire_sequence_o            = '0;
    retire_pc_o                  = '0;
    retire_instruction_o         = '0;
    retire_instruction_length_o  = '0;
    retire_next_pc_o             = '0;
    retire_writes_destination_o  = '0;
    retire_destination_class_o   = '0;
    retire_destination_arch_o    = '0;
    retire_destination_phys_o    = '0;
    retire_stale_phys_o          = '0;
    retire_is_store_o            = '0;
    retire_is_load_o             = '0;
    retire_lq_index_o            = '0;
    retire_sq_index_o            = '0;

    if (count_q != 0) begin
      retire_sequence_o[0]           = entries_q[head_q].sequence_id;
      retire_pc_o[0]                 = entries_q[head_q].pc;
      retire_instruction_o[0]        = entries_q[head_q].instruction;
      retire_instruction_length_o[0] = entries_q[head_q].instruction_length;
      retire_next_pc_o[0] = entries_q[head_q].is_branch ?
        entries_q[head_q].branch_target :
        (entries_q[head_q].pc +
         ((entries_q[head_q].instruction_length == INST_LEN_16) ? 2 : 4));
      retire_writes_destination_o[0] =
        entries_q[head_q].writes_destination;
      retire_destination_class_o[0]  = entries_q[head_q].destination_class;
      retire_destination_arch_o[0]   = entries_q[head_q].destination_arch;
      retire_destination_phys_o[0]   = entries_q[head_q].destination_phys;
      retire_stale_phys_o[0]         = entries_q[head_q].stale_phys;
      retire_is_store_o[0]           = entries_q[head_q].is_store;
      retire_is_load_o[0]            = entries_q[head_q].is_load;
      retire_lq_index_o[0]           = entries_q[head_q].lq_index;
      retire_sq_index_o[0]           = entries_q[head_q].sq_index;
    end
    if (count_q > 1) begin
      retire_sequence_o[1]           = entries_q[head_plus_one].sequence_id;
      retire_pc_o[1]                 = entries_q[head_plus_one].pc;
      retire_instruction_o[1]        = entries_q[head_plus_one].instruction;
      retire_instruction_length_o[1] =
        entries_q[head_plus_one].instruction_length;
      retire_next_pc_o[1] = entries_q[head_plus_one].is_branch ?
        entries_q[head_plus_one].branch_target :
        (entries_q[head_plus_one].pc +
         ((entries_q[head_plus_one].instruction_length == INST_LEN_16) ? 2 : 4));
      retire_writes_destination_o[1] =
        entries_q[head_plus_one].writes_destination;
      retire_destination_class_o[1]  =
        entries_q[head_plus_one].destination_class;
      retire_destination_arch_o[1]   =
        entries_q[head_plus_one].destination_arch;
      retire_destination_phys_o[1]   =
        entries_q[head_plus_one].destination_phys;
      retire_stale_phys_o[1]         = entries_q[head_plus_one].stale_phys;
      retire_is_store_o[1]           = entries_q[head_plus_one].is_store;
      retire_is_load_o[1]            = entries_q[head_plus_one].is_load;
      retire_lq_index_o[1]           = entries_q[head_plus_one].lq_index;
      retire_sq_index_o[1]           = entries_q[head_plus_one].sq_index;
    end

    trap_valid_o    = (count_q != 0) && entries_q[head_q].valid &&
                      entries_q[head_q].complete &&
                      entries_q[head_q].exception_valid;
    trap_sequence_o = (count_q != 0) ? entries_q[head_q].sequence_id : '0;
    trap_pc_o       = (count_q != 0) ? entries_q[head_q].pc : '0;
    trap_cause_o    = (count_q != 0) ? entries_q[head_q].exception_cause :
                                       EXC_ILLEGAL_INSTRUCTION;
    trap_tval_o     = (count_q != 0) ? entries_q[head_q].exception_tval : '0;
    head_valid_o    = (count_q != 0) && entries_q[head_q].valid;
    head_complete_o = head_valid_o && entries_q[head_q].complete;
    head_sequence_o = (count_q != 0) ? entries_q[head_q].sequence_id : '0;
    head_pc_o = (count_q != 0) ? entries_q[head_q].pc : '0;
    head_instruction_o = (count_q != 0) ?
      entries_q[head_q].instruction : '0;
    head_instruction_length_o = (count_q != 0) ?
      entries_q[head_q].instruction_length : '0;
    head_writes_destination_o = (count_q != 0) &&
      entries_q[head_q].writes_destination;
    head_destination_class_o = (count_q != 0) ?
      entries_q[head_q].destination_class : REG_NONE;
    head_destination_phys_o = (count_q != 0) ?
      entries_q[head_q].destination_phys : '0;
    head_source0_phys_o = (count_q != 0) ?
      entries_q[head_q].source0_phys : '0;
  end

  always_comb begin
    flush_boundary_found = 1'b0;
    flush_tail           = tail_q;
    flush_kept_count     = '0;
    for (int unsigned entry = 0; entry < ROB_ENTRIES; entry++) begin
      if (entries_q[entry].valid &&
          !sequence_after(entries_q[entry].sequence_id, flush_sequence_i))
        flush_kept_count = flush_kept_count + 1'b1;
      if (entries_q[entry].valid &&
          (entries_q[entry].sequence_id == flush_sequence_i)) begin
        flush_boundary_found = 1'b1;
        flush_tail = increment_index(ROB_INDEX_WIDTH'(entry), 1);
      end
    end
  end

  always_ff @(posedge clk_i) begin
    if (!rst_ni) begin
      head_q          <= '0;
      tail_q          <= '0;
      count_q         <= '0;
      next_sequence_q <= '0;
      for (int unsigned entry = 0; entry < ROB_ENTRIES; entry++)
        entries_q[entry] <= '0;
    end else if (flush_all_i) begin
      for (int unsigned entry = 0; entry < ROB_ENTRIES; entry++)
        entries_q[entry].valid <= 1'b0;
      head_q  <= tail_q;
      count_q <= '0;
    end else if (flush_younger_i) begin
      if (flush_boundary_found) begin
        for (int unsigned entry = 0; entry < ROB_ENTRIES; entry++) begin
          if (entries_q[entry].valid &&
              sequence_after(entries_q[entry].sequence_id, flush_sequence_i))
            entries_q[entry].valid <= 1'b0;
        end
        tail_q  <= flush_tail;
        count_q <= flush_kept_count;

        // The resolving branch normally completes in the same cycle that it
        // requests a younger flush. Preserve completions at or before the
        // boundary; otherwise the branch result could be consumed by WB while
        // its ROB entry remains permanently incomplete.
        for (int unsigned port = 0; port < COMPLETE_PORTS; port++) begin
          if (complete_valid_i[port] &&
              !sequence_after(complete_sequence_i[port], flush_sequence_i)) begin
            for (int unsigned entry = 0; entry < ROB_ENTRIES; entry++) begin
              if (entries_q[entry].valid &&
                  (entries_q[entry].sequence_id == complete_sequence_i[port])) begin
                entries_q[entry].complete <= 1'b1;
                if (complete_exception_valid_i[port]) begin
                  entries_q[entry].exception_valid <= 1'b1;
                  entries_q[entry].exception_cause <=
                    complete_exception_cause_i[port];
                  entries_q[entry].exception_tval <=
                    complete_exception_tval_i[port];
                end
                if (entries_q[entry].is_branch) begin
                  entries_q[entry].branch_mispredict <=
                    complete_branch_mispredict_i[port];
                  entries_q[entry].branch_target <=
                    complete_branch_target_i[port];
                end
              end
            end
          end
        end
      end else begin
        for (int unsigned entry = 0; entry < ROB_ENTRIES; entry++)
          entries_q[entry].valid <= 1'b0;
        head_q  <= tail_q;
        count_q <= '0;
      end
    end else begin
      for (int unsigned port = 0; port < COMPLETE_PORTS; port++) begin
        if (complete_valid_i[port]) begin
          for (int unsigned entry = 0; entry < ROB_ENTRIES; entry++) begin
            if (entries_q[entry].valid &&
                (entries_q[entry].sequence_id == complete_sequence_i[port])) begin
              entries_q[entry].complete <= 1'b1;
              if (complete_exception_valid_i[port]) begin
                entries_q[entry].exception_valid <= 1'b1;
                entries_q[entry].exception_cause <=
                  complete_exception_cause_i[port];
                entries_q[entry].exception_tval <=
                  complete_exception_tval_i[port];
              end
              if (entries_q[entry].is_branch) begin
                entries_q[entry].branch_mispredict <=
                  complete_branch_mispredict_i[port];
                entries_q[entry].branch_target <=
                  complete_branch_target_i[port];
              end
            end
          end
        end
      end

      if (retire_fire[0])
        entries_q[head_q].valid <= 1'b0;
      if (retire_fire[1])
        entries_q[head_plus_one].valid <= 1'b0;
      if (retire_count != 0)
        head_q <= increment_index(head_q, retire_count);

      if (accepted_alloc_count != 0) begin
        for (int unsigned lane = 0; lane < 2; lane++) begin
          if (alloc_valid_i[lane]) begin
            entries_q[alloc_index_o[lane]].valid <= 1'b1;
            entries_q[alloc_index_o[lane]].complete <=
              alloc_complete_i[lane] || alloc_exception_valid_i[lane];
            entries_q[alloc_index_o[lane]].sequence_id <=
              alloc_sequence_o[lane];
            entries_q[alloc_index_o[lane]].pc <= alloc_pc_i[lane];
            entries_q[alloc_index_o[lane]].instruction <=
              alloc_instruction_i[lane];
            entries_q[alloc_index_o[lane]].instruction_length <=
              alloc_instruction_length_i[lane];
            entries_q[alloc_index_o[lane]].writes_destination <=
              alloc_writes_destination_i[lane];
            entries_q[alloc_index_o[lane]].destination_class <=
              alloc_destination_class_i[lane];
            entries_q[alloc_index_o[lane]].destination_arch <=
              alloc_destination_arch_i[lane];
            entries_q[alloc_index_o[lane]].destination_phys <=
              alloc_destination_phys_i[lane];
            entries_q[alloc_index_o[lane]].stale_phys <=
              alloc_stale_phys_i[lane];
            entries_q[alloc_index_o[lane]].source0_phys <=
              alloc_source0_phys_i[lane];
            entries_q[alloc_index_o[lane]].is_store <=
              alloc_is_store_i[lane];
            entries_q[alloc_index_o[lane]].is_load <=
              alloc_is_load_i[lane];
            entries_q[alloc_index_o[lane]].lq_index <=
              alloc_lq_index_i[lane];
            entries_q[alloc_index_o[lane]].sq_index <= alloc_sq_index_i[lane];
            entries_q[alloc_index_o[lane]].is_branch <=
              alloc_is_branch_i[lane];
            entries_q[alloc_index_o[lane]].serializing <=
              alloc_serializing_i[lane];
            entries_q[alloc_index_o[lane]].exception_valid <=
              alloc_exception_valid_i[lane];
            entries_q[alloc_index_o[lane]].exception_cause <=
              alloc_exception_cause_i[lane];
            entries_q[alloc_index_o[lane]].exception_tval <=
              alloc_exception_tval_i[lane];
            entries_q[alloc_index_o[lane]].branch_mispredict <= 1'b0;
            entries_q[alloc_index_o[lane]].branch_target <= '0;
          end
        end
        tail_q <= increment_index(tail_q, accepted_alloc_count);
        next_sequence_q <= next_sequence_q +
                           SEQ_WIDTH'(accepted_alloc_count);
      end

      count_q <= count_q + ROB_COUNT_WIDTH'(accepted_alloc_count) -
                 ROB_COUNT_WIDTH'(retire_count);
    end
  end

  assign count_o = count_q;
  assign empty_o = (count_q == 0);
  assign full_o  = (count_q == ROB_ENTRIES);

`ifndef SYNTHESIS
  property p_lane1_allocation_requires_lane0;
    @(posedge clk_i) disable iff (!rst_ni)
      alloc_valid_i[1] |-> alloc_valid_i[0];
  endproperty
  assert property (p_lane1_allocation_requires_lane0);

  property p_lane1_retire_requires_lane0;
    @(posedge clk_i) disable iff (!rst_ni)
      retire_valid_o[1] |-> retire_valid_o[0];
  endproperty
  assert property (p_lane1_retire_requires_lane0);

  property p_lane1_fire_requires_lane0_fire;
    @(posedge clk_i) disable iff (!rst_ni)
      retire_fire[1] |-> retire_fire[0];
  endproperty
  assert property (p_lane1_fire_requires_lane0_fire);

  property p_count_in_range;
    @(posedge clk_i) disable iff (!rst_ni)
      count_q <= ROB_ENTRIES;
  endproperty
  assert property (p_count_in_range);

  property p_flush_boundary_must_exist;
    @(posedge clk_i) disable iff (!rst_ni)
      flush_younger_i |-> flush_boundary_found;
  endproperty
  assert property (p_flush_boundary_must_exist);

  property p_trap_accept_requires_flush;
    @(posedge clk_i) disable iff (!rst_ni)
      trap_valid_o && trap_ready_i |-> flush_all_i;
  endproperty
  assert property (p_trap_accept_requires_flush);
`endif

  initial begin : p_parameter_checks
    if ((XLEN != 32) && (XLEN != 64))
      $fatal(1, "ROB XLEN must be 32 or 64");
    if (ROB_ENTRIES < 4)
      $fatal(1, "ROB must contain at least four entries");
    if (ROB_ENTRIES >= (1 << (SEQ_WIDTH-1)))
      $fatal(1, "ROB entries must be less than half the sequence space");
    if ((COMPLETE_PORTS == 0) || (LIVE_QUERY_PORTS == 0))
      $fatal(1, "ROB requires at least one completion port");
  end

endmodule
