module rv_perf_profiler #(
  parameter int unsigned ROB_ENTRIES = 48,
  parameter int unsigned IQ_ENTRIES  = 56,
  parameter int unsigned LQ_ENTRIES  = 24,
  parameter int unsigned SQ_ENTRIES  = 16
) (
  input logic clk_i,
  input logic rst_ni,
  input logic start_i,
  input logic stop_i,

  input logic [1:0] fetch_valid_i,
  input logic [1:0] fetch_ready_i,
  input logic       imem_req_valid_i,
  input logic       imem_req_ready_i,
  input logic       imem_rsp_valid_i,
  input logic       imem_rsp_ready_i,
  input logic       frontend_redirect_i,
  input logic       predicted_redirect_i,
  input logic       architectural_redirect_i,
  input logic       target_buffer_hit_i,
  input logic       fetch_outstanding_i,
  input logic [6:0] fetch_queue_bytes_i,

  input logic [1:0] decode_valid_i,
  input logic       dispatch_fire_i,
  input logic       dispatch_resources_ready_i,
  input logic       rename_ready_i,
  input logic       branch_ready_i,
  input logic       rob_capacity_i,
  input logic       iq_capacity_i,
  input logic       lsq_ready_i,
  input logic       serial_block_i,

  input logic [1:0] issue_valid_i,
  input logic       iq_empty_i,
  input logic [1:0] retire_valid_i,
  input logic [1:0] retire_ready_i,
  input logic [1:0] retire_fire_i,
  input logic       rob_head_valid_i,
  input logic       rob_head_complete_i,

  input logic       branch_resolve_i,
  input logic       branch_mispredict_i,
  input logic [31:0] branch_instruction_i,
  input logic [1:0]  branch_inst_len_i,
  input logic        branch_predicted_taken_i,
  input logic [31:0] branch_predicted_target_i,
  input logic        branch_actual_taken_i,
  input logic [31:0] branch_actual_target_i,
  input logic       flush_valid_i,

  input logic [1:0] load_candidate_present_i,
  input logic [1:0] load_candidate_valid_i,
  input logic [1:0][2:0] load_stall_reason_i,
  input logic [1:0] dmem_req_valid_i,
  input logic [1:0] dmem_req_ready_i,

  input logic [$clog2(ROB_ENTRIES+1)-1:0] rob_count_i,
  input logic [$clog2(IQ_ENTRIES+1)-1:0]  iq_count_i,
  input logic [$clog2(LQ_ENTRIES+1)-1:0]  lq_count_i,
  input logic [$clog2(SQ_ENTRIES+1)-1:0]  sq_count_i
);
  localparam logic [2:0] LSQ_STALL_UNKNOWN_ADDR    = 3'd1;
  localparam logic [2:0] LSQ_STALL_STORE_DATA     = 3'd2;
  localparam logic [2:0] LSQ_STALL_PARTIAL_OVERLAP= 3'd3;
  localparam logic [2:0] LSQ_STALL_BANK_CONFLICT  = 3'd4;
  localparam logic [2:0] LSQ_STALL_DEVICE_SERIALIZE=3'd5;

  logic active_q;
  string perf_file;
  integer perf_fd;
  longint unsigned cycles_q;
  longint unsigned fetched_q, dispatched_q, issued_q, retired_q;
  longint unsigned fetch_zero_q, fetch_one_q, fetch_two_q;
  longint unsigned dispatch_zero_q, dispatch_one_q, dispatch_two_q;
  longint unsigned issue_zero_q, issue_one_q, issue_two_q;
  longint unsigned retire_zero_q, retire_one_q, retire_two_q;
  longint unsigned frontend_empty_q, frontend_backpressure_q;
  longint unsigned frontend_empty_queue_zero_q, frontend_empty_partial_q;
  longint unsigned frontend_empty_outstanding_q;
  longint unsigned frontend_empty_after_target_hit_q;
  longint unsigned frontend_redirect_q, predicted_redirect_q;
  longint unsigned architectural_redirect_q, target_buffer_hit_q;
  longint unsigned redirect_refill_empty_q;
  longint unsigned imem_requests_q, imem_responses_q, imem_wait_q;
  longint unsigned dispatch_stall_q, rename_stall_q, branch_stall_q;
  longint unsigned rob_stall_q, iq_stall_q, lsq_dispatch_stall_q;
  longint unsigned serial_stall_q;
  longint unsigned iq_no_ready_q, rob_head_wait_q, retire_backpressure_q;
  longint unsigned retire_lane1_blocked_q;
  longint unsigned branch_resolve_q, branch_mispredict_q, flush_q;
  longint unsigned conditional_resolve_q, conditional_mispredict_q;
  longint unsigned direct_resolve_q, direct_mispredict_q;
  longint unsigned indirect_resolve_q, indirect_mispredict_q;
  longint unsigned call_resolve_q, call_mispredict_q;
  longint unsigned return_resolve_q, return_mispredict_q;
  longint unsigned branch_direction_mispredict_q;
  longint unsigned branch_target_mispredict_q;
  longint unsigned load_unknown_addr_q, load_store_data_q;
  longint unsigned load_partial_q, load_bank_q, load_device_q;
  longint unsigned dmem_wait_q;
  longint unsigned rob_occupancy_sum_q, iq_occupancy_sum_q;
  longint unsigned lq_occupancy_sum_q, sq_occupancy_sum_q;
  longint unsigned rob_occupancy_max_q, iq_occupancy_max_q;
  longint unsigned lq_occupancy_max_q, sq_occupancy_max_q;
  logic redirect_refill_q, target_hit_refill_q;

  function automatic int unsigned pop2(input logic [1:0] value);
    return value[0] + value[1];
  endfunction

  function automatic logic is_conditional_branch(
    input logic [31:0] instruction,
    input logic [1:0] length
  );
    if (length == 2'd1)
      return (instruction[1:0] == 2'b01) &&
             ((instruction[15:13] == 3'b110) ||
              (instruction[15:13] == 3'b111));
    return instruction[6:0] == 7'b1100011;
  endfunction

  function automatic logic is_direct_jump(
    input logic [31:0] instruction,
    input logic [1:0] length
  );
    if (length == 2'd1)
      return (instruction[1:0] == 2'b01) &&
             ((instruction[15:13] == 3'b101) ||
              (instruction[15:13] == 3'b001));
    return instruction[6:0] == 7'b1101111;
  endfunction

  function automatic logic is_indirect_jump(
    input logic [31:0] instruction,
    input logic [1:0] length
  );
    if (length == 2'd1)
      return (instruction[1:0] == 2'b10) &&
             ((instruction[15:12] == 4'b1000) ||
              (instruction[15:12] == 4'b1001)) &&
             (instruction[6:2] == 0) && (instruction[11:7] != 0);
    return (instruction[6:0] == 7'b1100111) &&
           (instruction[14:12] == 0);
  endfunction

  function automatic logic is_call_instruction(
    input logic [31:0] instruction,
    input logic [1:0] length
  );
    logic [4:0] destination;
    if (length == 2'd1)
      return ((instruction[1:0] == 2'b01) &&
              (instruction[15:13] == 3'b001)) ||
             ((instruction[1:0] == 2'b10) &&
              (instruction[15:12] == 4'b1001) &&
              (instruction[6:2] == 0) && (instruction[11:7] != 0));
    destination = instruction[11:7];
    return ((instruction[6:0] == 7'b1101111) ||
            (instruction[6:0] == 7'b1100111)) &&
           ((destination == 5'd1) || (destination == 5'd5));
  endfunction

  function automatic logic is_return_instruction(
    input logic [31:0] instruction,
    input logic [1:0] length
  );
    logic [4:0] source;
    if (length == 2'd1)
      return (instruction[1:0] == 2'b10) &&
             (instruction[15:12] == 4'b1000) &&
             (instruction[6:2] == 0) &&
             ((instruction[11:7] == 5'd1) ||
              (instruction[11:7] == 5'd5));
    source = instruction[19:15];
    return (instruction[6:0] == 7'b1100111) &&
           (instruction[14:12] == 0) &&
           (instruction[11:7] == 0) &&
           ((source == 5'd1) || (source == 5'd5)) &&
           (instruction[31:20] == 0);
  endfunction

  task automatic clear_counters;
    cycles_q = 0;
    fetched_q = 0; dispatched_q = 0; issued_q = 0; retired_q = 0;
    fetch_zero_q = 0; fetch_one_q = 0; fetch_two_q = 0;
    dispatch_zero_q = 0; dispatch_one_q = 0; dispatch_two_q = 0;
    issue_zero_q = 0; issue_one_q = 0; issue_two_q = 0;
    retire_zero_q = 0; retire_one_q = 0; retire_two_q = 0;
    frontend_empty_q = 0; frontend_backpressure_q = 0;
    frontend_empty_queue_zero_q = 0; frontend_empty_partial_q = 0;
    frontend_empty_outstanding_q = 0;
    frontend_empty_after_target_hit_q = 0;
    frontend_redirect_q = 0; predicted_redirect_q = 0;
    architectural_redirect_q = 0; target_buffer_hit_q = 0;
    redirect_refill_empty_q = 0; redirect_refill_q = 1'b0;
    target_hit_refill_q = 1'b0;
    imem_requests_q = 0; imem_responses_q = 0; imem_wait_q = 0;
    dispatch_stall_q = 0; rename_stall_q = 0; branch_stall_q = 0;
    rob_stall_q = 0; iq_stall_q = 0; lsq_dispatch_stall_q = 0;
    serial_stall_q = 0; iq_no_ready_q = 0; rob_head_wait_q = 0;
    retire_backpressure_q = 0;
    retire_lane1_blocked_q = 0;
    branch_resolve_q = 0; branch_mispredict_q = 0; flush_q = 0;
    conditional_resolve_q = 0; conditional_mispredict_q = 0;
    direct_resolve_q = 0; direct_mispredict_q = 0;
    indirect_resolve_q = 0; indirect_mispredict_q = 0;
    call_resolve_q = 0; call_mispredict_q = 0;
    return_resolve_q = 0; return_mispredict_q = 0;
    branch_direction_mispredict_q = 0;
    branch_target_mispredict_q = 0;
    load_unknown_addr_q = 0; load_store_data_q = 0;
    load_partial_q = 0; load_bank_q = 0; load_device_q = 0;
    dmem_wait_q = 0;
    rob_occupancy_sum_q = 0; iq_occupancy_sum_q = 0;
    lq_occupancy_sum_q = 0; sq_occupancy_sum_q = 0;
    rob_occupancy_max_q = 0; iq_occupancy_max_q = 0;
    lq_occupancy_max_q = 0; sq_occupancy_max_q = 0;
  endtask

  task automatic write_profile;
    perf_fd = $fopen(perf_file, "w");
    if (perf_fd == 0) begin
      $error("Unable to open performance profile %s", perf_file);
    end else begin
      $fwrite(perf_fd, "{\n");
      $fwrite(perf_fd, "  \"profile_cycles\": %0d,\n", cycles_q);
      $fwrite(perf_fd, "  \"fetched_instructions\": %0d,\n", fetched_q);
      $fwrite(perf_fd, "  \"dispatched_instructions\": %0d,\n", dispatched_q);
      $fwrite(perf_fd, "  \"issued_instructions\": %0d,\n", issued_q);
      $fwrite(perf_fd, "  \"retired_instructions\": %0d,\n", retired_q);
      $fwrite(perf_fd, "  \"fetch_cycles_0_1_2\": [%0d, %0d, %0d],\n", fetch_zero_q, fetch_one_q, fetch_two_q);
      $fwrite(perf_fd, "  \"dispatch_cycles_0_1_2\": [%0d, %0d, %0d],\n", dispatch_zero_q, dispatch_one_q, dispatch_two_q);
      $fwrite(perf_fd, "  \"issue_cycles_0_1_2\": [%0d, %0d, %0d],\n", issue_zero_q, issue_one_q, issue_two_q);
      $fwrite(perf_fd, "  \"retire_cycles_0_1_2\": [%0d, %0d, %0d],\n", retire_zero_q, retire_one_q, retire_two_q);
      $fwrite(perf_fd, "  \"frontend_empty_cycles\": %0d,\n", frontend_empty_q);
      $fwrite(perf_fd, "  \"frontend_empty_queue_zero_cycles\": %0d,\n", frontend_empty_queue_zero_q);
      $fwrite(perf_fd, "  \"frontend_empty_partial_instruction_cycles\": %0d,\n", frontend_empty_partial_q);
      $fwrite(perf_fd, "  \"frontend_empty_with_fetch_outstanding_cycles\": %0d,\n", frontend_empty_outstanding_q);
      // Kept as a compatibility field for pre-v1.12.1 profiles.  The replay
      // register no longer exists, so this value is structurally zero.
      $fwrite(perf_fd, "  \"frontend_empty_with_target_replay_cycles\": 0,\n");
      $fwrite(perf_fd, "  \"frontend_empty_after_target_hit_cycles\": %0d,\n", frontend_empty_after_target_hit_q);
      $fwrite(perf_fd, "  \"frontend_redirects\": %0d,\n", frontend_redirect_q);
      $fwrite(perf_fd, "  \"predicted_redirects\": %0d,\n", predicted_redirect_q);
      $fwrite(perf_fd, "  \"architectural_redirects\": %0d,\n", architectural_redirect_q);
      $fwrite(perf_fd, "  \"target_buffer_hits\": %0d,\n", target_buffer_hit_q);
      $fwrite(perf_fd, "  \"redirect_refill_empty_cycles\": %0d,\n", redirect_refill_empty_q);
      $fwrite(perf_fd, "  \"frontend_backpressure_cycles\": %0d,\n", frontend_backpressure_q);
      $fwrite(perf_fd, "  \"imem_requests\": %0d,\n", imem_requests_q);
      $fwrite(perf_fd, "  \"imem_responses\": %0d,\n", imem_responses_q);
      $fwrite(perf_fd, "  \"imem_request_wait_cycles\": %0d,\n", imem_wait_q);
      $fwrite(perf_fd, "  \"dispatch_stall_cycles\": %0d,\n", dispatch_stall_q);
      $fwrite(perf_fd, "  \"rename_stall_cycles\": %0d,\n", rename_stall_q);
      $fwrite(perf_fd, "  \"branch_checkpoint_stall_cycles\": %0d,\n", branch_stall_q);
      $fwrite(perf_fd, "  \"rob_capacity_stall_cycles\": %0d,\n", rob_stall_q);
      $fwrite(perf_fd, "  \"iq_capacity_stall_cycles\": %0d,\n", iq_stall_q);
      $fwrite(perf_fd, "  \"lsq_dispatch_stall_cycles\": %0d,\n", lsq_dispatch_stall_q);
      $fwrite(perf_fd, "  \"serializing_stall_cycles\": %0d,\n", serial_stall_q);
      $fwrite(perf_fd, "  \"iq_nonempty_no_issue_cycles\": %0d,\n", iq_no_ready_q);
      $fwrite(perf_fd, "  \"rob_head_incomplete_cycles\": %0d,\n", rob_head_wait_q);
      $fwrite(perf_fd, "  \"retire_backpressure_cycles\": %0d,\n", retire_backpressure_q);
      $fwrite(perf_fd, "  \"retire_lane1_blocked_cycles\": %0d,\n", retire_lane1_blocked_q);
      $fwrite(perf_fd, "  \"branch_resolutions\": %0d,\n", branch_resolve_q);
      $fwrite(perf_fd, "  \"branch_mispredicts\": %0d,\n", branch_mispredict_q);
      $fwrite(perf_fd, "  \"conditional_branch_resolutions\": %0d,\n", conditional_resolve_q);
      $fwrite(perf_fd, "  \"conditional_branch_mispredicts\": %0d,\n", conditional_mispredict_q);
      $fwrite(perf_fd, "  \"direct_jump_resolutions\": %0d,\n", direct_resolve_q);
      $fwrite(perf_fd, "  \"direct_jump_mispredicts\": %0d,\n", direct_mispredict_q);
      $fwrite(perf_fd, "  \"indirect_jump_resolutions\": %0d,\n", indirect_resolve_q);
      $fwrite(perf_fd, "  \"indirect_jump_mispredicts\": %0d,\n", indirect_mispredict_q);
      $fwrite(perf_fd, "  \"call_resolutions\": %0d,\n", call_resolve_q);
      $fwrite(perf_fd, "  \"call_mispredicts\": %0d,\n", call_mispredict_q);
      $fwrite(perf_fd, "  \"return_resolutions\": %0d,\n", return_resolve_q);
      $fwrite(perf_fd, "  \"return_mispredicts\": %0d,\n", return_mispredict_q);
      $fwrite(perf_fd, "  \"branch_direction_mispredicts\": %0d,\n", branch_direction_mispredict_q);
      $fwrite(perf_fd, "  \"branch_target_mispredicts\": %0d,\n", branch_target_mispredict_q);
      $fwrite(perf_fd, "  \"flush_cycles\": %0d,\n", flush_q);
      $fwrite(perf_fd, "  \"load_stall_unknown_store_address\": %0d,\n", load_unknown_addr_q);
      $fwrite(perf_fd, "  \"load_stall_store_data\": %0d,\n", load_store_data_q);
      $fwrite(perf_fd, "  \"load_stall_partial_overlap\": %0d,\n", load_partial_q);
      $fwrite(perf_fd, "  \"load_stall_bank_conflict\": %0d,\n", load_bank_q);
      $fwrite(perf_fd, "  \"load_stall_device_serialize\": %0d,\n", load_device_q);
      $fwrite(perf_fd, "  \"dmem_request_wait_cycles\": %0d,\n", dmem_wait_q);
      $fwrite(perf_fd, "  \"rob_occupancy_sum\": %0d,\n", rob_occupancy_sum_q);
      $fwrite(perf_fd, "  \"iq_occupancy_sum\": %0d,\n", iq_occupancy_sum_q);
      $fwrite(perf_fd, "  \"lq_occupancy_sum\": %0d,\n", lq_occupancy_sum_q);
      $fwrite(perf_fd, "  \"sq_occupancy_sum\": %0d,\n", sq_occupancy_sum_q);
      $fwrite(perf_fd, "  \"rob_occupancy_max\": %0d,\n", rob_occupancy_max_q);
      $fwrite(perf_fd, "  \"iq_occupancy_max\": %0d,\n", iq_occupancy_max_q);
      $fwrite(perf_fd, "  \"lq_occupancy_max\": %0d,\n", lq_occupancy_max_q);
      $fwrite(perf_fd, "  \"sq_occupancy_max\": %0d\n", sq_occupancy_max_q);
      $fwrite(perf_fd, "}\n");
      $fclose(perf_fd);
      $display("PERF profile written: %s cycles=%0d retired=%0d", perf_file, cycles_q, retired_q);
    end
  endtask

  initial begin
    perf_file = "core_perf.json";
    void'($value$plusargs("perf_file=%s", perf_file));
    active_q = 1'b0;
    clear_counters();
  end

  always @(posedge clk_i) begin
    integer unsigned fetch_count, dispatch_count, issue_count, retire_count;
    if (!rst_ni) begin
      active_q = 1'b0;
      clear_counters();
    end else begin
      if (start_i) begin
        clear_counters();
        active_q = 1'b1;
      end else if (stop_i && active_q) begin
        active_q = 1'b0;
        write_profile();
      end else if (active_q) begin
        fetch_count = pop2(fetch_valid_i & fetch_ready_i);
        dispatch_count = dispatch_fire_i ? pop2(decode_valid_i) : 0;
        issue_count = pop2(issue_valid_i);
        retire_count = pop2(retire_fire_i);
        cycles_q = cycles_q + 1;
        fetched_q = fetched_q + fetch_count;
        dispatched_q = dispatched_q + dispatch_count;
        issued_q = issued_q + issue_count;
        retired_q = retired_q + retire_count;
        case (fetch_count) 0: fetch_zero_q=fetch_zero_q+1; 1: fetch_one_q=fetch_one_q+1; default: fetch_two_q=fetch_two_q+1; endcase
        case (dispatch_count) 0: dispatch_zero_q=dispatch_zero_q+1; 1: dispatch_one_q=dispatch_one_q+1; default: dispatch_two_q=dispatch_two_q+1; endcase
        case (issue_count) 0: issue_zero_q=issue_zero_q+1; 1: issue_one_q=issue_one_q+1; default: issue_two_q=issue_two_q+1; endcase
        case (retire_count) 0: retire_zero_q=retire_zero_q+1; 1: retire_one_q=retire_one_q+1; default: retire_two_q=retire_two_q+1; endcase
        if (frontend_redirect_i) begin
          frontend_redirect_q = frontend_redirect_q + 1;
        end
        if (predicted_redirect_i) predicted_redirect_q = predicted_redirect_q + 1;
        if (architectural_redirect_i)
          architectural_redirect_q = architectural_redirect_q + 1;
        if (target_buffer_hit_i) target_buffer_hit_q = target_buffer_hit_q + 1;
        if (!(|fetch_valid_i)) begin
          frontend_empty_q = frontend_empty_q + 1;
          if (fetch_queue_bytes_i == 0)
            frontend_empty_queue_zero_q = frontend_empty_queue_zero_q + 1;
          else
            frontend_empty_partial_q = frontend_empty_partial_q + 1;
          if (fetch_outstanding_i)
            frontend_empty_outstanding_q = frontend_empty_outstanding_q + 1;
          if (target_hit_refill_q)
            frontend_empty_after_target_hit_q =
              frontend_empty_after_target_hit_q + 1;
          if (redirect_refill_q)
            redirect_refill_empty_q = redirect_refill_empty_q + 1;
        end
        if (frontend_redirect_i)
          redirect_refill_q = 1'b1;
        else if (|fetch_valid_i)
          redirect_refill_q = 1'b0;
        target_hit_refill_q = target_buffer_hit_i;
        if ((|fetch_valid_i) && !(|fetch_ready_i)) frontend_backpressure_q = frontend_backpressure_q + 1;
        if (imem_req_valid_i && imem_req_ready_i) imem_requests_q = imem_requests_q + 1;
        if (imem_rsp_valid_i && imem_rsp_ready_i) imem_responses_q = imem_responses_q + 1;
        if (imem_req_valid_i && !imem_req_ready_i) imem_wait_q = imem_wait_q + 1;
        if ((|decode_valid_i) && !dispatch_resources_ready_i) dispatch_stall_q = dispatch_stall_q + 1;
        if ((|decode_valid_i) && !rename_ready_i) rename_stall_q = rename_stall_q + 1;
        if ((|decode_valid_i) && !branch_ready_i) branch_stall_q = branch_stall_q + 1;
        if ((|decode_valid_i) && !rob_capacity_i) rob_stall_q = rob_stall_q + 1;
        if ((|decode_valid_i) && !iq_capacity_i) iq_stall_q = iq_stall_q + 1;
        if ((|decode_valid_i) && !lsq_ready_i) lsq_dispatch_stall_q = lsq_dispatch_stall_q + 1;
        if ((|decode_valid_i) && serial_block_i) serial_stall_q = serial_stall_q + 1;
        if (!iq_empty_i && !(|issue_valid_i)) iq_no_ready_q = iq_no_ready_q + 1;
        if (rob_head_valid_i && !rob_head_complete_i) rob_head_wait_q = rob_head_wait_q + 1;
        if ((|retire_valid_i) && !(|retire_ready_i)) retire_backpressure_q = retire_backpressure_q + 1;
        if (retire_valid_i[1] && retire_fire_i[0] && !retire_fire_i[1])
          retire_lane1_blocked_q = retire_lane1_blocked_q + 1;
        if (branch_resolve_i) begin
          branch_resolve_q = branch_resolve_q + 1;
          if (is_conditional_branch(branch_instruction_i,
                                    branch_inst_len_i)) begin
            conditional_resolve_q = conditional_resolve_q + 1;
            if (branch_mispredict_i)
              conditional_mispredict_q = conditional_mispredict_q + 1;
          end
          if (is_direct_jump(branch_instruction_i, branch_inst_len_i)) begin
            direct_resolve_q = direct_resolve_q + 1;
            if (branch_mispredict_i)
              direct_mispredict_q = direct_mispredict_q + 1;
          end
          if (is_indirect_jump(branch_instruction_i, branch_inst_len_i)) begin
            indirect_resolve_q = indirect_resolve_q + 1;
            if (branch_mispredict_i)
              indirect_mispredict_q = indirect_mispredict_q + 1;
          end
          if (is_call_instruction(branch_instruction_i, branch_inst_len_i)) begin
            call_resolve_q = call_resolve_q + 1;
            if (branch_mispredict_i)
              call_mispredict_q = call_mispredict_q + 1;
          end
          if (is_return_instruction(branch_instruction_i,
                                    branch_inst_len_i)) begin
            return_resolve_q = return_resolve_q + 1;
            if (branch_mispredict_i)
              return_mispredict_q = return_mispredict_q + 1;
          end
          if (branch_mispredict_i) begin
            branch_mispredict_q = branch_mispredict_q + 1;
            if (branch_predicted_taken_i != branch_actual_taken_i)
              branch_direction_mispredict_q =
                branch_direction_mispredict_q + 1;
            else if (branch_actual_taken_i &&
                     (branch_predicted_target_i != branch_actual_target_i))
              branch_target_mispredict_q = branch_target_mispredict_q + 1;
          end
        end
        if (flush_valid_i) flush_q = flush_q + 1;
        for (int unsigned lane=0; lane<2; lane++) if (load_candidate_present_i[lane] && !load_candidate_valid_i[lane]) begin
          case (load_stall_reason_i[lane])
            LSQ_STALL_UNKNOWN_ADDR: load_unknown_addr_q = load_unknown_addr_q + 1;
            LSQ_STALL_STORE_DATA: load_store_data_q = load_store_data_q + 1;
            LSQ_STALL_PARTIAL_OVERLAP: load_partial_q = load_partial_q + 1;
            LSQ_STALL_BANK_CONFLICT: load_bank_q = load_bank_q + 1;
            LSQ_STALL_DEVICE_SERIALIZE: load_device_q = load_device_q + 1;
            default: begin end
          endcase
        end
        if (|(dmem_req_valid_i & ~dmem_req_ready_i)) dmem_wait_q = dmem_wait_q + 1;
        rob_occupancy_sum_q = rob_occupancy_sum_q + rob_count_i;
        iq_occupancy_sum_q = iq_occupancy_sum_q + iq_count_i;
        lq_occupancy_sum_q = lq_occupancy_sum_q + lq_count_i;
        sq_occupancy_sum_q = sq_occupancy_sum_q + sq_count_i;
        if (rob_count_i > rob_occupancy_max_q) rob_occupancy_max_q = rob_count_i;
        if (iq_count_i > iq_occupancy_max_q) iq_occupancy_max_q = iq_count_i;
        if (lq_count_i > lq_occupancy_max_q) lq_occupancy_max_q = lq_count_i;
        if (sq_count_i > sq_occupancy_max_q) sq_occupancy_max_q = sq_count_i;
      end
    end
  end
endmodule
