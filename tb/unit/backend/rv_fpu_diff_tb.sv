module rv_fpu_diff_tb;
  import rv_ooo_pkg::*;

  logic clk, rst_n;
  logic request_valid, request_ready;
  logic [31:0] instruction, operand_a, operand_b, operand_c;
  logic [2:0] rounding_mode;
  logic [7:0] sequence_id, result_sequence;
  logic result_valid;
  logic [31:0] result_data;
  logic [4:0] result_fflags;
  logic result_exception_valid;
  reg_class_e result_destination_class;

  string vector_path;
  integer vector_file;
  integer scan_count;
  integer vector_count;
  integer vector_index;
  logic [3:0] vector_operation;
  logic [2:0] vector_rm;
  logic [31:0] vector_a, vector_b, vector_c;
  logic [31:0] vector_expected;
  logic [4:0] vector_flags;

  always #5 clk = ~clk;

  function automatic logic [31:0] arithmetic_instruction(
    input logic [3:0] operation,
    input logic [2:0] rm
  );
    logic [6:0] opcode;
    logic [6:0] funct7;
    case (operation)
      4'd0: begin opcode = 7'h53; funct7 = 7'h00; end // FADD.S
      4'd1: begin opcode = 7'h53; funct7 = 7'h04; end // FSUB.S
      4'd2: begin opcode = 7'h53; funct7 = 7'h08; end // FMUL.S
      4'd3: begin opcode = 7'h53; funct7 = 7'h0c; end // FDIV.S
      4'd4: begin opcode = 7'h43; funct7 = 7'h00; end // FMADD.S
      4'd5: begin opcode = 7'h47; funct7 = 7'h00; end // FMSUB.S
      4'd6: begin opcode = 7'h4b; funct7 = 7'h00; end // FNMSUB.S
      default: begin opcode = 7'h4f; funct7 = 7'h00; end // FNMADD.S
    endcase
    if (operation < 4)
      return {funct7, 5'd2, 5'd1, rm, 5'd3, opcode};
    if (operation == 8)
      return {7'h2c, 5'd0, 5'd1, rm, 5'd3, 7'h53};
    return {5'd3, 2'b00, 5'd2, 5'd1, rm, 5'd4, opcode};
  endfunction

  rv_fpu #(
    .XLEN(32), .ROB_SEQ_WIDTH(8), .PHYS_TAG_WIDTH(7), .LATENCY(2)
  ) u_dut (
    .clk_i(clk), .rst_ni(rst_n),
    .request_valid_i(request_valid), .request_ready_o(request_ready),
    .instruction_i(instruction), .operand_a_i(operand_a),
    .operand_b_i(operand_b), .operand_c_i(operand_c),
    .rounding_mode_i(rounding_mode), .frm_i(3'b000),
    .sequence_i(sequence_id), .destination_valid_i(1'b1),
    .destination_class_i(REG_FP), .destination_phys_i(7'd40),
    .flush_valid_i(1'b0), .flush_all_i(1'b0), .flush_sequence_i('0),
    .result_valid_o(result_valid), .result_ready_i(1'b1),
    .result_sequence_o(result_sequence),
    .result_destination_valid_o(),
    .result_destination_class_o(result_destination_class),
    .result_destination_phys_o(), .result_data_o(result_data),
    .result_fflags_o(result_fflags),
    .result_exception_valid_o(result_exception_valid),
    .result_exception_cause_o(), .result_exception_tval_o()
  );

  task automatic issue_vector;
    instruction = arithmetic_instruction(vector_operation, vector_rm);
    operand_a = vector_a;
    operand_b = vector_b;
    operand_c = vector_c;
    rounding_mode = vector_rm;
    request_valid = 1'b1;
    do @(posedge clk); while (!request_ready);
    @(negedge clk);
    request_valid = 1'b0;
    do @(posedge clk); while (!result_valid);
    if (result_exception_valid || (result_sequence !== sequence_id) ||
        (result_destination_class !== REG_FP) ||
        (result_data !== vector_expected) ||
        (result_fflags !== vector_flags)) begin
      $fatal(1,
        "FPU differential mismatch vector=%0d op=%0d rm=%0d a=%h b=%h c=%h got=%h/%h expected=%h/%h exception=%b",
        vector_index, vector_operation, vector_rm, vector_a, vector_b,
        vector_c, result_data, result_fflags, vector_expected, vector_flags,
        result_exception_valid);
    end
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
    sequence_id = 8'h20;
    vector_count = 0;
    vector_index = 0;
    vector_path = "tb/fixtures/fpu/fpu_diff_vectors.hex";
    if ($value$plusargs("fpu_vectors=%s", vector_path)) begin end

    repeat (3) @(posedge clk);
    @(negedge clk);
    rst_n = 1'b1;

    vector_file = $fopen(vector_path, "r");
    if (vector_file == 0)
      $fatal(1, "Unable to open FPU differential vectors: %s", vector_path);

    while (!$feof(vector_file)) begin
      scan_count = $fscanf(vector_file, "%h %h %h %h %h %h %h\n",
                           vector_operation, vector_rm, vector_a, vector_b,
                           vector_c, vector_expected, vector_flags);
      if (scan_count == 7) begin
        issue_vector();
        vector_count = vector_count + 1;
        vector_index = vector_index + 1;
      end else if (!$feof(vector_file)) begin
        $fatal(1, "Malformed FPU vector at index %0d", vector_index);
      end
    end
    $fclose(vector_file);
    if (vector_count == 0)
      $fatal(1, "FPU differential vector file was empty");
    $display("rv_fpu_diff_tb PASS vectors=%0d", vector_count);
    $finish;
  end
endmodule
