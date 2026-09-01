module rv_i_fabric_tb;

  import rv_soc_pkg::*;

  logic clk;
  logic rst_n;
  logic if_req_valid;
  logic if_req_ready;
  logic [31:0] if_req_addr;
  logic [3:0] if_req_id;
  logic [3:0] if_req_epoch;
  logic if_rsp_valid;
  logic [3:0] if_rsp_id;
  logic [3:0] if_rsp_epoch;
  logic [127:0] if_rsp_data;
  logic [1:0] if_rsp_resp;

  logic x_req_valid;
  logic [5:0] x_req_id;
  logic [31:0] x_req_addr;
  logic x_req_write;
  logic [2:0] x_req_size;
  logic [63:0] x_req_wdata;
  logic [7:0] x_req_wstrb;
  logic x_req_committed;

  logic outbound_rsp_valid_q;
  logic [5:0] outbound_rsp_id_q;
  logic [63:0] outbound_rsp_data_q;
  int unsigned outbound_request_count;

  rv_local_mem_if xbar_in_bus (.clk_i(clk), .rst_ni(rst_n));
  rv_local_mem_if outbound_bus (.clk_i(clk), .rst_ni(rst_n));

  always #5 clk = ~clk;

  always_comb begin
    xbar_in_bus.req_valid     = x_req_valid;
    xbar_in_bus.req_id        = x_req_id;
    xbar_in_bus.req_addr      = x_req_addr;
    xbar_in_bus.req_write     = x_req_write;
    xbar_in_bus.req_size      = x_req_size;
    xbar_in_bus.req_wdata     = x_req_wdata;
    xbar_in_bus.req_wstrb     = x_req_wstrb;
    xbar_in_bus.req_priv      = PRIV_M;
    xbar_in_bus.req_rob_seq   = '0;
    xbar_in_bus.req_committed = x_req_committed;
    xbar_in_bus.req_device    = 1'b0;
    xbar_in_bus.rsp_ready     = 1'b1;

    outbound_bus.req_ready  = !outbound_rsp_valid_q;
    outbound_bus.rsp_valid  = outbound_rsp_valid_q;
    outbound_bus.rsp_id     = outbound_rsp_id_q;
    outbound_bus.rsp_rdata  = outbound_rsp_data_q;
    outbound_bus.rsp_resp   = AXI_RESP_OKAY;
    outbound_bus.rsp_replay = MEM_REPLAY_NONE;
  end

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      outbound_rsp_valid_q  <= 1'b0;
      outbound_rsp_id_q     <= '0;
      outbound_rsp_data_q   <= '0;
      outbound_request_count <= 0;
    end else begin
      if (outbound_rsp_valid_q && outbound_bus.rsp_ready)
        outbound_rsp_valid_q <= 1'b0;
      if (outbound_bus.req_valid && outbound_bus.req_ready) begin
        outbound_rsp_valid_q <= 1'b1;
        outbound_rsp_id_q    <= outbound_bus.req_id;
        outbound_rsp_data_q  <= {32'hfeed_cafe, outbound_bus.req_addr};
        outbound_request_count <= outbound_request_count + 1;
      end
    end
  end

  rv_i_fabric #(
    .BOOTROM_INIT_FILE ("tb/fixtures/bootrom/bootrom_test.hex")
  ) u_dut (
    .clk_i          (clk),
    .rst_ni         (rst_n),
    .if_req_valid_i (if_req_valid),
    .if_req_ready_o (if_req_ready),
    .if_req_addr_i  (if_req_addr),
    .if_req_id_i    (if_req_id),
    .if_req_epoch_i (if_req_epoch),
    .if_rsp_valid_o (if_rsp_valid),
    .if_rsp_ready_i (1'b1),
    .if_rsp_id_o    (if_rsp_id),
    .if_rsp_epoch_o (if_rsp_epoch),
    .if_rsp_data_o  (if_rsp_data),
    .if_rsp_resp_o  (if_rsp_resp),
    .xbar_in_bus,
    .outbound_bus
  );

  task automatic xbar_transfer(
    input logic [5:0] id,
    input logic [31:0] address,
    input logic write_request,
    input logic [63:0] write_data,
    output logic [63:0] response_data,
    output logic [1:0] response_code
  );
    @(negedge clk);
    x_req_valid     = 1'b1;
    x_req_id        = id;
    x_req_addr      = address;
    x_req_write     = write_request;
    x_req_size      = 3'd3;
    x_req_wdata     = write_data;
    x_req_wstrb     = 8'hff;
    x_req_committed = write_request;
    do @(posedge clk); while (!xbar_in_bus.req_ready);
    @(negedge clk);
    x_req_valid = 1'b0;
    while (!xbar_in_bus.rsp_valid) @(negedge clk);
    response_data = xbar_in_bus.rsp_rdata;
    response_code = xbar_in_bus.rsp_resp;
  endtask

  task automatic fetch_block(
    input logic [31:0] address,
    input logic [3:0] id,
    input logic [3:0] epoch,
    output logic [127:0] response_data,
    output logic [1:0] response_code
  );
    @(negedge clk);
    if_req_valid = 1'b1;
    if_req_addr  = address;
    if_req_id    = id;
    if_req_epoch = epoch;
    do @(posedge clk); while (!if_req_ready);
    @(negedge clk);
    if_req_valid = 1'b0;
    while (!if_rsp_valid) @(negedge clk);
    response_data = if_rsp_data;
    response_code = if_rsp_resp;
    if ((if_rsp_id != id) || (if_rsp_epoch != epoch))
      $fatal(1, "IFU response metadata mismatch");
  endtask

  logic [63:0] x_response_data;
  logic [1:0] x_response_code;
  logic [127:0] fetch_response_data;
  logic [1:0] fetch_response_code;
  int unsigned outbound_count_before;

  initial begin : p_directed_test
    clk             = 1'b0;
    rst_n           = 1'b0;
    if_req_valid    = 1'b0;
    if_req_addr     = '0;
    if_req_id       = '0;
    if_req_epoch    = '0;
    x_req_valid     = 1'b0;
    x_req_id        = '0;
    x_req_addr      = '0;
    x_req_write     = 1'b0;
    x_req_size      = 3'd3;
    x_req_wdata     = '0;
    x_req_wstrb     = '0;
    x_req_committed = 1'b0;

    repeat (3) @(posedge clk);
    @(negedge clk);
    rst_n = 1'b1;

    xbar_transfer(6'h01, ITIM_BASE_ADDR, 1'b1,
                  64'h0123_4567_89ab_cdef,
                  x_response_data, x_response_code);
    xbar_transfer(6'h02, ITIM_BASE_ADDR + 8, 1'b1,
                  64'hfedc_ba98_7654_3210,
                  x_response_data, x_response_code);

    fetch_block(ITIM_BASE_ADDR, 4'h3, 4'h7,
                fetch_response_data, fetch_response_code);
    if ((fetch_response_code != AXI_RESP_OKAY) ||
        (fetch_response_data !=
         128'hfedc_ba98_7654_3210_0123_4567_89ab_cdef))
      $fatal(1, "local ITIM 128-bit bank assembly failed");

    // A host write may use the independent write port during a fetch. The
    // same-row bank0 value is explicitly write-first.
    @(negedge clk);
    if_req_valid    = 1'b1;
    if_req_addr     = ITIM_BASE_ADDR;
    if_req_id       = 4'h4;
    if_req_epoch    = 4'h8;
    x_req_valid     = 1'b1;
    x_req_id        = 6'h04;
    x_req_addr      = ITIM_BASE_ADDR;
    x_req_write     = 1'b1;
    x_req_size      = 3'd3;
    x_req_wdata     = 64'h1111_2222_3333_4444;
    x_req_wstrb     = 8'hff;
    x_req_committed = 1'b1;
    @(posedge clk);
    @(negedge clk);
    if_req_valid = 1'b0;
    x_req_valid  = 1'b0;
    if (!if_rsp_valid ||
        (if_rsp_data[63:0] != 64'h1111_2222_3333_4444))
      $fatal(1, "ITIM same-row read/write bypass failed");

    outbound_count_before = outbound_request_count;
    fetch_block(BOOTROM_BASE_ADDR, 4'h5, 4'h9,
                fetch_response_data, fetch_response_code);
    if ((fetch_response_code != AXI_RESP_OKAY) ||
        (fetch_response_data !=
         128'hfedc_ba98_7654_3210_0123_4567_89ab_cdef) ||
        (outbound_request_count != outbound_count_before))
      $fatal(1, "Boot ROM fetch did not stay on I-local path");

    xbar_transfer(6'h05, BOOTROM_BASE_ADDR, 1'b0, '0,
                  x_response_data, x_response_code);
    if ((x_response_code != AXI_RESP_OKAY) ||
        (x_response_data != 64'h0123_4567_89ab_cdef))
      $fatal(1, "I-Fabric inbound Boot ROM read failed");

    xbar_transfer(6'h06, BOOTROM_BASE_ADDR, 1'b1,
                  64'hffff_ffff_ffff_ffff,
                  x_response_data, x_response_code);
    if (x_response_code == AXI_RESP_OKAY)
      $fatal(1, "I-Fabric allowed an inbound Boot ROM write");

    fetch_block(PLIC_BASE_ADDR, 4'h7, 4'hb,
                fetch_response_data, fetch_response_code);
    if ((fetch_response_code != AXI_RESP_OKAY) ||
        (fetch_response_data[63:0] !=
         {32'hfeed_cafe, PLIC_BASE_ADDR}) ||
        (fetch_response_data[127:64] !=
         {32'hfeed_cafe, PLIC_BASE_ADDR + 8}))
      $fatal(1, "non-local two-beat fetch assembly failed");

    fetch_block(ITIM_BASE_ADDR + 4, 4'h6, 4'ha,
                fetch_response_data, fetch_response_code);
    if (fetch_response_code == AXI_RESP_OKAY)
      $fatal(1, "misaligned IFU block request was not rejected");

    outbound_count_before = outbound_request_count;
    xbar_transfer(6'h08, DTIM_BASE_ADDR, 1'b0, '0,
                  x_response_data, x_response_code);
    if ((x_response_code == AXI_RESP_OKAY) ||
        (outbound_request_count != outbound_count_before))
      $fatal(1, "I-Fabric inbound non-local request looped outbound");

    $display("rv_i_fabric_tb PASS");
    $finish;
  end

endmodule
