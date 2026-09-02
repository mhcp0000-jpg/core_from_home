module rv_lsu_pipe_tb;
  import rv_ooo_pkg::*;

  logic clk;
  logic rst_n;
  logic issue_valid;
  logic issue_ready;
  logic is_load;
  logic is_store;
  logic issue_address_valid;
  logic issue_store_data_valid;
  logic [31:0] base;
  logic [31:0] immediate;
  logic [31:0] store_data;
  logic [2:0] memory_size;
  logic update_valid;
  logic update_ready;
  logic [31:0] address;
  logic [7:0] byte_mask;
  logic [63:0] aligned_store_data;
  logic exception_valid;
  logic update_address_valid;
  logic update_store_data_valid;
  exception_code_e exception_cause;

  always #5 clk = ~clk;

  rv_lsu_pipe #(.XLEN(32), .PADDR_WIDTH(32), .MEM_DATA_WIDTH(64)) u_dut (
    .clk_i                        (clk),
    .rst_ni                       (rst_n),
    .issue_valid_i               (issue_valid),
    .issue_ready_o               (issue_ready),
    .issue_rob_sequence_i        (8'd7),
    .issue_is_load_i             (is_load),
    .issue_is_store_i            (is_store),
    .issue_address_valid_i       (issue_address_valid),
    .issue_store_data_valid_i    (issue_store_data_valid),
    .issue_lq_valid_i            (is_load),
    .issue_lq_index_i            (5'd3),
    .issue_sq_valid_i            (is_store),
    .issue_sq_index_i            (4'd2),
    .base_i                      (base),
    .immediate_i                 (immediate),
    .store_data_i                (store_data),
    .memory_size_i               (memory_size),
    .flush_valid_i               (1'b0),
    .flush_all_i                 (1'b0),
    .flush_sequence_i            (8'd0),
    .update_valid_o              (update_valid),
    .update_ready_i              (update_ready),
    .update_address_o            (address),
    .update_byte_mask_o          (byte_mask),
    .update_store_data_o         (aligned_store_data),
    .update_address_valid_o      (update_address_valid),
    .update_store_data_valid_o   (update_store_data_valid),
    .update_exception_valid_o    (exception_valid),
    .update_exception_cause_o    (exception_cause)
  );

  task automatic issue_one;
    while (!issue_ready)
      @(posedge clk);
    @(negedge clk);
    issue_valid = 1'b1;
    @(posedge clk);
    @(negedge clk);
    issue_valid = 1'b0;
    #1;
  endtask

  initial begin : p_lsu_pipe_test
    clk = 1'b0;
    rst_n = 1'b0;
    issue_valid = 1'b0;
    is_load = 1'b0;
    is_store = 1'b0;
    issue_address_valid = 1'b1;
    issue_store_data_valid = 1'b0;
    base = '0;
    immediate = '0;
    store_data = '0;
    memory_size = '0;
    update_ready = 1'b1;
    repeat (2) @(posedge clk);
    @(negedge clk);
    rst_n = 1'b1;

    is_store = 1'b1;
    issue_store_data_valid = 1'b1;
    base = 32'h8002_0000;
    immediate = 4;
    store_data = 32'hdead_beef;
    memory_size = 3'd2;
    issue_one();
    if (!update_valid || (address != 32'h8002_0004) ||
        (byte_mask != 8'hf0) ||
        (aligned_store_data != 64'hdead_beef_0000_0000) ||
        !update_address_valid || !update_store_data_valid || exception_valid)
      $fatal(1, "Aligned store address/mask/data generation failed");
    @(posedge clk);

    // Address-only store phase must expose ordering information without
    // claiming that the store data is ready.
    issue_store_data_valid = 1'b0;
    base = 32'h8002_0010;
    immediate = 0;
    issue_one();
    if (!update_valid || (address != 32'h8002_0010) ||
        !update_address_valid || update_store_data_valid)
      $fatal(1, "Split store address phase failed");
    @(posedge clk);

    is_store = 1'b0;
    is_load = 1'b1;
    issue_address_valid = 1'b1;
    base = 32'h8002_0001;
    immediate = 0;
    memory_size = 3'd1;
    issue_one();
    if (!exception_valid || (exception_cause != EXC_LOAD_ADDR_MISALIGNED))
      $fatal(1, "Misaligned load exception failed");

    $display("rv_lsu_pipe_tb PASS");
    $finish;
  end
endmodule
