module rv_fetch_target_buffer_tb;
  localparam int unsigned FETCH_BYTES = 16;

  logic clk;
  logic rst_n;
  logic invalidate;
  logic [1:0] lookup_valid;
  logic [1:0][31:0] lookup_addr;
  logic lookup_select;
  logic lookup_hit;
  logic [FETCH_BYTES*8-1:0] lookup_data;
  logic [FETCH_BYTES/2-1:0] lookup_pmp_allow;
  logic fill_valid;
  logic [31:0] fill_addr;
  logic [FETCH_BYTES*8-1:0] fill_data;
  logic [FETCH_BYTES/2-1:0] fill_pmp_allow;

  always #5 clk = ~clk;

  rv_fetch_target_buffer #(
    .PADDR_WIDTH(32), .FETCH_BYTES(FETCH_BYTES), .ENTRIES(4),
    .LOOKUP_PORTS(2)
  ) u_dut (
    .clk_i(clk), .rst_ni(rst_n), .invalidate_i(invalidate),
    .lookup_valid_i(lookup_valid), .lookup_addr_i(lookup_addr),
    .lookup_select_i(lookup_select),
    .lookup_hit_o(lookup_hit), .lookup_data_o(lookup_data),
    .lookup_pmp_allow_o(lookup_pmp_allow),
    .fill_valid_i(fill_valid), .fill_addr_i(fill_addr),
    .fill_data_i(fill_data), .fill_pmp_allow_i(fill_pmp_allow)
  );

  task automatic write_block(
    input logic [31:0] address,
    input logic [FETCH_BYTES*8-1:0] data,
    input logic [FETCH_BYTES/2-1:0] pmp_allow
  );
    @(negedge clk);
    fill_valid = 1'b1;
    fill_addr = address;
    fill_data = data;
    fill_pmp_allow = pmp_allow;
    @(posedge clk);
    #1;
    fill_valid = 1'b0;
  endtask

  task automatic expect_lookup(
    input logic [31:0] address,
    input logic expected_hit,
    input logic [FETCH_BYTES*8-1:0] expected_data,
    input logic [FETCH_BYTES/2-1:0] expected_pmp_allow
  );
    @(negedge clk);
    lookup_valid[0] = 1'b1;
    lookup_addr[0] = address;
    lookup_select = 1'b0;
    #1;
    if (lookup_hit != expected_hit)
      $fatal(1, "Target-buffer hit mismatch at %h", address);
    if (expected_hit && (lookup_data != expected_data))
      $fatal(1, "Target-buffer data mismatch at %h", address);
    if (expected_hit && (lookup_pmp_allow != expected_pmp_allow))
      $fatal(1, "Target-buffer PMP mask mismatch at %h", address);
    lookup_valid[0] = 1'b0;
  endtask

  initial begin : p_target_buffer_test
    logic [FETCH_BYTES*8-1:0] block_a, block_b;
    block_a = 128'h0011_2233_4455_6677_8899_aabb_ccdd_eeff;
    block_b = 128'hfedc_ba98_7654_3210_0123_4567_89ab_cdef;
    clk = 1'b0;
    rst_n = 1'b0;
    invalidate = 1'b0;
    lookup_valid = 1'b0;
    lookup_addr = '0;
    lookup_select = 1'b0;
    fill_valid = 1'b0;
    fill_addr = '0;
    fill_data = '0;
    fill_pmp_allow = '0;
    repeat (2) @(posedge clk);
    @(negedge clk);
    rst_n = 1'b1;

    expect_lookup(32'h8000_0100, 1'b0, '0, '0);
    write_block(32'h8000_0100, block_a, 8'hf3);
    expect_lookup(32'h8000_0100, 1'b1, block_a, 8'hf3);

    // Four-entry direct mapping: +64 bytes aliases the same index.
    write_block(32'h8000_0140, block_b, 8'h5a);
    expect_lookup(32'h8000_0100, 1'b0, '0, '0);
    expect_lookup(32'h8000_0140, 1'b1, block_b, 8'h5a);

    // Both candidate addresses are available together; direction selection
    // chooses exactly one wide data/PMP-mask read.
    write_block(32'h8000_0120, block_a, 8'ha5);
    @(negedge clk);
    lookup_valid = 2'b11;
    lookup_addr[0] = 32'h8000_0140;
    lookup_addr[1] = 32'h8000_0120;
    lookup_select = 1'b0;
    #1;
    if (!lookup_hit || (lookup_data != block_b) ||
        (lookup_pmp_allow != 8'h5a))
      $fatal(1, "Lane-zero target-buffer lookup mismatch");
    lookup_select = 1'b1;
    #1;
    if (!lookup_hit || (lookup_data != block_a) ||
        (lookup_pmp_allow != 8'ha5))
      $fatal(1, "Lane-one target-buffer lookup mismatch");
    lookup_valid = '0;

    @(negedge clk);
    invalidate = 1'b1;
    @(posedge clk);
    #1;
    invalidate = 1'b0;
    expect_lookup(32'h8000_0140, 1'b0, '0, '0);

    $display("rv_fetch_target_buffer_tb PASS");
    $finish;
  end
endmodule
