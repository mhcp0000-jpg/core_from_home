module rv_fpu_diff_tb;
  import rv_ooo_pkg::*;

  logic clk, rst_n;
  logic request_valid, request_ready;
  logic [31:0] instruction, operand_a, operand_b, operand_c;
  logic [2:0] rounding_mode;
  logic [2:0] frm;
  bit dynamic_rounding;
  logic [7:0] sequence_id, result_sequence;
  logic result_valid;
  logic [31:0] result_data;
  logic [4:0] result_fflags;
  logic result_exception_valid;
  reg_class_e destination_class;
  reg_class_e result_destination_class;

  string vector_path;
  integer vector_file;
  integer scan_count;
  integer vector_count;
  integer vector_index;
  logic [4:0] vector_operation;
  logic [2:0] vector_rm;
  logic [31:0] vector_a, vector_b, vector_c;
  logic [31:0] vector_expected;
  logic [4:0] vector_flags;

  always #5 clk = ~clk;

  function automatic logic [31:0] arithmetic_instruction(
    input logic [4:0] operation,
    input logic [2:0] rm
  );
    logic [6:0] opcode;
    logic [6:0] funct7;
    logic [4:0] rs2;
    logic [2:0] funct3;
    opcode = 7'h53;
    funct7 = '0;
    rs2 = 5'd2;
    funct3 = rm;
    case (operation)
      5'd0: funct7 = 7'h00; // FADD.S
      5'd1: funct7 = 7'h04; // FSUB.S
      5'd2: funct7 = 7'h08; // FMUL.S
      5'd3: funct7 = 7'h0c; // FDIV.S
      5'd4: opcode = 7'h43; // FMADD.S
      5'd5: opcode = 7'h47; // FMSUB.S
      5'd6: opcode = 7'h4b; // FNMSUB.S
      5'd7: opcode = 7'h4f; // FNMADD.S
      5'd8: begin funct7 = 7'h2c; rs2 = 0; end // FSQRT.S
      5'd9: begin funct7 = 7'h10; funct3 = 0; end // FSGNJ.S
      5'd10: begin funct7 = 7'h10; funct3 = 1; end // FSGNJN.S
      5'd11: begin funct7 = 7'h10; funct3 = 2; end // FSGNJX.S
      5'd12: begin funct7 = 7'h14; funct3 = 0; end // FMIN.S
      5'd13: begin funct7 = 7'h14; funct3 = 1; end // FMAX.S
      5'd14: begin funct7 = 7'h50; funct3 = 2; end // FEQ.S
      5'd15: begin funct7 = 7'h50; funct3 = 1; end // FLT.S
      5'd16: begin funct7 = 7'h50; funct3 = 0; end // FLE.S
      5'd17: begin funct7 = 7'h60; rs2 = 0; end // FCVT.W.S
      5'd18: begin funct7 = 7'h60; rs2 = 1; end // FCVT.WU.S
      5'd19: begin funct7 = 7'h68; rs2 = 0; end // FCVT.S.W
      5'd20: begin funct7 = 7'h68; rs2 = 1; end // FCVT.S.WU
      5'd21: begin funct7 = 7'h70; rs2 = 0; funct3 = 1; end // FCLASS.S
      5'd22: begin funct7 = 7'h70; rs2 = 0; funct3 = 0; end // FMV.X.W
      default: begin funct7 = 7'h78; rs2 = 0; funct3 = 0; end // FMV.W.X
    endcase
    if ((operation >= 4) && (operation <= 7))
      return {5'd3, 2'b00, 5'd2, 5'd1, rm, 5'd4, opcode};
    return {funct7, rs2, 5'd1, funct3, 5'd3, opcode};
  endfunction

  function automatic reg_class_e operation_destination_class(
    input logic [4:0] operation
  );
    if (((operation >= 14) && (operation <= 18)) ||
        (operation == 21) || (operation == 22))
      return REG_INT;
    return REG_FP;
  endfunction

  rv_fpu #(
    .XLEN(32), .ROB_SEQ_WIDTH(8), .PHYS_TAG_WIDTH(7), .LATENCY(2)
  ) u_dut (
    .clk_i(clk), .rst_ni(rst_n),
    .request_valid_i(request_valid), .request_ready_o(request_ready),
    .instruction_i(instruction), .operand_a_i(operand_a),
    .operand_b_i(operand_b), .operand_c_i(operand_c),
    .rounding_mode_i(rounding_mode), .frm_i(frm),
    .sequence_i(sequence_id), .destination_valid_i(1'b1),
    .destination_class_i(destination_class), .destination_phys_i(7'd40),
    .flush_valid_i(1'b0), .flush_all_i(1'b0), .flush_sequence_i(8'b0),
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
    // Only arithmetic/conversion instructions interpret funct3 as rm.
    // Sign/min/compare/class/move retain their operation-select funct3.
    frm = vector_rm;
    if (dynamic_rounding && ((vector_operation <= 8) ||
        ((vector_operation >= 17) && (vector_operation <= 20))))
      instruction[14:12] = 3'b111;
    operand_a = vector_a;
    operand_b = vector_b;
    operand_c = vector_c;
    rounding_mode = instruction[14:12];
    destination_class = operation_destination_class(vector_operation);
    request_valid = 1'b1;
    do @(posedge clk); while (!request_ready);
    @(negedge clk);
    request_valid = 1'b0;
    do @(posedge clk); while (!result_valid);
    if (result_exception_valid || (result_sequence !== sequence_id) ||
        (result_destination_class !== destination_class) ||
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
    frm = '0;
    dynamic_rounding = $test$plusargs("fpu_dynamic_rm");
    destination_class = REG_FP;
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
    $display("rv_fpu_diff_tb PASS vectors=%0d dynamic_rm=%0b",
             vector_count, dynamic_rounding);
    $finish;
  end
endmodule
