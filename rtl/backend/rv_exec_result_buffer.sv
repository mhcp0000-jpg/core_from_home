module rv_exec_result_buffer #(
  parameter int unsigned XLEN           = 32,
  parameter int unsigned ROB_SEQ_WIDTH  = rv_ooo_pkg::ROB_SEQ_WIDTH,
  parameter int unsigned PHYS_TAG_WIDTH = 7,
  // DEPTH=1: original single register; request_ready depends on this cycle's
  //          result_ready (writeback grant).
  // DEPTH=2: two entries; request_ready depends only on registered occupancy,
  //          so the writeback arbiter no longer reaches issue selection.
  parameter int unsigned DEPTH          = 1
) (
  input  logic                               clk_i,
  input  logic                               rst_ni,

  input  logic                               request_valid_i,
  output logic                               request_ready_o,
  // With a successful push, the incoming value is at the head next cycle.
  // This is a forwarding eligibility hint, never a request-ready input.
  output logic                               request_at_head_next_o,
  // Read-only forwarding tap for the non-head result. No WB/commit effect.
  output logic                               pending_valid_o,
  output logic [ROB_SEQ_WIDTH-1:0]           pending_sequence_o,
  output logic                               pending_destination_valid_o,
  output rv_ooo_pkg::reg_class_e             pending_destination_class_o,
  output logic [PHYS_TAG_WIDTH-1:0]          pending_destination_phys_o,
  output logic [XLEN-1:0]                    pending_data_o,
  output logic                               pending_exception_valid_o,
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

  function automatic logic sequence_is_younger(
    input logic [ROB_SEQ_WIDTH-1:0] candidate,
    input logic [ROB_SEQ_WIDTH-1:0] boundary
  );
    logic [ROB_SEQ_WIDTH-1:0] distance;
    distance = candidate - boundary;
    return (distance != 0) && !distance[ROB_SEQ_WIDTH-1];
  endfunction

  result_payload_t request_payload;
  always_comb begin
    request_payload.sequence_id = request_sequence_i;
    request_payload.destination_valid = request_destination_valid_i;
    request_payload.destination_class = request_destination_class_i;
    request_payload.destination_phys = request_destination_phys_i;
    request_payload.data = request_data_i;
    request_payload.exception_valid = request_exception_valid_i;
    request_payload.exception_cause = request_exception_cause_i;
    request_payload.exception_tval = request_exception_tval_i;
    request_payload.branch_mispredict = request_branch_mispredict_i;
    request_payload.branch_target = request_branch_target_i;
    request_payload.fflags = request_fflags_i;
  end

  logic valid_q;
  result_payload_t payload_q;
  result_payload_t pending_payload;

  generate
    if (DEPTH == 1) begin : g_depth1
      assign pending_valid_o=1'b0;
      assign pending_payload='0;
      assign request_at_head_next_o = 1'b1;
      assign request_ready_o = (!valid_q || result_ready_i) && !flush_valid_i;

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
          if (request_valid_i)
            payload_q <= request_payload;
        end
      end
    end else begin : g_depth2
      // Circular storage: WB pop changes only occupancy/pointer FFs, never
      // copies the wide payload into a head register. Capacity, full-cycle
      // backpressure and insertion order are unchanged (no extra cycle).
      result_payload_t slots_q [0:1];
      logic head_q, tail_q;
      logic [1:0] count_q;
      assign pending_valid_o=(count_q==2);
      assign pending_payload=slots_q[!head_q];
      logic pop, push, keep_head, keep_second;

      assign valid_q = count_q != 0;
      assign payload_q = slots_q[head_q];
      assign request_ready_o = (count_q < 2) && !flush_valid_i;
      assign pop = valid_q && result_ready_i;
      assign request_at_head_next_o = (count_q == 0) ||
                                      ((count_q == 1) && pop);
      assign push = request_valid_i && request_ready_o;
      // FIFO order is issue order, not ROB age. Independently test both
      // entries: a younger head may die while its older second survives.
      assign keep_head = (count_q != 0) && !flush_all_i &&
        !sequence_is_younger(slots_q[head_q].sequence_id, flush_sequence_i);
      assign keep_second = (count_q == 2) && !flush_all_i &&
        !sequence_is_younger(slots_q[!head_q].sequence_id, flush_sequence_i);

      // Constant-address word writes. A variable array write here makes
      // frontend lowering build temporary array versions/priority muxes on
      // the late ALU-result -> payload-FF path. Decode the one-bit tail only
      // in the write enable; each payload FF has a single data source.
      // push includes !flush_valid_i, so a flush edge never changes a slot.
      for (genvar slot = 0; slot < 2; slot++) begin : g_slot_write
        always_ff @(posedge clk_i) begin
          if (!rst_ni)
            slots_q[slot] <= '0;
          else if (push && (tail_q == 1'(slot)))
            slots_q[slot] <= request_payload;
        end
      end

      always_ff @(posedge clk_i) begin
        if (!rst_ni) begin
          head_q <= 1'b0;
          tail_q <= 1'b0;
          count_q <= '0;
        end else if (flush_valid_i) begin
          // No transfer on a flush edge. Rebuild pointers around surviving
          // entries without copying data. Every new FF has an explicit reset.
          case ({keep_head, keep_second})
            2'b00: begin
              count_q <= '0;
              head_q <= 1'b0;
              tail_q <= 1'b0;
            end
            2'b01: begin
              count_q <= 2'd1;
              head_q <= !head_q;
              tail_q <= head_q;
            end
            2'b10: begin
              count_q <= 2'd1;
              tail_q <= !head_q;
            end
            2'b11: begin
              count_q <= 2'd2;
              tail_q <= head_q;
            end
          endcase
        end else begin
          if (push) begin
            tail_q <= !tail_q;
          end
          if (pop) head_q <= !head_q;
          count_q <= count_q + {1'b0,push} - {1'b0,pop};
        end
      end
`ifndef SYNTHESIS
      assert property (@(posedge clk_i) disable iff (!rst_ni) count_q <= 2);
      assert property (@(posedge clk_i) disable iff (!rst_ni)
        (count_q == 1) == (head_q != tail_q));
      assert property (@(posedge clk_i) disable iff (!rst_ni || flush_valid_i)
        push && valid_q |-> head_q != tail_q);
`endif
    end
  endgenerate

  assign result_valid_o = valid_q;
  assign pending_sequence_o=pending_payload.sequence_id;
  assign pending_destination_valid_o=pending_payload.destination_valid;
  assign pending_destination_class_o=pending_payload.destination_class;
  assign pending_destination_phys_o=pending_payload.destination_phys;
  assign pending_data_o=pending_payload.data;
  assign pending_exception_valid_o=pending_payload.exception_valid;
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

`ifndef SYNTHESIS
  assert property (@(posedge clk_i) disable iff (!rst_ni || flush_valid_i)
    request_valid_i && request_ready_o && request_at_head_next_o |=>
      result_valid_o && result_sequence_o == $past(request_sequence_i) &&
      result_data_o == $past(request_data_i));
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
    if ((DEPTH != 1) && (DEPTH != 2))
      $fatal(1, "Result buffer DEPTH must be 1 or 2");
  end

endmodule
