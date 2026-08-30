module rv_divider_tb;
  import rv_ooo_pkg::*;

  logic clk;
  logic rst_n;
  logic request_valid;
  logic request_ready;
  logic [31:0] operand_a;
  logic [31:0] operand_b;
  divide_op_e operation;
  logic [7:0] request_sequence;
  logic result_valid;
  logic result_ready;
  logic [31:0] result;
  logic [7:0] result_sequence;

  always #5 clk = ~clk;

  rv_divider #(.XLEN(32)) u_dut (
    .clk_i                      (clk),
    .rst_ni                     (rst_n),
    .request_valid_i            (request_valid),
    .request_ready_o            (request_ready),
    .operand_a_i                (operand_a),
    .operand_b_i                (operand_b),
    .operation_i                (operation),
    .word_operation_i           (1'b0),
    .request_rob_sequence_i     (request_sequence),
    .request_destination_valid_i(1'b1),
    .request_destination_phys_i (7'd9),
    .flush_valid_i              (1'b0),
    .flush_all_i                (1'b0),
    .flush_sequence_i           (8'd0),
    .result_valid_o             (result_valid),
    .result_ready_i             (result_ready),
    .result_o                   (result),
    .result_rob_sequence_o      (result_sequence)
  );

  task automatic run_divide(
    input logic [31:0] a,
    input logic [31:0] b,
    input divide_op_e op,
    input logic [31:0] expected,
    input logic [7:0] seq_value
  );
    while (!request_ready)
      @(posedge clk);
    @(negedge clk);
    operand_a = a;
    operand_b = b;
    operation = op;
    request_sequence = seq_value;
    request_valid = 1'b1;
    @(posedge clk);
    @(negedge clk);
    request_valid = 1'b0;
    while (!result_valid)
      @(posedge clk);
    if ((result != expected) || (result_sequence != seq_value))
      $fatal(1, "Divider result/identity mismatch");
    @(posedge clk);
  endtask

  initial begin : p_divider_test
    clk = 1'b0;
    rst_n = 1'b0;
    request_valid = 1'b0;
    operand_a = '0;
    operand_b = '0;
    operation = DIV_SIGNED_QUOTIENT;
    request_sequence = '0;
    result_ready = 1'b1;
    repeat (2) @(posedge clk);
    @(negedge clk);
    rst_n = 1'b1;

    run_divide(32'd20, -32'sd3, DIV_SIGNED_QUOTIENT,
               -32'sd6, 8'd1);
    run_divide(-32'sd20, 32'd3, DIV_SIGNED_REMAINDER,
               -32'sd2, 8'd2);
    run_divide(32'hffff_ffff, 32'd2, DIV_UNSIGNED_QUOTIENT,
               32'h7fff_ffff, 8'd3);
    run_divide(32'h1234_5678, 32'd0, DIV_UNSIGNED_QUOTIENT,
               32'hffff_ffff, 8'd4);
    run_divide(32'h8000_0000, 32'hffff_ffff, DIV_SIGNED_QUOTIENT,
               32'h8000_0000, 8'd5);

    $display("rv_divider_tb PASS");
    $finish;
  end
endmodule
