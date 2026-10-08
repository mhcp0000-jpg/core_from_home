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
  input  logic [COMPLETE_PORTS-1:0][4:0]        complete_fflags_i,
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
  output logic [1:0][4:0]                       retire_fflags_o,

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
    logic [4:0]                   fflags;
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
  localparam int unsigned HEAD_READ_LEAVES = 1 << $clog2(ROB_ENTRIES);
  localparam int unsigned ENTRY_BITS = $bits(rob_entry_t);
  rob_entry_t head_read [0:1];
  for (genvar port = 0; port < 2; port++) begin : g_head_read
    wire [ROB_INDEX_WIDTH-1:0] index = port == 0 ? head_q : head_plus_one;
    wire [ENTRY_BITS-1:0] tree [0:2*HEAD_READ_LEAVES-1];
    assign tree[0] = '0;
    for (genvar row = 0; row < HEAD_READ_LEAVES; row++) begin : g_leaf
      if (row < ROB_ENTRIES) begin : g_present
        wire hit = index == ROB_INDEX_WIDTH'(row);
        assign tree[HEAD_READ_LEAVES+row] = entries_q[row] & {ENTRY_BITS{hit}};
      end else begin : g_pad
        assign tree[HEAD_READ_LEAVES+row] = '0;
      end
    end
    for (genvar node = 1; node < HEAD_READ_LEAVES; node++) begin : g_merge
      assign tree[node] = tree[2*node] | tree[2*node+1];
    end
    assign head_read[port] = ($unsigned(index) < ROB_ENTRIES) ? tree[1] : 'x;
  end

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

  assign head_plus_one = increment_index(head_q, 1);
  always_comb begin
    retire_valid_o = '0;
    if ((count_q != 0) && head_read[0].valid &&
        head_read[0].complete &&
        !head_read[0].exception_valid)
      retire_valid_o[0] = 1'b1;

    if ((count_q > 1) && retire_valid_o[0] &&
        !head_read[0].serializing &&
        head_read[1].valid &&
        head_read[1].complete &&
        !head_read[1].exception_valid &&
        !head_read[1].serializing)
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

  // Preserve the resident-generation CAM semantics, including pre-edge flush
  // visibility.  A forward "if (hit) live=1" scan becomes a serial OR chain
  // before mapping.  Explicit padding/reduction bounds this part of the late
  // memory-response -> WB-live -> arbiter-ready path to ceil(log2(entries)).
  localparam int unsigned LIVE_LEAVES = 1 << $clog2(ROB_ENTRIES);
  for (genvar query = 0; query < LIVE_QUERY_PORTS; query++) begin : g_live_query
    logic [2*LIVE_LEAVES-1:1] hit_tree;
    for (genvar leaf = 0; leaf < LIVE_LEAVES; leaf++) begin : g_leaf
      if (leaf < ROB_ENTRIES)
        assign hit_tree[LIVE_LEAVES+leaf] = entries_q[leaf].valid &&
          (entries_q[leaf].sequence_id == live_query_sequence_i[query]);
      else
        assign hit_tree[LIVE_LEAVES+leaf] = 1'b0;
    end
    for (genvar node = 1; node < LIVE_LEAVES; node++) begin : g_reduce
      assign hit_tree[node] = hit_tree[2*node] | hit_tree[2*node+1];
    end
    assign live_query_valid_o[query] = hit_tree[1];
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
    retire_fflags_o              = '0;

    if (count_q != 0) begin
      retire_sequence_o[0]           = head_read[0].sequence_id;
      retire_pc_o[0]                 = head_read[0].pc;
      retire_instruction_o[0]        = head_read[0].instruction;
      retire_instruction_length_o[0] = head_read[0].instruction_length;
      retire_next_pc_o[0] = head_read[0].is_branch ?
        head_read[0].branch_target :
        (head_read[0].pc +
         ((head_read[0].instruction_length == INST_LEN_16) ? 2 : 4));
      retire_writes_destination_o[0] =
        head_read[0].writes_destination;
      retire_destination_class_o[0]  = head_read[0].destination_class;
      retire_destination_arch_o[0]   = head_read[0].destination_arch;
      retire_destination_phys_o[0]   = head_read[0].destination_phys;
      retire_stale_phys_o[0]         = head_read[0].stale_phys;
      retire_is_store_o[0]           = head_read[0].is_store;
      retire_is_load_o[0]            = head_read[0].is_load;
      retire_lq_index_o[0]           = head_read[0].lq_index;
      retire_sq_index_o[0]           = head_read[0].sq_index;
      retire_fflags_o[0]             = head_read[0].fflags;
    end
    if (count_q > 1) begin
      retire_sequence_o[1]           = head_read[1].sequence_id;
      retire_pc_o[1]                 = head_read[1].pc;
      retire_instruction_o[1]        = head_read[1].instruction;
      retire_instruction_length_o[1] =
        head_read[1].instruction_length;
      retire_next_pc_o[1] = head_read[1].is_branch ?
        head_read[1].branch_target :
        (head_read[1].pc +
         ((head_read[1].instruction_length == INST_LEN_16) ? 2 : 4));
      retire_writes_destination_o[1] =
        head_read[1].writes_destination;
      retire_destination_class_o[1]  =
        head_read[1].destination_class;
      retire_destination_arch_o[1]   =
        head_read[1].destination_arch;
      retire_destination_phys_o[1]   =
        head_read[1].destination_phys;
      retire_stale_phys_o[1]         = head_read[1].stale_phys;
      retire_is_store_o[1]           = head_read[1].is_store;
      retire_is_load_o[1]            = head_read[1].is_load;
      retire_lq_index_o[1]           = head_read[1].lq_index;
      retire_sq_index_o[1]           = head_read[1].sq_index;
      retire_fflags_o[1]             = head_read[1].fflags;
    end

    trap_valid_o    = (count_q != 0) && head_read[0].valid &&
                      head_read[0].complete &&
                      head_read[0].exception_valid;
    trap_sequence_o = (count_q != 0) ? head_read[0].sequence_id : '0;
    trap_pc_o       = (count_q != 0) ? head_read[0].pc : '0;
    trap_cause_o    = (count_q != 0) ? head_read[0].exception_cause :
                                       EXC_ILLEGAL_INSTRUCTION;
    trap_tval_o     = (count_q != 0) ? head_read[0].exception_tval : '0;
    head_valid_o    = (count_q != 0) && head_read[0].valid;
    head_complete_o = head_valid_o && head_read[0].complete;
    head_sequence_o = (count_q != 0) ? head_read[0].sequence_id : '0;
    head_pc_o = (count_q != 0) ? head_read[0].pc : '0;
    head_instruction_o = (count_q != 0) ?
      head_read[0].instruction : '0;
    head_instruction_length_o = (count_q != 0) ?
      head_read[0].instruction_length : '0;
    head_writes_destination_o = (count_q != 0) &&
      head_read[0].writes_destination;
    head_destination_class_o = (count_q != 0) ?
      head_read[0].destination_class : REG_NONE;
    head_destination_phys_o = (count_q != 0) ?
      head_read[0].destination_phys : '0;
    head_source0_phys_o = (count_q != 0) ?
      head_read[0].source0_phys : '0;
  end

  localparam int unsigned KEEP_LEVELS = $clog2(ROB_ENTRIES);
  localparam int unsigned KEEP_LEAVES = 1 << KEEP_LEVELS;
  logic [ROB_COUNT_WIDTH-1:0] keep_tree [0:KEEP_LEVELS][0:KEEP_LEAVES-1];

  always_comb begin
    flush_boundary_found = 1'b0;
    flush_tail           = tail_q;
    // PROTOTYPE: balanced popcount tree.  The previous sequential increment
    // over ROB_ENTRIES synthesized as a 48-deep carry chain.
    for (int unsigned level = 0; level <= KEEP_LEVELS; level++)
      for (int unsigned node = 0; node < KEEP_LEAVES; node++)
        keep_tree[level][node] = '0;
    for (int unsigned leaf = 0; leaf < KEEP_LEAVES; leaf++)
      keep_tree[0][leaf] =
        ((leaf < ROB_ENTRIES) && entries_q[leaf].valid &&
         !sequence_after(entries_q[leaf].sequence_id, flush_sequence_i)) ?
          ROB_COUNT_WIDTH'(1) : ROB_COUNT_WIDTH'(0);
    for (int unsigned level = 1; level <= KEEP_LEVELS; level++)
      for (int unsigned node = 0; node < KEEP_LEAVES; node++)
        if (node < (KEEP_LEAVES >> level))
          keep_tree[level][node] = keep_tree[level-1][2*node] +
                                   keep_tree[level-1][2*node+1];
    flush_kept_count = keep_tree[KEEP_LEVELS][0];
    for (int unsigned entry = 0; entry < ROB_ENTRIES; entry++) begin
      if (entries_q[entry].valid &&
          (entries_q[entry].sequence_id == flush_sequence_i)) begin
        flush_boundary_found = 1'b1;
        flush_tail = increment_index(ROB_INDEX_WIDTH'(entry), 1);
      end
    end
  end

  // Cursor control and entry storage are separate. Each entry has a constant
  // write address: a late WB completion must not traverse the array-wide
  // variable-index partial-write network generated for allocation/retirement.
  // Priority is unchanged: reset > global flush > selective flush >
  // completion (highest port last) > retire > allocation (highest lane last).
  always_ff @(posedge clk_i) begin
    if (!rst_ni) begin
      head_q <= '0;
      tail_q <= '0;
      count_q <= '0;
      next_sequence_q <= '0;
    end else if (flush_all_i) begin
      head_q <= tail_q;
      count_q <= '0;
    end else if (flush_younger_i) begin
      if (flush_boundary_found) begin
        tail_q <= flush_tail;
        count_q <= flush_kept_count;
      end else begin
        head_q <= tail_q;
        count_q <= '0;
      end
    end else begin
      if (retire_count != 0)
        head_q <= increment_index(head_q, retire_count);
      if (accepted_alloc_count != 0) begin
        tail_q <= increment_index(tail_q, accepted_alloc_count);
        next_sequence_q <= next_sequence_q + SEQ_WIDTH'(accepted_alloc_count);
      end
      count_q <= count_q + ROB_COUNT_WIDTH'(accepted_alloc_count) -
                 ROB_COUNT_WIDTH'(retire_count);
    end
  end

  for (genvar entry = 0; entry < ROB_ENTRIES; entry++) begin : g_entry_storage
    localparam int unsigned COMPLETE_LEAVES = 1 << $clog2(COMPLETE_PORTS);
    localparam int unsigned COMPLETE_BITS = XLEN + 6;
    localparam int unsigned EXCEPTION_BITS = XLEN + $bits(exception_code_e);
    wire [COMPLETE_PORTS-1:0] complete_hit;
    wire [COMPLETE_PORTS-1:0] exception_hit;
    wire [COMPLETE_BITS-1:0] complete_tree [0:2*COMPLETE_LEAVES-1];
    wire [EXCEPTION_BITS-1:0] exception_tree [0:2*COMPLETE_LEAVES-1];
    assign complete_tree[0] = '0;
    assign exception_tree[0] = '0;
    for (genvar port = 0; port < COMPLETE_PORTS; port++) begin : g_complete_hit
      assign complete_hit[port] = complete_valid_i[port] &&
        entries_q[entry].valid &&
        (entries_q[entry].sequence_id == complete_sequence_i[port]) &&
        (!flush_younger_i ||
         !sequence_after(complete_sequence_i[port], flush_sequence_i));
      assign exception_hit[port] = complete_hit[port] && complete_exception_valid_i[port];
    end
    // Preserve highest-port priority even for duplicate generations. Exception
    // payload has its OWN winner: a later non-exception completion updates
    // fflags/branch but does not erase an earlier exception's cause/tval.
    for (genvar leaf = 0; leaf < COMPLETE_LEAVES; leaf++) begin : g_complete_leaf
      if (leaf < COMPLETE_PORTS) begin : g_present
        wire complete_wins, exception_wins;
        if (leaf == COMPLETE_PORTS-1) begin : g_last
          assign complete_wins = complete_hit[leaf];
          assign exception_wins = exception_hit[leaf];
        end else begin : g_prioritized
          assign complete_wins = complete_hit[leaf] && !(|complete_hit[COMPLETE_PORTS-1:leaf+1]);
          assign exception_wins = exception_hit[leaf] && !(|exception_hit[COMPLETE_PORTS-1:leaf+1]);
        end
        assign complete_tree[COMPLETE_LEAVES+leaf] =
          {complete_fflags_i[leaf], complete_branch_mispredict_i[leaf], complete_branch_target_i[leaf]} &
          {COMPLETE_BITS{complete_wins}};
        assign exception_tree[COMPLETE_LEAVES+leaf] =
          {complete_exception_cause_i[leaf], complete_exception_tval_i[leaf]} &
          {EXCEPTION_BITS{exception_wins}};
      end else begin : g_pad
        assign complete_tree[COMPLETE_LEAVES+leaf] = '0;
        assign exception_tree[COMPLETE_LEAVES+leaf] = '0;
      end
    end
    for (genvar node = 1; node < COMPLETE_LEAVES; node++) begin : g_complete_merge
      assign complete_tree[node] = complete_tree[2*node] | complete_tree[2*node+1];
      assign exception_tree[node] = exception_tree[2*node] | exception_tree[2*node+1];
    end
    always_ff @(posedge clk_i) begin
      if (!rst_ni) begin
        entries_q[entry] <= '0;
      end else if (flush_all_i ||
                   (flush_younger_i && !flush_boundary_found)) begin
        entries_q[entry].valid <= 1'b0;
      end else begin
        if (flush_younger_i && entries_q[entry].valid &&
            sequence_after(entries_q[entry].sequence_id, flush_sequence_i))
          entries_q[entry].valid <= 1'b0;

        // Selective flush preserves same-edge older/boundary completions.
        // Match uses pre-edge generation state, including slot reuse.
        if (|complete_hit) begin
          entries_q[entry].complete <= 1'b1;
          entries_q[entry].fflags <= complete_tree[1][COMPLETE_BITS-1 -: 5];
          if (entries_q[entry].is_branch) begin
            entries_q[entry].branch_mispredict <= complete_tree[1][XLEN];
            entries_q[entry].branch_target <= complete_tree[1][XLEN-1:0];
          end
        end
        if (|exception_hit) begin
          entries_q[entry].exception_valid <= 1'b1;
          entries_q[entry].exception_cause <= exception_code_e'(exception_tree[1][EXCEPTION_BITS-1:XLEN]);
          entries_q[entry].exception_tval <= exception_tree[1][XLEN-1:0];
        end

        if (!flush_younger_i) begin
          if ((retire_fire[0] && (head_q == ROB_INDEX_WIDTH'(entry))) ||
              (retire_fire[1] && (head_plus_one == ROB_INDEX_WIDTH'(entry))))
            entries_q[entry].valid <= 1'b0;

          for (int unsigned lane = 0; lane < 2; lane++) begin
            if ((accepted_alloc_count != 0) && alloc_valid_i[lane] &&
                (alloc_index_o[lane] == ROB_INDEX_WIDTH'(entry))) begin
            entries_q[entry].valid <= 1'b1;
            entries_q[entry].complete <=
              alloc_complete_i[lane] || alloc_exception_valid_i[lane];
            entries_q[entry].sequence_id <=
              alloc_sequence_o[lane];
            entries_q[entry].pc <= alloc_pc_i[lane];
            entries_q[entry].instruction <=
              alloc_instruction_i[lane];
            entries_q[entry].instruction_length <=
              alloc_instruction_length_i[lane];
            entries_q[entry].writes_destination <=
              alloc_writes_destination_i[lane];
            entries_q[entry].destination_class <=
              alloc_destination_class_i[lane];
            entries_q[entry].destination_arch <=
              alloc_destination_arch_i[lane];
            entries_q[entry].destination_phys <=
              alloc_destination_phys_i[lane];
            entries_q[entry].stale_phys <=
              alloc_stale_phys_i[lane];
            entries_q[entry].source0_phys <=
              alloc_source0_phys_i[lane];
            entries_q[entry].is_store <=
              alloc_is_store_i[lane];
            entries_q[entry].is_load <=
              alloc_is_load_i[lane];
            entries_q[entry].lq_index <=
              alloc_lq_index_i[lane];
            entries_q[entry].sq_index <= alloc_sq_index_i[lane];
            entries_q[entry].is_branch <=
              alloc_is_branch_i[lane];
            entries_q[entry].serializing <=
              alloc_serializing_i[lane];
            entries_q[entry].exception_valid <=
              alloc_exception_valid_i[lane];
            entries_q[entry].exception_cause <=
              alloc_exception_cause_i[lane];
            entries_q[entry].exception_tval <=
              alloc_exception_tval_i[lane];
            entries_q[entry].fflags <= '0;
            entries_q[entry].branch_mispredict <= 1'b0;
            entries_q[entry].branch_target <= '0;
            end
          end
        end
      end
    end
  end

  assign count_o = count_q;
  assign empty_o = (count_q == 0);
  assign full_o  = (count_q == ROB_ENTRIES);

`ifndef SYNTHESIS
  // Independent linear CAM oracle. This deliberately keeps the old algorithm
  // in assertions only, checking the tree across reset, sequence wrap, retire,
  // allocation and recovery without changing synthesized state or latency.
  function automatic logic live_cam_reference(input logic [SEQ_WIDTH-1:0] sequence_id);
    logic resident;
    resident = 1'b0;
    for (int entry = 0; entry < ROB_ENTRIES; entry++)
      resident |= entries_q[entry].valid &&
                  (entries_q[entry].sequence_id == sequence_id);
    return resident;
  endfunction
  for (genvar query = 0; query < LIVE_QUERY_PORTS; query++) begin : g_live_oracle
    assert property (@(posedge clk_i) disable iff (!rst_ni)
      live_query_valid_o[query] == live_cam_reference(live_query_sequence_i[query]));
  end
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
