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

  function automatic logic [31:0] fp_op(
    input logic [6:0] funct7,
    input logic [4:0] rs2,
    input logic [2:0] funct3
  );
    return {funct7, rs2, 5'd1, funct3, 5'd3, 7'h53};
  endfunction

  function automatic logic [31:0] fp_fma_op(input logic [6:0] opcode);
    return {5'd3, 2'b00, 5'd2, 5'd1, 3'b000, 5'd4, opcode};
  endfunction

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
    input logic [31:0] test_c,
    input logic [2:0] test_rm,
    input logic [2:0] test_frm,
    input logic [31:0] expected_data,
    input logic [4:0] expected_flags,
    input logic expected_exception,
    input reg_class_e expected_class
  );
    instruction = test_instruction;
    operand_a = test_a;
    operand_b = test_b;
    operand_c = test_c;
    rounding_mode = test_rm;
    frm = test_frm;
    destination_class = expected_class;
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
    if (result_fflags != expected_flags)
      $fatal(1, "FPU flags mismatch instruction=%h got=%h expected=%h",
             test_instruction, result_fflags, expected_flags);
    if ((result_sequence != sequence_id) || !result_destination_valid ||
        (result_destination_class != expected_class) ||
        (result_destination_phys != destination_phys))
      $fatal(1, "FPU completion metadata mismatch instruction=%h seq=%h/%h valid=%b class=%0d/%0d phys=%0d/%0d",
             test_instruction, result_sequence, sequence_id,
             result_destination_valid, result_destination_class, expected_class,
             result_destination_phys, destination_phys);
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

    issue_and_expect(fp_op(7'h78, 0, 0), 32'h3f80_0000, 0, 0,
                     3'b000, 3'b000, 32'h3f80_0000, 0, 1'b0, REG_FP); // FMV.W.X
    issue_and_expect(fp_op(7'h00, 2, 0), 32'h3f80_0000, 32'h4000_0000, 0,
                     3'b000, 3'b000, 32'h4040_0000, 0, 1'b0, REG_FP); // FADD.S
    issue_and_expect(fp_op(7'h04, 2, 0), 32'h40b0_0000, 32'h4000_0000, 0,
                     3'b000, 3'b000, 32'h4060_0000, 0, 1'b0, REG_FP); // FSUB.S
    issue_and_expect(fp_op(7'h08, 2, 0), 32'h3fc0_0000, 32'h4000_0000, 0,
                     3'b000, 3'b000, 32'h4040_0000, 0, 1'b0, REG_FP); // FMUL.S
    issue_and_expect(fp_op(7'h0c, 2, 0), 32'h3f80_0000, 32'h4000_0000, 0,
                     3'b000, 3'b000, 32'h3f00_0000, 0, 1'b0, REG_FP); // FDIV.S
    issue_and_expect(fp_op(7'h0c, 2, 0), 32'h3f80_0000, 0, 0,
                     3'b000, 3'b000, 32'h7f80_0000, 5'b01000, 1'b0, REG_FP); // divide by zero
    issue_and_expect(fp_op(7'h2c, 0, 0), 32'h4080_0000, 0, 0,
                     3'b000, 3'b000, 32'h4000_0000, 0, 1'b0, REG_FP); // FSQRT.S
    issue_and_expect(fp_op(7'h2c, 0, 0), 32'hbf80_0000, 0, 0,
                     3'b000, 3'b000, 32'h7fc0_0000, 5'b10000, 1'b0, REG_FP); // sqrt(-1)

    issue_and_expect(fp_op(7'h10, 2, 0), 32'hbfc0_0000, 32'h4000_0000, 0,
                     3'b000, 3'b000, 32'h3fc0_0000, 0, 1'b0, REG_FP); // FSGNJ.S
    issue_and_expect(fp_op(7'h10, 2, 1), 32'h3fc0_0000, 32'h4000_0000, 0,
                     3'b001, 3'b000, 32'hbfc0_0000, 0, 1'b0, REG_FP); // FSGNJN.S
    issue_and_expect(fp_op(7'h10, 2, 2), 32'hbfc0_0000, 32'hc000_0000, 0,
                     3'b010, 3'b000, 32'h3fc0_0000, 0, 1'b0, REG_FP); // FSGNJX.S
    issue_and_expect(fp_op(7'h14, 2, 0), 32'hbf80_0000, 32'h4000_0000, 0,
                     3'b000, 3'b000, 32'hbf80_0000, 0, 1'b0, REG_FP); // FMIN.S
    issue_and_expect(fp_op(7'h14, 2, 1), 32'hbf80_0000, 32'h4000_0000, 0,
                     3'b001, 3'b000, 32'h4000_0000, 0, 1'b0, REG_FP); // FMAX.S

    issue_and_expect(fp_op(7'h50, 2, 2), 32'h3f80_0000, 32'h3f80_0000, 0,
                     3'b010, 3'b000, 32'h0000_0001, 0, 1'b0, REG_INT); // FEQ.S
    issue_and_expect(fp_op(7'h50, 2, 1), 32'hbf80_0000, 32'h4000_0000, 0,
                     3'b001, 3'b000, 32'h0000_0001, 0, 1'b0, REG_INT); // FLT.S
    issue_and_expect(fp_op(7'h50, 2, 0), 32'h4000_0000, 32'h3f80_0000, 0,
                     3'b000, 3'b000, 32'h0000_0000, 0, 1'b0, REG_INT); // FLE.S
    issue_and_expect(fp_op(7'h60, 0, 0), 32'h4060_0000, 0, 0,
                     3'b000, 3'b000, 32'h0000_0004, 5'b00001, 1'b0, REG_INT); // FCVT.W.S 3.5
    issue_and_expect(fp_op(7'h68, 0, 0), 32'hffff_fffd, 0, 0,
                     3'b000, 3'b000, 32'hc040_0000, 0, 1'b0, REG_FP); // FCVT.S.W -3
    issue_and_expect(fp_op(7'h68, 1, 0), 32'hffff_ffff, 0, 0,
                     3'b000, 3'b000, 32'h4f80_0000, 5'b00001, 1'b0, REG_FP); // FCVT.S.WU
    issue_and_expect(fp_op(7'h70, 0, 1), 32'h7f80_0000, 0, 0,
                     3'b001, 3'b000, 32'h0000_0080, 0, 1'b0, REG_INT); // FCLASS.S +inf
    issue_and_expect(fp_op(7'h70, 0, 0), 32'hbf80_0000, 0, 0,
                     3'b000, 3'b000, 32'hbf80_0000, 0, 1'b0, REG_INT); // FMV.X.W

    issue_and_expect(fp_fma_op(7'h43), 32'h3fc0_0000, 32'h4000_0000,
                     32'h3f00_0000, 3'b000, 3'b000, 32'h4060_0000,
                     0, 1'b0, REG_FP); // FMADD.S
    issue_and_expect(fp_op(7'h00, 2, 0), 32'h3f80_0000, 32'h0000_0001, 0,
                     3'b011, 3'b000, 32'h3f80_0001, 5'b00001, 1'b0, REG_FP); // RUP
    issue_and_expect(fp_op(7'h00, 2, 7), 32'h3f80_0000, 32'h4000_0000, 0,
                     3'b111, 3'b101, 0, 0, 1'b1, REG_FP); // reserved dynamic rm

    $display("rv_fpu_tb PASS");
    $finish;
  end
endmodule
