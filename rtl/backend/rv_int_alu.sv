module rv_int_alu #(
  parameter int unsigned XLEN = 32,
  localparam int unsigned SHAMT_WIDTH = $clog2(XLEN)
) (
  input  logic [XLEN-1:0]             operand_a_i,
  input  logic [XLEN-1:0]             operand_b_i,
  input  rv_ooo_pkg::int_alu_op_e      operation_i,
  input  logic                        word_operation_i,
  output logic [XLEN-1:0]             result_o
);

  import rv_ooo_pkg::*;

  logic [XLEN-1:0] full_result;
  logic [31:0] word_result;
  logic [XLEN-1:0] add_result, sub_result;

  // Four-bit carry-select slices calculate both carry cases in parallel.
  // Group carry is an AND/OR prefix of propagate/generate terms rather than
  // a full-width serial carry chain. The low 32 bits also serve ADDW/SUBW.
  function automatic logic [XLEN-1:0] sliced_add(
    input logic [XLEN-1:0] lhs,
    input logic [XLEN-1:0] rhs,
    input logic carry_in
  );
    localparam int GROUPS = XLEN/4;
    logic [GROUPS-1:0] propagate, generate_carry, carry;
    logic [4:0] sum0 [0:GROUPS-1];
    logic [4:0] sum1 [0:GROUPS-1];
    logic term;
    for (int group = 0; group < GROUPS; group++) begin
      sum0[group] = {1'b0,lhs[group*4 +: 4]} +
                    {1'b0,rhs[group*4 +: 4]};
      sum1[group] = {1'b0,lhs[group*4 +: 4]} +
                    {1'b0,rhs[group*4 +: 4]} + 5'd1;
      propagate[group] = &(lhs[group*4 +: 4] ^ rhs[group*4 +: 4]);
      generate_carry[group] = sum0[group][4];
    end
    for (int group = 0; group < GROUPS; group++) begin
      term = carry_in;
      for (int earlier = 0; earlier < group; earlier++)
        term &= propagate[earlier];
      carry[group] = term;
      for (int source = 0; source < group; source++) begin
        term = generate_carry[source];
        for (int between = source+1; between < group; between++)
          term &= propagate[between];
        carry[group] |= term;
      end
      sliced_add[group*4 +: 4] = carry[group] ?
        sum1[group][3:0] : sum0[group][3:0];
    end
  endfunction

  assign add_result = sliced_add(operand_a_i, operand_b_i, 1'b0);
  assign sub_result = sliced_add(operand_a_i, ~operand_b_i, 1'b1);

  always_comb begin
    case (operation_i)
      ALU_ADD:       full_result = add_result;
      ALU_SUB:       full_result = sub_result;
      ALU_SLT:       full_result = XLEN'($signed(operand_a_i) <
                                         $signed(operand_b_i));
      ALU_SLTU:      full_result = XLEN'(operand_a_i < operand_b_i);
      ALU_XOR:       full_result = operand_a_i ^ operand_b_i;
      ALU_OR:        full_result = operand_a_i | operand_b_i;
      ALU_AND:       full_result = operand_a_i & operand_b_i;
      ALU_SLL:       full_result = operand_a_i <<
                                   operand_b_i[SHAMT_WIDTH-1:0];
      ALU_SRL:       full_result = operand_a_i >>
                                   operand_b_i[SHAMT_WIDTH-1:0];
      ALU_SRA:       full_result = $unsigned($signed(operand_a_i) >>>
                                             operand_b_i[SHAMT_WIDTH-1:0]);
      ALU_COPY_SRC0: full_result = operand_a_i;
      ALU_COPY_SRC1: full_result = operand_b_i;
      default:       full_result = '0;
    endcase

    case (operation_i)
      ALU_ADD:       word_result = add_result[31:0];
      ALU_SUB:       word_result = sub_result[31:0];
      ALU_SLT:       word_result = 32'($signed(operand_a_i[31:0]) <
                                       $signed(operand_b_i[31:0]));
      ALU_SLTU:      word_result = 32'(operand_a_i[31:0] < operand_b_i[31:0]);
      ALU_XOR:       word_result = operand_a_i[31:0] ^ operand_b_i[31:0];
      ALU_OR:        word_result = operand_a_i[31:0] | operand_b_i[31:0];
      ALU_AND:       word_result = operand_a_i[31:0] & operand_b_i[31:0];
      ALU_SLL:       word_result = operand_a_i[31:0] << operand_b_i[4:0];
      ALU_SRL:       word_result = operand_a_i[31:0] >> operand_b_i[4:0];
      ALU_SRA:       word_result =
        $unsigned($signed(operand_a_i[31:0]) >>> operand_b_i[4:0]);
      ALU_COPY_SRC0: word_result = operand_a_i[31:0];
      ALU_COPY_SRC1: word_result = operand_b_i[31:0];
      default:       word_result = '0;
    endcase

    if ((XLEN == 64) && word_operation_i)
      result_o = {{(XLEN-32){word_result[31]}}, word_result};
    else
      result_o = full_result;
  end

  initial begin : p_parameter_checks
    if ((XLEN != 32) && (XLEN != 64))
      $fatal(1, "Integer ALU XLEN must be 32 or 64");
  end

endmodule
