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
  localparam int unsigned SQ_COUNT_WIDTH = $clog2(SQ_ENTRIES + 1)
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

  always @(*) begin
    candidate_found = '0;
    candidate_index = '0;
    candidate_sequence = '0;
    for (int unsigned entry = 0; entry < LQ_ENTRIES; entry++) begin
      if (lq_valid_q[entry] && !lq_killed_q[entry] &&
          lq_address_valid_q[entry] && !lq_issued_q[entry] &&
          !lq_completed_q[entry] && !lq_exception_q[entry]) begin
        if (!candidate_found[0] ||
            sequence_after(candidate_sequence[0], lq_sequence_q[entry])) begin
          candidate_found[1] = candidate_found[0];
          candidate_index[1] = candidate_index[0];
          candidate_sequence[1] = candidate_sequence[0];
          candidate_found[0] = 1'b1;
          candidate_index[0] = LQ_INDEX_WIDTH'(entry);
          candidate_sequence[0] = lq_sequence_q[entry];
        end else if (!candidate_found[1] ||
                     sequence_after(candidate_sequence[1],
                                    lq_sequence_q[entry])) begin
          candidate_found[1] = 1'b1;
          candidate_index[1] = LQ_INDEX_WIDTH'(entry);
          candidate_sequence[1] = lq_sequence_q[entry];
        end
      end
    end
  end

  for (genvar lane = 0; lane < 2; lane++) begin : g_order_check
    always @(*) begin
      logic unknown_address;
      logic older_device_memory;
      logic partial_overlap;
      logic sq_match;
      logic sq_match_data_valid;
      logic [SEQ_WIDTH-1:0] youngest_distance;
      logic [DATA_WIDTH-1:0] sq_forward_data;

      unknown_address = 1'b0;
      older_device_memory = 1'b0;
      partial_overlap = 1'b0;
      sq_match = 1'b0;
      sq_match_data_valid = 1'b0;
      youngest_distance = '1;
      sq_forward_data = '0;

      load_candidate_present_o[lane] = candidate_found[lane];
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

      for (int unsigned store = 0; store < SQ_ENTRIES; store++) begin
        logic [SEQ_WIDTH-1:0] distance;
        logic [DATA_BYTES-1:0] overlap;
        distance = candidate_sequence[lane] - sq_sequence_q[store];
        overlap = sq_mask_q[store] & load_candidate_mask_o[lane];
        if (candidate_found[lane] && sq_valid_q[store] &&
            (distance != 0) && !distance[SEQ_WIDTH-1]) begin
          if (sq_device_q[store]) begin
            older_device_memory = 1'b1;
          end else if (!sq_address_valid_q[store]) begin
            unknown_address = 1'b1;
          end else if ((sq_address_q[store]
                        [PADDR_WIDTH-1:BYTE_OFFSET_WIDTH] ==
                        load_candidate_address_o[lane]
                        [PADDR_WIDTH-1:BYTE_OFFSET_WIDTH]) &&
                       (overlap != '0)) begin
            if ((overlap != load_candidate_mask_o[lane]) &&
                (!sq_match || (distance < youngest_distance))) begin
              partial_overlap = 1'b1;
              sq_match = 1'b0;
              youngest_distance = distance;
            end else if ((overlap == load_candidate_mask_o[lane]) &&
                         (distance < youngest_distance)) begin
              partial_overlap = 1'b0;
              sq_match = 1'b1;
              sq_match_data_valid = sq_data_valid_q[store];
              youngest_distance = distance;
              sq_forward_data = sq_data_q[store];
            end
          end
        end
      end

      // The baseline scheduler also waits for older load addresses. This is
      // deliberately conservative: it prevents a younger normal load from
      // escaping before an older access is discovered to be strongly ordered
      // MMIO. A later replay-capable implementation may relax this rule.
      for (int unsigned older_load = 0; older_load < LQ_ENTRIES;
           older_load++) begin
        logic [SEQ_WIDTH-1:0] load_distance;
        load_distance = candidate_sequence[lane] -
                        lq_sequence_q[older_load];
        if (candidate_found[lane] && lq_valid_q[older_load] &&
            (load_distance != 0) && !load_distance[SEQ_WIDTH-1]) begin
          if (!lq_address_valid_q[older_load])
            unknown_address = 1'b1;
          else if (lq_device_q[older_load])
            older_device_memory = 1'b1;
        end
      end

      load_candidate_valid_o[lane] = 1'b0;
      load_memory_read_o[lane] = 1'b0;
      load_forward_valid_o[lane] = 1'b0;
      load_forward_data_o[lane] = '0;
      load_stall_reason_o[lane] = LSQ_STALL_NONE;

      if (candidate_found[lane]) begin
        if (older_device_memory) begin
          load_stall_reason_o[lane] = LSQ_STALL_DEVICE_SERIALIZE;
        end else if (load_candidate_device_o[lane] &&
            !device_load_permit_i[lane]) begin
          load_stall_reason_o[lane] = LSQ_STALL_DEVICE_SERIALIZE;
        end else if (unknown_address) begin
          load_stall_reason_o[lane] = LSQ_STALL_UNKNOWN_ADDR;
        end else if (partial_overlap) begin
          load_stall_reason_o[lane] = LSQ_STALL_PARTIAL_OVERLAP;
        end else if (sq_match && !sq_match_data_valid) begin
          load_stall_reason_o[lane] = LSQ_STALL_STORE_DATA;
        end else if (sq_match) begin
          load_candidate_valid_o[lane] = 1'b1;
          load_forward_valid_o[lane] = 1'b1;
          load_forward_data_o[lane] = sq_forward_data;
        end else if (sb_query_partial_i[lane]) begin
          load_stall_reason_o[lane] = LSQ_STALL_PARTIAL_OVERLAP;
        end else if (sb_query_full_cover_i[lane]) begin
          load_candidate_valid_o[lane] = 1'b1;
          load_forward_valid_o[lane] = 1'b1;
          load_forward_data_o[lane] = sb_query_data_i[lane];
        end else begin
          load_candidate_valid_o[lane] = 1'b1;
          load_memory_read_o[lane] = 1'b1;
        end
      end
    end
  end

  // Keep the store-buffer query request independent from its combinational
  // response. This is both the intended one-way CAM contract and avoids
  // introducing an artificial combinational loop by assigning request and
  // response-dependent load controls in the same procedural block.
  always_comb begin
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
      lq_issued_q <= '0;
      lq_completed_q <= '0;
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
            lq_issued_q[entry] <= 1'b0;
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
            lq_issued_q[entry] <= 1'b0;
          end else begin
            lq_issued_q[entry] <= 1'b0;
            lq_completed_q[entry] <= 1'b1;
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
          lq_issued_q[dispatch_lq_index_o[lane]] <= 1'b0;
          lq_completed_q[dispatch_lq_index_o[lane]] <= 1'b0;
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
            if (agu_exception_valid_i[lane])
              lq_completed_q[agu_lq_index_i[lane]] <= 1'b1;
          end
          if (agu_sq_valid_i[lane]) begin
            sq_address_q[agu_sq_index_i[lane]] <= agu_address_i[lane];
            sq_mask_q[agu_sq_index_i[lane]] <= agu_mask_i[lane];
            sq_data_q[agu_sq_index_i[lane]] <= agu_store_data_i[lane];
            sq_address_valid_q[agu_sq_index_i[lane]] <=
              agu_address_valid_i[lane];
            sq_data_valid_q[agu_sq_index_i[lane]] <=
              agu_store_data_valid_i[lane];
            sq_device_q[agu_sq_index_i[lane]] <= agu_device_i[lane];
            sq_exception_q[agu_sq_index_i[lane]] <=
              agu_exception_valid_i[lane];
            sq_exception_cause_q[agu_sq_index_i[lane]] <=
              agu_exception_cause_i[lane];
          end
        end

        if (load_candidate_valid_o[lane] &&
            load_candidate_ready_i[lane]) begin
          if (load_forward_valid_o[lane])
            lq_completed_q[load_candidate_index_o[lane]] <= 1'b1;
          else
            lq_issued_q[load_candidate_index_o[lane]] <= 1'b1;
        end

        if (load_response_valid_i[lane] &&
            (load_response_index_i[lane] < LQ_ENTRIES) &&
            lq_valid_q[load_response_index_i[lane]]) begin
          if (lq_killed_q[load_response_index_i[lane]]) begin
            lq_valid_q[load_response_index_i[lane]] <= 1'b0;
            lq_killed_q[load_response_index_i[lane]] <= 1'b0;
          end else if (load_response_replay_i[lane]) begin
            lq_issued_q[load_response_index_i[lane]] <= 1'b0;
          end else begin
            lq_issued_q[load_response_index_i[lane]] <= 1'b0;
            lq_completed_q[load_response_index_i[lane]] <= 1'b1;
          end
        end

        if (load_commit_valid_i[lane] && load_commit_ready_o[lane]) begin
          lq_valid_q[load_commit_index_i[lane]] <= 1'b0;
          lq_completed_q[load_commit_index_i[lane]] <= 1'b0;
        end
        if (store_commit_valid_i[lane] && store_commit_ready_o[lane]) begin
          sq_valid_q[store_commit_index_i[lane]] <= 1'b0;
          sq_address_valid_q[store_commit_index_i[lane]] <= 1'b0;
          sq_data_valid_q[store_commit_index_i[lane]] <= 1'b0;
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
