module rv_clint_tb;
  import rv_soc_pkg::*;

  logic clk, rst_n;
  logic msip, mtip;
  logic [63:0] mtime;
  logic req_valid;
  logic [5:0] req_id;
  logic [31:0] req_addr;
  logic req_write;
  logic [2:0] req_size;
  logic [63:0] req_wdata;
  logic [7:0] req_wstrb;

  rv_local_mem_if bus (.clk_i(clk), .rst_ni(rst_n));
  always #5 clk = ~clk;

  always_comb begin
    bus.req_valid = req_valid;
    bus.req_id = req_id;
    bus.req_addr = req_addr;
    bus.req_write = req_write;
    bus.req_size = req_size;
    bus.req_wdata = req_wdata;
    bus.req_wstrb = req_wstrb;
    bus.req_priv = PRIV_M;
    bus.req_rob_seq = '0;
    bus.req_committed = req_write;
    bus.req_device = 1'b1;
    bus.rsp_ready = 1'b1;
  end

  rv_clint #(
    .CLOCK_HZ(4), .TIMEBASE_HZ(1)
  ) u_dut (
    .clk_i(clk), .rst_ni(rst_n), .bus(bus), .msip_o(msip),
    .mtip_o(mtip), .mtime_o(mtime)
  );

  task automatic transfer(
    input logic [31:0] address,
    input logic write_request,
    input logic [31:0] write_data,
    input logic [2:0] size,
    output logic [31:0] read_data,
    output logic [1:0] response
  );
    int unsigned lane;
    @(negedge clk);
    lane = address[2] ? 4 : 0;
    req_valid = 1'b1;
    req_id = req_id + 1'b1;
    req_addr = address;
    req_write = write_request;
    req_size = size;
    req_wdata = '0;
    req_wstrb = '0;
    req_wdata[lane*8 +: 32] = write_data;
    req_wstrb[lane +: 4] = 4'hf;
    do @(posedge clk); while (!bus.req_ready);
    @(negedge clk);
    req_valid = 1'b0;
    do @(posedge clk); while (!bus.rsp_valid);
    read_data = bus.rsp_rdata[lane*8 +: 32];
    response = bus.rsp_resp;
  endtask

  task automatic write_word(input logic [31:0] address,
                            input logic [31:0] data);
    logic [31:0] ignored;
    logic [1:0] response;
    transfer(address, 1'b1, data, 3'd2, ignored, response);
    if (response != AXI_RESP_OKAY)
      $fatal(1, "CLINT write failed address=%h response=%0d", address, response);
  endtask

  initial begin
    logic [63:0] start_time, compare_time;
    logic [31:0] data;
    logic [1:0] response;
    int unsigned wait_cycles;
    clk = 1'b0;
    rst_n = 1'b0;
    req_valid = 1'b0;
    req_id = '0;
    req_addr = '0;
    req_write = 1'b0;
    req_size = 3'd2;
    req_wdata = '0;
    req_wstrb = '0;
    repeat (3) @(posedge clk);
    @(negedge clk);
    rst_n = 1'b1;

    start_time = mtime;
    repeat (9) @(posedge clk);
    if (mtime <= start_time)
      $fatal(1, "CLINT mtime did not advance at the programmed timebase");

    write_word(CLINT_BASE_ADDR + CLINT_MSIP_OFFSET, 1);
    if (!msip)
      $fatal(1, "CLINT MSIP set failed");
    write_word(CLINT_BASE_ADDR + CLINT_MSIP_OFFSET, 0);
    if (msip)
      $fatal(1, "CLINT MSIP clear failed");

    compare_time = mtime + 64'd8;
    write_word(CLINT_BASE_ADDR + CLINT_MTIMECMP_HI_OFF,
               compare_time[63:32]);
    write_word(CLINT_BASE_ADDR + CLINT_MTIMECMP_LO_OFF,
               compare_time[31:0]);
    if (mtip)
      $fatal(1, "CLINT MTIP asserted before mtimecmp");
    wait_cycles = 0;
    while (!mtip && (wait_cycles < 64)) begin
      @(posedge clk);
      wait_cycles++;
    end
    if (!mtip || (mtime < compare_time))
      $fatal(1, "CLINT timer interrupt did not assert at mtimecmp");

    transfer(CLINT_BASE_ADDR + CLINT_MTIME_LO_OFF, 1'b0, '0,
             3'd2, data, response);
    if ((response != AXI_RESP_OKAY) || (data > mtime[31:0]))
      $fatal(1, "CLINT mtime read failed");
    transfer(CLINT_BASE_ADDR + 32'h0000_0100, 1'b0, '0,
             3'd2, data, response);
    if (response != AXI_RESP_SLVERR)
      $fatal(1, "CLINT unmapped register error path failed");
    transfer(CLINT_BASE_ADDR + CLINT_MSIP_OFFSET, 1'b0, '0,
             3'd3, data, response);
    if (response != AXI_RESP_SLVERR)
      $fatal(1, "CLINT access-size error path failed");

    $display("rv_clint_tb PASS");
    $finish;
  end
endmodule
