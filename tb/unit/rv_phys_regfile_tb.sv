module rv_phys_regfile_tb;
  localparam int unsigned TAG_WIDTH = 7;

  logic clk;
  logic rst_n;
  logic [3:0][TAG_WIDTH-1:0] read_addr;
  logic [3:0][31:0] read_data;
  logic [3:0] read_ready;
  logic [1:0] write_valid;
  logic [1:0][TAG_WIDTH-1:0] write_addr;
  logic [1:0][31:0] write_data;
  logic [1:0] allocate_valid;
  logic [1:0][TAG_WIDTH-1:0] allocate_addr;
  logic [TAG_WIDTH-1:0] probe_addr;
  logic probe_ready;

  always #5 clk = ~clk;

  rv_phys_regfile #(
    .DATA_WIDTH    (32),
    .PHYS_REGS     (80),
    .TAG_WIDTH     (TAG_WIDTH),
    .ZERO_REGISTER (1'b1)
  ) u_dut (
    .clk_i            (clk),
    .rst_ni          (rst_n),
    .read_addr_i     (read_addr),
    .read_data_o     (read_data),
    .read_ready_o    (read_ready),
    .write_valid_i   (write_valid),
    .write_addr_i    (write_addr),
    .write_data_i    (write_data),
    .allocate_valid_i(allocate_valid),
    .allocate_addr_i (allocate_addr),
    .probe_addr_i    (probe_addr),
    .probe_ready_o   (probe_ready)
  );

  task automatic clear_inputs;
    read_addr      = '0;
    write_valid    = '0;
    write_addr     = '0;
    write_data     = '0;
    allocate_valid = '0;
    allocate_addr  = '0;
    probe_addr     = '0;
  endtask

  initial begin : p_prf_test
    clk   = 1'b0;
    rst_n = 1'b0;
    clear_inputs();
    repeat (3) @(posedge clk);
    @(negedge clk);
    rst_n = 1'b1;
    read_addr[0] = 0;
    read_addr[1] = 1;
    read_addr[2] = 31;
    read_addr[3] = 32;
    #1;
    if ((read_ready != 4'b0111) || (read_data[0] != 0))
      $fatal(1, "PRF reset readiness or x0 value is wrong");

    allocate_valid[0] = 1'b1;
    allocate_addr[0]  = 7'd32;
    @(posedge clk);
    @(negedge clk);
    clear_inputs();
    read_addr[0] = 7'd32;
    probe_addr   = 7'd32;
    #1;
    if (read_ready[0] || probe_ready)
      $fatal(1, "Newly allocated physical tag was not cleared");

    // Writeback is forwarded combinationally before the state update.
    write_valid[0] = 1'b1;
    write_addr[0]  = 7'd32;
    write_data[0]  = 32'h1234_5678;
    #1;
    if (!read_ready[0] || (read_data[0] != 32'h1234_5678) || !probe_ready)
      $fatal(1, "PRF same-cycle writeback forwarding failed");
    @(posedge clk);
    @(negedge clk);
    clear_inputs();
    read_addr[0] = 7'd32;
    #1;
    if (!read_ready[0] || (read_data[0] != 32'h1234_5678))
      $fatal(1, "PRF writeback did not persist");

    // Allocation has generation priority over a same-cycle stale writeback.
    read_addr[0]      = 7'd33;
    probe_addr        = 7'd33;
    write_valid[0]    = 1'b1;
    write_addr[0]     = 7'd33;
    write_data[0]     = 32'hdead_beef;
    allocate_valid[0] = 1'b1;
    allocate_addr[0]  = 7'd33;
    #1;
    if (read_ready[0] || probe_ready)
      $fatal(1, "Stale writeback overrode a new physical-tag allocation");
    @(posedge clk);
    @(negedge clk);
    clear_inputs();
    read_addr[0] = 7'd33;
    #1;
    if (read_ready[0])
      $fatal(1, "Allocation priority was not retained after the clock");

    // Integer physical tag0 remains hardwired even under a write attempt.
    write_valid[0] = 1'b1;
    write_addr[0]  = 0;
    write_data[0]  = 32'hffff_ffff;
    read_addr[0]   = 0;
    #1;
    if (!read_ready[0] || (read_data[0] != 0))
      $fatal(1, "Integer x0 physical tag was modified");

    $display("rv_phys_regfile_tb PASS");
    $finish;
  end
endmodule
