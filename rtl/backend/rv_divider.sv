module rv_divider #(
  parameter int unsigned XLEN           = 32,
  parameter int unsigned ROB_SEQ_WIDTH  = rv_ooo_pkg::ROB_SEQ_WIDTH,
  parameter int unsigned PHYS_TAG_WIDTH = 7,
  localparam int unsigned COUNT_WIDTH   = $clog2(XLEN + 1)
) (
  input  logic                            clk_i,
  input  logic                            rst_ni,

  input  logic                            request_valid_i,
  output logic                            request_ready_o,
  input  logic [XLEN-1:0]                 operand_a_i,
  input  logic [XLEN-1:0]                 operand_b_i,
  input  rv_ooo_pkg::divide_op_e          operation_i,
  input  logic                            word_operation_i,
  input  logic [ROB_SEQ_WIDTH-1:0]        request_rob_sequence_i,
  input  logic                            request_destination_valid_i,
  input  logic [PHYS_TAG_WIDTH-1:0]       request_destination_phys_i,

  input  logic                            flush_valid_i,
  input  logic                            flush_all_i,
  input  logic [ROB_SEQ_WIDTH-1:0]        flush_sequence_i,

  output logic                            result_valid_o,
  input  logic                            result_ready_i,
  output logic [XLEN-1:0]                 result_o,
  output logic [ROB_SEQ_WIDTH-1:0]        result_rob_sequence_o,
  output logic                            result_destination_valid_o,
  output logic [PHYS_TAG_WIDTH-1:0]       result_destination_phys_o
);

  import rv_ooo_pkg::*;

  logic busy_q;
  logic [XLEN-1:0] dividend_q;
  logic [XLEN-1:0] divisor_q;
  logic [XLEN:0] remainder_q;
  logic [XLEN-1:0] quotient_q;
  logic [COUNT_WIDTH-1:0] iteration_q;
  logic quotient_negative_q;
  logic remainder_negative_q;
  logic quotient_result_q;
  logic word_operation_q;
  logic [ROB_SEQ_WIDTH-1:0] rob_sequence_q;
  logic destination_valid_q;
  logic [PHYS_TAG_WIDTH-1:0] destination_phys_q;

  logic result_valid_q;
  logic [XLEN-1:0] result_q;
  logic [ROB_SEQ_WIDTH-1:0] result_rob_sequence_q;
  logic result_destination_valid_q;
  logic [PHYS_TAG_WIDTH-1:0] result_destination_phys_q;

  logic signed_operation;
  logic quotient_operation;
  logic [XLEN-1:0] operand_a_effective;
  logic [XLEN-1:0] operand_b_effective;
  logic [XLEN-1:0] dividend_absolute;
  logic [XLEN-1:0] divisor_absolute;
  logic dividend_negative;
  logic divisor_negative;
  logic [XLEN-1:0] signed_minimum;
  logic divide_by_zero;
  logic signed_overflow;
  logic [COUNT_WIDTH-1:0] request_iterations;

  logic [XLEN:0] trial_remainder;
  logic [XLEN:0] reduced_remainder;
  logic [XLEN-1:0] quotient_next;
  logic [XLEN-1:0] signed_quotient_next;
  logic [XLEN-1:0] signed_remainder_next;
  logic [XLEN-1:0] selected_result_next;

  function automatic logic sequence_is_younger(
    input logic [ROB_SEQ_WIDTH-1:0] candidate,
    input logic [ROB_SEQ_WIDTH-1:0] boundary
  );
    logic [ROB_SEQ_WIDTH-1:0] distance;
    distance = candidate - boundary;
    return (distance != 0) && !distance[ROB_SEQ_WIDTH-1];
  endfunction

  always_comb begin
    signed_operation = (operation_i == DIV_SIGNED_QUOTIENT) ||
                       (operation_i == DIV_SIGNED_REMAINDER);
    quotient_operation = (operation_i == DIV_SIGNED_QUOTIENT) ||
                         (operation_i == DIV_UNSIGNED_QUOTIENT);

    if ((XLEN == 64) && word_operation_i) begin
      operand_a_effective = signed_operation ?
        {{(XLEN-32){operand_a_i[31]}}, operand_a_i[31:0]} :
        {{(XLEN-32){1'b0}}, operand_a_i[31:0]};
      operand_b_effective = signed_operation ?
        {{(XLEN-32){operand_b_i[31]}}, operand_b_i[31:0]} :
        {{(XLEN-32){1'b0}}, operand_b_i[31:0]};
      signed_minimum = {{(XLEN-32){1'b1}}, 32'h8000_0000};
      request_iterations = COUNT_WIDTH'(32);
    end else begin
      operand_a_effective = operand_a_i;
      operand_b_effective = operand_b_i;
      signed_minimum = {1'b1, {(XLEN-1){1'b0}}};
      request_iterations = COUNT_WIDTH'(XLEN);
    end

    dividend_negative = signed_operation && operand_a_effective[XLEN-1];
    divisor_negative = signed_operation && operand_b_effective[XLEN-1];
    dividend_absolute = dividend_negative ?
                        (~operand_a_effective + 1'b1) : operand_a_effective;
    divisor_absolute = divisor_negative ?
                       (~operand_b_effective + 1'b1) : operand_b_effective;
    divide_by_zero = (operand_b_effective == 0);
    signed_overflow = signed_operation &&
                      (operand_a_effective == signed_minimum) &&
                      (&operand_b_effective);

    trial_remainder = remainder_q;
    reduced_remainder = remainder_q;
    quotient_next = quotient_q;
    if (iteration_q != 0) begin
      trial_remainder = {remainder_q[XLEN-1:0],
                         dividend_q[iteration_q-1'b1]};
      if (trial_remainder >= {1'b0, divisor_q}) begin
        reduced_remainder = trial_remainder - {1'b0, divisor_q};
        quotient_next[iteration_q-1'b1] = 1'b1;
      end else begin
        reduced_remainder = trial_remainder;
        quotient_next[iteration_q-1'b1] = 1'b0;
      end
    end

    signed_quotient_next = quotient_negative_q ?
                           (~quotient_next + 1'b1) : quotient_next;
    signed_remainder_next = remainder_negative_q ?
                            (~reduced_remainder[XLEN-1:0] + 1'b1) :
                            reduced_remainder[XLEN-1:0];
    selected_result_next = quotient_result_q ?
                           signed_quotient_next : signed_remainder_next;
    if ((XLEN == 64) && word_operation_q)
      selected_result_next = {{(XLEN-32){selected_result_next[31]}},
                              selected_result_next[31:0]};
  end

  assign request_ready_o = !busy_q && !result_valid_q && !flush_valid_i;
  assign result_valid_o = result_valid_q;
  assign result_o = result_q;
  assign result_rob_sequence_o = result_rob_sequence_q;
  assign result_destination_valid_o = result_destination_valid_q;
  assign result_destination_phys_o = result_destination_phys_q;

  always_ff @(posedge clk_i) begin
    if (!rst_ni) begin
      busy_q <= 1'b0;
      dividend_q <= '0;
      divisor_q <= '0;
      remainder_q <= '0;
      quotient_q <= '0;
      iteration_q <= '0;
      quotient_negative_q <= 1'b0;
      remainder_negative_q <= 1'b0;
      quotient_result_q <= 1'b0;
      word_operation_q <= 1'b0;
      rob_sequence_q <= '0;
      destination_valid_q <= 1'b0;
      destination_phys_q <= '0;
      result_valid_q <= 1'b0;
      result_q <= '0;
      result_rob_sequence_q <= '0;
      result_destination_valid_q <= 1'b0;
      result_destination_phys_q <= '0;
    end else begin
      if (result_valid_q && result_ready_i)
        result_valid_q <= 1'b0;

      if (flush_valid_i) begin
        if (flush_all_i ||
            (busy_q && sequence_is_younger(rob_sequence_q,
                                           flush_sequence_i))) begin
          busy_q <= 1'b0;
        end
        if (flush_all_i ||
            (result_valid_q &&
             sequence_is_younger(result_rob_sequence_q,
                                 flush_sequence_i))) begin
          result_valid_q <= 1'b0;
        end
      end

      if (request_valid_i && request_ready_o) begin
        rob_sequence_q <= request_rob_sequence_i;
        destination_valid_q <= request_destination_valid_i;
        destination_phys_q <= request_destination_phys_i;
        word_operation_q <= word_operation_i;
        quotient_result_q <= quotient_operation;
        quotient_negative_q <= signed_operation &&
                               (dividend_negative ^ divisor_negative);
        remainder_negative_q <= signed_operation && dividend_negative;
        dividend_q <= dividend_absolute;
        divisor_q <= divisor_absolute;
        remainder_q <= '0;
        quotient_q <= '0;
        iteration_q <= request_iterations;

        if (divide_by_zero || signed_overflow) begin
          busy_q <= 1'b0;
          result_valid_q <= 1'b1;
          result_rob_sequence_q <= request_rob_sequence_i;
          result_destination_valid_q <= request_destination_valid_i;
          result_destination_phys_q <= request_destination_phys_i;
          if (divide_by_zero) begin
            result_q <= quotient_operation ? {XLEN{1'b1}} :
                        (((XLEN == 64) && word_operation_i) ?
                         {{(XLEN-32){operand_a_i[31]}}, operand_a_i[31:0]} :
                         operand_a_i);
          end else begin
            result_q <= quotient_operation ? operand_a_effective : '0;
          end
        end else begin
          busy_q <= 1'b1;
        end
      end else if (busy_q && !(flush_valid_i &&
                   (flush_all_i || sequence_is_younger(rob_sequence_q,
                                                       flush_sequence_i)))) begin
        remainder_q <= reduced_remainder;
        quotient_q <= quotient_next;
        iteration_q <= iteration_q - 1'b1;
        if (iteration_q == 1) begin
          busy_q <= 1'b0;
          result_valid_q <= 1'b1;
          result_q <= selected_result_next;
          result_rob_sequence_q <= rob_sequence_q;
          result_destination_valid_q <= destination_valid_q;
          result_destination_phys_q <= destination_phys_q;
        end
      end
    end
  end

`ifndef SYNTHESIS
  property p_result_stable_when_stalled;
    @(posedge clk_i) disable iff (!rst_ni || flush_valid_i)
      result_valid_o && !result_ready_i |=> result_valid_o &&
      $stable({result_o, result_rob_sequence_o,
               result_destination_valid_o, result_destination_phys_o});
  endproperty
  assert property (p_result_stable_when_stalled);
`endif

  initial begin : p_parameter_checks
    if ((XLEN != 32) && (XLEN != 64))
      $fatal(1, "Divider XLEN must be 32 or 64");
    if (ROB_SEQ_WIDTH < 2)
      $fatal(1, "Divider needs a wrap-aware ROB sequence");
  end

endmodule
