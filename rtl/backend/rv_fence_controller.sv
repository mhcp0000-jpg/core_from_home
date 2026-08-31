module rv_fence_controller #(
  parameter int unsigned XLEN = 32,
  parameter int unsigned ROB_SEQ_WIDTH = rv_ooo_pkg::ROB_SEQ_WIDTH
) (
  input  logic                         request_valid_i,
  input  logic                         request_is_fence_i,
  input  logic                         request_is_fence_i_i,
  input  logic [3:0]                   predecessor_i,
  input  logic [3:0]                   successor_i,
  input  logic [ROB_SEQ_WIDTH-1:0]     sequence_i,
  input  logic [XLEN-1:0]              next_pc_i,

  input  logic                         lsu_memory_idle_i,
  input  logic                         i_fabric_idle_i,

  output logic                         request_ready_o,
  output logic                         completion_valid_o,
  output logic [ROB_SEQ_WIDTH-1:0]     completion_sequence_o,
  output logic                         frontend_flush_required_o,
  output logic [XLEN-1:0]              frontend_redirect_pc_o
);

  logic fence_request;

  assign fence_request = request_valid_i &&
                         (request_is_fence_i || request_is_fence_i_i);

  // In the initial cacheless ITIM/DTIM implementation memory_idle means all
  // older loads, SQ entries, committed stores and device transactions drained.
  // FENCE.I additionally waits for the instruction fabric boundary.
  always_comb begin
    request_ready_o = lsu_memory_idle_i &&
                      (!request_is_fence_i_i || i_fabric_idle_i);
    completion_valid_o = fence_request && request_ready_o;
    completion_sequence_o = sequence_i;
    frontend_flush_required_o = completion_valid_o && request_is_fence_i_i;
    frontend_redirect_pc_o = next_pc_i;
  end

  // The masks are retained at the controller boundary for a future cache and
  // coherent fabric implementation. The conservative baseline drains all
  // memory classes regardless of the encoded predecessor/successor subset.
  logic unused_masks;
  assign unused_masks = ^{predecessor_i, successor_i};

`ifndef SYNTHESIS
  always_comb begin
    if (completion_valid_o) begin
      assert (request_valid_i &&
              (request_is_fence_i || request_is_fence_i_i));
      assert (lsu_memory_idle_i);
      if (request_is_fence_i_i)
        assert (i_fabric_idle_i && frontend_flush_required_o);
    end
  end
`endif

endmodule
