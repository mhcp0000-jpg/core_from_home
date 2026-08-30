module rv_exec_result_buffer #(
  parameter int unsigned XLEN           = 32,
  parameter int unsigned ROB_SEQ_WIDTH  = rv_ooo_pkg::ROB_SEQ_WIDTH,
  parameter int unsigned PHYS_TAG_WIDTH = 7
) (
  input  logic                               clk_i,
  input  logic                               rst_ni,

  input  logic                               request_valid_i,
  output logic                               request_ready_o,
  input  logic [ROB_SEQ_WIDTH-1:0]           request_sequence_i,
  input  logic                               request_destination_valid_i,
  input  rv_ooo_pkg::reg_class_e             request_destination_class_i,
  input  logic [PHYS_TAG_WIDTH-1:0]          request_destination_phys_i,
  input  logic [XLEN-1:0]                    request_data_i,
  input  logic                               request_exception_valid_i,
  input  rv_ooo_pkg::exception_code_e        request_exception_cause_i,
  input  logic [XLEN-1:0]                    request_exception_tval_i,
  input  logic                               request_branch_mispredict_i,
  input  logic [XLEN-1:0]                    request_branch_target_i,
  input  logic [4:0]                         request_fflags_i,

  input  logic                               flush_valid_i,
  input  logic                               flush_all_i,
  input  logic [ROB_SEQ_WIDTH-1:0]           flush_sequence_i,

  output logic                               result_valid_o,
  input  logic                               result_ready_i,
  output logic [ROB_SEQ_WIDTH-1:0]           result_sequence_o,
  output logic                               result_destination_valid_o,
  output rv_ooo_pkg::reg_class_e             result_destination_class_o,
  output logic [PHYS_TAG_WIDTH-1:0]          result_destination_phys_o,
  output logic [XLEN-1:0]                    result_data_o,
  output logic                               result_exception_valid_o,
  output rv_ooo_pkg::exception_code_e        result_exception_cause_o,
  output logic [XLEN-1:0]                    result_exception_tval_o,
  output logic                               result_branch_mispredict_o,
  output logic [XLEN-1:0]                    result_branch_target_o,
  output logic [4:0]                         result_fflags_o
);

  import rv_ooo_pkg::*;

  typedef struct packed {
    logic [ROB_SEQ_WIDTH-1:0] sequence_id;
    logic destination_valid;
    reg_class_e destination_class;
    logic [PHYS_TAG_WIDTH-1:0] destination_phys;
    logic [XLEN-1:0] data;
    logic exception_valid;
    exception_code_e exception_cause;
    logic [XLEN-1:0] exception_tval;
    logic branch_mispredict;
    logic [XLEN-1:0] branch_target;
    logic [4:0] fflags;
  } result_payload_t;

  logic valid_q;
  result_payload_t payload_q;

  function automatic logic sequence_is_younger(
    input logic [ROB_SEQ_WIDTH-1:0] candidate,
    input logic [ROB_SEQ_WIDTH-1:0] boundary
  );
    logic [ROB_SEQ_WIDTH-1:0] distance;
    distance = candidate - boundary;
    return (distance != 0) && !distance[ROB_SEQ_WIDTH-1];
  endfunction

  assign request_ready_o = (!valid_q || result_ready_i) && !flush_valid_i;
  assign result_valid_o = valid_q;
  assign result_sequence_o = payload_q.sequence_id;
  assign result_destination_valid_o = payload_q.destination_valid;
  assign result_destination_class_o = payload_q.destination_class;
  assign result_destination_phys_o = payload_q.destination_phys;
  assign result_data_o = payload_q.data;
  assign result_exception_valid_o = payload_q.exception_valid;
  assign result_exception_cause_o = payload_q.exception_cause;
  assign result_exception_tval_o = payload_q.exception_tval;
  assign result_branch_mispredict_o = payload_q.branch_mispredict;
  assign result_branch_target_o = payload_q.branch_target;
  assign result_fflags_o = payload_q.fflags;

  always_ff @(posedge clk_i) begin
    if (!rst_ni) begin
      valid_q <= 1'b0;
      payload_q <= '0;
    end else if (flush_valid_i) begin
      if (flush_all_i ||
          (valid_q &&
           sequence_is_younger(payload_q.sequence_id, flush_sequence_i)))
        valid_q <= 1'b0;
    end else if (request_ready_o) begin
      valid_q <= request_valid_i;
      if (request_valid_i) begin
        payload_q.sequence_id <= request_sequence_i;
        payload_q.destination_valid <= request_destination_valid_i;
        payload_q.destination_class <= request_destination_class_i;
        payload_q.destination_phys <= request_destination_phys_i;
        payload_q.data <= request_data_i;
        payload_q.exception_valid <= request_exception_valid_i;
        payload_q.exception_cause <= request_exception_cause_i;
        payload_q.exception_tval <= request_exception_tval_i;
        payload_q.branch_mispredict <= request_branch_mispredict_i;
        payload_q.branch_target <= request_branch_target_i;
        payload_q.fflags <= request_fflags_i;
      end
    end
  end

`ifndef SYNTHESIS
  property p_result_stable_when_stalled;
    @(posedge clk_i) disable iff (!rst_ni || flush_valid_i)
      result_valid_o && !result_ready_i |=> result_valid_o &&
      $stable(payload_q);
  endproperty
  assert property (p_result_stable_when_stalled);
`endif

  initial begin : p_parameter_checks
    if ((XLEN != 32) && (XLEN != 64))
      $fatal(1, "Result buffer XLEN must be 32 or 64");
    if (ROB_SEQ_WIDTH < 2)
      $fatal(1, "Result buffer requires wrap-aware sequences");
  end

endmodule
