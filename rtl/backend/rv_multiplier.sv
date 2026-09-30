module rv_multiplier #(
  parameter int unsigned XLEN = 32,
  parameter int unsigned ROB_SEQ_WIDTH = rv_ooo_pkg::ROB_SEQ_WIDTH,
  parameter int unsigned PHYS_TAG_WIDTH = 7
) (
  input  logic                         clk_i,
  input  logic                         rst_ni,
  input  logic                         request_valid_i,
  output logic                         request_ready_o,
  input  logic [XLEN-1:0]              operand_a_i,
  input  logic [XLEN-1:0]              operand_b_i,
  input  rv_ooo_pkg::multiply_op_e      operation_i,
  input  logic                         word_operation_i,
  input  logic [ROB_SEQ_WIDTH-1:0]      sequence_i,
  input  logic                         destination_valid_i,
  input  logic [PHYS_TAG_WIDTH-1:0]    destination_phys_i,

  input  logic                         flush_valid_i,
  input  logic                         flush_all_i,
  input  logic [ROB_SEQ_WIDTH-1:0]     flush_sequence_i,

  output logic                         result_valid_o,
  input  logic                         result_ready_i,
  output logic [XLEN-1:0]              result_o,
  output logic [ROB_SEQ_WIDTH-1:0]      result_sequence_o,
  output logic                         result_destination_valid_o,
  output logic [PHYS_TAG_WIDTH-1:0]    result_destination_phys_o
);

  import rv_ooo_pkg::*;

  localparam int unsigned PRODUCT_WIDTH = 2 * XLEN;

  typedef struct packed {
    logic [XLEN-1:0]           result;
    logic [ROB_SEQ_WIDTH-1:0] sequence_id;
    logic                      destination_valid;
    logic [PHYS_TAG_WIDTH-1:0] destination_phys;
  } multiply_result_t;

  // PROTOTYPE: stage0 now captures the request operands instead of the
  // finished product.  The 2*XLEN multiply moves into stage0 -> stage1, which
  // previously was a pure register copy.  Total latency stays 2 cycles and
  // throughput stays 1/cycle, but issue -> multiplier stage0 is now just
  // operand transport instead of a full 32x32 multiply.
  typedef struct packed {
    logic [XLEN-1:0]              operand_a;
    logic [XLEN-1:0]              operand_b;
    rv_ooo_pkg::multiply_op_e     operation;
    logic                         word_operation;
    logic [ROB_SEQ_WIDTH-1:0]     sequence_id;
    logic                         destination_valid;
    logic [PHYS_TAG_WIDTH-1:0]    destination_phys;
  } multiply_request_t;

  logic stage0_valid_q;
  logic stage1_valid_q;
  multiply_request_t stage0_q;
  multiply_result_t stage1_q;
  logic stage1_advance;

  // One (XLEN+1)-bit signed multiply represents all three signedness cases.
  // The extra bit is the sign for a signed operand and zero for an unsigned
  // operand. The architectural result uses only the low 2*XLEN bits.
  logic signed [XLEN:0] multiplicand, multiplier;
  logic signed [PRODUCT_WIDTH+1:0] product_shared;
  logic signed_a, signed_b;
  logic [XLEN-1:0] selected_result;
  logic [31:0] word_result;

  function automatic logic sequence_is_younger(
    input logic [ROB_SEQ_WIDTH-1:0] candidate,
    input logic [ROB_SEQ_WIDTH-1:0] boundary
  );
    logic [ROB_SEQ_WIDTH-1:0] distance;
    distance = candidate - boundary;
    return (distance != 0) && !distance[ROB_SEQ_WIDTH-1];
  endfunction

  always_comb begin
    signed_a = (stage0_q.operation == MUL_HIGH_SS) ||
               (stage0_q.operation == MUL_HIGH_SU);
    signed_b = (stage0_q.operation == MUL_HIGH_SS);
    multiplicand = $signed({signed_a && stage0_q.operand_a[XLEN-1],
                            stage0_q.operand_a});
    multiplier = $signed({signed_b && stage0_q.operand_b[XLEN-1],
                          stage0_q.operand_b});
    product_shared = multiplicand * multiplier;

    case (stage0_q.operation)
      MUL_LOW:     selected_result = product_shared[XLEN-1:0];
      MUL_HIGH_SS, MUL_HIGH_SU, MUL_HIGH_UU:
                   selected_result = product_shared[PRODUCT_WIDTH-1:XLEN];
      default:     selected_result = '0;
    endcase
    word_result = product_shared[31:0];
    if ((XLEN == 64) && stage0_q.word_operation)
      selected_result = {{(XLEN-32){word_result[31]}}, word_result};
  end

  assign stage1_advance = !stage1_valid_q || result_ready_i;
  assign request_ready_o = (!stage0_valid_q || stage1_advance) &&
                           !flush_valid_i;
  assign result_valid_o = stage1_valid_q;
  assign result_o = stage1_q.result;
  assign result_sequence_o = stage1_q.sequence_id;
  assign result_destination_valid_o = stage1_q.destination_valid;
  assign result_destination_phys_o = stage1_q.destination_phys;

  always_ff @(posedge clk_i) begin
    if (!rst_ni) begin
      stage0_valid_q <= 1'b0;
      stage1_valid_q <= 1'b0;
      stage0_q       <= '0;
      stage1_q       <= '0;
    end else if (flush_valid_i) begin
      if (flush_all_i ||
          (stage0_valid_q &&
           sequence_is_younger(stage0_q.sequence_id, flush_sequence_i)))
        stage0_valid_q <= 1'b0;
      if (flush_all_i ||
          (stage1_valid_q &&
           sequence_is_younger(stage1_q.sequence_id, flush_sequence_i)))
        stage1_valid_q <= 1'b0;
    end else begin
      if (stage1_advance) begin
        stage1_valid_q <= stage0_valid_q;
        if (stage0_valid_q) begin
          stage1_q.result            <= selected_result;
          stage1_q.sequence_id       <= stage0_q.sequence_id;
          stage1_q.destination_valid <= stage0_q.destination_valid;
          stage1_q.destination_phys  <= stage0_q.destination_phys;
        end
      end

      if (request_ready_o) begin
        stage0_valid_q <= request_valid_i;
        if (request_valid_i) begin
          stage0_q.operand_a         <= operand_a_i;
          stage0_q.operand_b         <= operand_b_i;
          stage0_q.operation         <= operation_i;
          stage0_q.word_operation    <= word_operation_i;
          stage0_q.sequence_id       <= sequence_i;
          stage0_q.destination_valid <= destination_valid_i;
          stage0_q.destination_phys  <= destination_phys_i;
        end
      end
    end
  end

`ifndef SYNTHESIS
  property p_result_stable_when_stalled;
    @(posedge clk_i) disable iff (!rst_ni || flush_valid_i)
      result_valid_o && !result_ready_i |=> result_valid_o &&
      $stable({result_o, result_sequence_o, result_destination_valid_o,
               result_destination_phys_o});
  endproperty
  assert property (p_result_stable_when_stalled);
`endif

  initial begin : p_parameter_checks
    if ((XLEN != 32) && (XLEN != 64))
      $fatal(1, "Multiplier XLEN must be 32 or 64");
  end

endmodule
