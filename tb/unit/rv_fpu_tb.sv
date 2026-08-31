module rv_fpu_tb;
  import rv_ooo_pkg::*;

  logic clk, rst_n;
  logic request_valid, request_ready;
  logic [31:0] instruction, operand_a, operand_b, operand_c;
  logic [2:0] rounding_mode, frm;
  logic [7:0] sequence_id, result_sequence;
  logic destination_valid, flush_valid, flush_all;
  reg_class_e destination_class, result_destination_class;
  logic [6:0] destination_phys, result_destination_phys;
  logic result_valid, result_ready, result_destination_valid;
  logic [31:0] result_data, result_tval;
  logic [4:0] result_fflags;
  logic result_exception_valid;
  exception_code_e result_exception_cause;

  always #5 clk = ~clk;

  rv_fpu #(.XLEN(32), .ROB_SEQ_WIDTH(8), .PHYS_TAG_WIDTH(7), .LATENCY(2)) u_dut (
    .clk_i(clk), .rst_ni(rst_n), .request_valid_i(request_valid),
    .request_ready_o(request_ready), .instruction_i(instruction),
    .operand_a_i(operand_a), .operand_b_i(operand_b), .operand_c_i(operand_c),
    .rounding_mode_i(rounding_mode), .frm_i(frm), .sequence_i(sequence_id),
    .destination_valid_i(destination_valid),
    .destination_class_i(destination_class),
    .destination_phys_i(destination_phys), .flush_valid_i(flush_valid),
    .flush_all_i(flush_all), .flush_sequence_i('0),
    .result_valid_o(result_valid), .result_ready_i(result_ready),
    .result_sequence_o(result_sequence),
    .result_destination_valid_o(result_destination_valid),
    .result_destination_class_o(result_destination_class),
    .result_destination_phys_o(result_destination_phys),
    .result_data_o(result_data), .result_fflags_o(result_fflags),
    .result_exception_valid_o(result_exception_valid),
    .result_exception_cause_o(result_exception_cause),
    .result_exception_tval_o(result_tval)
  );

  task automatic issue_and_expect(
    input logic [31:0] test_instruction,
    input logic [31:0] test_a,
    input logic [31:0] test_b,
    input logic [2:0] test_rm,
    input logic [2:0] test_frm,
    input logic [31:0] expected_data,
    input logic expected_exception
  );
    instruction = test_instruction;
    operand_a = test_a;
    operand_b = test_b;
    operand_c = '0;
    rounding_mode = test_rm;
    frm = test_frm;
    request_valid = 1'b1;
    do @(posedge clk); while (!request_ready);
    @(negedge clk);
    request_valid = 1'b0;
    do @(posedge clk); while (!result_valid);
    if (result_exception_valid != expected_exception)
      $fatal(1, "FPU exception mismatch instruction=%h", test_instruction);
    if (!expected_exception && (result_data != expected_data))
      $fatal(1, "FPU result mismatch instruction=%h got=%h expected=%h",
             test_instruction, result_data, expected_data);
    if ((result_sequence != sequence_id) || !result_destination_valid ||
        (result_destination_class != REG_FP) ||
        (result_destination_phys != destination_phys))
      $fatal(1, "FPU completion metadata mismatch");
    @(negedge clk);
    sequence_id = sequence_id + 1'b1;
  endtask

  initial begin
    clk = 1'b0;
    rst_n = 1'b0;
    request_valid = 1'b0;
    instruction = '0;
    operand_a = '0;
    operand_b = '0;
    operand_c = '0;
    rounding_mode = '0;
    frm = '0;
    sequence_id = 8'h20;
    destination_valid = 1'b1;
    destination_class = REG_FP;
    destination_phys = 7'd40;
    flush_valid = 1'b0;
    flush_all = 1'b0;
    result_ready = 1'b1;
    repeat (3) @(posedge clk);
    @(negedge clk);
    rst_n = 1'b1;

    issue_and_expect(32'hf006_00d3, 32'h3f80_0000, 0,
                     3'b000, 3'b000, 32'h3f80_0000, 1'b0); // FMV.W.X
    issue_and_expect(32'h0020_81d3, 32'h3f80_0000, 32'h4000_0000,
                     3'b000, 3'b000, 32'h4040_0000, 1'b0); // FADD.S
    issue_and_expect(32'h1020_81d3, 32'h3fc0_0000, 32'h4000_0000,
                     3'b000, 3'b000, 32'h4040_0000, 1'b0); // FMUL.S
    issue_and_expect(32'h1820_81d3, 32'h3f80_0000, 32'h4000_0000,
                     3'b000, 3'b000, 32'h3f00_0000, 1'b0); // FDIV.S
    issue_and_expect(32'h5800_81d3, 32'h4080_0000, 0,
                     3'b000, 3'b000, 32'h4000_0000, 1'b0); // FSQRT.S
    issue_and_expect(32'h0020_f1d3, 32'h3f80_0000, 32'h4000_0000,
                     3'b111, 3'b101, 0, 1'b1); // reserved dynamic rm

    $display("rv_fpu_tb PASS");
    $finish;
  end
endmodule
