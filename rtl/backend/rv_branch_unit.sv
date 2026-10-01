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
  logic operands_equal, operands_unsigned_less, operands_signed_less;

  // Compare four-bit groups in parallel, then select the highest differing
  // group by a prefix of equality predicates. Signed/unsigned conditions
  // share the magnitude comparison instead of duplicating full-width trees.
  function automatic logic grouped_unsigned_less(
    input logic [XLEN-1:0] lhs, input logic [XLEN-1:0] rhs
  );
    localparam int GROUPS = XLEN / 4;
    logic [GROUPS-1:0] equal_group, less_group;
    logic higher_equal;
    for (int group = 0; group < GROUPS; group++) begin
      equal_group[group] = lhs[group*4 +: 4] == rhs[group*4 +: 4];
      less_group[group] = lhs[group*4 +: 4] < rhs[group*4 +: 4];
    end
    grouped_unsigned_less = 1'b0;
    for (int group = 0; group < GROUPS; group++) begin
      higher_equal = 1'b1;
      for (int higher = group + 1; higher < GROUPS; higher++)
        higher_equal &= equal_group[higher];
      grouped_unsigned_less |= less_group[group] && higher_equal;
    end
  endfunction

  assign operands_equal = operand_a_i == operand_b_i;
  assign operands_unsigned_less = grouped_unsigned_less(operand_a_i, operand_b_i);
  assign operands_signed_less = (operand_a_i[XLEN-1] != operand_b_i[XLEN-1]) ?
                                operand_a_i[XLEN-1] : operands_unsigned_less;

  function automatic logic [XLEN-1:0] target_add(
    input logic [XLEN-1:0] lhs, input logic [XLEN-1:0] rhs
  );
    localparam int GROUPS = XLEN / 4;
    logic [GROUPS-1:0] propagate, generate_carry, carry;
    logic [4:0] sum0 [0:GROUPS-1], sum1 [0:GROUPS-1];
    logic term;
    for (int group = 0; group < GROUPS; group++) begin
      sum0[group] = {1'b0,lhs[group*4 +: 4]} + {1'b0,rhs[group*4 +: 4]};
      sum1[group] = sum0[group] + 5'd1;
      propagate[group] = &(lhs[group*4 +: 4] ^ rhs[group*4 +: 4]);
      generate_carry[group] = sum0[group][4];
    end
    for (int group = 0; group < GROUPS; group++) begin
      carry[group] = 1'b0;
      for (int source = 0; source < group; source++) begin
        term = generate_carry[source];
        for (int between = source + 1; between < group; between++)
          term &= propagate[between];
        carry[group] |= term;
      end
      target_add[group*4 +: 4] = carry[group] ? sum1[group][3:0] : sum0[group][3:0];
    end
  endfunction

  always_comb begin
    sequential_pc = target_add(pc_i, XLEN'(instruction_bytes_i));
    direct_target = target_add(pc_i, immediate_i);
    indirect_target = target_add(operand_a_i, immediate_i) &
                      {{(XLEN-1){1'b1}}, 1'b0};
    conditional_taken = 1'b0;

    case (operation_i)
      BR_EQ:  conditional_taken = operands_equal;
      BR_NE:  conditional_taken = !operands_equal;
      BR_LT:  conditional_taken = operands_signed_less;
      BR_GE:  conditional_taken = !operands_signed_less;
      BR_LTU: conditional_taken = operands_unsigned_less;
      BR_GEU: conditional_taken = !operands_unsigned_less;
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
