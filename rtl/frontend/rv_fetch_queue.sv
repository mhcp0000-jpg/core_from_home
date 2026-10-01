module rv_fetch_queue #(
  parameter int unsigned XLEN        = 32,
  parameter int unsigned PADDR_WIDTH = 32,
  parameter int unsigned FETCH_BYTES = 16,
  parameter int unsigned QUEUE_BYTES = 64,
  // Payload has no architectural meaning when out_valid_o is zero. Allow
  // a tightly coupled predictor to read bytes/PC without a validity mux.
  parameter bit UNGATED_PAYLOAD = 1'b0,
  parameter bit SEPARATE_NORMAL_FILL_ADDRESS = 1'b0,
  parameter logic [XLEN-1:0] RESET_VECTOR = 'h8000_0000,
  localparam int unsigned COUNT_WIDTH = $clog2(QUEUE_BYTES + 1),
  localparam int unsigned FETCH_ADDR_LSB = $clog2(FETCH_BYTES)
) (
  input  logic                               clk_i,
  input  logic                               rst_ni,
  input  logic                               fill_valid_i,
  output logic                               fill_ready_o,
  input  logic [PADDR_WIDTH-1:0]             fill_addr_i,
  // With SEPARATE_NORMAL_FILL_ADDRESS, normal response address/valid bypass
  // the predicted-target/FTB mux. The frontend supplies its outstanding
  // address register and current-epoch response valid. fill_addr_i still
  // describes the actual block for redirect/metadata assertions. Both normal
  // inputs are ignored on redirect; without redirect both valids must agree.
  input  logic [PADDR_WIDTH-1:0]             normal_fill_addr_i,
  input  logic                               normal_fill_valid_i,
  input  logic [3:0]                         fill_id_i,
  input  logic [3:0]                         fill_epoch_i,
  input  logic [FETCH_BYTES*8-1:0]           fill_data_i,
  input  logic [1:0]                         fill_resp_i,
  input  logic [FETCH_BYTES/2-1:0]           fill_pmp_allow_i,
  input  logic                               redirect_valid_i,
  input  logic [XLEN-1:0]                    redirect_pc_i,
  input  logic [3:0]                         new_epoch_i,
  output logic [1:0]                         out_valid_o,
  input  logic [1:0]                         out_ready_i,
  output logic [1:0][XLEN-1:0]               out_pc_o,
  output logic [1:0][31:0]                   out_instruction_o,
  output rv_ooo_pkg::inst_len_e [1:0]        out_inst_len_o,
  output logic [1:0]                         out_fault_o,
  output logic                               empty_o,
  output logic [COUNT_WIDTH-1:0]             byte_count_o
);

  import rv_ooo_pkg::*;

  // Aligned fetch responses are stored as complete blocks. A four-entry block
  // FIFO has the same 64-byte capacity as the former 32-entry parcel ring, but
  // its read mux and write decoder are only four ways. Current and next blocks
  // are concatenated so a 32-bit instruction may cross a block boundary.
  localparam int unsigned FETCH_PARCELS = FETCH_BYTES / 2;
  localparam int unsigned QUEUE_BLOCKS = QUEUE_BYTES / FETCH_BYTES;
  localparam int unsigned BLOCK_INDEX_WIDTH = $clog2(QUEUE_BLOCKS);
  localparam int unsigned BLOCK_COUNT_WIDTH = $clog2(QUEUE_BLOCKS + 1);
  localparam int unsigned PARCEL_OFFSET_WIDTH = $clog2(FETCH_PARCELS);

  logic [FETCH_BYTES*8-1:0] block_data_q [0:QUEUE_BLOCKS-1];
  logic [FETCH_PARCELS-1:0] block_fault_q [0:QUEUE_BLOCKS-1];
  logic [BLOCK_INDEX_WIDTH-1:0] head_block_q, tail_block_q;
  logic [BLOCK_COUNT_WIDTH-1:0] block_count_q;
  logic [PARCEL_OFFSET_WIDTH-1:0] head_parcel_offset_q;
  logic [XLEN-1:0] head_pc_q;

  logic [FETCH_BYTES*8-1:0] current_block_data, next_block_data;
  logic [FETCH_PARCELS-1:0] current_block_fault, next_block_fault;
  logic [FETCH_BYTES*16-1:0] two_block_data, aligned_data;
  logic [FETCH_PARCELS*2-1:0] two_block_fault, aligned_fault;
  logic [15:0] parcel0, parcel1, parcel2, parcel3;
  logic fault0, fault1, fault2, fault3;
  logic [PADDR_WIDTH-1:0] head_paddr, redirect_paddr;
  logic [PADDR_WIDTH-1:0] fill_reference_paddr, fill_address_delta;
  logic [15:0] lane1_first_parcel;

  integer unsigned available_parcels;
  integer unsigned length0_parcels, length1_parcels;
  integer unsigned lane1_offset_parcels;
  integer unsigned consume_parcels, consume_blocks;
  integer unsigned next_head_offset;
  integer unsigned fill_head_offset;
  integer unsigned byte_count_integer;

  if (PADDR_WIDTH >= XLEN) begin : g_head_paddr_extend
    assign head_paddr = {{(PADDR_WIDTH-XLEN){1'b0}}, head_pc_q};
    assign redirect_paddr = {{(PADDR_WIDTH-XLEN){1'b0}}, redirect_pc_i};
  end else begin : g_head_paddr_truncate
    assign head_paddr = head_pc_q[PADDR_WIDTH-1:0];
    assign redirect_paddr = redirect_pc_i[PADDR_WIDTH-1:0];
  end

  assign current_block_data = block_data_q[head_block_q];
  assign current_block_fault = block_fault_q[head_block_q];
  assign next_block_data =
    block_data_q[head_block_q + BLOCK_INDEX_WIDTH'(1)];
  assign next_block_fault =
    block_fault_q[head_block_q + BLOCK_INDEX_WIDTH'(1)];
  assign two_block_data = {next_block_data, current_block_data};
  assign two_block_fault = {next_block_fault, current_block_fault};
  assign aligned_data = two_block_data >> (head_parcel_offset_q * 16);
  assign aligned_fault = two_block_fault >> head_parcel_offset_q;
  assign parcel0 = aligned_data[15:0];
  assign parcel1 = aligned_data[31:16];
  assign parcel2 = aligned_data[47:32];
  assign parcel3 = aligned_data[63:48];
  assign fault0 = aligned_fault[0];
  assign fault1 = aligned_fault[1];
  assign fault2 = aligned_fault[2];
  assign fault3 = aligned_fault[3];

  always_comb begin
    // A redirect records its within-block offset before the replacement block
    // arrives.  With no resident blocks that offset is only metadata, not
    // consumable data; saturate availability at zero to prevent stale array
    // contents from appearing as valid instructions.
    if (block_count_q == 0)
      available_parcels = 0;
    else
      available_parcels = (block_count_q * FETCH_PARCELS) -
                          head_parcel_offset_q;
    length0_parcels = 0;
    length1_parcels = 0;
    lane1_offset_parcels = 0;
    lane1_first_parcel = '0;
    out_valid_o = '0;
    out_pc_o = '0;
    out_instruction_o = '0;
    out_inst_len_o[0] = INST_LEN_NONE;
    out_inst_len_o[1] = INST_LEN_NONE;
    out_fault_o = '0;

    if (available_parcels != 0) begin
      length0_parcels = (parcel0[1:0] == 2'b11) ? 2 : 1;
      if (available_parcels >= length0_parcels) begin
        out_valid_o[0] = 1'b1;
        out_pc_o[0] = head_pc_q;
        out_instruction_o[0][15:0] = parcel0;
        out_inst_len_o[0] = (length0_parcels == 1) ?
          INST_LEN_16 : INST_LEN_32;
        out_fault_o[0] = fault0;
        if (length0_parcels == 2) begin
          out_instruction_o[0][31:16] = parcel1;
          out_fault_o[0] |= fault1;
        end
      end
    end

    lane1_offset_parcels = length0_parcels;
    if (out_valid_o[0] &&
        (available_parcels >= (lane1_offset_parcels + 1))) begin
      lane1_first_parcel = (lane1_offset_parcels == 1) ? parcel1 : parcel2;
      length1_parcels = (lane1_first_parcel[1:0] == 2'b11) ? 2 : 1;
      if (available_parcels >= (lane1_offset_parcels + length1_parcels)) begin
        out_valid_o[1] = 1'b1;
        out_pc_o[1] = head_pc_q + XLEN'(lane1_offset_parcels * 2);
        if (lane1_offset_parcels == 1) begin
          out_instruction_o[1][15:0] = parcel1;
          out_fault_o[1] = fault1;
          if (length1_parcels == 2) begin
            out_instruction_o[1][31:16] = parcel2;
            out_fault_o[1] |= fault2;
          end
        end else begin
          out_instruction_o[1][15:0] = parcel2;
          out_fault_o[1] = fault2;
          if (length1_parcels == 2) begin
            out_instruction_o[1][31:16] = parcel3;
            out_fault_o[1] |= fault3;
          end
        end
        out_inst_len_o[1] = (length1_parcels == 1) ?
          INST_LEN_16 : INST_LEN_32;
      end
    end
    if (UNGATED_PAYLOAD) begin
      out_pc_o[0] = head_pc_q;
      out_pc_o[1] = head_pc_q + ((parcel0[1:0] == 2'b11) ? XLEN'(4) : XLEN'(2));
      out_instruction_o[0] = (parcel0[1:0] == 2'b11) ? {parcel1,parcel0} : {16'b0,parcel0};
      if (parcel0[1:0] != 2'b11) begin
        out_instruction_o[1] = (parcel1[1:0] == 2'b11) ? {parcel2,parcel1} : {16'b0,parcel1};
        out_inst_len_o[1] = (parcel1[1:0] == 2'b11) ? INST_LEN_32 : INST_LEN_16;
      end else begin
        out_instruction_o[1] = (parcel2[1:0] == 2'b11) ? {parcel3,parcel2} : {16'b0,parcel2};
        out_inst_len_o[1] = (parcel2[1:0] == 2'b11) ? INST_LEN_32 : INST_LEN_16;
      end
      out_inst_len_o[0] = (parcel0[1:0] == 2'b11) ? INST_LEN_32 : INST_LEN_16;
    end
  end

  always_comb begin
    consume_parcels = 0;
    if (out_valid_o[0] && out_ready_i[0]) begin
      consume_parcels = length0_parcels;
      if (out_valid_o[1] && out_ready_i[1])
        consume_parcels += length1_parcels;
    end
    next_head_offset = head_parcel_offset_q + consume_parcels;
    consume_blocks = (next_head_offset >= FETCH_PARCELS) ? 1 : 0;
    if (consume_blocks != 0)
      next_head_offset -= FETCH_PARCELS;
  end

  always_comb begin
    // A normal response arriving to an empty queue is positioned relative to
    // the retained head PC.  Atomic redirect+FTB fills use redirect_pc_i's
    // low bits directly in the sequential block below, keeping address
    // subtract/compare logic out of the prediction feedback path.
    fill_reference_paddr = head_paddr;
    fill_address_delta = fill_reference_paddr - fill_addr_i;
    fill_head_offset = 0;
    if (SEPARATE_NORMAL_FILL_ADDRESS) begin
      // Transport blocks are aligned. Equal block tags imply the retained
      // PC's low bits are the offset; neither an add nor subtract is needed.
      // Crucially this cone never consumes predicted target/FTB hit signals.
      if ((block_count_q == 0) &&
          (fill_reference_paddr[PADDR_WIDTH-1:FETCH_ADDR_LSB] ==
           normal_fill_addr_i[PADDR_WIDTH-1:FETCH_ADDR_LSB]))
        fill_head_offset = fill_reference_paddr[FETCH_ADDR_LSB-1:1];
    end else if ((block_count_q == 0) &&
        (fill_reference_paddr >= fill_addr_i) &&
        (fill_reference_paddr <
         (fill_addr_i + PADDR_WIDTH'(FETCH_BYTES)))) begin
      fill_head_offset = fill_address_delta[FETCH_ADDR_LSB-1:1];
    end
    fill_ready_o = redirect_valid_i || (block_count_q < QUEUE_BLOCKS) ||
                   (consume_blocks != 0);
  end

  always_ff @(posedge clk_i) begin
    if (!rst_ni) begin
      for (int unsigned block = 0; block < QUEUE_BLOCKS; block++) begin
        block_data_q[block] <= '0;
        block_fault_q[block] <= '0;
      end
      head_block_q <= '0;
      tail_block_q <= '0;
      block_count_q <= '0;
      head_parcel_offset_q <= '0;
      head_pc_q <= RESET_VECTOR;
    end else if (redirect_valid_i) begin
      head_block_q <= '0;
      tail_block_q <= '0;
      block_count_q <= '0;
      head_parcel_offset_q <= PARCEL_OFFSET_WIDTH'(
        redirect_pc_i[FETCH_ADDR_LSB-1:1]);
      head_pc_q <= redirect_pc_i;
      if (fill_valid_i && fill_ready_o) begin
        block_data_q[0] <= fill_data_i;
        for (int unsigned parcel = 0; parcel < FETCH_PARCELS; parcel++)
          block_fault_q[0][parcel] <= (fill_resp_i != 2'b00) ||
                                              !fill_pmp_allow_i[parcel];
        tail_block_q <= BLOCK_INDEX_WIDTH'(1);
        block_count_q <= BLOCK_COUNT_WIDTH'(1);
      end
    end else begin
      if (consume_parcels != 0) begin
        head_parcel_offset_q <= PARCEL_OFFSET_WIDTH'(next_head_offset);
        head_pc_q <= head_pc_q + XLEN'(consume_parcels * 2);
        if (consume_blocks != 0)
          head_block_q <= head_block_q + BLOCK_INDEX_WIDTH'(1);
      end

      block_count_q <= block_count_q -
                       BLOCK_COUNT_WIDTH'(consume_blocks);
      if ((SEPARATE_NORMAL_FILL_ADDRESS ? normal_fill_valid_i : fill_valid_i) &&
          fill_ready_o) begin
        block_data_q[tail_block_q] <= fill_data_i;
        for (int unsigned parcel = 0; parcel < FETCH_PARCELS; parcel++)
          block_fault_q[tail_block_q][parcel] <=
            (fill_resp_i != 2'b00) || !fill_pmp_allow_i[parcel];
        tail_block_q <= tail_block_q + BLOCK_INDEX_WIDTH'(1);
        block_count_q <= block_count_q -
                         BLOCK_COUNT_WIDTH'(consume_blocks) +
                         BLOCK_COUNT_WIDTH'(1);
        if (block_count_q == 0) begin
          head_block_q <= tail_block_q;
          head_parcel_offset_q <= PARCEL_OFFSET_WIDTH'(fill_head_offset);
        end
      end
    end
  end

  always_comb begin
    // The retained head offset describes where the next response starts when
    // the FIFO is empty; it must not turn the externally visible occupancy
    // into an unsigned underflow while that response is still in flight.
    if (block_count_q == 0)
      byte_count_integer = 0;
    else
      byte_count_integer = (block_count_q * FETCH_BYTES) -
                           (head_parcel_offset_q * 2);
    byte_count_o = COUNT_WIDTH'(byte_count_integer);
  end
  assign empty_o = (block_count_q == 0);

`ifndef SYNTHESIS
  assert property (@(posedge clk_i) disable iff (!rst_ni)
    (SEPARATE_NORMAL_FILL_ADDRESS && !redirect_valid_i) |->
      normal_fill_valid_i == fill_valid_i);
  always_comb begin
    if (rst_ni === 1'b1) begin
      assert (!out_valid_o[1] || out_valid_o[0]);
      assert (block_count_q <= QUEUE_BLOCKS);
      assert (!redirect_valid_i || !redirect_pc_i[0]);
      if (redirect_valid_i && fill_valid_i) begin
        assert (fill_ready_o);
        assert ((redirect_paddr >= fill_addr_i) &&
                (redirect_paddr <
                 (fill_addr_i + PADDR_WIDTH'(FETCH_BYTES))));
      end
      if (SEPARATE_NORMAL_FILL_ADDRESS && fill_valid_i && !redirect_valid_i)
        assert (normal_fill_addr_i[FETCH_ADDR_LSB-1:0] == '0);
    end
  end
`endif

  logic unused_metadata;
  always_comb begin
    unused_metadata = (^fill_id_i) ^ (^fill_epoch_i) ^ (^new_epoch_i);
  end

  initial begin : p_parameter_checks
    if ((XLEN != 32) && (XLEN != 64))
      $fatal(1, "Fetch queue XLEN must be 32 or 64");
    if ((FETCH_BYTES < 8) || ((FETCH_BYTES & (FETCH_BYTES-1)) != 0))
      $fatal(1, "FETCH_BYTES must be a power of two and at least 8");
    if ((FETCH_BYTES % 2) != 0)
      $fatal(1, "FETCH_BYTES must contain whole 2-byte instruction parcels");
    if ((QUEUE_BYTES < (2*FETCH_BYTES)) ||
        ((QUEUE_BYTES % FETCH_BYTES) != 0))
      $fatal(1, "Fetch queue must contain an integer number of blocks");
    if ((QUEUE_BLOCKS & (QUEUE_BLOCKS-1)) != 0)
      $fatal(1, "Fetch queue block count must be a power of two");
  end
endmodule
