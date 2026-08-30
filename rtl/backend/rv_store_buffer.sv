module rv_store_buffer #(
  parameter int unsigned PADDR_WIDTH = 32,
  parameter int unsigned DATA_WIDTH  = 64,
  parameter int unsigned ENTRIES     = 16,
  parameter int unsigned SEQ_WIDTH   = rv_ooo_pkg::ROB_SEQ_WIDTH,
  localparam int unsigned DATA_BYTES = DATA_WIDTH / 8,
  localparam int unsigned INDEX_WIDTH = $clog2(ENTRIES),
  localparam int unsigned COUNT_WIDTH = $clog2(ENTRIES + 1),
  localparam int unsigned BANK_BIT = $clog2(DATA_BYTES)
) (
  input  logic                                  clk_i,
  input  logic                                  rst_ni,

  input  logic [1:0]                            enq_valid_i,
  output logic [1:0]                            enq_ready_o,
  input  logic [1:0][SEQ_WIDTH-1:0]             enq_sequence_i,
  input  logic [1:0][PADDR_WIDTH-1:0]           enq_address_i,
  input  logic [1:0][DATA_WIDTH-1:0]            enq_data_i,
  input  logic [1:0][DATA_BYTES-1:0]            enq_mask_i,
  input  logic [1:0][2:0]                       enq_size_i,
  input  logic [1:0]                            enq_device_i,

  output logic [1:0]                            drain_valid_o,
  input  logic [1:0]                            drain_ready_i,
  output logic [1:0][INDEX_WIDTH-1:0]           drain_index_o,
  output logic [1:0][SEQ_WIDTH-1:0]             drain_sequence_o,
  output logic [1:0][PADDR_WIDTH-1:0]           drain_address_o,
  output logic [1:0][DATA_WIDTH-1:0]            drain_data_o,
  output logic [1:0][DATA_BYTES-1:0]            drain_mask_o,
  output logic [1:0][2:0]                       drain_size_o,
  output logic [1:0]                            drain_device_o,

  input  logic [1:0]                            drain_rsp_valid_i,
  output logic [1:0]                            drain_rsp_ready_o,
  input  logic [1:0][INDEX_WIDTH-1:0]           drain_rsp_index_i,
  input  logic [1:0][1:0]                       drain_rsp_resp_i,

  input  logic [1:0]                            query_valid_i,
  input  logic [1:0][PADDR_WIDTH-1:0]           query_address_i,
  input  logic [1:0][DATA_BYTES-1:0]            query_mask_i,
  output logic [1:0]                            query_full_cover_o,
  output logic [1:0]                            query_partial_o,
  output logic [1:0][DATA_WIDTH-1:0]            query_data_o,
  output logic [1:0][INDEX_WIDTH-1:0]           query_index_o,

  output logic                                  empty_o,
  output logic                                  full_o,
  output logic [COUNT_WIDTH-1:0]                count_o,
  output logic [SEQ_WIDTH-1:0]                  head_sequence_o,
  output logic                                  device_pending_o,
  output logic                                  machine_check_o
);

  logic [ENTRIES-1:0] valid_q;
  logic [ENTRIES-1:0] sent_q;
  logic [ENTRIES-1:0] done_q;
  logic [ENTRIES-1:0] device_q;
  logic [SEQ_WIDTH-1:0] sequence_q [0:ENTRIES-1];
  logic [PADDR_WIDTH-1:0] address_q [0:ENTRIES-1];
  logic [DATA_WIDTH-1:0] data_q [0:ENTRIES-1];
  logic [DATA_BYTES-1:0] mask_q [0:ENTRIES-1];
  logic [2:0] size_q [0:ENTRIES-1];

  logic [INDEX_WIDTH-1:0] head_q;
  logic [INDEX_WIDTH-1:0] tail_q;
  logic [COUNT_WIDTH-1:0] count_q;
  logic machine_check_q;

  logic [INDEX_WIDTH-1:0] head_next;
  logic [1:0] pop_count;
  logic [1:0] accepted_count;
  logic [COUNT_WIDTH:0] available_slots;
  logic pair_same_beat;
  logic pair_overlaps;
  logic pair_different_bank;
  logic pair_can_drain;
  localparam logic [COUNT_WIDTH:0] BUFFER_CAPACITY = ENTRIES;

  function automatic logic [INDEX_WIDTH-1:0] increment_index(
    input logic [INDEX_WIDTH-1:0] index,
    input logic [1:0] amount
  );
    logic [INDEX_WIDTH:0] sum;
    sum = {1'b0, index} + {{(INDEX_WIDTH-1){1'b0}}, amount};
    if (sum >= ENTRIES)
      sum = sum - ENTRIES;
    return sum[INDEX_WIDTH-1:0];
  endfunction

  function automatic logic sequence_after(
    input logic [SEQ_WIDTH-1:0] lhs,
    input logic [SEQ_WIDTH-1:0] rhs
  );
    logic signed [SEQ_WIDTH-1:0] distance;
    distance = $signed(lhs - rhs);
    return distance > 0;
  endfunction

  always_comb begin
    head_next = increment_index(head_q, 1);
    pop_count = '0;
    if ((count_q != 0) && valid_q[head_q] && done_q[head_q]) begin
      pop_count = 1;
      if ((count_q > 1) && valid_q[head_next] && done_q[head_next])
        pop_count = 2;
    end

    available_slots = BUFFER_CAPACITY - {1'b0, count_q} +
                      {{(COUNT_WIDTH-1){1'b0}}, pop_count};
    enq_ready_o[0] = (available_slots >= 1);
    enq_ready_o[1] = (available_slots >= 2);
    accepted_count =
      {1'b0, enq_valid_i[0] && enq_ready_o[0]} +
      {1'b0, enq_valid_i[1] && enq_ready_o[1]};
  end

  always_comb begin
    pair_same_beat =
      address_q[head_q][PADDR_WIDTH-1:BANK_BIT] ==
      address_q[head_next][PADDR_WIDTH-1:BANK_BIT];
    pair_overlaps = pair_same_beat &&
                    ((mask_q[head_q] & mask_q[head_next]) != '0);
    pair_different_bank =
      address_q[head_q][BANK_BIT] != address_q[head_next][BANK_BIT];
    pair_can_drain = !device_q[head_q] && !device_q[head_next] &&
                     !pair_overlaps && pair_different_bank;

    drain_valid_o = '0;
    drain_index_o = '0;
    drain_sequence_o = '0;
    drain_address_o = '0;
    drain_data_o = '0;
    drain_mask_o = '0;
    drain_size_o = '0;
    drain_device_o = '0;

    if (count_q != 0) begin
      if (!sent_q[head_q] && !done_q[head_q]) begin
        drain_valid_o[0] = 1'b1;
        drain_index_o[0] = head_q;
        if ((count_q > 1) && !sent_q[head_next] && !done_q[head_next] &&
            pair_can_drain) begin
          drain_valid_o[1] = 1'b1;
          drain_index_o[1] = head_next;
        end
      end else if ((count_q > 1) && !sent_q[head_next] &&
                   !done_q[head_next] &&
                   (done_q[head_q] || pair_can_drain)) begin
        drain_valid_o[0] = 1'b1;
        drain_index_o[0] = head_next;
      end
    end

    for (int unsigned lane = 0; lane < 2; lane++) begin
      if (drain_valid_o[lane]) begin
        drain_sequence_o[lane] = sequence_q[drain_index_o[lane]];
        drain_address_o[lane] = address_q[drain_index_o[lane]];
        drain_data_o[lane] = data_q[drain_index_o[lane]];
        drain_mask_o[lane] = mask_q[drain_index_o[lane]];
        drain_size_o[lane] = size_q[drain_index_o[lane]];
        drain_device_o[lane] = device_q[drain_index_o[lane]];
      end
    end
  end

  for (genvar lane = 0; lane < 2; lane++) begin : g_query
    always @(*) begin
      logic found;
      logic [SEQ_WIDTH-1:0] selected_sequence;
      logic [DATA_BYTES-1:0] selected_overlap;

      found = 1'b0;
      selected_sequence = '0;
      selected_overlap = '0;
      query_full_cover_o[lane] = 1'b0;
      query_partial_o[lane] = 1'b0;
      query_data_o[lane] = '0;
      query_index_o[lane] = '0;

      for (int unsigned entry = 0; entry < ENTRIES; entry++) begin
        if (query_valid_i[lane] && valid_q[entry] &&
            (address_q[entry][PADDR_WIDTH-1:BANK_BIT] ==
             query_address_i[lane][PADDR_WIDTH-1:BANK_BIT]) &&
            ((mask_q[entry] & query_mask_i[lane]) != '0) &&
            (!found || sequence_after(sequence_q[entry],
                                      selected_sequence))) begin
          found = 1'b1;
          selected_sequence = sequence_q[entry];
          selected_overlap = mask_q[entry] & query_mask_i[lane];
          query_data_o[lane] = data_q[entry];
          query_index_o[lane] = INDEX_WIDTH'(entry);
        end
      end

      if (found) begin
        query_full_cover_o[lane] =
          (query_mask_i[lane] != '0) &&
          (selected_overlap == query_mask_i[lane]);
        query_partial_o[lane] = !query_full_cover_o[lane];
      end
    end
  end

  assign drain_rsp_ready_o = 2'b11;
  assign empty_o = (count_q == 0);
  assign full_o = (count_q == ENTRIES);
  assign count_o = count_q;
  assign head_sequence_o = (count_q != 0) ? sequence_q[head_q] : '0;
  assign device_pending_o = |(valid_q & device_q);
  assign machine_check_o = machine_check_q;

  always_ff @(posedge clk_i) begin
    if (!rst_ni) begin
      valid_q <= '0;
      sent_q <= '0;
      done_q <= '0;
      device_q <= '0;
      head_q <= '0;
      tail_q <= '0;
      count_q <= '0;
      machine_check_q <= 1'b0;
      for (int unsigned entry = 0; entry < ENTRIES; entry++) begin
        sequence_q[entry] <= '0;
        address_q[entry] <= '0;
        data_q[entry] <= '0;
        mask_q[entry] <= '0;
        size_q[entry] <= '0;
      end
    end else begin
      for (int unsigned lane = 0; lane < 2; lane++) begin
        if (drain_rsp_valid_i[lane] && drain_rsp_ready_o[lane] &&
            valid_q[drain_rsp_index_i[lane]] &&
            sent_q[drain_rsp_index_i[lane]]) begin
          done_q[drain_rsp_index_i[lane]] <= 1'b1;
          if (drain_rsp_resp_i[lane] != 2'b00)
            machine_check_q <= 1'b1;
        end
        if (drain_valid_o[lane] && drain_ready_i[lane])
          sent_q[drain_index_o[lane]] <= 1'b1;
      end

      if (pop_count != 0) begin
        valid_q[head_q] <= 1'b0;
        sent_q[head_q] <= 1'b0;
        done_q[head_q] <= 1'b0;
        if (pop_count == 2) begin
          valid_q[head_next] <= 1'b0;
          sent_q[head_next] <= 1'b0;
          done_q[head_next] <= 1'b0;
        end
        head_q <= increment_index(head_q, pop_count);
      end

      for (int unsigned lane = 0; lane < 2; lane++) begin
        if (enq_valid_i[lane] && enq_ready_o[lane]) begin
          logic [INDEX_WIDTH-1:0] write_index;
          write_index = increment_index(tail_q, 2'(lane));
          valid_q[write_index] <= 1'b1;
          sent_q[write_index] <= 1'b0;
          done_q[write_index] <= 1'b0;
          sequence_q[write_index] <= enq_sequence_i[lane];
          address_q[write_index] <= enq_address_i[lane];
          data_q[write_index] <= enq_data_i[lane];
          mask_q[write_index] <= enq_mask_i[lane];
          size_q[write_index] <= enq_size_i[lane];
          device_q[write_index] <= enq_device_i[lane];
        end
      end
      if (accepted_count != 0)
        tail_q <= increment_index(tail_q, accepted_count);

      count_q <= count_q + COUNT_WIDTH'(accepted_count) -
                 COUNT_WIDTH'(pop_count);
    end
  end

`ifndef SYNTHESIS
  property p_lane1_enqueue_requires_lane0;
    @(posedge clk_i) disable iff (!rst_ni)
      enq_valid_i[1] |-> enq_valid_i[0];
  endproperty
  assert property (p_lane1_enqueue_requires_lane0);

  property p_lane1_drain_requires_lane0;
    @(posedge clk_i) disable iff (!rst_ni)
      drain_valid_o[1] |-> drain_valid_o[0];
  endproperty
  assert property (p_lane1_drain_requires_lane0);

  property p_device_is_never_second_drain;
    @(posedge clk_i) disable iff (!rst_ni)
      drain_valid_o[1] |-> !drain_device_o[0] && !drain_device_o[1];
  endproperty
  assert property (p_device_is_never_second_drain);

  property p_query_modes_are_exclusive;
    @(posedge clk_i) disable iff (!rst_ni)
      !(|(query_full_cover_o & query_partial_o));
  endproperty
  assert property (p_query_modes_are_exclusive);
`endif

  initial begin : p_parameter_checks
    if ((ENTRIES < 2) || ((ENTRIES & (ENTRIES-1)) != 0))
      $fatal(1, "Store buffer ENTRIES must be a power of two >= 2");
    if ((DATA_WIDTH < 32) || ((DATA_WIDTH % 8) != 0) ||
        ((DATA_BYTES & (DATA_BYTES-1)) != 0))
      $fatal(1, "Store buffer DATA_WIDTH must be a power-of-two byte width");
    if ((PADDR_WIDTH <= BANK_BIT) || (SEQ_WIDTH < 2))
      $fatal(1, "Store buffer address/sequence widths are invalid");
  end

endmodule
