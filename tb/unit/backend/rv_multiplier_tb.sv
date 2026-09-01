module rv_multiplier_tb;
  import rv_ooo_pkg::*;

  logic clk;
  logic rst_n;

  logic req32_valid;
  logic req32_ready;
  logic [31:0] req32_a;
  logic [31:0] req32_b;
  multiply_op_e req32_op;
  logic [7:0] req32_sequence;
  logic [6:0] req32_destination;
  logic result32_valid;
  logic result32_ready;
  logic [31:0] result32;
  logic [7:0] result32_sequence;
  logic result32_destination_valid;
  logic [6:0] result32_destination;

  logic req64_valid;
  logic req64_ready;
  logic [63:0] req64_a;
  logic [63:0] req64_b;
  logic req64_word;
  logic result64_valid;
  logic [63:0] result64;
  logic [7:0] result64_sequence;
  logic result64_destination_valid;
  logic [6:0] result64_destination;

  always #5 clk = ~clk;

  rv_multiplier #(.XLEN(32)) u_mul32 (
    .clk_i                    (clk),
    .rst_ni                   (rst_n),
    .request_valid_i          (req32_valid),
    .request_ready_o          (req32_ready),
    .operand_a_i              (req32_a),
    .operand_b_i              (req32_b),
    .operation_i              (req32_op),
    .word_operation_i         (1'b0),
    .sequence_i               (req32_sequence),
    .destination_valid_i      (1'b1),
    .destination_phys_i       (req32_destination),
    .flush_valid_i            (1'b0),
    .flush_all_i              (1'b0),
    .flush_sequence_i         (8'd0),
    .result_valid_o           (result32_valid),
    .result_ready_i           (result32_ready),
    .result_o                 (result32),
    .result_sequence_o        (result32_sequence),
    .result_destination_valid_o(result32_destination_valid),
    .result_destination_phys_o(result32_destination)
  );

  rv_multiplier #(.XLEN(64)) u_mul64 (
    .clk_i                    (clk),
    .rst_ni                   (rst_n),
    .request_valid_i          (req64_valid),
    .request_ready_o          (req64_ready),
    .operand_a_i              (req64_a),
    .operand_b_i              (req64_b),
    .operation_i              (MUL_LOW),
    .word_operation_i         (req64_word),
    .sequence_i               (8'h40),
    .destination_valid_i      (1'b1),
    .destination_phys_i       (7'd40),
    .flush_valid_i            (1'b0),
    .flush_all_i              (1'b0),
    .flush_sequence_i         (8'd0),
    .result_valid_o           (result64_valid),
    .result_ready_i           (1'b1),
    .result_o                 (result64),
    .result_sequence_o        (result64_sequence),
    .result_destination_valid_o(result64_destination_valid),
    .result_destination_phys_o(result64_destination)
  );

  task automatic multiply32(
    input logic [31:0] operand_a,
    input logic [31:0] operand_b,
    input multiply_op_e operation,
    input logic [31:0] expected,
    input logic [7:0] sequence_id,
    input logic [6:0] destination_tag
  );
    @(negedge clk);
    req32_valid       = 1'b1;
    req32_a           = operand_a;
    req32_b           = operand_b;
    req32_op          = operation;
    req32_sequence    = sequence_id;
    req32_destination = destination_tag;
    do @(posedge clk); while (!req32_ready);
    @(negedge clk);
    req32_valid = 1'b0;
    while (!result32_valid)
      @(negedge clk);
    if ((result32 != expected) || (result32_sequence != sequence_id) ||
        !result32_destination_valid ||
        (result32_destination != destination_tag))
      $fatal(1, "Multiplier result or metadata mismatch");
    @(posedge clk);
  endtask

  initial begin : p_multiplier_test
    clk               = 1'b0;
    rst_n             = 1'b0;
    req32_valid       = 1'b0;
    req32_a           = '0;
    req32_b           = '0;
    req32_op          = MUL_LOW;
    req32_sequence    = '0;
    req32_destination = '0;
    result32_ready    = 1'b1;
    req64_valid       = 1'b0;
    req64_a           = '0;
    req64_b           = '0;
    req64_word        = 1'b0;
    repeat (3) @(posedge clk);
    @(negedge clk);
    rst_n = 1'b1;

    multiply32(32'hffff_fffd, 32'd7, MUL_LOW,
               32'hffff_ffeb, 8'h10, 7'd32);
    multiply32(32'hffff_fffe, 32'd3, MUL_HIGH_SS,
               32'hffff_ffff, 8'h11, 7'd33);
    multiply32(32'hffff_fffe, 32'hffff_ffff, MUL_HIGH_SU,
               32'hffff_fffe, 8'h12, 7'd34);
    multiply32(32'hffff_ffff, 32'd2, MUL_HIGH_UU,
               32'h0000_0001, 8'h13, 7'd35);

    @(negedge clk);
    req64_valid = 1'b1;
    req64_a     = 64'h0000_0000_7fff_ffff;
    req64_b     = 2;
    req64_word  = 1'b1;
    do @(posedge clk); while (!req64_ready);
    @(negedge clk);
    req64_valid = 1'b0;
    while (!result64_valid)
      @(negedge clk);
    if (result64 != 64'hffff_ffff_ffff_fffe)
      $fatal(1, "RV64 MULW sign extension failed");

    // Hold a result under backpressure and let the interface assertion check
    // metadata/data stability for multiple cycles.
    @(negedge clk);
    result32_ready    = 1'b0;
    req32_valid       = 1'b1;
    req32_a           = 9;
    req32_b           = 9;
    req32_op          = MUL_LOW;
    req32_sequence    = 8'h20;
    req32_destination = 7'd36;
    do @(posedge clk); while (!req32_ready);
    @(negedge clk);
    req32_valid = 1'b0;
    while (!result32_valid)
      @(negedge clk);
    repeat (3) @(posedge clk);
    if (result32 != 81)
      $fatal(1, "Multiplier backpressured result changed");
    @(negedge clk);
    result32_ready = 1'b1;

    $display("rv_multiplier_tb PASS");
    $finish;
  end
endmodule
