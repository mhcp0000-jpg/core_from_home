module rv_lsu_pipe #(
  parameter int unsigned XLEN           = 32,
  parameter int unsigned PADDR_WIDTH    = 32,
  parameter int unsigned MEM_DATA_WIDTH = 64,
  parameter int unsigned ROB_SEQ_WIDTH  = rv_ooo_pkg::ROB_SEQ_WIDTH,
  parameter int unsigned LQ_INDEX_WIDTH = 5,
  parameter int unsigned SQ_INDEX_WIDTH = 4,
  localparam int unsigned MEM_BYTES     = MEM_DATA_WIDTH / 8,
  localparam int unsigned BYTE_OFFSET_WIDTH = $clog2(MEM_BYTES)
) (
  input  logic                              clk_i,
  input  logic                              rst_ni,

  input  logic                              issue_valid_i,
  output logic                              issue_ready_o,
  input  logic [ROB_SEQ_WIDTH-1:0]          issue_rob_sequence_i,
  input  logic                              issue_is_load_i,
  input  logic                              issue_is_store_i,
  input  logic                              issue_lq_valid_i,
  input  logic [LQ_INDEX_WIDTH-1:0]         issue_lq_index_i,
  input  logic                              issue_sq_valid_i,
  input  logic [SQ_INDEX_WIDTH-1:0]         issue_sq_index_i,
  input  logic [XLEN-1:0]                   base_i,
  input  logic [XLEN-1:0]                   immediate_i,
  input  logic [XLEN-1:0]                   store_data_i,
  input  logic [2:0]                        memory_size_i,

  input  logic                              flush_valid_i,
  input  logic                              flush_all_i,
  input  logic [ROB_SEQ_WIDTH-1:0]          flush_sequence_i,

  output logic                              update_valid_o,
  input  logic                              update_ready_i,
  output logic [ROB_SEQ_WIDTH-1:0]          update_rob_sequence_o,
  output logic                              update_is_load_o,
  output logic                              update_is_store_o,
  output logic                              update_lq_valid_o,
  output logic [LQ_INDEX_WIDTH-1:0]         update_lq_index_o,
  output logic                              update_sq_valid_o,
  output logic [SQ_INDEX_WIDTH-1:0]         update_sq_index_o,
  output logic [PADDR_WIDTH-1:0]            update_address_o,
  output logic [MEM_BYTES-1:0]              update_byte_mask_o,
  output logic [MEM_DATA_WIDTH-1:0]         update_store_data_o,
  output logic                              update_address_valid_o,
  output logic                              update_store_data_valid_o,
  output logic                              update_exception_valid_o,
  output rv_ooo_pkg::exception_code_e       update_exception_cause_o,
  output logic [XLEN-1:0]                   update_exception_tval_o
);

  import rv_ooo_pkg::*;

  logic [XLEN-1:0] effective_address;
  logic [PADDR_WIDTH-1:0] physical_address;
  logic [MEM_DATA_WIDTH-1:0] store_data_extended;
  logic [MEM_BYTES-1:0] generated_mask;
  logic [MEM_DATA_WIDTH-1:0] generated_store_data;
  logic [BYTE_OFFSET_WIDTH-1:0] byte_offset;
  integer unsigned access_bytes;
  integer unsigned byte_offset_integer;
  logic [XLEN-1:0] alignment_mask;
  logic unsupported_size;
  logic misaligned;

  logic update_valid_q;
  logic [ROB_SEQ_WIDTH-1:0] update_rob_sequence_q;
  logic update_is_load_q;
  logic update_is_store_q;
  logic update_lq_valid_q;
  logic [LQ_INDEX_WIDTH-1:0] update_lq_index_q;
  logic update_sq_valid_q;
  logic [SQ_INDEX_WIDTH-1:0] update_sq_index_q;
  logic [PADDR_WIDTH-1:0] update_address_q;
  logic [MEM_BYTES-1:0] update_byte_mask_q;
  logic [MEM_DATA_WIDTH-1:0] update_store_data_q;
  logic update_address_valid_q;
  logic update_store_data_valid_q;
  logic update_exception_valid_q;
  exception_code_e update_exception_cause_q;
  logic [XLEN-1:0] update_exception_tval_q;

  function automatic logic sequence_is_younger(
    input logic [ROB_SEQ_WIDTH-1:0] candidate,
    input logic [ROB_SEQ_WIDTH-1:0] boundary
  );
    logic [ROB_SEQ_WIDTH-1:0] distance;
    distance = candidate - boundary;
    return (distance != 0) && !distance[ROB_SEQ_WIDTH-1];
  endfunction

  assign effective_address = base_i + immediate_i;

  if (PADDR_WIDTH >= XLEN) begin : g_address_extend
    assign physical_address =
      {{(PADDR_WIDTH-XLEN){1'b0}}, effective_address};
  end else begin : g_address_truncate
    assign physical_address = effective_address[PADDR_WIDTH-1:0];
  end

  if (MEM_DATA_WIDTH >= XLEN) begin : g_store_data_extend
    assign store_data_extended =
      {{(MEM_DATA_WIDTH-XLEN){1'b0}}, store_data_i};
  end

  always_comb begin
    byte_offset = effective_address[BYTE_OFFSET_WIDTH-1:0];
    byte_offset_integer = byte_offset;
    access_bytes = 1 << memory_size_i;
    alignment_mask = access_bytes - 1;
    unsupported_size = (access_bytes > MEM_BYTES) ||
                       (memory_size_i > BYTE_OFFSET_WIDTH);
    misaligned = unsupported_size ||
                 ((effective_address & alignment_mask) != 0);
    generated_mask = '0;
    for (int unsigned byte_index = 0; byte_index < MEM_BYTES; byte_index++) begin
      if ((byte_index >= byte_offset_integer) &&
          (byte_index < (byte_offset_integer + access_bytes))) begin
        generated_mask[byte_index] = 1'b1;
      end
    end
    generated_store_data = store_data_extended << (byte_offset_integer * 8);
  end

  assign issue_ready_o = (!update_valid_q || update_ready_i) && !flush_valid_i;
  assign update_valid_o = update_valid_q;
  assign update_rob_sequence_o = update_rob_sequence_q;
  assign update_is_load_o = update_is_load_q;
  assign update_is_store_o = update_is_store_q;
  assign update_lq_valid_o = update_lq_valid_q;
  assign update_lq_index_o = update_lq_index_q;
  assign update_sq_valid_o = update_sq_valid_q;
  assign update_sq_index_o = update_sq_index_q;
  assign update_address_o = update_address_q;
  assign update_byte_mask_o = update_byte_mask_q;
  assign update_store_data_o = update_store_data_q;
  assign update_address_valid_o = update_address_valid_q;
  assign update_store_data_valid_o = update_store_data_valid_q;
  assign update_exception_valid_o = update_exception_valid_q;
  assign update_exception_cause_o = update_exception_cause_q;
  assign update_exception_tval_o = update_exception_tval_q;

  always_ff @(posedge clk_i) begin
    if (!rst_ni) begin
      update_valid_q <= 1'b0;
      update_rob_sequence_q <= '0;
      update_is_load_q <= 1'b0;
      update_is_store_q <= 1'b0;
      update_lq_valid_q <= 1'b0;
      update_lq_index_q <= '0;
      update_sq_valid_q <= 1'b0;
      update_sq_index_q <= '0;
      update_address_q <= '0;
      update_byte_mask_q <= '0;
      update_store_data_q <= '0;
      update_address_valid_q <= 1'b0;
      update_store_data_valid_q <= 1'b0;
      update_exception_valid_q <= 1'b0;
      update_exception_cause_q <= EXC_LOAD_ADDR_MISALIGNED;
      update_exception_tval_q <= '0;
    end else begin
      if (update_valid_q && update_ready_i)
        update_valid_q <= 1'b0;

      if (flush_valid_i &&
          (flush_all_i ||
           (update_valid_q &&
            sequence_is_younger(update_rob_sequence_q, flush_sequence_i)))) begin
        update_valid_q <= 1'b0;
      end

      if (issue_valid_i && issue_ready_o) begin
        update_valid_q <= 1'b1;
        update_rob_sequence_q <= issue_rob_sequence_i;
        update_is_load_q <= issue_is_load_i;
        update_is_store_q <= issue_is_store_i;
        update_lq_valid_q <= issue_lq_valid_i;
        update_lq_index_q <= issue_lq_index_i;
        update_sq_valid_q <= issue_sq_valid_i;
        update_sq_index_q <= issue_sq_index_i;
        update_address_q <= physical_address;
        update_byte_mask_q <= generated_mask;
        update_store_data_q <= generated_store_data;
        update_address_valid_q <= 1'b1;
        update_store_data_valid_q <= issue_is_store_i;
        update_exception_valid_q <= misaligned;
        update_exception_cause_q <= issue_is_store_i ?
          EXC_STORE_ADDR_MISALIGNED : EXC_LOAD_ADDR_MISALIGNED;
        update_exception_tval_q <= effective_address;
      end
    end
  end

`ifndef SYNTHESIS
  property p_update_stable_when_stalled;
    @(posedge clk_i) disable iff (!rst_ni || flush_valid_i)
      update_valid_o && !update_ready_i |=> update_valid_o &&
      $stable({update_rob_sequence_o, update_is_load_o, update_is_store_o,
               update_lq_valid_o, update_lq_index_o,
               update_sq_valid_o, update_sq_index_o, update_address_o,
               update_byte_mask_o, update_store_data_o,
               update_address_valid_o, update_store_data_valid_o,
               update_exception_valid_o, update_exception_cause_o,
               update_exception_tval_o});
  endproperty
  assert property (p_update_stable_when_stalled);
`endif

  initial begin : p_parameter_checks
    if ((XLEN != 32) && (XLEN != 64))
      $fatal(1, "LSU pipe XLEN must be 32 or 64");
    if ((MEM_DATA_WIDTH < XLEN) || ((MEM_DATA_WIDTH % 8) != 0) ||
        ((MEM_BYTES & (MEM_BYTES-1)) != 0))
      $fatal(1, "LSU pipe memory beat must be a power-of-two byte width covering XLEN");
    if (ROB_SEQ_WIDTH < 2)
      $fatal(1, "LSU pipe needs a wrap-aware ROB sequence");
  end

endmodule
