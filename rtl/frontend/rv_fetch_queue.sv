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

  logic [7:0] byte_q [QUEUE_BYTES];
  logic       fault_q[QUEUE_BYTES];
  logic [7:0] byte_d [QUEUE_BYTES];
  logic       fault_d[QUEUE_BYTES];
  logic [COUNT_WIDTH-1:0] count_q;
  logic [COUNT_WIDTH-1:0] count_d;
  logic [XLEN-1:0] head_pc_q;
  logic [XLEN-1:0] head_pc_d;
  logic [PADDR_WIDTH-1:0] head_paddr;
  logic [PADDR_WIDTH-1:0] redirect_paddr;
  logic [PADDR_WIDTH-1:0] fill_reference_paddr;

  integer unsigned length0;
  integer unsigned length1;
  integer unsigned lane1_offset;
  integer unsigned consume_bytes;
  integer unsigned fill_skip;
  integer unsigned fill_count;
  integer unsigned count_integer;
  logic [PADDR_WIDTH-1:0] fill_address_delta;

  if (PADDR_WIDTH >= XLEN) begin : g_head_paddr_extend
    assign head_paddr = {{(PADDR_WIDTH-XLEN){1'b0}}, head_pc_q};
    assign redirect_paddr = {{(PADDR_WIDTH-XLEN){1'b0}}, redirect_pc_i};
  end else begin : g_head_paddr_truncate
    assign head_paddr = head_pc_q[PADDR_WIDTH-1:0];
    assign redirect_paddr = redirect_pc_i[PADDR_WIDTH-1:0];
  end

  always_comb begin
    length0 = 0;
    length1 = 0;
    lane1_offset = 0;
    out_valid_o = '0;
    out_pc_o = '0;
    out_instruction_o = '0;
    out_inst_len_o[0] = INST_LEN_NONE;
    out_inst_len_o[1] = INST_LEN_NONE;
    out_fault_o = '0;

    if (count_q >= 2) begin
      length0 = (byte_q[0][1:0] == 2'b11) ? 4 : 2;
      if (count_q >= length0) begin
        out_valid_o[0] = 1'b1;
        out_pc_o[0] = head_pc_q;
        out_instruction_o[0][7:0] = byte_q[0];
        out_instruction_o[0][15:8] = byte_q[1];
        out_inst_len_o[0] = (length0 == 2) ? INST_LEN_16 : INST_LEN_32;
        out_fault_o[0] = fault_q[0] | fault_q[1];
        if (length0 == 4) begin
          out_instruction_o[0][23:16] = byte_q[2];
          out_instruction_o[0][31:24] = byte_q[3];
          out_fault_o[0] |= fault_q[2] | fault_q[3];
        end
      end
    end

    lane1_offset = length0;
    if (out_valid_o[0] && (count_q >= (lane1_offset + 2))) begin
      length1 = (byte_q[lane1_offset][1:0] == 2'b11) ? 4 : 2;
      if (count_q >= (lane1_offset + length1)) begin
        out_valid_o[1] = 1'b1;
        out_pc_o[1] = head_pc_q + XLEN'(lane1_offset);
        out_instruction_o[1][7:0] = byte_q[lane1_offset];
        out_instruction_o[1][15:8] = byte_q[lane1_offset+1];
        out_inst_len_o[1] = (length1 == 2) ? INST_LEN_16 : INST_LEN_32;
        out_fault_o[1] = fault_q[lane1_offset] | fault_q[lane1_offset+1];
        if (length1 == 4) begin
          out_instruction_o[1][23:16] = byte_q[lane1_offset+2];
          out_instruction_o[1][31:24] = byte_q[lane1_offset+3];
          out_fault_o[1] |= fault_q[lane1_offset+2] |
                             fault_q[lane1_offset+3];
        end
      end
    end
  end

  always_comb begin
    count_integer = count_q;
    // A redirect and a fill may arrive together when the target-block buffer
    // hits.  In that case the new PC, rather than the discarded queue head,
    // selects the first useful byte in the aligned fetch block.
    fill_reference_paddr = redirect_valid_i ? redirect_paddr : head_paddr;
    fill_address_delta = fill_reference_paddr - fill_addr_i;
    fill_skip = 0;
    if (((count_q == 0) || redirect_valid_i) &&
        (fill_reference_paddr >= fill_addr_i) &&
        (fill_reference_paddr <
         (fill_addr_i + PADDR_WIDTH'(FETCH_BYTES)))) begin
      fill_skip = fill_address_delta[FETCH_ADDR_LSB-1:0];
    end
    fill_count = FETCH_BYTES - fill_skip;
    fill_ready_o = redirect_valid_i ? (fill_count <= QUEUE_BYTES) :
      ((count_integer + fill_count) <= QUEUE_BYTES);
  end

  always_comb begin
    for (int unsigned index = 0; index < QUEUE_BYTES; index++) begin
      byte_d[index] = byte_q[index];
      fault_d[index] = fault_q[index];
    end
    count_d = count_q;
    head_pc_d = head_pc_q;
    consume_bytes = 0;

    if (out_valid_o[0] && out_ready_i[0]) begin
      consume_bytes = length0;
      if (out_valid_o[1] && out_ready_i[1])
        consume_bytes += length1;
    end

    if (redirect_valid_i) begin
      // Redirect owns the queue state.  A simultaneous fill is the block for
      // the new target and is installed atomically, eliminating the former
      // redirect-empty/replay cycle.  Bytes preceding an unaligned target PC
      // are intentionally skipped.
      for (int unsigned index = 0; index < QUEUE_BYTES; index++) begin
        byte_d[index] = '0;
        fault_d[index] = 1'b0;
      end
      count_d = '0;
      head_pc_d = redirect_pc_i;

      if (fill_valid_i && fill_ready_o) begin
        for (int unsigned source = 0; source < FETCH_BYTES; source++) begin
          if (source >= fill_skip) begin
            byte_d[source - fill_skip] = fill_data_i[source*8 +: 8];
            fault_d[source - fill_skip] = (fill_resp_i != 2'b00);
          end
        end
        count_d = COUNT_WIDTH'(fill_count);
      end
    end else begin
      if (consume_bytes != 0) begin
        for (int unsigned index = 0; index < QUEUE_BYTES; index++) begin
          if ((index + consume_bytes) < count_q) begin
            byte_d[index] = byte_q[index + consume_bytes];
            fault_d[index] = fault_q[index + consume_bytes];
          end else begin
            byte_d[index] = '0;
            fault_d[index] = 1'b0;
          end
        end
        count_d = count_q - COUNT_WIDTH'(consume_bytes);
        head_pc_d = head_pc_q + XLEN'(consume_bytes);
      end

      if (fill_valid_i && fill_ready_o) begin
        for (int unsigned source = 0; source < FETCH_BYTES; source++) begin
          if (source >= fill_skip) begin
            byte_d[count_integer - consume_bytes + source - fill_skip] =
              fill_data_i[source*8 +: 8];
            fault_d[count_integer - consume_bytes + source - fill_skip] =
              (fill_resp_i != 2'b00);
          end
        end
        count_d = count_q - COUNT_WIDTH'(consume_bytes) +
                  COUNT_WIDTH'(fill_count);
      end
    end
  end

  always_ff @(posedge clk_i) begin
    if (!rst_ni) begin
      for (int unsigned index = 0; index < QUEUE_BYTES; index++) begin
        byte_q[index] <= '0;
        fault_q[index] <= 1'b0;
      end
      count_q <= '0;
      head_pc_q <= RESET_VECTOR;
    end else begin
      for (int unsigned index = 0; index < QUEUE_BYTES; index++) begin
        byte_q[index] <= byte_d[index];
        fault_q[index] <= fault_d[index];
      end
      count_q <= count_d;
      head_pc_q <= head_pc_d;
    end
  end

  assign empty_o = (count_q == 0);
  assign byte_count_o = count_q;

`ifndef SYNTHESIS
  always_comb begin
    assert (!out_valid_o[1] || out_valid_o[0]);
    assert (count_q <= QUEUE_BYTES);
    if (redirect_valid_i && fill_valid_i) begin
      assert (fill_ready_o);
      assert ((redirect_paddr >= fill_addr_i) &&
              (redirect_paddr <
               (fill_addr_i + PADDR_WIDTH'(FETCH_BYTES))));
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
    if ((QUEUE_BYTES < (2*FETCH_BYTES)) ||
        ((QUEUE_BYTES % FETCH_BYTES) != 0))
      $fatal(1, "Fetch queue must contain an integer number of blocks");
  end

endmodule
