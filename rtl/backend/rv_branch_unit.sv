module rv_branch_unit #(
  parameter int unsigned XLEN = 32
) (
  input  logic                         valid_i,
  input  rv_ooo_pkg::branch_op_e       operation_i,
  input  logic [XLEN-1:0]              pc_i,
  input  logic [XLEN-1:0]              operand_a_i,
  input  logic [XLEN-1:0]              operand_b_i,
  input  logic [XLEN-1:0]              immediate_i,
  input  logic [2:0]                   instruction_bytes_i,
  input  logic                         predicted_taken_i,
  input  logic [XLEN-1:0]              predicted_target_i,

  output logic                         taken_o,
  output logic [XLEN-1:0]              target_o,
  output logic [XLEN-1:0]              next_pc_o,
  output logic [XLEN-1:0]              link_value_o,
  output logic                         target_misaligned_o,
  output logic                         mispredict_o
);

  import rv_ooo_pkg::*;

  logic conditional_taken;
  logic [XLEN-1:0] sequential_pc;
  logic [XLEN-1:0] direct_target;
  logic [XLEN-1:0] indirect_target;

  always_comb begin
    sequential_pc = pc_i + XLEN'(instruction_bytes_i);
    direct_target = pc_i + immediate_i;
    indirect_target = (operand_a_i + immediate_i) &
                      {{(XLEN-1){1'b1}}, 1'b0};
    conditional_taken = 1'b0;

    case (operation_i)
      BR_EQ:  conditional_taken = (operand_a_i == operand_b_i);
      BR_NE:  conditional_taken = (operand_a_i != operand_b_i);
      BR_LT:  conditional_taken = $signed(operand_a_i) <
                                   $signed(operand_b_i);
      BR_GE:  conditional_taken = $signed(operand_a_i) >=
                                   $signed(operand_b_i);
      BR_LTU: conditional_taken = operand_a_i < operand_b_i;
      BR_GEU: conditional_taken = operand_a_i >= operand_b_i;
      default: conditional_taken = 1'b0;
    endcase

    taken_o = 1'b0;
    target_o = direct_target;
    case (operation_i)
      BR_EQ, BR_NE, BR_LT, BR_GE, BR_LTU, BR_GEU: begin
        taken_o  = conditional_taken;
        target_o = direct_target;
      end
      BR_JAL: begin
        taken_o  = 1'b1;
        target_o = direct_target;
      end
      BR_JALR: begin
        taken_o  = 1'b1;
        target_o = indirect_target;
      end
      default: begin
        taken_o  = 1'b0;
        target_o = sequential_pc;
      end
    endcase

    next_pc_o = taken_o ? target_o : sequential_pc;
    link_value_o = sequential_pc;
    target_misaligned_o = valid_i && taken_o && target_o[0];
    mispredict_o = valid_i &&
      ((predicted_taken_i != taken_o) ||
       (taken_o && (predicted_target_i != target_o)));
  end

  initial begin : p_parameter_checks
    if ((XLEN != 32) && (XLEN != 64))
      $fatal(1, "Branch unit XLEN must be 32 or 64");
  end

endmodule
