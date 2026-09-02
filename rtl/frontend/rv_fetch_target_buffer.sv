module rv_fetch_target_buffer #(
  parameter int unsigned PADDR_WIDTH = 32,
  parameter int unsigned FETCH_BYTES = 16,
  parameter int unsigned ENTRIES     = 16,
  localparam int unsigned OFFSET_BITS = $clog2(FETCH_BYTES),
  localparam int unsigned INDEX_BITS  = $clog2(ENTRIES),
  localparam int unsigned TAG_BITS    = PADDR_WIDTH-OFFSET_BITS-INDEX_BITS
) (
  input  logic                         clk_i,
  input  logic                         rst_ni,
  input  logic                         invalidate_i,

  input  logic                         lookup_valid_i,
  input  logic [PADDR_WIDTH-1:0]       lookup_addr_i,
  output logic                         lookup_hit_o,
  output logic [FETCH_BYTES*8-1:0]     lookup_data_o,

  input  logic                         fill_valid_i,
  input  logic [PADDR_WIDTH-1:0]       fill_addr_i,
  input  logic [FETCH_BYTES*8-1:0]     fill_data_i
);
  logic [ENTRIES-1:0] valid_q;
  logic [TAG_BITS-1:0] tag_q [0:ENTRIES-1];
  logic [FETCH_BYTES*8-1:0] data_q [0:ENTRIES-1];
  logic [INDEX_BITS-1:0] lookup_index, fill_index;
  logic [TAG_BITS-1:0] lookup_tag, fill_tag;

  assign lookup_index =
    lookup_addr_i[OFFSET_BITS+INDEX_BITS-1:OFFSET_BITS];
  assign fill_index = fill_addr_i[OFFSET_BITS+INDEX_BITS-1:OFFSET_BITS];
  assign lookup_tag = lookup_addr_i[PADDR_WIDTH-1:OFFSET_BITS+INDEX_BITS];
  assign fill_tag = fill_addr_i[PADDR_WIDTH-1:OFFSET_BITS+INDEX_BITS];
  assign lookup_hit_o = lookup_valid_i && valid_q[lookup_index] &&
                        (tag_q[lookup_index] == lookup_tag);
  assign lookup_data_o = data_q[lookup_index];

  always_ff @(posedge clk_i) begin
    if (!rst_ni || invalidate_i) begin
      valid_q <= '0;
    end else if (fill_valid_i) begin
      valid_q[fill_index] <= 1'b1;
      tag_q[fill_index] <= fill_tag;
      data_q[fill_index] <= fill_data_i;
    end
  end

`ifndef SYNTHESIS
  property p_lookup_is_block_aligned;
    @(posedge clk_i) disable iff (!rst_ni)
      lookup_valid_i |-> lookup_addr_i[OFFSET_BITS-1:0] == '0;
  endproperty
  assert property (p_lookup_is_block_aligned);

  property p_fill_is_block_aligned;
    @(posedge clk_i) disable iff (!rst_ni)
      fill_valid_i |-> fill_addr_i[OFFSET_BITS-1:0] == '0;
  endproperty
  assert property (p_fill_is_block_aligned);
`endif

  initial begin : p_parameter_checks
    if ((FETCH_BYTES < 8) || ((FETCH_BYTES & (FETCH_BYTES-1)) != 0))
      $fatal(1, "Fetch target buffer FETCH_BYTES must be a power of two");
    if ((ENTRIES < 2) || ((ENTRIES & (ENTRIES-1)) != 0))
      $fatal(1, "Fetch target buffer ENTRIES must be a power of two");
    if (TAG_BITS <= 0)
      $fatal(1, "Fetch target buffer address tag width must be positive");
  end
endmodule
