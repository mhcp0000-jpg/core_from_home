module rv_lsu_cluster #(
  parameter int unsigned XLEN                 = 32,
  parameter int unsigned PADDR_WIDTH          = 32,
  parameter int unsigned MEM_DATA_WIDTH       = 64,
  parameter int unsigned ROB_SEQ_WIDTH        = rv_ooo_pkg::ROB_SEQ_WIDTH,
  parameter int unsigned PHYS_TAG_WIDTH       = 7,
  parameter int unsigned LQ_ENTRIES           = 24,
  parameter int unsigned SQ_ENTRIES           = 16,
  parameter int unsigned STORE_BUFFER_ENTRIES = 16,
  parameter int unsigned PMP_ENTRIES          = 8,
  parameter logic [PADDR_WIDTH-1:0] ITIM_BASE_ADDR = 'h8000_0000,
  parameter int unsigned ITIM_SIZE_KB         = 128,
  parameter logic [PADDR_WIDTH-1:0] DTIM_BASE_ADDR = 'h8002_0000,
  parameter int unsigned DTIM_SIZE_KB         = 128,
  localparam int unsigned MEM_BYTES           = MEM_DATA_WIDTH / 8,
  localparam int unsigned LQ_INDEX_WIDTH       = $clog2(LQ_ENTRIES),
  localparam int unsigned SQ_INDEX_WIDTH       = $clog2(SQ_ENTRIES),
  localparam int unsigned SB_INDEX_WIDTH       = $clog2(STORE_BUFFER_ENTRIES),
  localparam int unsigned PMP_ADDR_WIDTH       = PADDR_WIDTH - 2,
  localparam int unsigned COMPLETION_SOURCES   = 5
) (
  input  logic                                  clk_i,
  input  logic                                  rst_ni,

  input  logic [1:0]                            dispatch_valid_i,
  input  logic                                  dispatch_accept_i,
  output logic                                  dispatch_ready_o,
  input  logic [1:0]                            dispatch_is_load_i,
  input  logic [1:0]                            dispatch_is_store_i,
  input  logic [1:0][ROB_SEQ_WIDTH-1:0]         dispatch_sequence_i,
  input  logic [1:0]                            dispatch_destination_valid_i,
  input  rv_ooo_pkg::reg_class_e [1:0]          dispatch_destination_class_i,
  input  logic [1:0][PHYS_TAG_WIDTH-1:0]        dispatch_destination_phys_i,
  input  logic [1:0][2:0]                       dispatch_size_i,
  input  logic [1:0]                            dispatch_unsigned_i,
  output logic [1:0]                            dispatch_lq_valid_o,
  output logic [1:0][LQ_INDEX_WIDTH-1:0]        dispatch_lq_index_o,
  output logic [1:0]                            dispatch_sq_valid_o,
  output logic [1:0][SQ_INDEX_WIDTH-1:0]        dispatch_sq_index_o,

  input  logic [1:0]                            issue_valid_i,
  output logic [1:0]                            issue_ready_o,
  input  logic [1:0][ROB_SEQ_WIDTH-1:0]         issue_sequence_i,
  input  logic [1:0]                            issue_is_load_i,
  input  logic [1:0]                            issue_is_store_i,
  input  logic [1:0]                            issue_address_valid_i,
  input  logic [1:0]                            issue_store_data_valid_i,
  input  logic [1:0]                            issue_lq_valid_i,
  input  logic [1:0][LQ_INDEX_WIDTH-1:0]        issue_lq_index_i,
  input  logic [1:0]                            issue_sq_valid_i,
  input  logic [1:0][SQ_INDEX_WIDTH-1:0]        issue_sq_index_i,
  input  logic [1:0][XLEN-1:0]                  issue_base_i,
  input  logic [1:0][XLEN-1:0]                  issue_immediate_i,
  input  logic [1:0][XLEN-1:0]                  issue_store_data_i,
  input  logic [1:0][2:0]                       issue_size_i,
  input  rv_ooo_pkg::privilege_e                 current_privilege_i,
  input  logic [PMP_ENTRIES*8-1:0]               pmpcfg_i,
  input  logic [PMP_ENTRIES*PMP_ADDR_WIDTH-1:0]  pmpaddr_i,

  input  logic                                  rob_head_valid_i,
  input  logic [ROB_SEQ_WIDTH-1:0]              rob_head_sequence_i,
  input  logic [1:0]                            commit_valid_i,
  input  logic [1:0]                            commit_is_load_i,
  input  logic [1:0]                            commit_is_store_i,
  input  logic [1:0][ROB_SEQ_WIDTH-1:0]         commit_sequence_i,
  input  logic [1:0][LQ_INDEX_WIDTH-1:0]        commit_lq_index_i,
  input  logic [1:0][SQ_INDEX_WIDTH-1:0]        commit_sq_index_i,
  output logic [1:0]                            commit_ready_o,

  output logic [COMPLETION_SOURCES-1:0]         completion_valid_o,
  input  logic [COMPLETION_SOURCES-1:0]         completion_ready_i,
  output logic [COMPLETION_SOURCES-1:0][ROB_SEQ_WIDTH-1:0]
                                                   completion_sequence_o,
  output logic [COMPLETION_SOURCES-1:0]         completion_destination_valid_o,
  output rv_ooo_pkg::reg_class_e [COMPLETION_SOURCES-1:0]
                                                   completion_destination_class_o,
  output logic [COMPLETION_SOURCES-1:0][PHYS_TAG_WIDTH-1:0]
                                                   completion_destination_phys_o,
  output logic [COMPLETION_SOURCES-1:0][XLEN-1:0]
                                                   completion_data_o,
  output logic [COMPLETION_SOURCES-1:0]         completion_exception_valid_o,
  output rv_ooo_pkg::exception_code_e [COMPLETION_SOURCES-1:0]
                                                   completion_exception_cause_o,
  output logic [COMPLETION_SOURCES-1:0][XLEN-1:0]
                                                   completion_exception_tval_o,

  input  logic                                  flush_valid_i,
  input  logic                                  flush_all_i,
  input  logic [ROB_SEQ_WIDTH-1:0]              flush_sequence_i,

  output logic [1:0]                            dmem_req_valid_o,
  input  logic [1:0]                            dmem_req_ready_i,
  output logic [1:0][5:0]                       dmem_req_id_o,
  output logic [1:0]                            dmem_req_write_o,
  output logic [1:0][PADDR_WIDTH-1:0]           dmem_req_addr_o,
  output logic [1:0][2:0]                       dmem_req_size_o,
  output logic [1:0][MEM_DATA_WIDTH-1:0]        dmem_req_wdata_o,
  output logic [1:0][MEM_BYTES-1:0]             dmem_req_wstrb_o,
  output logic [1:0][1:0]                       dmem_req_priv_o,
  output logic [1:0][ROB_SEQ_WIDTH-1:0]         dmem_req_rob_seq_o,
  output logic [1:0]                            dmem_req_committed_o,
  output logic [1:0]                            dmem_req_device_o,
  input  logic [1:0]                            dmem_rsp_valid_i,
  output logic [1:0]                            dmem_rsp_ready_o,
  input  logic [1:0][5:0]                       dmem_rsp_id_i,
  input  logic [1:0][MEM_DATA_WIDTH-1:0]        dmem_rsp_rdata_i,
  input  logic [1:0][1:0]                       dmem_rsp_resp_i,
  input  logic [1:0][2:0]                       dmem_rsp_replay_i,

  output logic                                  store_buffer_empty_o,
  output logic                                  memory_idle_o,
  output logic                                  store_machine_check_o
);
  import rv_ooo_pkg::*;

  localparam logic [1:0] MEM_RSP_OKAY = 2'b00;

  function automatic logic sequence_after(
    input logic [ROB_SEQ_WIDTH-1:0] lhs,
    input logic [ROB_SEQ_WIDTH-1:0] rhs
  );
    logic signed [ROB_SEQ_WIDTH-1:0] distance;
    distance = $signed(lhs - rhs);
    return distance > 0;
  endfunction

  function automatic logic address_in_region(
    input logic [PADDR_WIDTH-1:0] address,
    input logic [PADDR_WIDTH-1:0] base,
    input longint unsigned size_bytes
  );
    logic [PADDR_WIDTH:0] upper;
    upper = {1'b0, base} + (PADDR_WIDTH+1)'(size_bytes);
    return ({1'b0, address} >= {1'b0, base}) &&
           ({1'b0, address} < upper);
  endfunction

  function automatic logic is_device_address(
    input logic [PADDR_WIDTH-1:0] address
  );
    return !(address_in_region(address, ITIM_BASE_ADDR,
                               ITIM_SIZE_KB * 1024) ||
             address_in_region(address, DTIM_BASE_ADDR,
                               DTIM_SIZE_KB * 1024));
  endfunction

  function automatic logic [XLEN-1:0] format_load_data(
    input logic [MEM_DATA_WIDTH-1:0] beat,
    input logic [PADDR_WIDTH-1:0] address,
    input logic [2:0] size,
    input logic unsigned_load
  );
    logic [MEM_DATA_WIDTH-1:0] shifted;
    shifted = beat >> (address[$clog2(MEM_BYTES)-1:0] * 8);
    case (size)
      3'd0: format_load_data = unsigned_load ?
        XLEN'(shifted[7:0]) : {{(XLEN-8){shifted[7]}}, shifted[7:0]};
      3'd1: format_load_data = unsigned_load ?
        XLEN'(shifted[15:0]) : {{(XLEN-16){shifted[15]}}, shifted[15:0]};
      3'd2: format_load_data = unsigned_load ?
        XLEN'(shifted[31:0]) : {{(XLEN-32){shifted[31]}}, shifted[31:0]};
      default: format_load_data = XLEN'(shifted);
    endcase
  endfunction

  // Per-LQ response metadata. The LSQ owns validity and generation; this
  // sidecar only supplies data needed to format an eventually returned beat.
  reg_class_e lq_destination_class_q [0:LQ_ENTRIES-1];
  logic [ROB_SEQ_WIDTH-1:0] load_meta_sequence_q [0:LQ_ENTRIES-1];
  reg_class_e load_meta_class_q [0:LQ_ENTRIES-1];
  logic load_meta_destination_valid_q [0:LQ_ENTRIES-1];
  logic [PHYS_TAG_WIDTH-1:0] load_meta_destination_phys_q [0:LQ_ENTRIES-1];
  logic [PADDR_WIDTH-1:0] load_meta_address_q [0:LQ_ENTRIES-1];
  logic [2:0] load_meta_size_q [0:LQ_ENTRIES-1];
  logic load_meta_unsigned_q [0:LQ_ENTRIES-1];

  logic [1:0] agu_update_valid, agu_update_ready;
  logic [1:0][ROB_SEQ_WIDTH-1:0] agu_update_sequence;
  logic [1:0] agu_update_is_load, agu_update_is_store;
  logic [1:0] agu_update_lq_valid, agu_update_sq_valid;
  logic [1:0][LQ_INDEX_WIDTH-1:0] agu_update_lq_index;
  logic [1:0][SQ_INDEX_WIDTH-1:0] agu_update_sq_index;
  logic [1:0][PADDR_WIDTH-1:0] agu_update_address;
  logic [1:0][2:0] agu_update_size;
  logic [1:0][MEM_BYTES-1:0] agu_update_mask;
  logic [1:0][MEM_DATA_WIDTH-1:0] agu_update_store_data;
  logic [1:0] agu_update_address_valid, agu_update_store_data_valid;
  logic [1:0] agu_update_exception;
  exception_code_e [1:0] agu_update_cause;
  logic [1:0][XLEN-1:0] agu_update_tval;
  logic [1:0] agu_effective_exception;
  exception_code_e [1:0] agu_effective_cause;
  logic [1:0][XLEN-1:0] agu_effective_tval;
  logic [1:0] agu_to_lsq_valid, agu_lsq_ready, agu_completion_needed;
  logic [1:0] agu_device;
  logic [1:0] pmp_check_valid, pmp_allow, pmp_matched;
  logic [1:0][2:0] pmp_access;
  logic [1:0][PADDR_WIDTH-1:0] pmp_fault_address;
  privilege_e [1:0] pmp_privilege;

  for (genvar lane = 0; lane < 2; lane++) begin : g_agu
    rv_lsu_pipe #(
      .XLEN(XLEN), .PADDR_WIDTH(PADDR_WIDTH),
      .MEM_DATA_WIDTH(MEM_DATA_WIDTH), .ROB_SEQ_WIDTH(ROB_SEQ_WIDTH),
      .LQ_INDEX_WIDTH(LQ_INDEX_WIDTH), .SQ_INDEX_WIDTH(SQ_INDEX_WIDTH)
    ) u_pipe (
      .clk_i, .rst_ni, .issue_valid_i(issue_valid_i[lane]),
      .issue_ready_o(issue_ready_o[lane]),
      .issue_rob_sequence_i(issue_sequence_i[lane]),
      .issue_is_load_i(issue_is_load_i[lane]),
      .issue_is_store_i(issue_is_store_i[lane]),
      .issue_address_valid_i(issue_address_valid_i[lane]),
      .issue_store_data_valid_i(issue_store_data_valid_i[lane]),
      .issue_lq_valid_i(issue_lq_valid_i[lane]),
      .issue_lq_index_i(issue_lq_index_i[lane]),
      .issue_sq_valid_i(issue_sq_valid_i[lane]),
      .issue_sq_index_i(issue_sq_index_i[lane]),
      .base_i(issue_base_i[lane]), .immediate_i(issue_immediate_i[lane]),
      .store_data_i(issue_store_data_i[lane]),
      .memory_size_i(issue_size_i[lane]), .flush_valid_i,
      .flush_all_i, .flush_sequence_i,
      .update_valid_o(agu_update_valid[lane]),
      .update_ready_i(agu_update_ready[lane]),
      .update_rob_sequence_o(agu_update_sequence[lane]),
      .update_is_load_o(agu_update_is_load[lane]),
      .update_is_store_o(agu_update_is_store[lane]),
      .update_lq_valid_o(agu_update_lq_valid[lane]),
      .update_lq_index_o(agu_update_lq_index[lane]),
      .update_sq_valid_o(agu_update_sq_valid[lane]),
      .update_sq_index_o(agu_update_sq_index[lane]),
      .update_address_o(agu_update_address[lane]),
      .update_memory_size_o(agu_update_size[lane]),
      .update_byte_mask_o(agu_update_mask[lane]),
      .update_store_data_o(agu_update_store_data[lane]),
      .update_address_valid_o(agu_update_address_valid[lane]),
      .update_store_data_valid_o(agu_update_store_data_valid[lane]),
      .update_exception_valid_o(agu_update_exception[lane]),
      .update_exception_cause_o(agu_update_cause[lane]),
      .update_exception_tval_o(agu_update_tval[lane])
    );
  end

  rv_pmp #(
    .PADDR_WIDTH(PADDR_WIDTH), .PMP_ENTRIES(PMP_ENTRIES), .CHECK_PORTS(2)
  ) u_data_pmp (
    .pmpcfg_i, .pmpaddr_i, .check_valid_i(pmp_check_valid),
    .check_address_i(agu_update_address), .check_size_i(agu_update_size),
    .check_access_i(pmp_access), .check_privilege_i(pmp_privilege),
    .allow_o(pmp_allow), .matched_o(pmp_matched),
    .fault_address_o(pmp_fault_address)
  );

  logic [1:0] load_candidate_present, load_candidate_valid;
  logic [1:0] load_candidate_ready;
  logic [1:0][LQ_INDEX_WIDTH-1:0] load_candidate_index;
  logic [1:0][ROB_SEQ_WIDTH-1:0] load_candidate_sequence;
  logic [1:0][PADDR_WIDTH-1:0] load_candidate_address;
  logic [1:0][MEM_BYTES-1:0] load_candidate_mask;
  logic [1:0][2:0] load_candidate_size;
  logic [1:0] load_candidate_unsigned, load_candidate_device;
  logic [1:0] load_destination_valid;
  logic [1:0][PHYS_TAG_WIDTH-1:0] load_destination_phys;
  logic [1:0] load_memory_read, load_forward_valid;
  logic [1:0][MEM_DATA_WIDTH-1:0] load_forward_data;
  lsq_stall_reason_e [1:0] load_stall_reason;
  logic [1:0] device_load_permit;
  logic [1:0] sb_query_valid, sb_query_full_cover, sb_query_partial;
  logic [1:0][PADDR_WIDTH-1:0] sb_query_address;
  logic [1:0][MEM_BYTES-1:0] sb_query_mask;
  logic [1:0][MEM_DATA_WIDTH-1:0] sb_query_data;
  logic [1:0] lsq_load_response_valid, lsq_load_response_replay;
  logic [1:0][LQ_INDEX_WIDTH-1:0] lsq_load_response_index;
  logic [1:0] load_commit_valid, load_commit_ready;
  logic [1:0] store_commit_valid, store_commit_ready, store_commit_error;
  logic [1:0] sb_enq_valid, sb_enq_ready, sb_enq_device;
  logic [1:0][ROB_SEQ_WIDTH-1:0] sb_enq_sequence;
  logic [1:0][PADDR_WIDTH-1:0] sb_enq_address;
  logic [1:0][MEM_DATA_WIDTH-1:0] sb_enq_data;
  logic [1:0][MEM_BYTES-1:0] sb_enq_mask;
  logic [1:0][2:0] sb_enq_size;
  logic [1:0] direct_store_valid, direct_store_complete, direct_store_error;
  logic [1:0][ROB_SEQ_WIDTH-1:0] direct_store_sequence;
  logic [1:0][PADDR_WIDTH-1:0] direct_store_address;
  logic [1:0][MEM_DATA_WIDTH-1:0] direct_store_data;
  logic [1:0][MEM_BYTES-1:0] direct_store_mask;
  logic [1:0][2:0] direct_store_size;
  logic load_outstanding;
  logic [$clog2(LQ_ENTRIES+1)-1:0] lq_count;
  logic [$clog2(SQ_ENTRIES+1)-1:0] sq_count;

  always_comb begin
    for (int unsigned lane = 0; lane < 2; lane++) begin
      // A split store-data phase recomputes the same effective address for
      // PMP/exception checking but does not overwrite the SQ address-valid
      // bit.  Loads always arrive as a single address phase.
      pmp_check_valid[lane] = agu_update_valid[lane] &&
        (agu_update_address_valid[lane] ||
         (agu_update_is_store[lane] &&
          agu_update_store_data_valid[lane])) &&
        !agu_update_exception[lane];
      pmp_access[lane] = agu_update_is_store[lane] ? 3'b010 : 3'b001;
      pmp_privilege[lane] = current_privilege_i;
      agu_effective_exception[lane] = agu_update_exception[lane] ||
        (pmp_check_valid[lane] && !pmp_allow[lane]);
      agu_effective_cause[lane] = agu_update_cause[lane];
      agu_effective_tval[lane] = agu_update_tval[lane];
      if (!agu_update_exception[lane] && pmp_check_valid[lane] &&
          !pmp_allow[lane]) begin
        agu_effective_cause[lane] = agu_update_is_store[lane] ?
          EXC_STORE_ACCESS_FAULT : EXC_LOAD_ACCESS_FAULT;
        agu_effective_tval[lane] = XLEN'(pmp_fault_address[lane]);
      end
      // A store address-only phase updates ordering state but cannot complete
      // the ROB entry.  Completion waits for store data (and repeats any
      // address/PMP exception) so commit always sees a fully formed SQ entry.
      agu_completion_needed[lane] = agu_update_is_store[lane] ?
        agu_update_store_data_valid[lane] : agu_effective_exception[lane];
      agu_device[lane] = is_device_address(agu_update_address[lane]);
      agu_to_lsq_valid[lane] = agu_update_valid[lane] &&
        !flush_valid_i &&
        (!agu_completion_needed[lane] || completion_ready_i[lane]);
      agu_update_ready[lane] = !flush_valid_i && agu_lsq_ready[lane] &&
        (!agu_completion_needed[lane] || completion_ready_i[lane]);
    end
  end

  always_comb begin
    load_commit_valid = '0;
    store_commit_valid = '0;
    if (!flush_valid_i && commit_valid_i[0] && commit_is_load_i[0])
      load_commit_valid[0] = 1'b1;
    if (!flush_valid_i && commit_valid_i[0] && commit_is_store_i[0])
      store_commit_valid[0] = 1'b1;

    commit_ready_o = {2{!flush_valid_i}};
    if (commit_valid_i[0] && commit_is_load_i[0])
      commit_ready_o[0] = load_commit_ready[0];
    else if (commit_valid_i[0] && commit_is_store_i[0])
      commit_ready_o[0] = store_commit_ready[0];
    // A memory operation in slot 1 waits one cycle and becomes the head. This
    // keeps SQ/LQ release and store visibility single-copy atomic.
    if (commit_valid_i[1] && (commit_is_load_i[1] || commit_is_store_i[1]))
      commit_ready_o[1] = 1'b0;
    if (!commit_ready_o[0])
      commit_ready_o[1] = 1'b0;
  end

  rv_lsq #(
    .PADDR_WIDTH(PADDR_WIDTH), .DATA_WIDTH(MEM_DATA_WIDTH),
    .LQ_ENTRIES(LQ_ENTRIES), .SQ_ENTRIES(SQ_ENTRIES),
    .SEQ_WIDTH(ROB_SEQ_WIDTH), .PHYS_TAG_WIDTH(PHYS_TAG_WIDTH)
  ) u_lsq (
    .clk_i, .rst_ni, .dispatch_valid_i,
    .dispatch_accept_i, .dispatch_ready_o,
    .dispatch_is_load_i, .dispatch_is_store_i, .dispatch_sequence_i,
    .dispatch_destination_valid_i, .dispatch_destination_phys_i,
    .dispatch_size_i, .dispatch_unsigned_i, .dispatch_device_i('0),
    .dispatch_lq_valid_o, .dispatch_lq_index_o,
    .dispatch_sq_valid_o, .dispatch_sq_index_o,
    .agu_valid_i(agu_to_lsq_valid), .agu_ready_o(agu_lsq_ready),
    .agu_sequence_i(agu_update_sequence),
    .agu_lq_valid_i(agu_update_lq_valid), .agu_lq_index_i(agu_update_lq_index),
    .agu_sq_valid_i(agu_update_sq_valid), .agu_sq_index_i(agu_update_sq_index),
    .agu_address_i(agu_update_address), .agu_mask_i(agu_update_mask),
    .agu_store_data_i(agu_update_store_data),
    .agu_address_valid_i(agu_update_address_valid),
    .agu_store_data_valid_i(agu_update_store_data_valid),
    .agu_device_i(agu_device), .agu_exception_valid_i(agu_effective_exception),
    .agu_exception_cause_i(agu_effective_cause),
    .load_candidate_present_o(load_candidate_present),
    .load_candidate_valid_o(load_candidate_valid),
    .load_candidate_ready_i(load_candidate_ready),
    .load_candidate_index_o(load_candidate_index),
    .load_candidate_sequence_o(load_candidate_sequence),
    .load_candidate_address_o(load_candidate_address),
    .load_candidate_mask_o(load_candidate_mask),
    .load_candidate_size_o(load_candidate_size),
    .load_candidate_unsigned_o(load_candidate_unsigned),
    .load_candidate_device_o(load_candidate_device),
    .load_destination_valid_o(load_destination_valid),
    .load_destination_phys_o(load_destination_phys),
    .load_memory_read_o(load_memory_read),
    .load_forward_valid_o(load_forward_valid),
    .load_forward_data_o(load_forward_data),
    .load_stall_reason_o(load_stall_reason), .device_load_permit_i(device_load_permit),
    .sb_query_valid_o(sb_query_valid), .sb_query_address_o(sb_query_address),
    .sb_query_mask_o(sb_query_mask), .sb_query_full_cover_i(sb_query_full_cover),
    .sb_query_partial_i(sb_query_partial), .sb_query_data_i(sb_query_data),
    .load_response_valid_i(lsq_load_response_valid),
    .load_response_index_i(lsq_load_response_index),
    .load_response_replay_i(lsq_load_response_replay),
    .load_commit_valid_i(load_commit_valid), .load_commit_ready_o(load_commit_ready),
    .load_commit_sequence_i(commit_sequence_i),
    .load_commit_index_i(commit_lq_index_i),
    .store_commit_valid_i(store_commit_valid),
    .store_commit_ready_o(store_commit_ready),
    .store_commit_error_o(store_commit_error),
    .store_commit_sequence_i(commit_sequence_i),
    .store_commit_index_i(commit_sq_index_i),
    .sb_enq_valid_o(sb_enq_valid), .sb_enq_ready_i(sb_enq_ready),
    .sb_enq_sequence_o(sb_enq_sequence), .sb_enq_address_o(sb_enq_address),
    .sb_enq_data_o(sb_enq_data), .sb_enq_mask_o(sb_enq_mask),
    .sb_enq_size_o(sb_enq_size), .sb_enq_device_o(sb_enq_device),
    .direct_store_valid_o(direct_store_valid),
    .direct_store_complete_i(direct_store_complete),
    .direct_store_error_i(direct_store_error),
    .direct_store_sequence_o(direct_store_sequence),
    .direct_store_address_o(direct_store_address),
    .direct_store_data_o(direct_store_data),
    .direct_store_mask_o(direct_store_mask),
    .direct_store_size_o(direct_store_size),
    .flush_valid_i, .flush_all_i, .flush_sequence_i,
    .lq_count_o(lq_count), .sq_count_o(sq_count),
    .load_outstanding_o(load_outstanding)
  );

  logic [1:0] sb_drain_valid, sb_drain_ready;
  logic [1:0][SB_INDEX_WIDTH-1:0] sb_drain_index;
  logic [1:0][ROB_SEQ_WIDTH-1:0] sb_drain_sequence;
  logic [1:0][PADDR_WIDTH-1:0] sb_drain_address;
  logic [1:0][MEM_DATA_WIDTH-1:0] sb_drain_data;
  logic [1:0][MEM_BYTES-1:0] sb_drain_mask;
  logic [1:0][2:0] sb_drain_size;
  logic [1:0] sb_drain_device;
  logic [1:0] sb_rsp_valid;
  logic [1:0][SB_INDEX_WIDTH-1:0] sb_rsp_index;
  logic [1:0][1:0] sb_rsp_resp;

  rv_store_buffer #(
    .PADDR_WIDTH(PADDR_WIDTH), .DATA_WIDTH(MEM_DATA_WIDTH),
    .ENTRIES(STORE_BUFFER_ENTRIES), .SEQ_WIDTH(ROB_SEQ_WIDTH)
  ) u_store_buffer (
    .clk_i, .rst_ni, .enq_valid_i(sb_enq_valid), .enq_ready_o(sb_enq_ready),
    .enq_sequence_i(sb_enq_sequence), .enq_address_i(sb_enq_address),
    .enq_data_i(sb_enq_data), .enq_mask_i(sb_enq_mask),
    .enq_size_i(sb_enq_size), .enq_device_i(sb_enq_device),
    .drain_valid_o(sb_drain_valid), .drain_ready_i(sb_drain_ready),
    .drain_index_o(sb_drain_index), .drain_sequence_o(sb_drain_sequence),
    .drain_address_o(sb_drain_address), .drain_data_o(sb_drain_data),
    .drain_mask_o(sb_drain_mask), .drain_size_o(sb_drain_size),
    .drain_device_o(sb_drain_device), .drain_rsp_valid_i(sb_rsp_valid),
    .drain_rsp_ready_o(), .drain_rsp_index_i(sb_rsp_index),
    .drain_rsp_resp_i(sb_rsp_resp), .query_valid_i(sb_query_valid),
    .query_address_i(sb_query_address), .query_mask_i(sb_query_mask),
    .query_full_cover_o(sb_query_full_cover),
    .query_partial_o(sb_query_partial), .query_data_o(sb_query_data),
    .query_index_o(), .empty_o(store_buffer_empty_o), .full_o(), .count_o(),
    .head_sequence_o(), .device_pending_o(),
    .machine_check_o(store_machine_check_o)
  );

  logic direct_pending_q, direct_failed_q;
  logic [ROB_SEQ_WIDTH-1:0] direct_sequence_q;
  logic [PADDR_WIDTH-1:0] direct_address_q;
  logic direct_request_selected;
  logic [1:0] load_request_selected;
  logic [1:0] response_is_load, response_is_sb, response_is_direct;
  logic [1:0][LQ_INDEX_WIDTH-1:0] response_lq_index;

  always_comb begin
    for (int unsigned lane = 0; lane < 2; lane++) begin
      response_is_load[lane] = !dmem_rsp_id_i[lane][5];
      response_is_sb[lane] = dmem_rsp_id_i[lane][5:4] == 2'b10;
      response_is_direct[lane] = dmem_rsp_id_i[lane][5:4] == 2'b11;
      response_lq_index[lane] =
        LQ_INDEX_WIDTH'(dmem_rsp_id_i[lane][4:0]);
      device_load_permit[lane] = rob_head_valid_i &&
        (load_candidate_sequence[lane] == rob_head_sequence_i) &&
        store_buffer_empty_o && !load_outstanding && !direct_pending_q;
    end
  end

  // Completion source 0/1: stores and AGU-detected alignment exceptions.
  // Completion source 2/3: forwarded or returned loads. Source 4 carries a
  // precise device-store access fault discovered while commit is waiting.
  always_comb begin
    completion_valid_o = '0;
    completion_sequence_o = '0;
    completion_destination_valid_o = '0;
    completion_destination_class_o = '{default: REG_NONE};
    completion_destination_phys_o = '0;
    completion_data_o = '0;
    completion_exception_valid_o = '0;
    completion_exception_cause_o = '{default: EXC_ILLEGAL_INSTRUCTION};
    completion_exception_tval_o = '0;

    for (int unsigned lane = 0; lane < 2; lane++) begin
      completion_valid_o[lane] = agu_update_valid[lane] &&
        agu_lsq_ready[lane] && !flush_valid_i && agu_completion_needed[lane];
      completion_sequence_o[lane] = agu_update_sequence[lane];
      completion_exception_valid_o[lane] = agu_effective_exception[lane];
      completion_exception_cause_o[lane] = agu_effective_cause[lane];
      completion_exception_tval_o[lane] = agu_effective_tval[lane];

      if (dmem_rsp_valid_i[lane] && response_is_load[lane] &&
          (dmem_rsp_replay_i[lane] == 0)) begin
        completion_valid_o[2+lane] = 1'b1;
        completion_sequence_o[2+lane] =
          load_meta_sequence_q[response_lq_index[lane]];
        completion_destination_valid_o[2+lane] =
          load_meta_destination_valid_q[response_lq_index[lane]];
        completion_destination_class_o[2+lane] =
          load_meta_class_q[response_lq_index[lane]];
        completion_destination_phys_o[2+lane] =
          load_meta_destination_phys_q[response_lq_index[lane]];
        completion_data_o[2+lane] = format_load_data(
          dmem_rsp_rdata_i[lane],
          load_meta_address_q[response_lq_index[lane]],
          load_meta_size_q[response_lq_index[lane]],
          load_meta_unsigned_q[response_lq_index[lane]]);
        completion_exception_valid_o[2+lane] =
          dmem_rsp_resp_i[lane] != MEM_RSP_OKAY;
        completion_exception_cause_o[2+lane] = EXC_LOAD_ACCESS_FAULT;
        completion_exception_tval_o[2+lane] =
          XLEN'(load_meta_address_q[response_lq_index[lane]]);
      end else if (load_candidate_valid[lane] &&
                   load_forward_valid[lane]) begin
        completion_valid_o[2+lane] = 1'b1;
        completion_sequence_o[2+lane] = load_candidate_sequence[lane];
        completion_destination_valid_o[2+lane] = load_destination_valid[lane];
        completion_destination_class_o[2+lane] =
          lq_destination_class_q[load_candidate_index[lane]];
        completion_destination_phys_o[2+lane] = load_destination_phys[lane];
        completion_data_o[2+lane] = format_load_data(
          load_forward_data[lane], load_candidate_address[lane],
          load_candidate_size[lane], load_candidate_unsigned[lane]);
      end
    end

    completion_valid_o[4] = dmem_rsp_valid_i[0] && response_is_direct[0] &&
                            (dmem_rsp_resp_i[0] != MEM_RSP_OKAY);
    completion_sequence_o[4] = direct_sequence_q;
    completion_exception_valid_o[4] = completion_valid_o[4];
    completion_exception_cause_o[4] = EXC_STORE_ACCESS_FAULT;
    completion_exception_tval_o[4] = XLEN'(direct_address_q);
  end

  // Request arbitration per physical LSU port. Committed stores have priority
  // over speculative loads; only port 0 carries the serialized device store.
  always_comb begin
    dmem_req_valid_o = '0;
    dmem_req_id_o = '0;
    dmem_req_write_o = '0;
    dmem_req_addr_o = '0;
    dmem_req_size_o = '0;
    dmem_req_wdata_o = '0;
    dmem_req_wstrb_o = '0;
    dmem_req_priv_o = '{default: current_privilege_i};
    dmem_req_rob_seq_o = '0;
    dmem_req_committed_o = '0;
    dmem_req_device_o = '0;
    sb_drain_ready = '0;
    load_candidate_ready = '0;
    load_request_selected = '0;
    direct_request_selected = 1'b0;

    for (int unsigned lane = 0; lane < 2; lane++) begin
      if ((lane == 0) && direct_store_valid[0] && !direct_pending_q &&
          !direct_failed_q) begin
        direct_request_selected = 1'b1;
        dmem_req_valid_o[lane] = 1'b1;
        dmem_req_id_o[lane] = 6'b11_0000;
        dmem_req_write_o[lane] = 1'b1;
        dmem_req_addr_o[lane] = direct_store_address[0];
        dmem_req_size_o[lane] = direct_store_size[0];
        dmem_req_wdata_o[lane] = direct_store_data[0];
        dmem_req_wstrb_o[lane] = direct_store_mask[0];
        dmem_req_rob_seq_o[lane] = direct_store_sequence[0];
        dmem_req_committed_o[lane] = 1'b1;
        dmem_req_device_o[lane] = 1'b1;
      end else if (sb_drain_valid[lane]) begin
        dmem_req_valid_o[lane] = 1'b1;
        dmem_req_id_o[lane] = {2'b10, 4'(sb_drain_index[lane])};
        dmem_req_write_o[lane] = 1'b1;
        dmem_req_addr_o[lane] = sb_drain_address[lane];
        dmem_req_size_o[lane] = sb_drain_size[lane];
        dmem_req_wdata_o[lane] = sb_drain_data[lane];
        dmem_req_wstrb_o[lane] = sb_drain_mask[lane];
        dmem_req_rob_seq_o[lane] = sb_drain_sequence[lane];
        dmem_req_committed_o[lane] = 1'b1;
        dmem_req_device_o[lane] = sb_drain_device[lane];
        sb_drain_ready[lane] = dmem_req_ready_i[lane];
      // A recovery invalidates younger LQ entries on this edge.  Do not let a
      // candidate from the pre-flush combinational view launch a request in
      // the same cycle: its later response could otherwise alias a reused LQ
      // index and complete the wrong ROB sequence.
      end else if (!flush_valid_i && load_candidate_valid[lane] &&
                   load_memory_read[lane]) begin
        load_request_selected[lane] = 1'b1;
        dmem_req_valid_o[lane] = 1'b1;
        dmem_req_id_o[lane] = {1'b0, 5'(load_candidate_index[lane])};
        dmem_req_addr_o[lane] = load_candidate_address[lane];
        dmem_req_size_o[lane] = load_candidate_size[lane];
        dmem_req_rob_seq_o[lane] = load_candidate_sequence[lane];
        dmem_req_device_o[lane] = load_candidate_device[lane];
        load_candidate_ready[lane] = dmem_req_ready_i[lane];
      end

      if (!flush_valid_i && load_candidate_valid[lane] &&
          load_forward_valid[lane] &&
          !(dmem_rsp_valid_i[lane] && response_is_load[lane]))
        load_candidate_ready[lane] = completion_ready_i[2+lane];
    end
  end

  // A fence at the ROB head has no older LQ/SQ entry left.  Younger memory
  // operations may already own queue entries but are held behind the
  // serializing barrier, so only accepted/outstanding traffic and committed
  // stores participate in the drain condition.
  assign memory_idle_o = store_buffer_empty_o && !load_outstanding &&
                         !direct_pending_q && !direct_failed_q;

  always_comb begin
    dmem_rsp_ready_o = '0;
    lsq_load_response_valid = '0;
    lsq_load_response_index = '0;
    lsq_load_response_replay = '0;
    sb_rsp_valid = '0;
    sb_rsp_index = '0;
    sb_rsp_resp = '0;
    direct_store_complete = '0;
    direct_store_error = '0;

    for (int unsigned lane = 0; lane < 2; lane++) begin
      if (dmem_rsp_valid_i[lane] && response_is_load[lane]) begin
        dmem_rsp_ready_o[lane] = (dmem_rsp_replay_i[lane] != 0) ?
          1'b1 : completion_ready_i[2+lane];
        if (dmem_rsp_ready_o[lane]) begin
          lsq_load_response_valid[lane] = 1'b1;
          lsq_load_response_index[lane] = response_lq_index[lane];
          lsq_load_response_replay[lane] = dmem_rsp_replay_i[lane] != 0;
        end
      end else if (dmem_rsp_valid_i[lane] && response_is_sb[lane]) begin
        dmem_rsp_ready_o[lane] = 1'b1;
        sb_rsp_valid[lane] = 1'b1;
        sb_rsp_index[lane] = SB_INDEX_WIDTH'(dmem_rsp_id_i[lane][3:0]);
        sb_rsp_resp[lane] = dmem_rsp_resp_i[lane];
      end else if (dmem_rsp_valid_i[lane] && response_is_direct[lane]) begin
        dmem_rsp_ready_o[lane] = (dmem_rsp_resp_i[lane] == MEM_RSP_OKAY) ?
          1'b1 : completion_ready_i[4];
        direct_store_complete[0] = 1'b1;
        direct_store_error[0] = dmem_rsp_resp_i[lane] != MEM_RSP_OKAY;
      end else begin
        dmem_rsp_ready_o[lane] = 1'b1;
      end
    end
  end

  always_ff @(posedge clk_i) begin
    if (!rst_ni) begin
      direct_pending_q <= 1'b0;
      direct_failed_q <= 1'b0;
      direct_sequence_q <= '0;
      direct_address_q <= '0;
      for (int unsigned entry = 0; entry < LQ_ENTRIES; entry++) begin
        lq_destination_class_q[entry] <= REG_NONE;
        load_meta_sequence_q[entry] <= '0;
        load_meta_class_q[entry] <= REG_NONE;
        load_meta_destination_valid_q[entry] <= 1'b0;
        load_meta_destination_phys_q[entry] <= '0;
        load_meta_address_q[entry] <= '0;
        load_meta_size_q[entry] <= '0;
        load_meta_unsigned_q[entry] <= 1'b0;
      end
    end else begin
      // A direct device store is issued only when its store owns the ROB
      // head.  A younger branch recovery must therefore leave the accepted
      // transaction alive; dropping it would allow the same MMIO write to be
      // issued twice after recovery.  Full recovery, or a boundary older than
      // the tracked request, is allowed to kill it.
      if (flush_valid_i &&
          (flush_all_i ||
           (direct_pending_q &&
            sequence_after(direct_sequence_q, flush_sequence_i)))) begin
        direct_pending_q <= 1'b0;
        direct_failed_q <= 1'b0;
      end else begin
        if (direct_request_selected && dmem_req_ready_i[0]) begin
          direct_pending_q <= 1'b1;
          direct_sequence_q <= direct_store_sequence[0];
          direct_address_q <= direct_store_address[0];
        end
        if (dmem_rsp_valid_i[0] && dmem_rsp_ready_o[0] &&
            response_is_direct[0]) begin
          direct_pending_q <= 1'b0;
          if (dmem_rsp_resp_i[0] != MEM_RSP_OKAY)
            direct_failed_q <= 1'b1;
        end
      end

      for (int unsigned lane = 0; lane < 2; lane++) begin
        if (dispatch_lq_valid_o[lane])
          lq_destination_class_q[dispatch_lq_index_o[lane]] <=
            dispatch_destination_class_i[lane];
        if (load_request_selected[lane] && dmem_req_ready_i[lane]) begin
          load_meta_sequence_q[load_candidate_index[lane]] <=
            load_candidate_sequence[lane];
          load_meta_class_q[load_candidate_index[lane]] <=
            lq_destination_class_q[load_candidate_index[lane]];
          load_meta_destination_valid_q[load_candidate_index[lane]] <=
            load_destination_valid[lane];
          load_meta_destination_phys_q[load_candidate_index[lane]] <=
            load_destination_phys[lane];
          load_meta_address_q[load_candidate_index[lane]] <=
            load_candidate_address[lane];
          load_meta_size_q[load_candidate_index[lane]] <=
            load_candidate_size[lane];
          load_meta_unsigned_q[load_candidate_index[lane]] <=
            load_candidate_unsigned[lane];
        end
      end
    end
  end

`ifndef SYNTHESIS
  always_comb begin
    for (int unsigned lane = 0; lane < 2; lane++) begin
      if (dmem_req_valid_o[lane] && dmem_req_write_o[lane])
        assert (dmem_req_committed_o[lane]);
      if (flush_valid_i)
        assert (!(dmem_req_valid_o[lane] && !dmem_req_write_o[lane]));
      assert (!(load_forward_valid[lane] && load_memory_read[lane]));
      if (agu_update_valid[lane] && agu_update_is_store[lane] &&
          agu_update_address_valid[lane] &&
          !agu_update_store_data_valid[lane])
        assert (!completion_valid_o[lane]);
      if (completion_valid_o[lane] && agu_update_is_store[lane])
        assert (agu_update_store_data_valid[lane]);
    end
    if (memory_idle_o)
      assert (store_buffer_empty_o && !load_outstanding &&
              !direct_pending_q && !direct_failed_q);
  end
`endif

  initial begin
    if ((XLEN != 32) && (XLEN != 64))
      $fatal(1, "LSU cluster XLEN must be 32 or 64");
    if ((LQ_ENTRIES > 32) || (STORE_BUFFER_ENTRIES > 16))
      $fatal(1, "LSU response ID encoding supports LQ<=32 and SB<=16");
    if ((PADDR_WIDTH < 4) || (PMP_ENTRIES == 0))
      $fatal(1, "LSU PMP configuration is invalid");
    if ((MEM_DATA_WIDTH < XLEN) || ((MEM_DATA_WIDTH % 8) != 0))
      $fatal(1, "LSU memory beat must cover XLEN");
  end
endmodule
