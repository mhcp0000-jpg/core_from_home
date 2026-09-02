module rv_fetch_target_buffer_tb;
  localparam int unsigned FETCH_BYTES = 16;

  logic clk;
  logic rst_n;
  logic invalidate;
  logic lookup_valid;
  logic [31:0] lookup_addr;
  logic lookup_hit;
  logic [FETCH_BYTES*8-1:0] lookup_data;
  logic fill_valid;
  logic [31:0] fill_addr;
  logic [FETCH_BYTES*8-1:0] fill_data;

  always #5 clk = ~clk;

  rv_fetch_target_buffer #(
    .PADDR_WIDTH(32), .FETCH_BYTES(FETCH_BYTES), .ENTRIES(4)
  ) u_dut (
    .clk_i(clk), .rst_ni(rst_n), .invalidate_i(invalidate),
    .lookup_valid_i(lookup_valid), .lookup_addr_i(lookup_addr),
    .lookup_hit_o(lookup_hit), .lookup_data_o(lookup_data),
    .fill_valid_i(fill_valid), .fill_addr_i(fill_addr),
    .fill_data_i(fill_data)
  );

  task automatic write_block(
    input logic [31:0] address,
    input logic [FETCH_BYTES*8-1:0] data
  );
    @(negedge clk);
    fill_valid = 1'b1;
    fill_addr = address;
    fill_data = data;
    @(posedge clk);
    #1;
    fill_valid = 1'b0;
  endtask

  task automatic expect_lookup(
    input logic [31:0] address,
    input logic expected_hit,
    input logic [FETCH_BYTES*8-1:0] expected_data
  );
    @(negedge clk);
    lookup_valid = 1'b1;
    lookup_addr = address;
    #1;
    if (lookup_hit != expected_hit)
      $fatal(1, "Target-buffer hit mismatch at %h", address);
    if (expected_hit && (lookup_data != expected_data))
      $fatal(1, "Target-buffer data mismatch at %h", address);
    lookup_valid = 1'b0;
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
    fill_valid = 1'b0;
    fill_addr = '0;
    fill_data = '0;
    repeat (2) @(posedge clk);
    @(negedge clk);
    rst_n = 1'b1;

    expect_lookup(32'h8000_0100, 1'b0, '0);
    write_block(32'h8000_0100, block_a);
    expect_lookup(32'h8000_0100, 1'b1, block_a);

    // Four-entry direct mapping: +64 bytes aliases the same index.
    write_block(32'h8000_0140, block_b);
    expect_lookup(32'h8000_0100, 1'b0, '0);
    expect_lookup(32'h8000_0140, 1'b1, block_b);

    @(negedge clk);
    invalidate = 1'b1;
    @(posedge clk);
    #1;
    invalidate = 1'b0;
    expect_lookup(32'h8000_0140, 1'b0, '0);

    $display("rv_fetch_target_buffer_tb PASS");
    $finish;
  end
endmodule
