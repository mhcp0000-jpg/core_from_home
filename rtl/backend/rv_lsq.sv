module rv_lsq #(
  parameter int unsigned PADDR_WIDTH    = 32,
  parameter int unsigned DATA_WIDTH     = 64,
  parameter int unsigned LQ_ENTRIES     = 24,
  parameter int unsigned SQ_ENTRIES     = 16,
  parameter int unsigned SEQ_WIDTH      = rv_ooo_pkg::ROB_SEQ_WIDTH,
  parameter int unsigned PHYS_TAG_WIDTH = 7,
  localparam int unsigned DATA_BYTES    = DATA_WIDTH / 8,
  localparam int unsigned BYTE_OFFSET_WIDTH = $clog2(DATA_BYTES),
  localparam int unsigned LQ_INDEX_WIDTH = $clog2(LQ_ENTRIES),
  localparam int unsigned SQ_INDEX_WIDTH = $clog2(SQ_ENTRIES),
  localparam int unsigned LQ_COUNT_WIDTH = $clog2(LQ_ENTRIES + 1),
  localparam int unsigned SQ_COUNT_WIDTH = $clog2(SQ_ENTRIES + 1),
  localparam int unsigned LQ_RANK_WIDTH  = $clog2(LQ_ENTRIES + 1)
) (
  input  logic                                  clk_i,
  input  logic                                  rst_ni,

  input  logic [1:0]                            dispatch_valid_i,
  input  logic                                  dispatch_accept_i,
  output logic                                  dispatch_ready_o,
  input  logic [1:0]                            dispatch_is_load_i,
  input  logic [1:0]                            dispatch_is_store_i,
  input  logic [1:0][SEQ_WIDTH-1:0]             dispatch_sequence_i,
  input  logic [1:0]                            dispatch_destination_valid_i,
  input  logic [1:0][PHYS_TAG_WIDTH-1:0]        dispatch_destination_phys_i,
  input  logic [1:0][2:0]                       dispatch_size_i,
  input  logic [1:0]                            dispatch_unsigned_i,
  input  logic [1:0]                            dispatch_device_i,
  output logic [1:0]                            dispatch_lq_valid_o,
  output logic [1:0][LQ_INDEX_WIDTH-1:0]        dispatch_lq_index_o,
  output logic [1:0]                            dispatch_sq_valid_o,
  output logic [1:0][SQ_INDEX_WIDTH-1:0]        dispatch_sq_index_o,

  input  logic [1:0]                            agu_valid_i,
  output logic [1:0]                            agu_ready_o,
  input  logic [1:0][SEQ_WIDTH-1:0]             agu_sequence_i,
  input  logic [1:0]                            agu_lq_valid_i,
  input  logic [1:0][LQ_INDEX_WIDTH-1:0]        agu_lq_index_i,
  input  logic [1:0]                            agu_sq_valid_i,
  input  logic [1:0][SQ_INDEX_WIDTH-1:0]        agu_sq_index_i,
  input  logic [1:0][PADDR_WIDTH-1:0]           agu_address_i,
  input  logic [1:0][DATA_BYTES-1:0]            agu_mask_i,
  input  logic [1:0][DATA_WIDTH-1:0]            agu_store_data_i,
  input  logic [1:0]                            agu_address_valid_i,
  input  logic [1:0]                            agu_store_data_valid_i,
  input  logic [1:0]                            agu_device_i,
  input  logic [1:0]                            agu_exception_valid_i,
  input  rv_ooo_pkg::exception_code_e [1:0]     agu_exception_cause_i,

  output logic [1:0]                            load_candidate_present_o,
  output logic [1:0]                            load_candidate_valid_o,
  input  logic [1:0]                            load_candidate_ready_i,
  output logic [1:0][LQ_INDEX_WIDTH-1:0]        load_candidate_index_o,
  output logic [1:0][SEQ_WIDTH-1:0]             load_candidate_sequence_o,
  output logic [1:0][PADDR_WIDTH-1:0]           load_candidate_address_o,
  output logic [1:0][DATA_BYTES-1:0]            load_candidate_mask_o,
  output logic [1:0][2:0]                       load_candidate_size_o,
  output logic [1:0]                            load_candidate_unsigned_o,
  output logic [1:0]                            load_candidate_device_o,
  output logic [1:0]                            load_destination_valid_o,
  output logic [1:0][PHYS_TAG_WIDTH-1:0]        load_destination_phys_o,
  output logic [1:0]                            load_memory_read_o,
  output logic [1:0]                            load_forward_valid_o,
  output logic [1:0][DATA_WIDTH-1:0]            load_forward_data_o,
  output rv_ooo_pkg::lsq_stall_reason_e [1:0]   load_stall_reason_o,
  input  logic [1:0]                            device_load_permit_i,

  output logic [1:0]                            sb_query_valid_o,
  output logic [1:0][PADDR_WIDTH-1:0]           sb_query_address_o,
  output logic [1:0][DATA_BYTES-1:0]            sb_query_mask_o,
  input  logic [1:0]                            sb_query_full_cover_i,
  input  logic [1:0]                            sb_query_partial_i,
  input  logic [1:0][DATA_WIDTH-1:0]            sb_query_data_i,

  input  logic [1:0]                            load_response_valid_i,
  input  logic [1:0][LQ_INDEX_WIDTH-1:0]        load_response_index_i,
  input  logic [1:0]                            load_response_replay_i,

  input  logic [1:0]                            load_commit_valid_i,
  output logic [1:0]                            load_commit_ready_o,
  input  logic [1:0][SEQ_WIDTH-1:0]             load_commit_sequence_i,
  input  logic [1:0][LQ_INDEX_WIDTH-1:0]        load_commit_index_i,

  input  logic [1:0]                            store_commit_valid_i,
  output logic [1:0]                            store_commit_ready_o,
  output logic [1:0]                            store_commit_error_o,
  input  logic [1:0][SEQ_WIDTH-1:0]             store_commit_sequence_i,
  input  logic [1:0][SQ_INDEX_WIDTH-1:0]        store_commit_index_i,
  output logic [1:0]                            sb_enq_valid_o,
  input  logic [1:0]                            sb_enq_ready_i,
  output logic [1:0][SEQ_WIDTH-1:0]             sb_enq_sequence_o,
  output logic [1:0][PADDR_WIDTH-1:0]           sb_enq_address_o,
  output logic [1:0][DATA_WIDTH-1:0]            sb_enq_data_o,
  output logic [1:0][DATA_BYTES-1:0]            sb_enq_mask_o,
  output logic [1:0][2:0]                       sb_enq_size_o,
  output logic [1:0]                            sb_enq_device_o,

  output logic [1:0]                            direct_store_valid_o,
  input  logic [1:0]                            direct_store_complete_i,
  input  logic [1:0]                            direct_store_error_i,
  output logic [1:0][SEQ_WIDTH-1:0]             direct_store_sequence_o,
  output logic [1:0][PADDR_WIDTH-1:0]           direct_store_address_o,
  output logic [1:0][DATA_WIDTH-1:0]            direct_store_data_o,
  output logic [1:0][DATA_BYTES-1:0]            direct_store_mask_o,
  output logic [1:0][2:0]                       direct_store_size_o,

  input  logic                                  flush_valid_i,
  input  logic                                  flush_all_i,
  input  logic [SEQ_WIDTH-1:0]                  flush_sequence_i,

  output logic [LQ_COUNT_WIDTH-1:0]             lq_count_o,
  output logic [SQ_COUNT_WIDTH-1:0]             sq_count_o,
  output logic                                  load_outstanding_o
);

  import rv_ooo_pkg::*;

  logic [LQ_ENTRIES-1:0] lq_valid_q;
  logic [LQ_ENTRIES-1:0] lq_killed_q;
  logic [LQ_ENTRIES-1:0] lq_address_valid_q;
  logic [LQ_ENTRIES-1:0] lq_issued_q;
  logic [LQ_ENTRIES-1:0] lq_completed_q;
  logic [LQ_ENTRIES-1:0] lq_exception_q;
  logic [LQ_ENTRIES-1:0] lq_destination_valid_q;
  logic [LQ_ENTRIES-1:0] lq_unsigned_q;
  logic [LQ_ENTRIES-1:0] lq_device_q;
  logic [SEQ_WIDTH-1:0] lq_sequence_q [0:LQ_ENTRIES-1];
  logic [PHYS_TAG_WIDTH-1:0] lq_destination_phys_q [0:LQ_ENTRIES-1];
  logic [2:0] lq_size_q [0:LQ_ENTRIES-1];
  logic [PADDR_WIDTH-1:0] lq_address_q [0:LQ_ENTRIES-1];
  logic [DATA_BYTES-1:0] lq_mask_q [0:LQ_ENTRIES-1];
  exception_code_e lq_exception_cause_q [0:LQ_ENTRIES-1];

  logic [SQ_ENTRIES-1:0] sq_valid_q;
  logic [SQ_ENTRIES-1:0] sq_address_valid_q;
  logic [SQ_ENTRIES-1:0] sq_data_valid_q;
  logic [SQ_ENTRIES-1:0] sq_exception_q;
  logic [SQ_ENTRIES-1:0] sq_device_q;
  logic [SEQ_WIDTH-1:0] sq_sequence_q [0:SQ_ENTRIES-1];
  logic [PADDR_WIDTH-1:0] sq_address_q [0:SQ_ENTRIES-1];
  logic [DATA_WIDTH-1:0] sq_data_q [0:SQ_ENTRIES-1];
  logic [DATA_BYTES-1:0] sq_mask_q [0:SQ_ENTRIES-1];
  logic [2:0] sq_size_q [0:SQ_ENTRIES-1];
  exception_code_e sq_exception_cause_q [0:SQ_ENTRIES-1];

  logic [LQ_ENTRIES-1:0] lq_free_work;
  logic [SQ_ENTRIES-1:0] sq_free_work;
  logic [1:0] requested_lq_count;
  logic [1:0] requested_sq_count;
  logic [1:0] candidate_found;
  logic [1:0][LQ_INDEX_WIDTH-1:0] candidate_index;
  logic [1:0][SEQ_WIDTH-1:0] candidate_sequence;
  logic [1:0] selected_candidate_found;
  logic [1:0][LQ_INDEX_WIDTH-1:0] selected_candidate_index;
  logic [1:0][SEQ_WIDTH-1:0] selected_candidate_sequence;
  logic [1:0] candidate_replace;
  logic [1:0] candidate_blocked_q;
  logic [1:0] candidate_order_valid;
  logic [1:0] candidate_forward_valid;

  localparam int unsigned LQ_SELECT_TREE_LEVELS = $clog2(LQ_ENTRIES);
  localparam int unsigned LQ_SELECT_TREE_LEAVES =
    1 << LQ_SELECT_TREE_LEVELS;
  localparam int unsigned SQ_FORWARD_TREE_LEVELS = $clog2(SQ_ENTRIES);
  localparam int unsigned SQ_FORWARD_TREE_LEAVES =
    1 << SQ_FORWARD_TREE_LEVELS;

  // Keep the tree as parallel scalar arrays.  Besides mapping cleanly to
  // comparators/muxes, this remains compatible with Icarus, which cannot
  // elaborate variable indexing through a multi-dimensional struct array.
  logic lq_select_valid [0:LQ_SELECT_TREE_LEVELS]
                         [0:LQ_SELECT_TREE_LEAVES-1][0:1];
  logic [SEQ_WIDTH-1:0] lq_select_sequence [0:LQ_SELECT_TREE_LEVELS]
                         [0:LQ_SELECT_TREE_LEAVES-1][0:1];
  logic [LQ_INDEX_WIDTH-1:0] lq_select_index [0:LQ_SELECT_TREE_LEVELS]
                         [0:LQ_SELECT_TREE_LEAVES-1][0:1];

  function automatic logic [LQ_INDEX_WIDTH-1:0] first_free_lq(
    input logic [LQ_ENTRIES-1:0] free_bitmap
  );
    logic found;
    logic [LQ_INDEX_WIDTH-1:0] selected;
    found = 1'b0;
    selected = '0;
    for (int unsigned entry = 0; entry < LQ_ENTRIES; entry++) begin
      if (free_bitmap[entry] && !found) begin
        found = 1'b1;
        selected = LQ_INDEX_WIDTH'(entry);
      end
    end
    return selected;
  endfunction

  function automatic logic [SQ_INDEX_WIDTH-1:0] first_free_sq(
    input logic [SQ_ENTRIES-1:0] free_bitmap
  );
    logic found;
    logic [SQ_INDEX_WIDTH-1:0] selected;
    found = 1'b0;
    selected = '0;
    for (int unsigned entry = 0; entry < SQ_ENTRIES; entry++) begin
      if (free_bitmap[entry] && !found) begin
        found = 1'b1;
        selected = SQ_INDEX_WIDTH'(entry);
      end
    end
    return selected;
  endfunction

  function automatic logic sequence_after(
    input logic [SEQ_WIDTH-1:0] lhs,
    input logic [SEQ_WIDTH-1:0] rhs
  );
    logic signed [SEQ_WIDTH-1:0] distance;
    distance = $signed(lhs - rhs);
    return distance > 0;
  endfunction

  function automatic logic lq_select_before(
    input logic lhs_valid,
    input logic [SEQ_WIDTH-1:0] lhs_sequence,
    input logic [LQ_INDEX_WIDTH-1:0] lhs_index,
    input logic rhs_valid,
    input logic [SEQ_WIDTH-1:0] rhs_sequence,
    input logic [LQ_INDEX_WIDTH-1:0] rhs_index
  );
    if (!lhs_valid)
      return 1'b0;
    if (!rhs_valid)
      return 1'b1;
    if (lhs_sequence == rhs_sequence)
      return lhs_index < rhs_index;
    return sequence_after(rhs_sequence, lhs_sequence);
  endfunction

  always_comb begin
    requested_lq_count = '0;
    requested_sq_count = '0;
    for (int unsigned lane = 0; lane < 2; lane++) begin
      if (dispatch_valid_i[lane] && dispatch_is_load_i[lane])
        requested_lq_count = requested_lq_count + 1'b1;
      if (dispatch_valid_i[lane] && dispatch_is_store_i[lane])
        requested_sq_count = requested_sq_count + 1'b1;
    end

    dispatch_ready_o =
      ($unsigned($countones(~lq_valid_q)) >=
       $unsigned(requested_lq_count)) &&
      ($unsigned($countones(~sq_valid_q)) >=
       $unsigned(requested_sq_count)) &&
      !flush_valid_i;
  end

  always_comb begin
    lq_free_work = ~lq_valid_q;
    sq_free_work = ~sq_valid_q;
    dispatch_lq_valid_o = '0;
    dispatch_lq_index_o = '0;
    dispatch_sq_valid_o = '0;
    dispatch_sq_index_o = '0;
    for (int unsigned lane = 0; lane < 2; lane++) begin
      if (dispatch_accept_i && dispatch_ready_o && dispatch_valid_i[lane] &&
          dispatch_is_load_i[lane]) begin
        dispatch_lq_valid_o[lane] = 1'b1;
        dispatch_lq_index_o[lane] = first_free_lq(lq_free_work);
        lq_free_work[dispatch_lq_index_o[lane]] = 1'b0;
      end
      if (dispatch_accept_i && dispatch_ready_o && dispatch_valid_i[lane] &&
          dispatch_is_store_i[lane]) begin
        dispatch_sq_valid_o[lane] = 1'b1;
        dispatch_sq_index_o[lane] = first_free_sq(sq_free_work);
        sq_free_work[dispatch_sq_index_o[lane]] = 1'b0;
      end
    end
  end

  always_comb begin
    agu_ready_o = '0;
    for (int unsigned lane = 0; lane < 2; lane++) begin
      agu_ready_o[lane] =
        (!agu_lq_valid_i[lane] ||
         ((agu_lq_index_i[lane] < LQ_ENTRIES) &&
          lq_valid_q[agu_lq_index_i[lane]] &&
          (lq_sequence_q[agu_lq_index_i[lane]] ==
           agu_sequence_i[lane]))) &&
        (!agu_sq_valid_i[lane] ||
         ((agu_sq_index_i[lane] < SQ_ENTRIES) &&
          sq_valid_q[agu_sq_index_i[lane]] &&
          (sq_sequence_q[agu_sq_index_i[lane]] ==
           agu_sequence_i[lane])));
    end
  end

  always_comb begin
    logic [LQ_ENTRIES-1:0] eligible_work;

    eligible_work = '0;
    selected_candidate_found = '0;
    selected_candidate_index = '0;
    selected_candidate_sequence = '0;

    for (int unsigned level = 0; level <= LQ_SELECT_TREE_LEVELS; level++)
      for (int unsigned node = 0; node < LQ_SELECT_TREE_LEAVES; node++)
        for (int unsigned rank = 0; rank < 2; rank++) begin
          lq_select_valid[level][node][rank] = 1'b0;
          lq_select_sequence[level][node][rank] = '0;
          lq_select_index[level][node][rank] = '0;
        end

    // Classify all loads independently.  A balanced tournament below carries
    // the two oldest identities from each subtree.  This replaces the former
    // 24x24 compare/popcount rank matrix with O(N) compare hardware and
    // logarithmic selection depth before the registered candidate boundary.
    for (int unsigned entry = 0; entry < LQ_ENTRIES; entry++) begin
      eligible_work[entry] =
        lq_valid_q[entry] && !lq_killed_q[entry] &&
        lq_address_valid_q[entry] && !lq_issued_q[entry] &&
        !lq_completed_q[entry] && !lq_exception_q[entry] &&
        !(candidate_found[0] &&
          (candidate_index[0] == LQ_INDEX_WIDTH'(entry))) &&
        !(candidate_found[1] &&
          (candidate_index[1] == LQ_INDEX_WIDTH'(entry)));
    end

    for (int unsigned leaf = 0; leaf < LQ_SELECT_TREE_LEAVES; leaf++) begin
      if (leaf < LQ_ENTRIES) begin
        lq_select_valid[0][leaf][0] = eligible_work[leaf];
        lq_select_sequence[0][leaf][0] = lq_sequence_q[leaf];
        lq_select_index[0][leaf][0] = LQ_INDEX_WIDTH'(leaf);
      end
    end

    for (int unsigned level = 1; level <= LQ_SELECT_TREE_LEVELS; level++) begin
      for (int unsigned node = 0; node < LQ_SELECT_TREE_LEAVES; node++) begin
        if (node < (LQ_SELECT_TREE_LEAVES >> level)) begin
          if (lq_select_before(
                lq_select_valid[level-1][node*2][0],
                lq_select_sequence[level-1][node*2][0],
                lq_select_index[level-1][node*2][0],
                lq_select_valid[level-1][node*2+1][0],
                lq_select_sequence[level-1][node*2+1][0],
                lq_select_index[level-1][node*2+1][0])) begin
            lq_select_valid[level][node][0] =
              lq_select_valid[level-1][node*2][0];
            lq_select_sequence[level][node][0] =
              lq_select_sequence[level-1][node*2][0];
            lq_select_index[level][node][0] =
              lq_select_index[level-1][node*2][0];
            if (lq_select_before(
                  lq_select_valid[level-1][node*2][1],
                  lq_select_sequence[level-1][node*2][1],
                  lq_select_index[level-1][node*2][1],
                  lq_select_valid[level-1][node*2+1][0],
                  lq_select_sequence[level-1][node*2+1][0],
                  lq_select_index[level-1][node*2+1][0])) begin
              lq_select_valid[level][node][1] =
                lq_select_valid[level-1][node*2][1];
              lq_select_sequence[level][node][1] =
                lq_select_sequence[level-1][node*2][1];
              lq_select_index[level][node][1] =
                lq_select_index[level-1][node*2][1];
            end else begin
              lq_select_valid[level][node][1] =
                lq_select_valid[level-1][node*2+1][0];
              lq_select_sequence[level][node][1] =
                lq_select_sequence[level-1][node*2+1][0];
              lq_select_index[level][node][1] =
                lq_select_index[level-1][node*2+1][0];
            end
          end else begin
            lq_select_valid[level][node][0] =
              lq_select_valid[level-1][node*2+1][0];
            lq_select_sequence[level][node][0] =
              lq_select_sequence[level-1][node*2+1][0];
            lq_select_index[level][node][0] =
              lq_select_index[level-1][node*2+1][0];
            if (lq_select_before(
                  lq_select_valid[level-1][node*2][0],
                  lq_select_sequence[level-1][node*2][0],
                  lq_select_index[level-1][node*2][0],
                  lq_select_valid[level-1][node*2+1][1],
                  lq_select_sequence[level-1][node*2+1][1],
                  lq_select_index[level-1][node*2+1][1])) begin
              lq_select_valid[level][node][1] =
                lq_select_valid[level-1][node*2][0];
              lq_select_sequence[level][node][1] =
                lq_select_sequence[level-1][node*2][0];
              lq_select_index[level][node][1] =
                lq_select_index[level-1][node*2][0];
            end else begin
              lq_select_valid[level][node][1] =
                lq_select_valid[level-1][node*2+1][1];
              lq_select_sequence[level][node][1] =
                lq_select_sequence[level-1][node*2+1][1];
              lq_select_index[level][node][1] =
                lq_select_index[level-1][node*2+1][1];
            end
          end
        end
      end
    end

    for (int unsigned lane = 0; lane < 2; lane++) begin
      selected_candidate_found[lane] =
        lq_select_valid[LQ_SELECT_TREE_LEVELS][0][lane];
      selected_candidate_index[lane] =
        lq_select_index[LQ_SELECT_TREE_LEVELS][0][lane];
      selected_candidate_sequence[lane] =
        lq_select_sequence[LQ_SELECT_TREE_LEVELS][0][lane];
    end
  end

  always_comb begin
    // A candidate blocked by an unresolved older access must not reserve a
    // slot indefinitely.  Capture that condition for one cycle, then replace
    // it only when the selector has another eligible identity.  This lets a
    // newly-ready older load preempt younger blocked candidates without
    // creating an empty-slot bubble when there is no alternative.
    //
    // Downstream ready also advances a slot, whether the candidate issued or
    // was blocked.  Crucially, the 16-SQ/24-LQ ordering result now ends at
    // candidate_blocked_q instead of feeding candidate identity D in the same
    // cycle; that feedback was the LSQ's dominant timing cone.
    candidate_replace[0] = !candidate_found[0] ||
                           load_candidate_ready_i[0] ||
                           (candidate_blocked_q[0] &&
                            selected_candidate_found[0]);
    candidate_replace[1] = !candidate_found[1] ||
                           load_candidate_ready_i[1] ||
                           (candidate_blocked_q[1] &&
                            (candidate_replace[0] ?
                              selected_candidate_found[1] :
                              selected_candidate_found[0]));
  end

  // Candidate identity is registered before the wide SQ/LQ ordering checks.
  // This cuts the 24-entry oldest-load selection and variable LQ array reads
  // away from the 16-entry store compare/forwarding cone.  Consumed slots may
  // be refilled on the same edge; the combinational selector excludes both
  // currently held identities so an outgoing load cannot be selected twice.
  always_ff @(posedge clk_i) begin
    if (!rst_ni) begin
      candidate_found <= '0;
      candidate_index <= '0;
      candidate_sequence <= '0;
      candidate_blocked_q <= '0;
    end else if (flush_valid_i) begin
      candidate_blocked_q <= '0;
      for (int unsigned lane = 0; lane < 2; lane++) begin
        if (candidate_found[lane] &&
            (flush_all_i ||
             sequence_after(candidate_sequence[lane], flush_sequence_i)))
          candidate_found[lane] <= 1'b0;
      end
    end else begin
      logic lane0_refill;
      lane0_refill = candidate_replace[0];
      if (lane0_refill) begin
        candidate_found[0] <= selected_candidate_found[0];
        candidate_blocked_q[0] <= 1'b0;
        if (selected_candidate_found[0]) begin
          candidate_index[0] <= selected_candidate_index[0];
          candidate_sequence[0] <= selected_candidate_sequence[0];
        end
      end else
        candidate_blocked_q[0] <= candidate_found[0] &&
                                  !candidate_order_valid[0];
      if (candidate_replace[1]) begin
        candidate_found[1] <= lane0_refill ? selected_candidate_found[1] :
                                             selected_candidate_found[0];
        candidate_blocked_q[1] <= 1'b0;
        if (lane0_refill && selected_candidate_found[1]) begin
          candidate_index[1] <= selected_candidate_index[1];
          candidate_sequence[1] <= selected_candidate_sequence[1];
        end else if (!lane0_refill && selected_candidate_found[0]) begin
          candidate_index[1] <= selected_candidate_index[0];
          candidate_sequence[1] <= selected_candidate_sequence[0];
        end
      end else
        candidate_blocked_q[1] <= candidate_found[1] &&
                                  !candidate_order_valid[1];
    end
  end

  for (genvar lane = 0; lane < 2; lane++) begin : g_order_check
    logic sq_forward_select_valid [0:SQ_FORWARD_TREE_LEVELS]
                                  [0:SQ_FORWARD_TREE_LEAVES-1];
    logic [SEQ_WIDTH-1:0] sq_forward_select_distance
                                  [0:SQ_FORWARD_TREE_LEVELS]
                                  [0:SQ_FORWARD_TREE_LEAVES-1];
    logic sq_forward_select_partial [0:SQ_FORWARD_TREE_LEVELS]
                                  [0:SQ_FORWARD_TREE_LEAVES-1];
    logic sq_forward_select_data_valid [0:SQ_FORWARD_TREE_LEVELS]
                                  [0:SQ_FORWARD_TREE_LEAVES-1];
    logic [DATA_WIDTH-1:0] sq_forward_select_data
                                  [0:SQ_FORWARD_TREE_LEVELS]
                                  [0:SQ_FORWARD_TREE_LEAVES-1];

    // Candidate identity/metadata is independent of device serialization.
    // Keep it in a separate cone so LSU-cluster's device_load_permit (which
    // compares this sequence against the ROB head) cannot feed back through
    // the same procedural block that produces the sequence.
    always_comb begin
      load_candidate_present_o[lane] = candidate_found[lane] && !flush_valid_i;
      load_candidate_index_o[lane] = candidate_index[lane];
      load_candidate_sequence_o[lane] = candidate_sequence[lane];
      load_candidate_address_o[lane] = '0;
      load_candidate_mask_o[lane] = '0;
      load_candidate_size_o[lane] = '0;
      load_candidate_unsigned_o[lane] = 1'b0;
      load_candidate_device_o[lane] = 1'b0;
      load_destination_valid_o[lane] = 1'b0;
      load_destination_phys_o[lane] = '0;

      if (candidate_found[lane]) begin
        load_candidate_address_o[lane] =
          lq_address_q[candidate_index[lane]];
        load_candidate_mask_o[lane] = lq_mask_q[candidate_index[lane]];
        load_candidate_size_o[lane] = lq_size_q[candidate_index[lane]];
        load_candidate_unsigned_o[lane] =
          lq_unsigned_q[candidate_index[lane]];
        load_candidate_device_o[lane] =
          lq_device_q[candidate_index[lane]];
        load_destination_valid_o[lane] =
          lq_destination_valid_q[candidate_index[lane]];
        load_destination_phys_o[lane] =
          lq_destination_phys_q[candidate_index[lane]];
      end
    end

    always_comb begin
      logic unknown_address;
      logic older_device_memory;
      logic partial_overlap;
      logic sq_match;
      logic sq_match_data_valid;
      logic [DATA_WIDTH-1:0] sq_forward_data;
      logic candidate_present;
      logic candidate_valid;
      logic [LQ_INDEX_WIDTH-1:0] selected_index;
      logic [SEQ_WIDTH-1:0] selected_sequence;
      logic [PADDR_WIDTH-1:0] selected_address;
      logic [DATA_BYTES-1:0] selected_mask;
      logic selected_device;
      logic memory_read;
      logic forward_valid;
      logic [DATA_WIDTH-1:0] forward_data;
      lsq_stall_reason_e stall_reason;

      unknown_address = 1'b0;
      older_device_memory = 1'b0;
      partial_overlap = 1'b0;
      sq_match = 1'b0;
      sq_match_data_valid = 1'b0;
      sq_forward_data = '0;

      candidate_present = candidate_found[lane];
      candidate_valid = 1'b0;
      selected_index = candidate_index[lane];
      selected_sequence = candidate_sequence[lane];
      selected_address = '0;
      selected_mask = '0;
      selected_device = 1'b0;
      memory_read = 1'b0;
      forward_valid = 1'b0;
      forward_data = '0;
      stall_reason = LSQ_STALL_NONE;

      for (int unsigned level = 0; level <= SQ_FORWARD_TREE_LEVELS;
           level++) begin
        for (int unsigned node = 0; node < SQ_FORWARD_TREE_LEAVES;
             node++) begin
          sq_forward_select_valid[level][node] = 1'b0;
          sq_forward_select_distance[level][node] = '1;
          sq_forward_select_partial[level][node] = 1'b0;
          sq_forward_select_data_valid[level][node] = 1'b0;
          sq_forward_select_data[level][node] = '0;
        end
      end

      if (candidate_present) begin
        selected_address = lq_address_q[selected_index];
        selected_mask = lq_mask_q[selected_index];
        selected_device = lq_device_q[selected_index];
      end

      for (int unsigned store = 0; store < SQ_ENTRIES; store++) begin
        logic [SEQ_WIDTH-1:0] distance;
        logic [DATA_BYTES-1:0] overlap;
        distance = selected_sequence - sq_sequence_q[store];
        overlap = sq_mask_q[store] & selected_mask;
        if (candidate_present && sq_valid_q[store] &&
            (distance != 0) && !distance[SEQ_WIDTH-1]) begin
          if (sq_device_q[store]) begin
            older_device_memory = 1'b1;
          end else if (!sq_address_valid_q[store]) begin
            unknown_address = 1'b1;
          end else if ((sq_address_q[store]
                        [PADDR_WIDTH-1:BYTE_OFFSET_WIDTH] ==
                        selected_address
                        [PADDR_WIDTH-1:BYTE_OFFSET_WIDTH]) &&
                       (overlap != '0)) begin
            sq_forward_select_valid[0][store] = 1'b1;
            sq_forward_select_distance[0][store] = distance;
            sq_forward_select_partial[0][store] =
              overlap != selected_mask;
            sq_forward_select_data_valid[0][store] =
              sq_data_valid_q[store];
            sq_forward_select_data[0][store] = sq_data_q[store];
          end
        end
      end

      // Reduce all overlapping older stores to the youngest one.  The old
      // running youngest_distance loop formed a 16-entry compare/mux chain;
      // this tree has four merge levels for the default 16-entry SQ.
      for (int unsigned level = 1; level <= SQ_FORWARD_TREE_LEVELS;
           level++) begin
        for (int unsigned node = 0; node < SQ_FORWARD_TREE_LEAVES;
             node++) begin
          if (node < (SQ_FORWARD_TREE_LEAVES >> level)) begin
            logic choose_left;
            choose_left = sq_forward_select_valid[level-1][node*2] &&
              (!sq_forward_select_valid[level-1][node*2+1] ||
               (sq_forward_select_distance[level-1][node*2] <=
                sq_forward_select_distance[level-1][node*2+1]));
            if (choose_left) begin
              sq_forward_select_valid[level][node] =
                sq_forward_select_valid[level-1][node*2];
              sq_forward_select_distance[level][node] =
                sq_forward_select_distance[level-1][node*2];
              sq_forward_select_partial[level][node] =
                sq_forward_select_partial[level-1][node*2];
              sq_forward_select_data_valid[level][node] =
                sq_forward_select_data_valid[level-1][node*2];
              sq_forward_select_data[level][node] =
                sq_forward_select_data[level-1][node*2];
            end else begin
              sq_forward_select_valid[level][node] =
                sq_forward_select_valid[level-1][node*2+1];
              sq_forward_select_distance[level][node] =
                sq_forward_select_distance[level-1][node*2+1];
              sq_forward_select_partial[level][node] =
                sq_forward_select_partial[level-1][node*2+1];
              sq_forward_select_data_valid[level][node] =
                sq_forward_select_data_valid[level-1][node*2+1];
              sq_forward_select_data[level][node] =
                sq_forward_select_data[level-1][node*2+1];
            end
          end
        end
      end

      partial_overlap =
        sq_forward_select_valid[SQ_FORWARD_TREE_LEVELS][0] &&
        sq_forward_select_partial[SQ_FORWARD_TREE_LEVELS][0];
      sq_match = sq_forward_select_valid[SQ_FORWARD_TREE_LEVELS][0] &&
                 !sq_forward_select_partial[SQ_FORWARD_TREE_LEVELS][0];
      sq_match_data_valid =
        sq_forward_select_data_valid[SQ_FORWARD_TREE_LEVELS][0];
      sq_forward_data =
        sq_forward_select_data[SQ_FORWARD_TREE_LEVELS][0];

      // The baseline scheduler also waits for older load addresses. This is
      // deliberately conservative: it prevents a younger normal load from
      // escaping before an older access is discovered to be strongly ordered
      // MMIO. A later replay-capable implementation may relax this rule.
      for (int unsigned older_load = 0; older_load < LQ_ENTRIES;
           older_load++) begin
        logic [SEQ_WIDTH-1:0] load_distance;
        load_distance = selected_sequence -
                        lq_sequence_q[older_load];
        if (candidate_present && lq_valid_q[older_load] &&
            (load_distance != 0) && !load_distance[SEQ_WIDTH-1]) begin
          if (!lq_address_valid_q[older_load])
            unknown_address = 1'b1;
          else if (lq_device_q[older_load])
            older_device_memory = 1'b1;
        end
      end

      if (candidate_present) begin
        if (older_device_memory) begin
          stall_reason = LSQ_STALL_DEVICE_SERIALIZE;
        end else if (selected_device &&
            !device_load_permit_i[lane]) begin
          stall_reason = LSQ_STALL_DEVICE_SERIALIZE;
        end else if (unknown_address) begin
          stall_reason = LSQ_STALL_UNKNOWN_ADDR;
        end else if (partial_overlap) begin
          stall_reason = LSQ_STALL_PARTIAL_OVERLAP;
        end else if (sq_match && !sq_match_data_valid) begin
          stall_reason = LSQ_STALL_STORE_DATA;
        end else if (sq_match) begin
          candidate_valid = 1'b1;
          forward_valid = 1'b1;
          forward_data = sq_forward_data;
        end else if (sb_query_partial_i[lane]) begin
          stall_reason = LSQ_STALL_PARTIAL_OVERLAP;
        end else if (sb_query_full_cover_i[lane]) begin
          candidate_valid = 1'b1;
          forward_valid = 1'b1;
          forward_data = sb_query_data_i[lane];
        end else begin
          candidate_valid = 1'b1;
          memory_read = 1'b1;
        end
      end

      // This block only produces permit-dependent issue/forward controls.
      // Candidate identity and metadata are generated above, outside the
      // device_load_permit feedback cone.
      candidate_order_valid[lane] = candidate_valid;
      candidate_forward_valid[lane] = forward_valid;
      // Do not combinationally gate LSU completion/request qualification with
      // branch flush.  Backend live-sequence filtering discards a younger
      // completion, while a normal wrong-path read is harmless and is drained
      // through the killed-entry mechanism.  Gating here formed a real loop:
      // LSU completion -> ROB live query -> branch resolve -> flush -> LSU.
      load_candidate_valid_o[lane] = candidate_valid;
      load_memory_read_o[lane] = memory_read;
      load_forward_valid_o[lane] = forward_valid;
      load_forward_data_o[lane] = forward_data;
      load_stall_reason_o[lane] = stall_reason;
    end
  end

  // Keep the store-buffer query request independent from its combinational
  // response. This is both the intended one-way CAM contract and avoids
  // introducing an artificial combinational loop by assigning request and
  // response-dependent load controls in the same procedural block.
  always_comb begin
    // A CAM query has no side effect, so keep it independent of branch flush.
    // This also prevents flush -> query -> forwarding -> completion from
    // closing the same branch-resolution loop described above.
    sb_query_valid_o = candidate_found;
    sb_query_address_o = '0;
    sb_query_mask_o = '0;
    for (int unsigned lane = 0; lane < 2; lane++) begin
      if (candidate_found[lane]) begin
        sb_query_address_o[lane] = lq_address_q[candidate_index[lane]];
        sb_query_mask_o[lane] = lq_mask_q[candidate_index[lane]];
      end
    end
  end

  always_comb begin
    load_commit_ready_o = '0;
    store_commit_ready_o = '0;
    store_commit_error_o = '0;
    sb_enq_valid_o = '0;
    sb_enq_sequence_o = '0;
    sb_enq_address_o = '0;
    sb_enq_data_o = '0;
    sb_enq_mask_o = '0;
    sb_enq_size_o = '0;
    sb_enq_device_o = '0;
    direct_store_valid_o = '0;
    direct_store_sequence_o = '0;
    direct_store_address_o = '0;
    direct_store_data_o = '0;
    direct_store_mask_o = '0;
    direct_store_size_o = '0;

    for (int unsigned lane = 0; lane < 2; lane++) begin
      if (load_commit_valid_i[lane] &&
          (load_commit_index_i[lane] < LQ_ENTRIES) &&
          lq_valid_q[load_commit_index_i[lane]] &&
          !lq_killed_q[load_commit_index_i[lane]] &&
          lq_completed_q[load_commit_index_i[lane]] &&
          (lq_sequence_q[load_commit_index_i[lane]] ==
           load_commit_sequence_i[lane]))
        load_commit_ready_o[lane] = 1'b1;

      if (store_commit_valid_i[lane] &&
          (store_commit_index_i[lane] < SQ_ENTRIES) &&
          sq_valid_q[store_commit_index_i[lane]] &&
          (sq_sequence_q[store_commit_index_i[lane]] ==
           store_commit_sequence_i[lane])) begin
        if (sq_exception_q[store_commit_index_i[lane]] ||
            !sq_address_valid_q[store_commit_index_i[lane]] ||
            !sq_data_valid_q[store_commit_index_i[lane]]) begin
          store_commit_error_o[lane] = 1'b1;
        end else if (sq_device_q[store_commit_index_i[lane]]) begin
          direct_store_valid_o[lane] = 1'b1;
          direct_store_sequence_o[lane] =
            sq_sequence_q[store_commit_index_i[lane]];
          direct_store_address_o[lane] =
            sq_address_q[store_commit_index_i[lane]];
          direct_store_data_o[lane] = sq_data_q[store_commit_index_i[lane]];
          direct_store_mask_o[lane] = sq_mask_q[store_commit_index_i[lane]];
          direct_store_size_o[lane] = sq_size_q[store_commit_index_i[lane]];
          store_commit_ready_o[lane] = direct_store_complete_i[lane] &&
                                       !direct_store_error_i[lane];
          store_commit_error_o[lane] = direct_store_complete_i[lane] &&
                                       direct_store_error_i[lane];
        end else begin
          sb_enq_valid_o[lane] = 1'b1;
          sb_enq_sequence_o[lane] =
            sq_sequence_q[store_commit_index_i[lane]];
          sb_enq_address_o[lane] = sq_address_q[store_commit_index_i[lane]];
          sb_enq_data_o[lane] = sq_data_q[store_commit_index_i[lane]];
          sb_enq_mask_o[lane] = sq_mask_q[store_commit_index_i[lane]];
          sb_enq_size_o[lane] = sq_size_q[store_commit_index_i[lane]];
          sb_enq_device_o[lane] = 1'b0;
          store_commit_ready_o[lane] = sb_enq_ready_i[lane];
        end
      end
    end
  end

  always_ff @(posedge clk_i) begin
    if (!rst_ni) begin
      lq_valid_q <= '0;
      lq_killed_q <= '0;
      lq_address_valid_q <= '0;
      lq_exception_q <= '0;
      lq_destination_valid_q <= '0;
      lq_unsigned_q <= '0;
      lq_device_q <= '0;
      sq_valid_q <= '0;
      sq_address_valid_q <= '0;
      sq_data_valid_q <= '0;
      sq_exception_q <= '0;
      sq_device_q <= '0;
      for (int unsigned entry = 0; entry < LQ_ENTRIES; entry++) begin
        lq_sequence_q[entry] <= '0;
        lq_destination_phys_q[entry] <= '0;
        lq_size_q[entry] <= '0;
        lq_address_q[entry] <= '0;
        lq_mask_q[entry] <= '0;
        lq_exception_cause_q[entry] <= EXC_LOAD_ACCESS_FAULT;
      end
      for (int unsigned entry = 0; entry < SQ_ENTRIES; entry++) begin
        sq_sequence_q[entry] <= '0;
        sq_address_q[entry] <= '0;
        sq_data_q[entry] <= '0;
        sq_mask_q[entry] <= '0;
        sq_size_q[entry] <= '0;
        sq_exception_cause_q[entry] <= EXC_STORE_ACCESS_FAULT;
      end
    end else if (flush_valid_i) begin
      for (int unsigned entry = 0; entry < LQ_ENTRIES; entry++) begin
        logic flush_entry;
        logic response_same_cycle;
        logic response_replay_same_cycle;
        flush_entry = lq_valid_q[entry] &&
          (flush_all_i || sequence_after(lq_sequence_q[entry],
                                         flush_sequence_i));
        response_same_cycle = 1'b0;
        response_replay_same_cycle = 1'b0;
        for (int unsigned lane = 0; lane < 2; lane++) begin
          if (load_response_valid_i[lane] &&
              (load_response_index_i[lane] == LQ_INDEX_WIDTH'(entry))) begin
            response_same_cycle = 1'b1;
            response_replay_same_cycle = load_response_replay_i[lane];
          end
        end
        if (flush_entry) begin
          if (lq_issued_q[entry] && !lq_completed_q[entry] &&
              !response_same_cycle) begin
            lq_killed_q[entry] <= 1'b1;
          end else begin
            lq_valid_q[entry] <= 1'b0;
            lq_killed_q[entry] <= 1'b0;
          end
        end else if (lq_valid_q[entry] && response_same_cycle) begin
          // A branch recovery may coincide with a response belonging to an
          // older load that survives the recovery boundary.  The fabric has
          // already completed the ready/valid handshake, so dropping this
          // update would leave the LQ entry permanently outstanding and stop
          // retirement at that load.
          if (lq_killed_q[entry]) begin
            lq_valid_q[entry] <= 1'b0;
            lq_killed_q[entry] <= 1'b0;
          end else if (response_replay_same_cycle) begin
          end else begin
          end
        end
      end
      for (int unsigned entry = 0; entry < SQ_ENTRIES; entry++) begin
        if (sq_valid_q[entry] &&
            (flush_all_i || sequence_after(sq_sequence_q[entry],
                                           flush_sequence_i))) begin
          sq_valid_q[entry] <= 1'b0;
          sq_address_valid_q[entry] <= 1'b0;
          sq_data_valid_q[entry] <= 1'b0;
        end
      end
    end else begin
      for (int unsigned lane = 0; lane < 2; lane++) begin
        if (dispatch_lq_valid_o[lane]) begin
          lq_valid_q[dispatch_lq_index_o[lane]] <= 1'b1;
          lq_killed_q[dispatch_lq_index_o[lane]] <= 1'b0;
          lq_address_valid_q[dispatch_lq_index_o[lane]] <= 1'b0;
          lq_exception_q[dispatch_lq_index_o[lane]] <= 1'b0;
          lq_sequence_q[dispatch_lq_index_o[lane]] <=
            dispatch_sequence_i[lane];
          lq_destination_valid_q[dispatch_lq_index_o[lane]] <=
            dispatch_destination_valid_i[lane];
          lq_destination_phys_q[dispatch_lq_index_o[lane]] <=
            dispatch_destination_phys_i[lane];
          lq_size_q[dispatch_lq_index_o[lane]] <= dispatch_size_i[lane];
          lq_unsigned_q[dispatch_lq_index_o[lane]] <=
            dispatch_unsigned_i[lane];
          lq_device_q[dispatch_lq_index_o[lane]] <=
            dispatch_device_i[lane];
        end
        if (dispatch_sq_valid_o[lane]) begin
          sq_valid_q[dispatch_sq_index_o[lane]] <= 1'b1;
          sq_address_valid_q[dispatch_sq_index_o[lane]] <= 1'b0;
          sq_data_valid_q[dispatch_sq_index_o[lane]] <= 1'b0;
          sq_exception_q[dispatch_sq_index_o[lane]] <= 1'b0;
          sq_sequence_q[dispatch_sq_index_o[lane]] <=
            dispatch_sequence_i[lane];
          sq_size_q[dispatch_sq_index_o[lane]] <= dispatch_size_i[lane];
          sq_device_q[dispatch_sq_index_o[lane]] <=
            dispatch_device_i[lane];
        end

        if (agu_valid_i[lane] && agu_ready_o[lane]) begin
          if (agu_lq_valid_i[lane]) begin
            lq_address_q[agu_lq_index_i[lane]] <= agu_address_i[lane];
            lq_mask_q[agu_lq_index_i[lane]] <= agu_mask_i[lane];
            lq_address_valid_q[agu_lq_index_i[lane]] <=
              agu_address_valid_i[lane];
            lq_device_q[agu_lq_index_i[lane]] <= agu_device_i[lane];
            lq_exception_q[agu_lq_index_i[lane]] <=
              agu_exception_valid_i[lane];
            lq_exception_cause_q[agu_lq_index_i[lane]] <=
              agu_exception_cause_i[lane];
          end
          if (agu_sq_valid_i[lane]) begin
            if (agu_address_valid_i[lane]) begin
              sq_address_q[agu_sq_index_i[lane]] <= agu_address_i[lane];
              sq_mask_q[agu_sq_index_i[lane]] <= agu_mask_i[lane];
              sq_address_valid_q[agu_sq_index_i[lane]] <= 1'b1;
              sq_device_q[agu_sq_index_i[lane]] <= agu_device_i[lane];
            end
            if (agu_store_data_valid_i[lane]) begin
              sq_data_q[agu_sq_index_i[lane]] <= agu_store_data_i[lane];
              sq_data_valid_q[agu_sq_index_i[lane]] <= 1'b1;
            end
            if (agu_exception_valid_i[lane]) begin
              sq_exception_q[agu_sq_index_i[lane]] <= 1'b1;
              sq_exception_cause_q[agu_sq_index_i[lane]] <=
                agu_exception_cause_i[lane];
            end
          end
        end

        if (load_response_valid_i[lane] &&
            (load_response_index_i[lane] < LQ_ENTRIES) &&
            lq_valid_q[load_response_index_i[lane]]) begin
          if (lq_killed_q[load_response_index_i[lane]]) begin
            lq_valid_q[load_response_index_i[lane]] <= 1'b0;
            lq_killed_q[load_response_index_i[lane]] <= 1'b0;
          end
        end

        if (load_commit_valid_i[lane] && load_commit_ready_o[lane]) begin
          lq_valid_q[load_commit_index_i[lane]] <= 1'b0;
        end
        if (store_commit_valid_i[lane] && store_commit_ready_o[lane]) begin
          sq_valid_q[store_commit_index_i[lane]] <= 1'b0;
          sq_address_valid_q[store_commit_index_i[lane]] <= 1'b0;
          sq_data_valid_q[store_commit_index_i[lane]] <= 1'b0;
        end
      end
    end
  end

  // Issued state only tracks a memory request that has left the LSQ and is
  // cleared by its response.  Flush changes validity/killed ownership, not
  // this transport fact: a killed outstanding request must remain marked
  // issued until the response drains.  Fixed-entry event decoding avoids the
  // former flush/sequence-compare -> issued-D mux chain.
  always_ff @(posedge clk_i) begin
    if (!rst_ni) begin
      lq_issued_q <= '0;
    end else begin
      for (int unsigned entry = 0; entry < LQ_ENTRIES; entry++) begin
        for (int unsigned lane = 0; lane < 2; lane++) begin
          if (dispatch_lq_valid_o[lane] &&
              (dispatch_lq_index_o[lane] == LQ_INDEX_WIDTH'(entry)))
            lq_issued_q[entry] <= 1'b0;

          if (load_memory_read_o[lane] && load_candidate_ready_i[lane] &&
              (load_candidate_index_o[lane] == LQ_INDEX_WIDTH'(entry)))
            lq_issued_q[entry] <= 1'b1;

          if (load_response_valid_i[lane] &&
              (load_response_index_i[lane] == LQ_INDEX_WIDTH'(entry)) &&
              lq_valid_q[entry])
            lq_issued_q[entry] <= 1'b0;
        end
      end
    end
  end

  // Completion bits use constant-index updates.  Variable-index writes from
  // dispatch, AGU, forwarding, response and commit used to collapse into a
  // very deep mux chain (flush_valid_i -> lq_completed_q D).  Decoding each
  // event against a fixed entry lets synthesis build shallow parallel compare
  // trees while preserving the original lane/operation priority.  Flush does
  // not need a separate completion-bit branch: flushed entries either become
  // invalid or remain killed until their response drains, and every future
  // allocation clears the bit.  A coincident response may therefore complete
  // an older survivor without putting flush on this register's data path.
  always_ff @(posedge clk_i) begin
    if (!rst_ni) begin
      lq_completed_q <= '0;
    end else begin
      for (int unsigned entry = 0; entry < LQ_ENTRIES; entry++) begin
        for (int unsigned lane = 0; lane < 2; lane++) begin
          if (dispatch_lq_valid_o[lane] &&
              (dispatch_lq_index_o[lane] == LQ_INDEX_WIDTH'(entry)))
            lq_completed_q[entry] <= 1'b0;

          if (agu_valid_i[lane] && agu_ready_o[lane] &&
              agu_lq_valid_i[lane] &&
              (agu_lq_index_i[lane] == LQ_INDEX_WIDTH'(entry)) &&
              agu_exception_valid_i[lane])
            lq_completed_q[entry] <= 1'b1;

          if (candidate_order_valid[lane] &&
              load_candidate_ready_i[lane] &&
              candidate_forward_valid[lane] &&
              (load_candidate_index_o[lane] == LQ_INDEX_WIDTH'(entry)))
            lq_completed_q[entry] <= 1'b1;

          if (load_response_valid_i[lane] &&
              (load_response_index_i[lane] == LQ_INDEX_WIDTH'(entry)) &&
              lq_valid_q[entry] && !lq_killed_q[entry] &&
              !load_response_replay_i[lane])
            lq_completed_q[entry] <= 1'b1;

          if (load_commit_valid_i[lane] && load_commit_ready_o[lane] &&
              (load_commit_index_i[lane] == LQ_INDEX_WIDTH'(entry)))
            lq_completed_q[entry] <= 1'b0;
        end
      end
    end
  end

  assign lq_count_o =
    LQ_COUNT_WIDTH'($unsigned($countones(lq_valid_q)));
  assign sq_count_o =
    SQ_COUNT_WIDTH'($unsigned($countones(sq_valid_q)));
  assign load_outstanding_o =
    |(lq_valid_q & lq_issued_q & ~lq_completed_q);

`ifndef SYNTHESIS
  property p_unknown_store_blocks_memory_lane0;
    @(posedge clk_i) disable iff (!rst_ni)
      load_candidate_present_o[0] &&
      (load_stall_reason_o[0] == LSQ_STALL_UNKNOWN_ADDR)
      |-> !load_memory_read_o[0];
  endproperty
  assert property (p_unknown_store_blocks_memory_lane0);

  property p_unknown_store_blocks_memory_lane1;
    @(posedge clk_i) disable iff (!rst_ni)
      load_candidate_present_o[1] &&
      (load_stall_reason_o[1] == LSQ_STALL_UNKNOWN_ADDR)
      |-> !load_memory_read_o[1];
  endproperty
  assert property (p_unknown_store_blocks_memory_lane1);

  property p_forward_and_memory_exclusive;
    @(posedge clk_i) disable iff (!rst_ni)
      !(|(load_forward_valid_o & load_memory_read_o));
  endproperty
  assert property (p_forward_and_memory_exclusive);

  property p_store_visible_only_at_commit;
    @(posedge clk_i) disable iff (!rst_ni)
      (|sb_enq_valid_o) |-> (|store_commit_valid_i);
  endproperty
  assert property (p_store_visible_only_at_commit);

  property p_store_commit_lane1_is_packed;
    @(posedge clk_i) disable iff (!rst_ni)
      store_commit_valid_i[1] |-> store_commit_valid_i[0];
  endproperty
  assert property (p_store_commit_lane1_is_packed);

  property p_device_store_is_serialized;
    @(posedge clk_i) disable iff (!rst_ni)
      (|direct_store_valid_o) |-> $onehot(direct_store_valid_o);
  endproperty
  assert property (p_device_store_is_serialized);
`endif

  initial begin : p_parameter_checks
    if ((LQ_ENTRIES < 2) || (SQ_ENTRIES < 2))
      $fatal(1, "LSQ needs at least two LQ and SQ entries");
    if ((LQ_ENTRIES > (1 << LQ_INDEX_WIDTH)) ||
        (SQ_ENTRIES > (1 << SQ_INDEX_WIDTH)))
      $fatal(1, "LSQ index width cannot represent all entries");
    if ((DATA_WIDTH % 8) != 0 ||
        ((DATA_BYTES & (DATA_BYTES-1)) != 0))
      $fatal(1, "LSQ DATA_WIDTH must contain a power-of-two byte count");
    if (SEQ_WIDTH < 2)
      $fatal(1, "LSQ requires a wrap-aware sequence width");
  end

endmodule
