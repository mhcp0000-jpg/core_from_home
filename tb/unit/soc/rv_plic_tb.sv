module rv_plic_tb;
  import rv_soc_pkg::*;

  localparam int unsigned NUM_SOURCES = 8;

  logic clk, rst_n;
  logic [NUM_SOURCES-1:1] source;
  logic meip, seip;
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

  rv_plic_local #(
    .NUM_SOURCES(NUM_SOURCES), .PRIORITY_WIDTH(3), .HAS_SMODE(1'b1)
  ) u_dut (
    .clk_i(clk), .rst_ni(rst_n), .bus(bus), .source_i(source),
    .meip_o(meip), .seip_o(seip)
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
      $fatal(1, "PLIC write failed address=%h response=%0d", address, response);
  endtask

  task automatic read_word(input logic [31:0] address,
                           output logic [31:0] data);
    logic [1:0] response;
    transfer(address, 1'b0, '0, 3'd2, data, response);
    if (response != AXI_RESP_OKAY)
      $fatal(1, "PLIC read failed address=%h response=%0d", address, response);
  endtask

  initial begin
    logic [31:0] data;
    logic [1:0] response;
    clk = 1'b0;
    rst_n = 1'b0;
    source = '0;
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

    write_word(PLIC_BASE_ADDR + 32'h000004, 2); // source 1
    write_word(PLIC_BASE_ADDR + 32'h000008, 5); // source 2
    write_word(PLIC_BASE_ADDR + 32'h00000c, 5); // source 3
    write_word(PLIC_BASE_ADDR + PLIC_M_ENABLE_OFFSET, 32'h0000_000e);

    @(negedge clk);
    source[1] = 1'b1;
    source[2] = 1'b1;
    source[3] = 1'b1;
    @(posedge clk);
    @(negedge clk);
    source = '0;
    #1;
    if (!meip)
      $fatal(1, "PLIC failed to assert MEIP for enabled pending sources");
    read_word(PLIC_BASE_ADDR + PLIC_PENDING_OFFSET, data);
    if ((data & 32'h0000_000e) != 32'h0000_000e)
      $fatal(1, "PLIC pending bits mismatch: %h", data);

    read_word(PLIC_BASE_ADDR + PLIC_M_CLAIM_OFF, data);
    if (data != 2)
      $fatal(1, "PLIC did not choose lower ID among equal priorities: %0d", data);
    read_word(PLIC_BASE_ADDR + PLIC_M_CLAIM_OFF, data);
    if (data != 3)
      $fatal(1, "PLIC second priority claim mismatch: %0d", data);
    read_word(PLIC_BASE_ADDR + PLIC_M_CLAIM_OFF, data);
    if (data != 1)
      $fatal(1, "PLIC final claim mismatch: %0d", data);
    #1;
    if (meip)
      $fatal(1, "PLIC MEIP remained asserted after all claims");
    write_word(PLIC_BASE_ADDR + PLIC_M_CLAIM_OFF, 2);
    write_word(PLIC_BASE_ADDR + PLIC_M_CLAIM_OFF, 3);
    write_word(PLIC_BASE_ADDR + PLIC_M_CLAIM_OFF, 1);

    // Priority equal to the threshold is not eligible.
    write_word(PLIC_BASE_ADDR + PLIC_M_THRESHOLD_OFF, 2);
    @(negedge clk);
    source[1] = 1'b1;
    @(posedge clk);
    @(negedge clk);
    source[1] = 1'b0;
    #1;
    if (meip)
      $fatal(1, "PLIC threshold comparison must be strict greater-than");
    write_word(PLIC_BASE_ADDR + PLIC_M_THRESHOLD_OFF, 1);
    #1;
    if (!meip)
      $fatal(1, "PLIC threshold lowering did not expose pending source");
    read_word(PLIC_BASE_ADDR + PLIC_M_CLAIM_OFF, data);
    if (data != 1)
      $fatal(1, "PLIC threshold claim mismatch");
    write_word(PLIC_BASE_ADDR + PLIC_M_CLAIM_OFF, 1);

    // Exercise the optional S-context independently of M enable state.
    write_word(PLIC_BASE_ADDR + 32'h000010, 6); // source 4
    write_word(PLIC_BASE_ADDR + PLIC_S_ENABLE_OFFSET, 32'h0000_0010);
    @(negedge clk);
    source[4] = 1'b1;
    @(posedge clk);
    @(negedge clk);
    source[4] = 1'b0;
    #1;
    if (!seip || meip)
      $fatal(1, "PLIC S-context routing failed");
    read_word(PLIC_BASE_ADDR + PLIC_S_CLAIM_OFF, data);
    if (data != 4)
      $fatal(1, "PLIC S-context claim mismatch: %0d", data);
    write_word(PLIC_BASE_ADDR + PLIC_S_CLAIM_OFF, 4);

    transfer(PLIC_BASE_ADDR + PLIC_PENDING_OFFSET, 1'b1, 32'hffff_ffff,
             3'd2, data, response);
    if (response != AXI_RESP_SLVERR)
      $fatal(1, "PLIC writable-pending error path failed");
    transfer(PLIC_BASE_ADDR + PLIC_M_THRESHOLD_OFF, 1'b0, '0,
             3'd3, data, response);
    if (response != AXI_RESP_SLVERR)
      $fatal(1, "PLIC access-size error path failed");

    $display("rv_plic_tb PASS");
    $finish;
  end
endmodule
