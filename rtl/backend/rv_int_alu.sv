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

  always_comb begin
    case (operation_i)
      ALU_ADD:       full_result = operand_a_i + operand_b_i;
      ALU_SUB:       full_result = operand_a_i - operand_b_i;
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
      ALU_ADD:       word_result = operand_a_i[31:0] + operand_b_i[31:0];
      ALU_SUB:       word_result = operand_a_i[31:0] - operand_b_i[31:0];
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
