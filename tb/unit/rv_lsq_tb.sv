module rv_lsq_tb;
  import rv_ooo_pkg::*;

  localparam int unsigned LQ_INDEX_WIDTH = 2;
  localparam int unsigned SQ_INDEX_WIDTH = 2;

  logic clk;
  logic rst_n;
  logic [1:0] dispatch_valid;
  logic dispatch_accept;
  logic dispatch_ready;
  logic [1:0] dispatch_is_load;
  logic [1:0] dispatch_is_store;
  logic [1:0][7:0] dispatch_sequence;
  logic [1:0] dispatch_destination_valid;
  logic [1:0][6:0] dispatch_destination_phys;
  logic [1:0][2:0] dispatch_size;
  logic [1:0] dispatch_unsigned;
  logic [1:0] dispatch_device;
  logic [1:0] dispatch_lq_valid;
  logic [1:0][LQ_INDEX_WIDTH-1:0] dispatch_lq_index;
  logic [1:0] dispatch_sq_valid;
  logic [1:0][SQ_INDEX_WIDTH-1:0] dispatch_sq_index;

  logic [1:0] agu_valid;
  logic [1:0] agu_ready;
  logic [1:0][7:0] agu_sequence;
  logic [1:0] agu_lq_valid;
  logic [1:0][LQ_INDEX_WIDTH-1:0] agu_lq_index;
  logic [1:0] agu_sq_valid;
  logic [1:0][SQ_INDEX_WIDTH-1:0] agu_sq_index;
  logic [1:0][31:0] agu_address;
  logic [1:0][7:0] agu_mask;
  logic [1:0][63:0] agu_store_data;
  logic [1:0] agu_address_valid;
  logic [1:0] agu_store_data_valid;
  logic [1:0] agu_device;
  logic [1:0] agu_exception_valid;
  exception_code_e [1:0] agu_exception_cause;

  logic [1:0] load_candidate_present;
  logic [1:0] load_candidate_valid;
  logic [1:0] load_candidate_ready;
  logic [1:0][LQ_INDEX_WIDTH-1:0] load_candidate_index;
  logic [1:0][7:0] load_candidate_sequence;
  logic [1:0] load_memory_read;
  logic [1:0] load_forward_valid;
  logic [1:0][63:0] load_forward_data;
  lsq_stall_reason_e [1:0] load_stall_reason;

  logic [1:0] load_response_valid;
  logic [1:0][LQ_INDEX_WIDTH-1:0] load_response_index;
  logic [1:0] load_response_replay;
  logic [1:0] load_commit_valid;
  logic [1:0] load_commit_ready;
  logic [1:0][7:0] load_commit_sequence;
  logic [1:0][LQ_INDEX_WIDTH-1:0] load_commit_index;
  logic [1:0] store_commit_valid;
  logic [1:0] store_commit_ready;
  logic [1:0] store_commit_error;
  logic [1:0][7:0] store_commit_sequence;
  logic [1:0][SQ_INDEX_WIDTH-1:0] store_commit_index;
  logic [1:0] sb_enq_valid;
  logic [1:0] sb_enq_ready;
  logic [1:0][63:0] sb_enq_data;
  logic [1:0][7:0] sb_enq_mask;
  logic [1:0] direct_store_valid;
  logic [1:0] direct_store_complete;
  logic [1:0] direct_store_error;
  logic [1:0] flush_valid_vector;
  logic flush_valid;
  logic flush_all;
  logic [7:0] flush_sequence;
  logic [2:0] lq_count;
  logic [2:0] sq_count;
  logic load_outstanding;

  logic [LQ_INDEX_WIDTH-1:0] saved_lq0;
  logic [LQ_INDEX_WIDTH-1:0] saved_lq1;
  logic [SQ_INDEX_WIDTH-1:0] saved_sq0;
  logic [SQ_INDEX_WIDTH-1:0] saved_sq1;

  always #5 clk = ~clk;

  rv_lsq #(
    .PADDR_WIDTH    (32),
    .DATA_WIDTH     (64),
    .LQ_ENTRIES     (4),
    .SQ_ENTRIES     (4),
    .SEQ_WIDTH      (8),
    .PHYS_TAG_WIDTH (7)
  ) u_dut (
    .clk_i                         (clk),
    .rst_ni                        (rst_n),
    .dispatch_valid_i              (dispatch_valid),
    .dispatch_accept_i             (dispatch_accept),
    .dispatch_ready_o              (dispatch_ready),
    .dispatch_is_load_i            (dispatch_is_load),
    .dispatch_is_store_i           (dispatch_is_store),
    .dispatch_sequence_i           (dispatch_sequence),
    .dispatch_destination_valid_i  (dispatch_destination_valid),
    .dispatch_destination_phys_i   (dispatch_destination_phys),
    .dispatch_size_i               (dispatch_size),
    .dispatch_unsigned_i           (dispatch_unsigned),
    .dispatch_device_i             (dispatch_device),
    .dispatch_lq_valid_o           (dispatch_lq_valid),
    .dispatch_lq_index_o           (dispatch_lq_index),
    .dispatch_sq_valid_o           (dispatch_sq_valid),
    .dispatch_sq_index_o           (dispatch_sq_index),
    .agu_valid_i                   (agu_valid),
    .agu_ready_o                   (agu_ready),
    .agu_sequence_i                (agu_sequence),
    .agu_lq_valid_i                (agu_lq_valid),
    .agu_lq_index_i                (agu_lq_index),
    .agu_sq_valid_i                (agu_sq_valid),
    .agu_sq_index_i                (agu_sq_index),
    .agu_address_i                 (agu_address),
    .agu_mask_i                    (agu_mask),
    .agu_store_data_i              (agu_store_data),
    .agu_address_valid_i           (agu_address_valid),
    .agu_store_data_valid_i        (agu_store_data_valid),
    .agu_device_i                  (agu_device),
    .agu_exception_valid_i         (agu_exception_valid),
    .agu_exception_cause_i         (agu_exception_cause),
    .load_candidate_present_o      (load_candidate_present),
    .load_candidate_valid_o        (load_candidate_valid),
    .load_candidate_ready_i        (load_candidate_ready),
    .load_candidate_index_o        (load_candidate_index),
    .load_candidate_sequence_o     (load_candidate_sequence),
    .load_memory_read_o            (load_memory_read),
    .load_forward_valid_o          (load_forward_valid),
    .load_forward_data_o           (load_forward_data),
    .load_stall_reason_o           (load_stall_reason),
    .device_load_permit_i          (2'b11),
    .sb_query_full_cover_i         (2'b00),
    .sb_query_partial_i            (2'b00),
    .sb_query_data_i               (128'd0),
    .load_response_valid_i         (load_response_valid),
    .load_response_index_i         (load_response_index),
    .load_response_replay_i        (load_response_replay),
    .load_commit_valid_i           (load_commit_valid),
    .load_commit_ready_o           (load_commit_ready),
    .load_commit_sequence_i        (load_commit_sequence),
    .load_commit_index_i           (load_commit_index),
    .store_commit_valid_i          (store_commit_valid),
    .store_commit_ready_o          (store_commit_ready),
    .store_commit_error_o          (store_commit_error),
    .store_commit_sequence_i       (store_commit_sequence),
    .store_commit_index_i          (store_commit_index),
    .sb_enq_valid_o                (sb_enq_valid),
    .sb_enq_ready_i                (sb_enq_ready),
    .sb_enq_data_o                 (sb_enq_data),
    .sb_enq_mask_o                 (sb_enq_mask),
    .direct_store_valid_o          (direct_store_valid),
    .direct_store_complete_i       (direct_store_complete),
    .direct_store_error_i          (direct_store_error),
    .flush_valid_i                 (flush_valid),
    .flush_all_i                   (flush_all),
    .flush_sequence_i              (flush_sequence),
    .lq_count_o                    (lq_count),
    .sq_count_o                    (sq_count),
    .load_outstanding_o            (load_outstanding)
  );

  task automatic reset_dut;
    @(negedge clk);
    rst_n = 1'b0;
    dispatch_valid = '0;
    dispatch_accept = 1'b1;
    agu_valid = '0;
    agu_device = '0;
    load_candidate_ready = '0;
    load_response_valid = '0;
    load_response_replay = '0;
    load_commit_valid = '0;
    store_commit_valid = '0;
    flush_valid = 1'b0;
    flush_all = 1'b0;
    repeat (2) @(posedge clk);
    @(negedge clk);
    rst_n = 1'b1;
  endtask

  task automatic dispatch_store_load(
    input logic [7:0] store_sequence,
    input logic [7:0] load_sequence
  );
    @(negedge clk);
    dispatch_valid = 2'b11;
    dispatch_is_store = 2'b01;
    dispatch_is_load = 2'b10;
    dispatch_sequence[0] = store_sequence;
    dispatch_sequence[1] = load_sequence;
    dispatch_destination_valid = 2'b10;
    dispatch_destination_phys[1] = 7'd9;
    dispatch_size[0] = 3'd2;
    dispatch_size[1] = 3'd2;
    #1;
    if (!dispatch_ready || !dispatch_sq_valid[0] ||
        !dispatch_lq_valid[1])
      $fatal(1, "Store/load pair allocation failed");
    saved_sq0 = dispatch_sq_index[0];
    saved_lq0 = dispatch_lq_index[1];
    @(posedge clk);
    @(negedge clk);
    dispatch_valid = '0;
    dispatch_is_store = '0;
    dispatch_is_load = '0;
  endtask

  task automatic update_store_load(
    input logic [7:0] store_sequence,
    input logic [7:0] load_sequence,
    input logic store_address_valid,
    input logic store_data_valid,
    input logic [63:0] store_data
  );
    @(negedge clk);
    agu_valid = 2'b11;
    agu_sequence[0] = store_sequence;
    agu_sequence[1] = load_sequence;
    agu_sq_valid = 2'b01;
    agu_sq_index[0] = saved_sq0;
    agu_lq_valid = 2'b10;
    agu_lq_index[1] = saved_lq0;
    agu_address[0] = 32'h8002_0000;
    agu_address[1] = 32'h8002_0000;
    agu_mask[0] = 8'h0f;
    agu_mask[1] = 8'h0f;
    agu_store_data[0] = store_data;
    agu_address_valid[0] = store_address_valid;
    agu_address_valid[1] = 1'b1;
    agu_store_data_valid[0] = store_data_valid;
    #1;
    if (agu_ready != 2'b11)
      $fatal(1, "Dual AGU update was not accepted");
    @(posedge clk);
    @(negedge clk);
    agu_valid = '0;
    agu_lq_valid = '0;
    agu_sq_valid = '0;
  endtask

  task automatic dispatch_single_load(input logic [7:0] seq_value);
    @(negedge clk);
    dispatch_valid = 2'b01;
    dispatch_is_load = 2'b01;
    dispatch_sequence[0] = seq_value;
    dispatch_destination_valid = 2'b01;
    dispatch_destination_phys[0] = 7'd10;
    dispatch_size[0] = 3'd2;
    #1;
    if (!dispatch_ready || !dispatch_lq_valid[0])
      $fatal(1, "Single load allocation failed");
    saved_lq1 = dispatch_lq_index[0];
    @(posedge clk);
    @(negedge clk);
    dispatch_valid = '0;
    dispatch_is_load = '0;
  endtask

  task automatic update_single_load(input logic [7:0] seq_value);
    @(negedge clk);
    agu_valid = 2'b01;
    agu_sequence[0] = seq_value;
    agu_lq_valid = 2'b01;
    agu_lq_index[0] = saved_lq1;
    agu_address[0] = 32'h8002_0040;
    agu_mask[0] = 8'h0f;
    agu_address_valid[0] = 1'b1;
    #1;
    if (!agu_ready[0])
      $fatal(1, "Load AGU update was not accepted");
    @(posedge clk);
    @(negedge clk);
    agu_valid = '0;
    agu_lq_valid = '0;
  endtask

  initial begin : p_lsq_test
    clk = 1'b0;
    rst_n = 1'b0;
    dispatch_valid = '0;
    dispatch_is_load = '0;
    dispatch_is_store = '0;
    dispatch_sequence = '0;
    dispatch_destination_valid = '0;
    dispatch_destination_phys = '0;
    dispatch_size = '0;
    dispatch_unsigned = '0;
    dispatch_device = '0;
    agu_valid = '0;
    agu_sequence = '0;
    agu_lq_valid = '0;
    agu_lq_index = '0;
    agu_sq_valid = '0;
    agu_sq_index = '0;
    agu_address = '0;
    agu_mask = '0;
    agu_store_data = '0;
    agu_address_valid = '0;
    agu_store_data_valid = '0;
    agu_exception_valid = '0;
    agu_exception_cause[0] = EXC_LOAD_ACCESS_FAULT;
    agu_exception_cause[1] = EXC_LOAD_ACCESS_FAULT;
    load_candidate_ready = '0;
    load_response_valid = '0;
    load_response_index = '0;
    load_commit_valid = '0;
    load_commit_sequence = '0;
    load_commit_index = '0;
    store_commit_valid = '0;
    store_commit_sequence = '0;
    store_commit_index = '0;
    sb_enq_ready = 2'b11;
    direct_store_complete = '0;
    direct_store_error = '0;
    flush_valid_vector = '0;
    flush_valid = 1'b0;
    flush_all = 1'b0;
    flush_sequence = '0;

    reset_dut();
    dispatch_store_load(8'd1, 8'd2);
    update_store_load(8'd1, 8'd2, 1'b1, 1'b1,
                      64'h0000_0000_dead_beef);
    #1;
    if (!load_candidate_present[0] || !load_candidate_valid[0] ||
        !load_forward_valid[0] || load_memory_read[0] ||
        (load_forward_data[0] != 64'h0000_0000_dead_beef))
      $fatal(1, "Store-to-load forwarding failed");

    load_candidate_ready = 2'b01;
    @(posedge clk);
    @(negedge clk);
    load_candidate_ready = '0;
    load_commit_valid = 2'b01;
    load_commit_sequence[0] = 8'd2;
    load_commit_index[0] = saved_lq0;
    #1;
    if (!load_commit_ready[0])
      $fatal(1, "Forwarded load did not become committable");
    @(posedge clk);
    @(negedge clk);
    load_commit_valid = '0;

    store_commit_valid = 2'b01;
    store_commit_sequence[0] = 8'd1;
    store_commit_index[0] = saved_sq0;
    #1;
    if (!store_commit_ready[0] || store_commit_error[0] ||
        !sb_enq_valid[0] ||
        (sb_enq_data[0] != 64'h0000_0000_dead_beef) ||
        (sb_enq_mask[0] != 8'h0f))
      $fatal(1, "ROB-head store enqueue contract failed");
    @(posedge clk);
    @(negedge clk);
    store_commit_valid = '0;
    #1;
    if ((lq_count != 0) || (sq_count != 0))
      $fatal(1, "Committed memory entries were not released");

    reset_dut();
    dispatch_store_load(8'd10, 8'd11);
    @(negedge clk);
    agu_valid = 2'b01;
    agu_sequence[0] = 8'd11;
    agu_lq_valid = 2'b01;
    agu_lq_index[0] = saved_lq0;
    agu_address[0] = 32'h8002_0000;
    agu_mask[0] = 8'h0f;
    agu_address_valid[0] = 1'b1;
    #1;
    if (!agu_ready[0]) $fatal(1, "Load-only update failed");
    @(posedge clk);
    @(negedge clk);
    agu_valid = '0;
    agu_lq_valid = '0;
    #1;
    if (!load_candidate_present[0] || load_candidate_valid[0] ||
        (load_stall_reason[0] != LSQ_STALL_UNKNOWN_ADDR) ||
        load_memory_read[0])
      $fatal(1, "Unknown older store did not block load");

    @(negedge clk);
    agu_valid = 2'b01;
    agu_sequence[0] = 8'd10;
    agu_sq_valid = 2'b01;
    agu_sq_index[0] = saved_sq0;
    agu_address[0] = 32'h8002_0000;
    agu_mask[0] = 8'h0f;
    agu_store_data[0] = 64'h1234;
    agu_address_valid[0] = 1'b1;
    agu_store_data_valid[0] = 1'b0;
    @(posedge clk);
    @(negedge clk);
    agu_valid = '0;
    agu_sq_valid = '0;
    #1;
    if (load_candidate_valid[0] ||
        (load_stall_reason[0] != LSQ_STALL_STORE_DATA))
      $fatal(1, "Older store without data did not block load");

    reset_dut();
    dispatch_single_load(8'd30);
    saved_lq0 = saved_lq1;
    update_single_load(8'd30);
    #1;
    if (!load_candidate_valid[0] || !load_memory_read[0])
      $fatal(1, "Independent load did not request memory");
    load_candidate_ready = 2'b01;
    @(posedge clk);
    @(negedge clk);
    load_candidate_ready = '0;
    flush_valid = 1'b1;
    flush_all = 1'b1;
    @(posedge clk);
    @(negedge clk);
    flush_valid = 1'b0;
    flush_all = 1'b0;
    #1;
    if ((lq_count != 1) || !load_outstanding)
      $fatal(1, "Flushed outstanding load was not retained as tombstone");

    dispatch_single_load(8'd31);
    if (saved_lq1 == saved_lq0)
      $fatal(1, "Outstanding tombstone index was reused");
    load_response_index[0] = saved_lq0;
    load_response_valid = 2'b01;
    @(posedge clk);
    @(negedge clk);
    load_response_valid = '0;
    #1;
    if (lq_count != 1)
      $fatal(1, "Killed outstanding response did not reclaim tombstone");

    reset_dut();
    dispatch_single_load(8'd50);
    saved_lq0 = saved_lq1;
    update_single_load(8'd50);
    load_candidate_ready = 2'b01;
    @(posedge clk);
    @(negedge clk);
    load_candidate_ready = '0;
    // A younger-branch recovery must not discard a same-cycle response for
    // this older, surviving load.
    flush_valid = 1'b1;
    flush_all = 1'b0;
    flush_sequence = 8'd50;
    load_response_index[0] = saved_lq0;
    load_response_valid = 2'b01;
    @(posedge clk);
    @(negedge clk);
    flush_valid = 1'b0;
    load_response_valid = '0;
    load_commit_valid = 2'b01;
    load_commit_sequence[0] = 8'd50;
    load_commit_index[0] = saved_lq0;
    #1;
    if (!load_commit_ready[0] || load_outstanding)
      $fatal(1, "Surviving same-cycle load response was lost on flush");
    @(posedge clk);
    @(negedge clk);
    load_commit_valid = '0;

    reset_dut();
    @(negedge clk);
    dispatch_valid = 2'b01;
    dispatch_is_store = 2'b01;
    dispatch_sequence[0] = 8'd40;
    dispatch_size[0] = 3'd2;
    dispatch_device[0] = 1'b1;
    #1;
    if (!dispatch_ready || !dispatch_sq_valid[0])
      $fatal(1, "Device store allocation failed");
    saved_sq0 = dispatch_sq_index[0];
    @(posedge clk);
    @(negedge clk);
    dispatch_valid = '0;
    dispatch_is_store = '0;

    agu_valid = 2'b01;
    agu_sequence[0] = 8'd40;
    agu_sq_valid = 2'b01;
    agu_sq_index[0] = saved_sq0;
    agu_address[0] = 32'h1000_0000;
    agu_mask[0] = 8'h0f;
    agu_store_data[0] = 64'h0000_0000_cafe_f00d;
    agu_address_valid[0] = 1'b1;
    agu_store_data_valid[0] = 1'b1;
    agu_device[0] = 1'b1;
    @(posedge clk);
    @(negedge clk);
    agu_valid = '0;
    agu_sq_valid = '0;
    agu_device = '0;

    store_commit_valid = 2'b01;
    store_commit_sequence[0] = 8'd40;
    store_commit_index[0] = saved_sq0;
    #1;
    if (!direct_store_valid[0] || sb_enq_valid[0] ||
        store_commit_ready[0] || store_commit_error[0])
      $fatal(1, "Device store escaped through normal store buffer path");
    direct_store_complete[0] = 1'b1;
    #1;
    if (!store_commit_ready[0])
      $fatal(1, "Successful direct device response did not release ROB head");
    @(posedge clk);
    @(negedge clk);
    store_commit_valid = '0;
    direct_store_complete = '0;
    dispatch_device = '0;
    #1;
    if (sq_count != 0)
      $fatal(1, "Completed device store did not release SQ entry");

    $display("rv_lsq_tb PASS");
    $finish;
  end

endmodule
