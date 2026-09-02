module rv_d_fabric_tb;

  import rv_soc_pkg::*;

  localparam int unsigned MASTER_COUNT = 3;

  logic clk;
  logic rst_n;
  logic [MASTER_COUNT-1:0] t_req_valid;
  logic [MASTER_COUNT-1:0] t_req_ready;
  logic [MASTER_COUNT-1:0][5:0] t_req_id;
  logic [MASTER_COUNT-1:0][31:0] t_req_addr;
  logic [MASTER_COUNT-1:0] t_req_write;
  logic [MASTER_COUNT-1:0][2:0] t_req_size;
  logic [MASTER_COUNT-1:0][63:0] t_req_wdata;
  logic [MASTER_COUNT-1:0][7:0] t_req_wstrb;
  logic [MASTER_COUNT-1:0][1:0] t_req_priv;
  logic [MASTER_COUNT-1:0][7:0] t_req_rob_seq;
  logic [MASTER_COUNT-1:0] t_req_committed;
  logic [MASTER_COUNT-1:0] t_req_device;
  logic [MASTER_COUNT-1:0] t_rsp_valid;
  logic [MASTER_COUNT-1:0][5:0] t_rsp_id;
  logic [MASTER_COUNT-1:0][63:0] t_rsp_data;
  logic [MASTER_COUNT-1:0][1:0] t_rsp_resp;
  logic [MASTER_COUNT-1:0][2:0] t_rsp_replay;
  logic msip;
  logic mtip;
  logic [63:0] mtime;

  logic outbound_rsp_valid_q;
  logic [5:0] outbound_rsp_id_q;
  logic [63:0] outbound_rsp_data_q;

  rv_local_mem_if lsu0_bus (.clk_i(clk), .rst_ni(rst_n));
  rv_local_mem_if lsu1_bus (.clk_i(clk), .rst_ni(rst_n));
  rv_local_mem_if xbar_in_bus (.clk_i(clk), .rst_ni(rst_n));
  rv_local_mem_if outbound_bus (.clk_i(clk), .rst_ni(rst_n));

  always #5 clk = ~clk;

  always_comb begin
    lsu0_bus.req_valid     = t_req_valid[0];
    lsu0_bus.req_id        = t_req_id[0];
    lsu0_bus.req_addr      = t_req_addr[0];
    lsu0_bus.req_write     = t_req_write[0];
    lsu0_bus.req_size      = t_req_size[0];
    lsu0_bus.req_wdata     = t_req_wdata[0];
    lsu0_bus.req_wstrb     = t_req_wstrb[0];
    lsu0_bus.req_priv      = privilege_e'(t_req_priv[0]);
    lsu0_bus.req_rob_seq   = t_req_rob_seq[0];
    lsu0_bus.req_committed = t_req_committed[0];
    lsu0_bus.req_device    = t_req_device[0];
    lsu0_bus.rsp_ready     = 1'b1;
    t_req_ready[0]         = lsu0_bus.req_ready;
    t_rsp_valid[0]         = lsu0_bus.rsp_valid;
    t_rsp_id[0]            = lsu0_bus.rsp_id;
    t_rsp_data[0]          = lsu0_bus.rsp_rdata;
    t_rsp_resp[0]          = lsu0_bus.rsp_resp;
    t_rsp_replay[0]        = lsu0_bus.rsp_replay;

    lsu1_bus.req_valid     = t_req_valid[1];
    lsu1_bus.req_id        = t_req_id[1];
    lsu1_bus.req_addr      = t_req_addr[1];
    lsu1_bus.req_write     = t_req_write[1];
    lsu1_bus.req_size      = t_req_size[1];
    lsu1_bus.req_wdata     = t_req_wdata[1];
    lsu1_bus.req_wstrb     = t_req_wstrb[1];
    lsu1_bus.req_priv      = privilege_e'(t_req_priv[1]);
    lsu1_bus.req_rob_seq   = t_req_rob_seq[1];
    lsu1_bus.req_committed = t_req_committed[1];
    lsu1_bus.req_device    = t_req_device[1];
    lsu1_bus.rsp_ready     = 1'b1;
    t_req_ready[1]         = lsu1_bus.req_ready;
    t_rsp_valid[1]         = lsu1_bus.rsp_valid;
    t_rsp_id[1]            = lsu1_bus.rsp_id;
    t_rsp_data[1]          = lsu1_bus.rsp_rdata;
    t_rsp_resp[1]          = lsu1_bus.rsp_resp;
    t_rsp_replay[1]        = lsu1_bus.rsp_replay;

    xbar_in_bus.req_valid     = t_req_valid[2];
    xbar_in_bus.req_id        = t_req_id[2];
    xbar_in_bus.req_addr      = t_req_addr[2];
    xbar_in_bus.req_write     = t_req_write[2];
    xbar_in_bus.req_size      = t_req_size[2];
    xbar_in_bus.req_wdata     = t_req_wdata[2];
    xbar_in_bus.req_wstrb     = t_req_wstrb[2];
    xbar_in_bus.req_priv      = privilege_e'(t_req_priv[2]);
    xbar_in_bus.req_rob_seq   = t_req_rob_seq[2];
    xbar_in_bus.req_committed = t_req_committed[2];
    xbar_in_bus.req_device    = t_req_device[2];
    xbar_in_bus.rsp_ready     = 1'b1;
    t_req_ready[2]            = xbar_in_bus.req_ready;
    t_rsp_valid[2]            = xbar_in_bus.rsp_valid;
    t_rsp_id[2]               = xbar_in_bus.rsp_id;
    t_rsp_data[2]             = xbar_in_bus.rsp_rdata;
    t_rsp_resp[2]             = xbar_in_bus.rsp_resp;
    t_rsp_replay[2]           = xbar_in_bus.rsp_replay;

    outbound_bus.req_ready  = !outbound_rsp_valid_q;
    outbound_bus.rsp_valid  = outbound_rsp_valid_q;
    outbound_bus.rsp_id     = outbound_rsp_id_q;
    outbound_bus.rsp_rdata  = outbound_rsp_data_q;
    outbound_bus.rsp_resp   = AXI_RESP_OKAY;
    outbound_bus.rsp_replay = MEM_REPLAY_NONE;
  end

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      outbound_rsp_valid_q <= 1'b0;
      outbound_rsp_id_q    <= '0;
      outbound_rsp_data_q  <= '0;
    end else begin
      if (outbound_rsp_valid_q && outbound_bus.rsp_ready)
        outbound_rsp_valid_q <= 1'b0;
      if (outbound_bus.req_valid && outbound_bus.req_ready) begin
        outbound_rsp_valid_q <= 1'b1;
        outbound_rsp_id_q    <= outbound_bus.req_id;
        outbound_rsp_data_q  <= 64'hcafe_f00d_1234_5678;
      end
    end
  end

  rv_d_fabric #(
    .CLOCK_HZ    (100_000_000),
    .TIMEBASE_HZ (10_000_000)
  ) u_dut (
    .clk_i          (clk),
    .rst_ni         (rst_n),
    .lsu0_bus,
    .lsu1_bus,
    .xbar_in_bus,
    .outbound_bus,
    .msip_o         (msip),
    .mtip_o         (mtip),
    .mtime_o        (mtime)
  );

  task automatic set_request(
    input int unsigned master,
    input logic [5:0] id,
    input logic [31:0] address,
    input logic write_request,
    input logic [63:0] write_data,
    input logic [7:0] write_strobe,
    input logic [7:0] rob_sequence,
    input logic device_request
  );
    t_req_valid[master]     = 1'b1;
    t_req_id[master]        = id;
    t_req_addr[master]      = address;
    t_req_write[master]     = write_request;
    t_req_size[master]      = 3'd3;
    t_req_wdata[master]     = write_data;
    t_req_wstrb[master]     = write_strobe;
    t_req_priv[master]      = PRIV_M;
    t_req_rob_seq[master]   = rob_sequence;
    t_req_committed[master] = write_request;
    t_req_device[master]    = device_request;
  endtask

  task automatic clear_request(input int unsigned master);
    t_req_valid[master] = 1'b0;
  endtask

  task automatic single_transfer(
    input int unsigned master,
    input logic [5:0] id,
    input logic [31:0] address,
    input logic write_request,
    input logic [63:0] write_data,
    input logic [7:0] write_strobe,
    input logic [7:0] rob_sequence,
    input logic device_request,
    output logic [63:0] response_data,
    output logic [1:0] response_code
  );
    @(negedge clk);
    set_request(master, id, address, write_request, write_data, write_strobe,
                rob_sequence, device_request);
    do @(posedge clk); while (!t_req_ready[master]);
    @(negedge clk);
    clear_request(master);
    while (!t_rsp_valid[master]) @(negedge clk);
    response_data = t_rsp_data[master];
    response_code = t_rsp_resp[master];
  endtask

  logic [63:0] response_data;
  logic [1:0] response_code;

  initial begin : p_directed_test
    clk             = 1'b0;
    rst_n           = 1'b0;
    t_req_valid     = '0;
    t_req_id        = '0;
    t_req_addr      = '0;
    t_req_write     = '0;
    t_req_size      = '{default: 3'd3};
    t_req_wdata     = '0;
    t_req_wstrb     = '0;
    t_req_priv      = '{default: PRIV_M};
    t_req_rob_seq   = '0;
    t_req_committed = '0;
    t_req_device    = '0;

    repeat (3) @(posedge clk);
    @(negedge clk);
    rst_n = 1'b1;

    // Host/Xbar preload one 64-bit word in each bank.
    single_transfer(2, 6'h01, DTIM_BASE_ADDR + 32'h0, 1'b1,
                    64'h1111_2222_3333_4444, 8'hff, 8'h00, 1'b0,
                    response_data, response_code);
    if (response_code != AXI_RESP_OKAY) $fatal(1, "bank0 preload failed");
    single_transfer(2, 6'h02, DTIM_BASE_ADDR + 32'h8, 1'b1,
                    64'haaaa_bbbb_cccc_dddd, 8'hff, 8'h00, 1'b0,
                    response_data, response_code);
    if (response_code != AXI_RESP_OKAY) $fatal(1, "bank1 preload failed");

    // Different-bank dual read must be accepted together and both return.
    @(negedge clk);
    set_request(0, 6'h10, DTIM_BASE_ADDR + 32'h0, 1'b0, '0, '0,
                8'h10, 1'b0);
    set_request(1, 6'h11, DTIM_BASE_ADDR + 32'h8, 1'b0, '0, '0,
                8'h11, 1'b0);
    @(posedge clk);
    @(negedge clk);
    clear_request(0);
    clear_request(1);
    if (!(t_rsp_valid[0] && t_rsp_valid[1]))
      $fatal(1, "different-bank dual read did not complete together");
    if ((t_rsp_data[0] != 64'h1111_2222_3333_4444) ||
        (t_rsp_data[1] != 64'haaaa_bbbb_cccc_dddd))
      $fatal(1, "different-bank dual read data mismatch");

    // A requester may consume one response and accept its next request on the
    // same edge.  The response must retain the old ID/data while the following
    // cycle returns the newly accepted transaction; outstanding depth remains
    // exactly one throughout the handoff.
    @(negedge clk);
    set_request(0, 6'h12, DTIM_BASE_ADDR + 32'h0, 1'b0, '0, '0,
                8'h12, 1'b0);
    @(posedge clk);
    if (!t_req_ready[0]) $fatal(1, "first handoff request was not accepted");
    @(negedge clk);
    if (!t_rsp_valid[0] || (t_rsp_id[0] != 6'h12) ||
        (t_rsp_data[0] != 64'h1111_2222_3333_4444))
      $fatal(1, "first handoff response metadata mismatch");
    set_request(0, 6'h13, DTIM_BASE_ADDR + 32'h8, 1'b0, '0, '0,
                8'h13, 1'b0);
    #1;
    if (!t_req_ready[0])
      $fatal(1, "response/next-request same-cycle handoff was blocked");
    @(posedge clk);
    @(negedge clk);
    clear_request(0);
    if (!t_rsp_valid[0] || (t_rsp_id[0] != 6'h13) ||
        (t_rsp_data[0] != 64'haaaa_bbbb_cccc_dddd))
      $fatal(1, "second handoff response metadata mismatch");

    // Same-bank collision: sequence 0x10 is older than 0x20, so LSU1 wins.
    @(negedge clk);
    set_request(0, 6'h20, DTIM_BASE_ADDR + 32'h0, 1'b0, '0, '0,
                8'h20, 1'b0);
    set_request(1, 6'h21, DTIM_BASE_ADDR + 32'h0, 1'b0, '0, '0,
                8'h10, 1'b0);
    @(posedge clk);
    @(negedge clk);
    if (!t_rsp_valid[1] || (t_rsp_id[1] != 6'h21))
      $fatal(1, "same-bank arbitration did not select older LSU request");
    clear_request(1);
    @(posedge clk);
    @(negedge clk);
    clear_request(0);
    if (!t_rsp_valid[0] || (t_rsp_id[0] != 6'h20))
      $fatal(1, "younger same-bank request did not replay through arbiter");

    // CLINT software interrupt write uses a 32-bit access in the low bus lane.
    @(negedge clk);
    set_request(2, 6'h30, CLINT_BASE_ADDR + CLINT_MSIP_OFFSET, 1'b1,
                64'h1, 8'h0f, 8'h00, 1'b1);
    t_req_size[2] = 3'd2;
    do @(posedge clk); while (!t_req_ready[2]);
    @(negedge clk);
    clear_request(2);
    while (!t_rsp_valid[2]) @(negedge clk);
    if (!msip || (t_rsp_resp[2] != AXI_RESP_OKAY))
      $fatal(1, "CLINT msip path failed");

    // LSU non-local access goes outbound and receives the bridged response.
    single_transfer(0, 6'h31, PLIC_BASE_ADDR, 1'b0, '0, '0, 8'h30, 1'b1,
                    response_data, response_code);
    if ((response_code != AXI_RESP_OKAY) ||
        (response_data != 64'hcafe_f00d_1234_5678))
      $fatal(1, "LSU outbound path failed");

    // Xbar inbound must never loop outbound; non-local address is DECERR/SLVERR.
    single_transfer(2, 6'h32, PLIC_BASE_ADDR, 1'b0, '0, '0, 8'h00, 1'b1,
                    response_data, response_code);
    if (response_code == AXI_RESP_OKAY)
      $fatal(1, "Xbar inbound non-local request looped or succeeded");

    $display("rv_d_fabric_tb PASS");
    $finish;
  end

endmodule
