module rv_soc_peripheral_tb;
  import rv_soc_pkg::*;

  logic clk;
  logic rst_n;
  logic rom_req_valid;
  logic [5:0] rom_req_id;
  logic [31:0] rom_req_addr;
  logic rom_req_write;
  logic [63:0] rom_req_wdata;
  logic [7:0] rom_req_wstrb;

  logic host_req_valid;
  logic [5:0] host_req_id;
  logic [31:0] host_req_addr;
  logic host_req_write;
  logic [63:0] host_req_wdata;
  logic [7:0] host_req_wstrb;
  logic event_ready;
  logic [31:0] boot_entry;
  logic [31:0] boot_flags;
  logic event_valid;
  host_event_e event_kind;
  logic [31:0] event_data;

  rv_local_mem_if rom_bus (.clk_i(clk), .rst_ni(rst_n));
  rv_local_mem_if host_bus (.clk_i(clk), .rst_ni(rst_n));

  always #5 clk = ~clk;

  always_comb begin
    rom_bus.req_valid     = rom_req_valid;
    rom_bus.req_id        = rom_req_id;
    rom_bus.req_addr      = rom_req_addr;
    rom_bus.req_write     = rom_req_write;
    rom_bus.req_size      = 3'd3;
    rom_bus.req_wdata     = rom_req_wdata;
    rom_bus.req_wstrb     = rom_req_wstrb;
    rom_bus.req_priv      = PRIV_M;
    rom_bus.req_rob_seq   = '0;
    rom_bus.req_committed = rom_req_write;
    rom_bus.req_device    = 1'b0;
    rom_bus.rsp_ready     = 1'b1;

    host_bus.req_valid     = host_req_valid;
    host_bus.req_id        = host_req_id;
    host_bus.req_addr      = host_req_addr;
    host_bus.req_write     = host_req_write;
    host_bus.req_size      = 3'd2;
    host_bus.req_wdata     = host_req_wdata;
    host_bus.req_wstrb     = host_req_wstrb;
    host_bus.req_priv      = PRIV_M;
    host_bus.req_rob_seq   = '0;
    host_bus.req_committed = host_req_write;
    host_bus.req_device    = 1'b1;
    host_bus.rsp_ready     = 1'b1;
  end

  rv_bootrom_local #(
    .INIT_FILE ("tb/fixtures/bootrom/bootrom_test.hex")
  ) u_rom (
    .clk_i  (clk),
    .rst_ni (rst_n),
    .bus    (rom_bus)
  );

  rv_hostif_local u_hostif (
    .clk_i          (clk),
    .rst_ni         (rst_n),
    .bus            (host_bus),
    .boot_entry_o   (boot_entry),
    .boot_flags_o   (boot_flags),
    .event_valid_o  (event_valid),
    .event_ready_i  (event_ready),
    .event_kind_o   (event_kind),
    .event_data_o   (event_data)
  );

  task automatic rom_transfer(
    input logic [5:0] id,
    input logic [31:0] address,
    input logic write_request,
    output logic [63:0] response_data,
    output logic [1:0] response_code
  );
    @(negedge clk);
    rom_req_valid = 1'b1;
    rom_req_id    = id;
    rom_req_addr  = address;
    rom_req_write = write_request;
    rom_req_wdata = 64'hffff_ffff_ffff_ffff;
    rom_req_wstrb = 8'hff;
    do @(posedge clk); while (!rom_bus.req_ready);
    @(negedge clk);
    rom_req_valid = 1'b0;
    while (!rom_bus.rsp_valid) @(negedge clk);
    response_data = rom_bus.rsp_rdata;
    response_code = rom_bus.rsp_resp;
    if (rom_bus.rsp_id != id)
      $fatal(1, "Boot ROM response ID mismatch");
  endtask

  task automatic host_transfer(
    input logic [5:0] id,
    input logic [11:0] offset,
    input logic write_request,
    input logic [31:0] write_word,
    output logic [31:0] response_word,
    output logic [1:0] response_code
  );
    @(negedge clk);
    host_req_valid = 1'b1;
    host_req_id    = id;
    host_req_addr  = HOSTIF_BASE_ADDR + {20'b0, offset};
    host_req_write = write_request;
    if (offset[2]) begin
      host_req_wdata = {write_word, 32'b0};
      host_req_wstrb = 8'hf0;
    end else begin
      host_req_wdata = {32'b0, write_word};
      host_req_wstrb = 8'h0f;
    end
    do @(posedge clk); while (!host_bus.req_ready);
    @(negedge clk);
    host_req_valid = 1'b0;
    while (!host_bus.rsp_valid) @(negedge clk);
    response_word = offset[2] ? host_bus.rsp_rdata[63:32] :
                                host_bus.rsp_rdata[31:0];
    response_code = host_bus.rsp_resp;
    if (host_bus.rsp_id != id)
      $fatal(1, "HostIF response ID mismatch");
  endtask

  logic [63:0] rom_response_data;
  logic [31:0] host_response_word;
  logic [1:0] response_code;

  initial begin : p_directed_test
    clk             = 1'b0;
    rst_n           = 1'b0;
    rom_req_valid   = 1'b0;
    rom_req_id      = '0;
    rom_req_addr    = '0;
    rom_req_write   = 1'b0;
    rom_req_wdata   = '0;
    rom_req_wstrb   = '0;
    host_req_valid  = 1'b0;
    host_req_id     = '0;
    host_req_addr   = '0;
    host_req_write  = 1'b0;
    host_req_wdata  = '0;
    host_req_wstrb  = '0;
    event_ready     = 1'b1;

    repeat (3) @(posedge clk);
    @(negedge clk);
    rst_n = 1'b1;

    rom_transfer(6'h01, BOOTROM_BASE_ADDR, 1'b0,
                 rom_response_data, response_code);
    if ((response_code != AXI_RESP_OKAY) ||
        (rom_response_data != 64'h0123_4567_89ab_cdef))
      $fatal(1, "Boot ROM initialized read failed");
    rom_transfer(6'h02, BOOTROM_BASE_ADDR + 8, 1'b0,
                 rom_response_data, response_code);
    if (rom_response_data != 64'hfedc_ba98_7654_3210)
      $fatal(1, "Boot ROM second word mismatch");
    rom_transfer(6'h03, BOOTROM_BASE_ADDR, 1'b1,
                 rom_response_data, response_code);
    if (response_code == AXI_RESP_OKAY)
      $fatal(1, "Boot ROM write was not rejected");

    host_transfer(6'h10, HOSTIF_BOOT_ENTRY_OFF, 1'b1, 32'h8000_0100,
                  host_response_word, response_code);
    if ((response_code != AXI_RESP_OKAY) ||
        (boot_entry != 32'h8000_0100))
      $fatal(1, "HostIF BOOT_ENTRY write failed");
    host_transfer(6'h11, HOSTIF_BOOT_ENTRY_OFF, 1'b0, '0,
                  host_response_word, response_code);
    if (host_response_word != 32'h8000_0100)
      $fatal(1, "HostIF BOOT_ENTRY readback failed");

    event_ready = 1'b0;
    host_transfer(6'h12, HOSTIF_CONSOLE_TX_OFF, 1'b1, 32'h0000_0041,
                  host_response_word, response_code);
    if (!event_valid || (event_kind != HOST_EVENT_CONSOLE_TX) ||
        (event_data != 32'h0000_0041))
      $fatal(1, "HostIF console event was not retained");
    repeat (3) @(posedge clk);
    if (!event_valid || (event_data != 32'h0000_0041))
      $fatal(1, "HostIF event changed under backpressure");
    @(negedge clk);
    event_ready = 1'b1;
    @(posedge clk);
    @(negedge clk);
    if (event_valid)
      $fatal(1, "HostIF event did not clear after handshake");

    $display("rv_soc_peripheral_tb PASS");
    $finish;
  end
endmodule
