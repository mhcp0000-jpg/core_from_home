module rv_store_buffer_tb;
  localparam int unsigned INDEX_WIDTH = 2;

  logic clk;
  logic rst_n;
  logic [1:0] enq_valid;
  logic [1:0] enq_ready;
  logic [1:0][7:0] enq_sequence;
  logic [1:0][31:0] enq_address;
  logic [1:0][63:0] enq_data;
  logic [1:0][7:0] enq_mask;
  logic [1:0][2:0] enq_size;
  logic [1:0] enq_device;
  logic [1:0] drain_valid;
  logic [1:0] drain_ready;
  logic [1:0][INDEX_WIDTH-1:0] drain_index;
  logic [1:0][31:0] drain_address;
  logic [1:0] drain_rsp_valid;
  logic [1:0][INDEX_WIDTH-1:0] drain_rsp_index;
  logic [1:0][1:0] drain_rsp_resp;
  logic [1:0] query_valid;
  logic [1:0][31:0] query_address;
  logic [1:0][7:0] query_mask;
  logic [1:0] query_full_cover;
  logic [1:0] query_partial;
  logic [1:0][63:0] query_data;
  logic [2:0] count;
  logic empty;
  logic machine_check;
  logic [INDEX_WIDTH-1:0] saved_index0;
  logic [INDEX_WIDTH-1:0] saved_index1;

  always #5 clk = ~clk;

  rv_store_buffer #(
    .PADDR_WIDTH (32),
    .DATA_WIDTH  (64),
    .ENTRIES     (4),
    .SEQ_WIDTH   (8)
  ) u_dut (
    .clk_i                      (clk),
    .rst_ni                     (rst_n),
    .enq_valid_i                (enq_valid),
    .enq_ready_o                (enq_ready),
    .enq_sequence_i             (enq_sequence),
    .enq_address_i              (enq_address),
    .enq_data_i                 (enq_data),
    .enq_mask_i                 (enq_mask),
    .enq_size_i                 (enq_size),
    .enq_device_i               (enq_device),
    .drain_valid_o              (drain_valid),
    .drain_ready_i              (drain_ready),
    .drain_index_o              (drain_index),
    .drain_address_o            (drain_address),
    .drain_rsp_valid_i          (drain_rsp_valid),
    .drain_rsp_index_i          (drain_rsp_index),
    .drain_rsp_resp_i           (drain_rsp_resp),
    .query_valid_i              (query_valid),
    .query_address_i            (query_address),
    .query_mask_i               (query_mask),
    .query_full_cover_o         (query_full_cover),
    .query_partial_o            (query_partial),
    .query_data_o               (query_data),
    .empty_o                    (empty),
    .count_o                    (count),
    .machine_check_o            (machine_check)
  );

  task automatic reset_dut;
    @(negedge clk);
    rst_n = 1'b0;
    enq_valid = '0;
    drain_ready = '0;
    drain_rsp_valid = '0;
    query_valid = '0;
    repeat (2) @(posedge clk);
    @(negedge clk);
    rst_n = 1'b1;
  endtask

  task automatic enqueue_one(
    input logic [7:0] seq_value,
    input logic [31:0] address,
    input logic [63:0] data,
    input logic [7:0] mask,
    input logic device
  );
    @(negedge clk);
    enq_sequence[0] = seq_value;
    enq_address[0] = address;
    enq_data[0] = data;
    enq_mask[0] = mask;
    enq_size[0] = 3'd2;
    enq_device[0] = device;
    enq_valid = 2'b01;
    #1;
    if (!enq_ready[0])
      $fatal(1, "Store buffer unexpectedly full");
    @(posedge clk);
    @(negedge clk);
    enq_valid = '0;
  endtask

  task automatic enqueue_two(
    input logic first_device
  );
    @(negedge clk);
    enq_sequence[0] = 8'd10;
    enq_sequence[1] = 8'd11;
    enq_address[0] = 32'h8002_0000;
    enq_address[1] = 32'h8002_0008;
    enq_data[0] = 64'h1111_1111_1111_1111;
    enq_data[1] = 64'h2222_2222_2222_2222;
    enq_mask[0] = 8'hff;
    enq_mask[1] = 8'hff;
    enq_size[0] = 3'd3;
    enq_size[1] = 3'd3;
    enq_device[0] = first_device;
    enq_device[1] = 1'b0;
    enq_valid = 2'b11;
    #1;
    if (enq_ready != 2'b11)
      $fatal(1, "Dual enqueue was not accepted");
    @(posedge clk);
    @(negedge clk);
    enq_valid = '0;
  endtask

  initial begin : p_store_buffer_test
    clk = 1'b0;
    rst_n = 1'b0;
    enq_valid = '0;
    enq_sequence = '0;
    enq_address = '0;
    enq_data = '0;
    enq_mask = '0;
    enq_size = '0;
    enq_device = '0;
    drain_ready = '0;
    drain_rsp_valid = '0;
    drain_rsp_index = '0;
    drain_rsp_resp = '0;
    query_valid = '0;
    query_address = '0;
    query_mask = '0;

    reset_dut();
    enqueue_one(8'd1, 32'h8002_0000, 64'h0000_0000_aaaa_aaaa,
                8'h0f, 1'b0);
    enqueue_one(8'd2, 32'h8002_0000, 64'h0000_0000_bbbb_bbbb,
                8'h0f, 1'b0);
    query_valid[0] = 1'b1;
    query_address[0] = 32'h8002_0000;
    query_mask[0] = 8'h0f;
    #1;
    if (!query_full_cover[0] || query_partial[0] ||
        (query_data[0] != 64'h0000_0000_bbbb_bbbb))
      $fatal(1, "Youngest committed store forwarding failed");

    enqueue_one(8'd3, 32'h8002_0000, 64'h0000_0000_0000_cccc,
                8'h03, 1'b0);
    #1;
    if (query_full_cover[0] || !query_partial[0])
      $fatal(1, "Youngest partial overlap must stall a load");
    query_valid = '0;

    reset_dut();
    enqueue_two(1'b0);
    #1;
    if (drain_valid != 2'b11 ||
        (drain_address[0] != 32'h8002_0000) ||
        (drain_address[1] != 32'h8002_0008))
      $fatal(1, "Different-bank normal stores did not dual drain");
    saved_index0 = drain_index[0];
    saved_index1 = drain_index[1];
    drain_ready = 2'b11;
    @(posedge clk);
    @(negedge clk);
    drain_ready = '0;
    drain_rsp_index[0] = saved_index0;
    drain_rsp_index[1] = saved_index1;
    drain_rsp_resp = '0;
    drain_rsp_valid = 2'b11;
    @(posedge clk);
    @(negedge clk);
    drain_rsp_valid = '0;
    @(posedge clk);
    @(negedge clk);
    if (!empty || (count != 0))
      $fatal(1, "Completed stores were not removed in FIFO order");

    reset_dut();
    enqueue_two(1'b1);
    #1;
    if (!drain_valid[0] || drain_valid[1])
      $fatal(1, "Device store must serialize the drain path");
    saved_index0 = drain_index[0];
    drain_ready = 2'b01;
    @(posedge clk);
    @(negedge clk);
    drain_ready = '0;
    drain_rsp_index[0] = saved_index0;
    drain_rsp_resp[0] = 2'b10;
    drain_rsp_valid = 2'b01;
    @(posedge clk);
    @(negedge clk);
    drain_rsp_valid = '0;
    if (!machine_check)
      $fatal(1, "Post-commit store error did not set machine check");

    $display("rv_store_buffer_tb PASS");
    $finish;
  end

endmodule
