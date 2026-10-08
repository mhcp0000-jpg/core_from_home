module rv_lsu_pipe #(
  parameter int unsigned XLEN           = 32,
  parameter int unsigned PADDR_WIDTH    = 32,
  parameter int unsigned MEM_DATA_WIDTH = 64,
  parameter int unsigned ROB_SEQ_WIDTH  = rv_ooo_pkg::ROB_SEQ_WIDTH,
  parameter int unsigned LQ_INDEX_WIDTH = 5,
  parameter int unsigned SQ_INDEX_WIDTH = 4,
  // DEPTH=1: single update register; issue_ready follows update_ready
  //          combinationally (original behaviour).
  // DEPTH=2: two-entry in-order buffer; issue_ready depends only on
  //          registered occupancy (and flush), so the downstream PMP /
  //          completion-port decision no longer reaches issue selection.
  parameter int unsigned DEPTH          = 1,
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
  input  logic                              issue_address_valid_i,
  input  logic                              issue_store_data_valid_i,
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
  output logic [2:0]                        update_memory_size_o,
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
  logic [2:0] update_memory_size_q;
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

  // Four-bit carry-select groups with a logarithmic group-carry prefix.
  // No extra state/latency: address and exception tval remain XLEN-bit
  // modulo addition, including signed offsets and wraparound. An unbounded
  // bit-ripple after late IQ/forwarding selection is especially expensive
  // for the high exception_tval bits on the reported critical path.
  function automatic logic [XLEN-1:0] address_add(
    input logic [XLEN-1:0] lhs, input logic [XLEN-1:0] rhs
  );
    localparam int GROUPS = XLEN / 4;
    localparam int LEVELS = $clog2(GROUPS);
    logic [GROUPS-1:0] p [0:LEVELS], g [0:LEVELS];
    logic [4:0] sum0 [0:GROUPS-1], sum1 [0:GROUPS-1];
    logic carry_in;
    for (int group=0; group<GROUPS; group++) begin
      sum0[group] = {1'b0,lhs[group*4+:4]} + {1'b0,rhs[group*4+:4]};
      sum1[group] = sum0[group] + 5'd1;
      p[0][group] = &(lhs[group*4+:4] ^ rhs[group*4+:4]);
      g[0][group] = sum0[group][4];
    end
    for (int level=0; level<LEVELS; level++) begin
      for (int group=0; group<GROUPS; group++) begin
        if (group >= (1<<level)) begin
          g[level+1][group] = g[level][group] |
            (p[level][group] & g[level][group-(1<<level)]);
          p[level+1][group] = p[level][group] & p[level][group-(1<<level)];
        end else begin
          g[level+1][group] = g[level][group];
          p[level+1][group] = p[level][group];
        end
      end
    end
    for (int group=0; group<GROUPS; group++) begin
      carry_in = (group==0) ? 1'b0 : g[LEVELS][group-1];
      address_add[group*4+:4] = carry_in ? sum1[group][3:0] : sum0[group][3:0];
    end
  endfunction

  assign effective_address = address_add(base_i, immediate_i);

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
    // size is three bits: (2**size)-1 has at most seven low bits set.
    // The beat width is a power of two (checked below), so this comparison
    // also covers access_bytes > MEM_BYTES without a wide subtract/compare.
    alignment_mask = '0;
    for (int bit_index = 0; bit_index < XLEN; bit_index++)
      if (bit_index < 7)
        alignment_mask[bit_index] = memory_size_i > bit_index;
    unsupported_size = memory_size_i > BYTE_OFFSET_WIDTH;
    misaligned = unsupported_size ||
                 ((effective_address & alignment_mask) != 0);
    generated_mask = '0;
    // Decode a low contiguous mask then shift within the beat. Clipping at
    // the beat end is intentional, INCLUDING invalid/misaligned requests.
    for (int unsigned byte_index = 0; byte_index < MEM_BYTES; byte_index++)
      generated_mask[byte_index] = memory_size_i >= $clog2(byte_index+1);
    generated_mask = generated_mask << byte_offset;
    generated_store_data = store_data_extended << (byte_offset_integer * 8);
  end

  typedef struct packed {
    logic [ROB_SEQ_WIDTH-1:0]  rob_sequence;
    logic                      is_load;
    logic                      is_store;
    logic                      lq_valid;
    logic [LQ_INDEX_WIDTH-1:0] lq_index;
    logic                      sq_valid;
    logic [SQ_INDEX_WIDTH-1:0] sq_index;
    logic [PADDR_WIDTH-1:0]    address;
    logic [2:0]                memory_size;
    logic [MEM_BYTES-1:0]      byte_mask;
    logic [MEM_DATA_WIDTH-1:0] store_data;
    logic                      address_valid;
    logic                      store_data_valid;
    logic                      exception_valid;
    exception_code_e           exception_cause;
    logic [XLEN-1:0]           exception_tval;
  } update_payload_t;

  if (DEPTH == 1) begin : g_depth1
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
    assign update_memory_size_o = update_memory_size_q;
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
        update_memory_size_q <= '0;
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
          update_memory_size_q <= memory_size_i;
          update_byte_mask_q <= generated_mask;
          update_store_data_q <= generated_store_data;
          update_address_valid_q <= issue_address_valid_i;
          update_store_data_valid_q <= issue_is_store_i &&
                                       issue_store_data_valid_i;
          update_exception_valid_q <= misaligned;
          update_exception_cause_q <= issue_is_store_i ?
            EXC_STORE_ADDR_MISALIGNED : EXC_LOAD_ADDR_MISALIGNED;
          update_exception_tval_q <= effective_address;
        end
      end
    end
  end else begin : g_depth2
    // Entry 0 is the head presented on update_*.  Entries stay in issue
    // order; a flush removes the killed ones and compacts the survivor.
    logic valid1_q;
    update_payload_t head_q, tail_q, issue_payload;
    logic pop, push, kill0, kill1;
    logic keep0, keep1;

    always_comb begin
      issue_payload.rob_sequence     = issue_rob_sequence_i;
      issue_payload.is_load          = issue_is_load_i;
      issue_payload.is_store         = issue_is_store_i;
      issue_payload.lq_valid         = issue_lq_valid_i;
      issue_payload.lq_index         = issue_lq_index_i;
      issue_payload.sq_valid         = issue_sq_valid_i;
      issue_payload.sq_index         = issue_sq_index_i;
      issue_payload.address          = physical_address;
      issue_payload.memory_size      = memory_size_i;
      issue_payload.byte_mask        = generated_mask;
      issue_payload.store_data       = generated_store_data;
      issue_payload.address_valid    = issue_address_valid_i;
      issue_payload.store_data_valid = issue_is_store_i &&
                                       issue_store_data_valid_i;
      issue_payload.exception_valid  = misaligned;
      issue_payload.exception_cause  = issue_is_store_i ?
        EXC_STORE_ADDR_MISALIGNED : EXC_LOAD_ADDR_MISALIGNED;
      issue_payload.exception_tval   = effective_address;
    end

    assign issue_ready_o = !(update_valid_q && valid1_q) && !flush_valid_i;
    assign pop  = update_valid_q && update_ready_i && !flush_valid_i;
    assign push = issue_valid_i && issue_ready_o;
    assign kill0 = flush_valid_i && update_valid_q &&
      (flush_all_i || sequence_is_younger(head_q.rob_sequence, flush_sequence_i));
    assign kill1 = flush_valid_i && valid1_q &&
      (flush_all_i || sequence_is_younger(tail_q.rob_sequence, flush_sequence_i));
    assign keep0 = update_valid_q && !kill0;
    assign keep1 = valid1_q && !kill1;

    always_ff @(posedge clk_i) begin
      if (!rst_ni) begin
        update_valid_q <= 1'b0;
        valid1_q <= 1'b0;
        head_q <= '0;
        tail_q <= '0;
      end else if (flush_valid_i) begin
        // No push or pop in a flush cycle (issue_ready_o is low).
        update_valid_q <= keep0 || keep1;
        valid1_q <= keep0 && keep1;
        if (!keep0 && keep1) head_q <= tail_q;
      end else begin
        case ({push, pop})
          2'b10: begin
            if (!update_valid_q) begin
              update_valid_q <= 1'b1;
              head_q <= issue_payload;
            end else begin
              valid1_q <= 1'b1;
              tail_q <= issue_payload;
            end
          end
          2'b01: begin
            update_valid_q <= valid1_q;
            valid1_q <= 1'b0;
            head_q <= tail_q;
          end
          2'b11: begin
            // push requires !full, so only the head was occupied: it leaves
            // and the new entry becomes the head.
            head_q <= issue_payload;
          end
          default: begin end
        endcase
      end
    end

    assign update_valid_o            = update_valid_q;
    assign update_rob_sequence_o     = head_q.rob_sequence;
    assign update_is_load_o          = head_q.is_load;
    assign update_is_store_o         = head_q.is_store;
    assign update_lq_valid_o         = head_q.lq_valid;
    assign update_lq_index_o         = head_q.lq_index;
    assign update_sq_valid_o         = head_q.sq_valid;
    assign update_sq_index_o         = head_q.sq_index;
    assign update_address_o          = head_q.address;
    assign update_memory_size_o      = head_q.memory_size;
    assign update_byte_mask_o        = head_q.byte_mask;
    assign update_store_data_o       = head_q.store_data;
    assign update_address_valid_o    = head_q.address_valid;
    assign update_store_data_valid_o = head_q.store_data_valid;
    assign update_exception_valid_o  = head_q.exception_valid;
    assign update_exception_cause_o  = head_q.exception_cause;
    assign update_exception_tval_o   = head_q.exception_tval;
  end

`ifndef SYNTHESIS
  assert property (@(posedge clk_i) disable iff (!rst_ni)
    issue_valid_i && issue_ready_o |->
      effective_address == (base_i + immediate_i));

  property p_update_stable_when_stalled;
    @(posedge clk_i) disable iff (!rst_ni || flush_valid_i)
      update_valid_o && !update_ready_i |=> update_valid_o &&
      $stable({update_rob_sequence_o, update_is_load_o, update_is_store_o,
               update_lq_valid_o, update_lq_index_o,
               update_sq_valid_o, update_sq_index_o, update_address_o,
               update_memory_size_o, update_byte_mask_o, update_store_data_o,
               update_address_valid_o, update_store_data_valid_o,
               update_exception_valid_o, update_exception_cause_o,
               update_exception_tval_o});
  endproperty
  assert property (p_update_stable_when_stalled);

  property p_store_phase_validity;
    @(posedge clk_i) disable iff (!rst_ni || flush_valid_i)
      update_valid_o &&
      (update_address_valid_o || update_store_data_valid_o)
      |-> update_is_load_o || update_is_store_o;
  endproperty
  assert property (p_store_phase_validity);
`endif

  initial begin : p_parameter_checks
    if ((XLEN != 32) && (XLEN != 64))
      $fatal(1, "LSU pipe XLEN must be 32 or 64");
    if ((MEM_DATA_WIDTH < XLEN) || ((MEM_DATA_WIDTH % 8) != 0) ||
        ((MEM_BYTES & (MEM_BYTES-1)) != 0))
      $fatal(1, "LSU pipe memory beat must be a power-of-two byte width covering XLEN");
    if (ROB_SEQ_WIDTH < 2)
      $fatal(1, "LSU pipe needs a wrap-aware ROB sequence");
    if ((DEPTH != 1) && (DEPTH != 2))
      $fatal(1, "LSU pipe DEPTH must be 1 or 2");
  end

endmodule
