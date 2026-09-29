module rv_fetch_queue #(
  parameter int unsigned XLEN        = 32,
  parameter int unsigned PADDR_WIDTH = 32,
  parameter int unsigned FETCH_BYTES = 16,
  parameter int unsigned QUEUE_BYTES = 64,
  parameter logic [XLEN-1:0] RESET_VECTOR = 'h8000_0000,
  localparam int unsigned COUNT_WIDTH = $clog2(QUEUE_BYTES + 1),
  localparam int unsigned FETCH_ADDR_LSB = $clog2(FETCH_BYTES)
) (
  input  logic                               clk_i,
  input  logic                               rst_ni,

  input  logic                               fill_valid_i,
  output logic                               fill_ready_o,
  input  logic [PADDR_WIDTH-1:0]             fill_addr_i,
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

  // IALIGN=16 means the stream can be stored as 16-bit parcels.  The former
  // byte queue shifted 64 byte/fault entries on every issue.  This circular
  // parcel queue halves the entry count, stores one fault bit per PMP parcel,
  // and removes that all-entry D-input mux without adding a pipeline stage.
  localparam int unsigned FETCH_PARCELS = FETCH_BYTES / 2;
  localparam int unsigned QUEUE_PARCELS = QUEUE_BYTES / 2;
  localparam int unsigned PARCEL_COUNT_WIDTH = $clog2(QUEUE_PARCELS + 1);
  localparam int unsigned PARCEL_INDEX_WIDTH = $clog2(QUEUE_PARCELS);

  logic [15:0] parcel_q [QUEUE_PARCELS];
  logic        fault_q [QUEUE_PARCELS];
  logic [PARCEL_COUNT_WIDTH-1:0] parcel_count_q;
  logic [PARCEL_INDEX_WIDTH-1:0] head_index_q;
  logic [XLEN-1:0] head_pc_q;
  logic [PADDR_WIDTH-1:0] head_paddr;
  logic [PADDR_WIDTH-1:0] redirect_paddr;
  logic [PADDR_WIDTH-1:0] fill_reference_paddr;
  logic [PADDR_WIDTH-1:0] fill_address_delta;

  integer unsigned length0_parcels;
  integer unsigned length1_parcels;
  integer unsigned lane1_offset_parcels;
  integer unsigned consume_parcels;
  integer unsigned fill_skip_parcels;
  integer unsigned fill_count_parcels;
  integer unsigned parcel_count_integer;

  if (PADDR_WIDTH >= XLEN) begin : g_head_paddr_extend
    assign head_paddr = {{(PADDR_WIDTH-XLEN){1'b0}}, head_pc_q};
    assign redirect_paddr = {{(PADDR_WIDTH-XLEN){1'b0}}, redirect_pc_i};
  end else begin : g_head_paddr_truncate
    assign head_paddr = head_pc_q[PADDR_WIDTH-1:0];
    assign redirect_paddr = redirect_pc_i[PADDR_WIDTH-1:0];
  end

  always_comb begin
    logic [15:0] parcel0;
    logic [15:0] parcel1;
    logic [15:0] parcel2;
    logic [15:0] lane1_parcel0;
    logic [15:0] lane1_parcel1;

    parcel0 = parcel_q[head_index_q];
    parcel1 = parcel_q[head_index_q + PARCEL_INDEX_WIDTH'(1)];
    parcel2 = parcel_q[head_index_q + PARCEL_INDEX_WIDTH'(2)];
    lane1_parcel0 = '0;
    lane1_parcel1 = '0;

    length0_parcels = 0;
    length1_parcels = 0;
    lane1_offset_parcels = 0;
    out_valid_o = '0;
    out_pc_o = '0;
    out_instruction_o = '0;
    out_inst_len_o[0] = INST_LEN_NONE;
    out_inst_len_o[1] = INST_LEN_NONE;
    out_fault_o = '0;

    if (parcel_count_q != 0) begin
      length0_parcels = (parcel0[1:0] == 2'b11) ? 2 : 1;
      if (parcel_count_q >= PARCEL_COUNT_WIDTH'(length0_parcels)) begin
        out_valid_o[0] = 1'b1;
        out_pc_o[0] = head_pc_q;
        out_instruction_o[0][15:0] = parcel0;
        out_inst_len_o[0] = (length0_parcels == 1) ?
          INST_LEN_16 : INST_LEN_32;
        out_fault_o[0] = fault_q[head_index_q];
        if (length0_parcels == 2) begin
          out_instruction_o[0][31:16] = parcel1;
          out_fault_o[0] |=
            fault_q[head_index_q + PARCEL_INDEX_WIDTH'(1)];
        end
      end
    end

    lane1_offset_parcels = length0_parcels;
    if (out_valid_o[0] &&
        (parcel_count_q >= PARCEL_COUNT_WIDTH'(lane1_offset_parcels + 1))) begin
      lane1_parcel0 = (lane1_offset_parcels == 1) ? parcel1 : parcel2;
      lane1_parcel1 = parcel_q[head_index_q +
                              PARCEL_INDEX_WIDTH'(lane1_offset_parcels + 1)];
      length1_parcels = (lane1_parcel0[1:0] == 2'b11) ? 2 : 1;
      if (parcel_count_q >=
          PARCEL_COUNT_WIDTH'(lane1_offset_parcels + length1_parcels)) begin
        out_valid_o[1] = 1'b1;
        out_pc_o[1] = head_pc_q + XLEN'(lane1_offset_parcels * 2);
        out_instruction_o[1][15:0] = lane1_parcel0;
        out_inst_len_o[1] = (length1_parcels == 1) ?
          INST_LEN_16 : INST_LEN_32;
        out_fault_o[1] =
          fault_q[head_index_q +
                  PARCEL_INDEX_WIDTH'(lane1_offset_parcels)];
        if (length1_parcels == 2) begin
          out_instruction_o[1][31:16] = lane1_parcel1;
          out_fault_o[1] |=
            fault_q[head_index_q +
                    PARCEL_INDEX_WIDTH'(lane1_offset_parcels + 1)];
        end
      end
    end
  end

  always_comb begin
    parcel_count_integer = parcel_count_q;
    fill_reference_paddr = redirect_valid_i ? redirect_paddr : head_paddr;
    fill_address_delta = fill_reference_paddr - fill_addr_i;
    fill_skip_parcels = 0;
    if (((parcel_count_q == 0) || redirect_valid_i) &&
        (fill_reference_paddr >= fill_addr_i) &&
        (fill_reference_paddr <
         (fill_addr_i + PADDR_WIDTH'(FETCH_BYTES)))) begin
      fill_skip_parcels = fill_address_delta[FETCH_ADDR_LSB-1:1];
    end
    fill_count_parcels = FETCH_PARCELS - fill_skip_parcels;
    fill_ready_o = redirect_valid_i ?
      (fill_count_parcels <= QUEUE_PARCELS) :
      ((parcel_count_integer + fill_count_parcels) <= QUEUE_PARCELS);
  end

  always_comb begin
    consume_parcels = 0;
    if (out_valid_o[0] && out_ready_i[0]) begin
      consume_parcels = length0_parcels;
      if (out_valid_o[1] && out_ready_i[1])
        consume_parcels += length1_parcels;
    end
  end

  always_ff @(posedge clk_i) begin
    if (!rst_ni) begin
      for (int unsigned index = 0; index < QUEUE_PARCELS; index++) begin
        parcel_q[index] <= '0;
        fault_q[index] <= 1'b0;
      end
      parcel_count_q <= '0;
      head_index_q <= '0;
      head_pc_q <= RESET_VECTOR;
    end else if (redirect_valid_i) begin
      // A target-buffer hit supplies an aligned block on the redirect edge.
      // Store it at fixed parcel positions and move only the head pointer to
      // the target offset.  Target instructions remain visible next cycle.
      parcel_count_q <= '0;
      head_index_q <= '0;
      head_pc_q <= redirect_pc_i;
      if (fill_valid_i && fill_ready_o) begin
        for (int unsigned source = 0; source < FETCH_PARCELS; source++) begin
          parcel_q[source] <= fill_data_i[source*16 +: 16];
          fault_q[source] <= (fill_resp_i != 2'b00) ||
                             !fill_pmp_allow_i[source];
        end
        parcel_count_q <= PARCEL_COUNT_WIDTH'(fill_count_parcels);
        head_index_q <= PARCEL_INDEX_WIDTH'(fill_skip_parcels);
      end
    end else begin
      if (consume_parcels != 0) begin
        head_index_q <= head_index_q +
                        PARCEL_INDEX_WIDTH'(consume_parcels);
        head_pc_q <= head_pc_q + XLEN'(consume_parcels * 2);
      end

      parcel_count_q <= parcel_count_q -
                        PARCEL_COUNT_WIDTH'(consume_parcels);
      if (fill_valid_i && fill_ready_o) begin
        // Circular tail = old head + old count.  Simultaneous consumption
        // advances the head by the amount by which count decreases.
        for (int unsigned source = 0; source < FETCH_PARCELS; source++) begin
          if (source >= fill_skip_parcels) begin
            parcel_q[head_index_q +
                     PARCEL_INDEX_WIDTH'(parcel_count_integer + source -
                                         fill_skip_parcels)] <=
              fill_data_i[source*16 +: 16];
            fault_q[head_index_q +
                    PARCEL_INDEX_WIDTH'(parcel_count_integer + source -
                                        fill_skip_parcels)] <=
              (fill_resp_i != 2'b00) || !fill_pmp_allow_i[source];
          end
        end
        parcel_count_q <= parcel_count_q -
                          PARCEL_COUNT_WIDTH'(consume_parcels) +
                          PARCEL_COUNT_WIDTH'(fill_count_parcels);
      end
    end
  end

  assign empty_o = (parcel_count_q == 0);
  assign byte_count_o = COUNT_WIDTH'(parcel_count_q) << 1;

`ifndef SYNTHESIS
  always_comb begin
    if (rst_ni === 1'b1) begin
      assert (!out_valid_o[1] || out_valid_o[0]);
      assert (parcel_count_q <= QUEUE_PARCELS);
      assert (!redirect_valid_i || !redirect_pc_i[0]);
      if (redirect_valid_i && fill_valid_i) begin
        assert (fill_ready_o);
        assert ((redirect_paddr >= fill_addr_i) &&
                (redirect_paddr <
                 (fill_addr_i + PADDR_WIDTH'(FETCH_BYTES))));
      end
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
    if ((QUEUE_PARCELS & (QUEUE_PARCELS-1)) != 0)
      $fatal(1, "Fetch queue parcel count must be a power of two");
  end

endmodule
