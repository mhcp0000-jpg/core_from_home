module rv_exec_result_buffer_tb;
  import rv_ooo_pkg::*;

  logic clk;
  logic rst_n;
  logic request_valid;
  logic request_ready;
  logic [7:0] request_sequence;
  logic [31:0] request_data;
  logic flush_valid;
  logic flush_all;
  logic [7:0] flush_sequence;
  logic result_valid;
  logic result_ready;
  logic [7:0] result_sequence;
  logic [31:0] result_data;

  always #5 clk = ~clk;

  rv_exec_result_buffer #(.XLEN(32)) u_dut (
    .clk_i                         (clk),
    .rst_ni                        (rst_n),
    .request_valid_i               (request_valid),
    .request_ready_o               (request_ready),
    .request_sequence_i            (request_sequence),
    .request_destination_valid_i   (1'b1),
    .request_destination_class_i   (REG_INT),
    .request_destination_phys_i    (7'd40),
    .request_data_i                (request_data),
    .request_exception_valid_i     (1'b0),
    .request_exception_cause_i     (EXC_ILLEGAL_INSTRUCTION),
    .request_exception_tval_i      (32'd0),
    .request_branch_mispredict_i   (1'b0),
    .request_branch_target_i       (32'd0),
    .request_fflags_i              (5'd0),
    .flush_valid_i                 (flush_valid),
    .flush_all_i                   (flush_all),
    .flush_sequence_i              (flush_sequence),
    .result_valid_o                (result_valid),
    .result_ready_i                (result_ready),
    .result_sequence_o             (result_sequence),
    .result_data_o                 (result_data)
  );

  initial begin
    clk = 1'b0;
    rst_n = 1'b0;
    request_valid = 1'b0;
    request_sequence = '0;
    request_data = '0;
    flush_valid = 1'b0;
    flush_all = 1'b0;
    flush_sequence = '0;
    result_ready = 1'b0;
    repeat (2) @(posedge clk);
    @(negedge clk);
    rst_n = 1'b1;

    request_sequence = 8'd10;
    request_data = 32'h1234_5678;
    request_valid = 1'b1;
    @(posedge clk);
    @(negedge clk);
    request_valid = 1'b0;
    if (!result_valid || (result_sequence != 8'd10) ||
        (result_data != 32'h1234_5678))
      $fatal(1, "Result buffer capture failed");

    request_sequence = 8'd11;
    request_data = 32'hdead_beef;
    request_valid = 1'b1;
    #1;
    if (request_ready)
      $fatal(1, "Full result buffer did not backpressure producer");
    request_valid = 1'b0;

    flush_valid = 1'b1;
    flush_sequence = 8'd5;
    @(posedge clk);
    @(negedge clk);
    flush_valid = 1'b0;
    if (result_valid)
      $fatal(1, "Younger buffered result survived flush");

    request_sequence = 8'd4;
    request_data = 32'haaaa_5555;
    request_valid = 1'b1;
    @(posedge clk);
    @(negedge clk);
    request_valid = 1'b0;
    flush_valid = 1'b1;
    flush_sequence = 8'd5;
    @(posedge clk);
    @(negedge clk);
    flush_valid = 1'b0;
    if (!result_valid || (result_sequence != 8'd4))
      $fatal(1, "Older buffered result was incorrectly flushed");

    result_ready = 1'b1;
    @(posedge clk);
    @(negedge clk);
    if (result_valid)
      $fatal(1, "Accepted result was not removed");

    $display("rv_exec_result_buffer_tb PASS");
    $finish;
  end
endmodule
