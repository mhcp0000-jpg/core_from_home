module rv_execute_units_tb;
  import rv_ooo_pkg::*;

  logic [31:0] alu32_a;
  logic [31:0] alu32_b;
  int_alu_op_e alu32_op;
  logic [31:0] alu32_result;
  logic [63:0] alu64_a;
  logic [63:0] alu64_b;
  int_alu_op_e alu64_op;
  logic alu64_word;
  logic [63:0] alu64_result;

  logic branch_valid;
  branch_op_e branch_op;
  logic [31:0] branch_pc;
  logic [31:0] branch_a;
  logic [31:0] branch_b;
  logic [31:0] branch_imm;
  logic [2:0] branch_instruction_bytes;
  logic branch_predicted_taken;
  logic [31:0] branch_predicted_target;
  logic branch_taken;
  logic [31:0] branch_target;
  logic [31:0] branch_next_pc;
  logic [31:0] branch_link;
  logic branch_misaligned;
  logic branch_mispredict;

  rv_int_alu #(.XLEN(32)) u_alu32 (
    .operand_a_i      (alu32_a),
    .operand_b_i      (alu32_b),
    .operation_i      (alu32_op),
    .word_operation_i (1'b0),
    .result_o         (alu32_result)
  );

  rv_int_alu #(.XLEN(64)) u_alu64 (
    .operand_a_i      (alu64_a),
    .operand_b_i      (alu64_b),
    .operation_i      (alu64_op),
    .word_operation_i (alu64_word),
    .result_o         (alu64_result)
  );

  rv_branch_unit #(.XLEN(32)) u_branch (
    .valid_i             (branch_valid),
    .operation_i         (branch_op),
    .pc_i                (branch_pc),
    .operand_a_i         (branch_a),
    .operand_b_i         (branch_b),
    .immediate_i         (branch_imm),
    .instruction_bytes_i (branch_instruction_bytes),
    .predicted_taken_i   (branch_predicted_taken),
    .predicted_target_i  (branch_predicted_target),
    .taken_o             (branch_taken),
    .target_o            (branch_target),
    .next_pc_o           (branch_next_pc),
    .link_value_o        (branch_link),
    .target_misaligned_o (branch_misaligned),
    .mispredict_o        (branch_mispredict)
  );

  initial begin : p_execute_test
    alu32_a = 32'hffff_ffff;
    alu32_b = 1;
    alu32_op = ALU_ADD;
    alu64_a = '0;
    alu64_b = '0;
    alu64_op = ALU_ADD;
    alu64_word = 1'b0;
    branch_valid = 1'b0;
    branch_op = BR_NONE;
    branch_pc = '0;
    branch_a = '0;
    branch_b = '0;
    branch_imm = '0;
    branch_instruction_bytes = 3'd4;
    branch_predicted_taken = 1'b0;
    branch_predicted_target = '0;
    #1;
    if (alu32_result != 0)
      $fatal(1, "ALU32 ADD wrap failed");

    alu32_a = 32'hffff_ffff;
    alu32_b = 0;
    alu32_op = ALU_SLT;
    #1;
    if (alu32_result != 1)
      $fatal(1, "ALU32 signed compare failed");
    alu32_op = ALU_SLTU;
    #1;
    if (alu32_result != 0)
      $fatal(1, "ALU32 unsigned compare failed");

    alu32_a = 32'h8000_0000;
    alu32_b = 4;
    alu32_op = ALU_SRA;
    #1;
    if (alu32_result != 32'hf800_0000)
      $fatal(1, "ALU32 arithmetic shift failed");

    alu64_a = 64'h0000_0000_7fff_ffff;
    alu64_b = 1;
    alu64_op = ALU_ADD;
    alu64_word = 1'b1;
    #1;
    if (alu64_result != 64'hffff_ffff_8000_0000)
      $fatal(1, "ALU64 ADDW sign extension failed");
    alu64_a = 64'hffff_ffff_8000_0000;
    alu64_b = 4;
    alu64_op = ALU_SRA;
    #1;
    if (alu64_result != 64'hffff_ffff_f800_0000)
      $fatal(1, "ALU64 SRAW sign extension failed");

    branch_valid = 1'b1;
    branch_op = BR_EQ;
    branch_pc = 32'h1000;
    branch_a = 32'h55;
    branch_b = 32'h55;
    branch_imm = 32'h20;
    branch_instruction_bytes = 3'd4;
    branch_predicted_taken = 1'b0;
    #1;
    if (!branch_taken || (branch_target != 32'h1020) ||
        (branch_next_pc != 32'h1020) || !branch_mispredict ||
        (branch_link != 32'h1004))
      $fatal(1, "Conditional branch resolve failed");

    branch_op = BR_NE;
    branch_predicted_taken = 1'b0;
    branch_predicted_target = 32'hdead_beef;
    #1;
    if (branch_taken || (branch_next_pc != 32'h1004) || branch_mispredict)
      $fatal(1, "Correctly predicted not-taken branch failed");

    branch_op = BR_JALR;
    branch_a = 32'h2001;
    branch_imm = 4;
    branch_instruction_bytes = 3'd2;
    branch_predicted_taken = 1'b1;
    branch_predicted_target = 32'h2004;
    #1;
    if (!branch_taken || (branch_target != 32'h2004) ||
        (branch_link != 32'h1002) || branch_mispredict || branch_misaligned)
      $fatal(1, "JALR target masking/link calculation failed");

    $display("rv_execute_units_tb PASS");
    $finish;
  end
endmodule
