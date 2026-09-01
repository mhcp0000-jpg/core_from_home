module rv_axi_bridge_tb;
  import rv_soc_pkg::*;

  logic clk;
  logic rst_n;
  logic src_req_valid;
  logic [5:0] src_req_id;
  logic [31:0] src_req_addr;
  logic src_req_write;
  logic [2:0] src_req_size;
  logic [63:0] src_req_wdata;
  logic [7:0] src_req_wstrb;

  logic target_rsp_valid_q;
  logic [5:0] target_rsp_id_q;
  logic [63:0] target_rsp_data_q;
  logic [63:0] memory [0:15];
  int unsigned target_request_count;

  rv_local_mem_if source_bus (.clk_i(clk), .rst_ni(rst_n));
  rv_axi4_if #(.ID_WIDTH(4)) axi_link (.clk_i(clk), .rst_ni(rst_n));
  rv_local_mem_if target_bus (.clk_i(clk), .rst_ni(rst_n));

  always #5 clk = ~clk;

  function automatic logic [63:0] apply_strobe(
    input logic [63:0] old_data,
    input logic [63:0] new_data,
    input logic [7:0] strobe
  );
    logic [63:0] merged;
    merged = old_data;
    for (int unsigned byte_index = 0; byte_index < 8; byte_index++)
      if (strobe[byte_index])
        merged[byte_index*8 +: 8] = new_data[byte_index*8 +: 8];
    return merged;
  endfunction

  always_comb begin
    source_bus.req_valid     = src_req_valid;
    source_bus.req_id        = src_req_id;
    source_bus.req_addr      = src_req_addr;
    source_bus.req_write     = src_req_write;
    source_bus.req_size      = src_req_size;
    source_bus.req_wdata     = src_req_wdata;
    source_bus.req_wstrb     = src_req_wstrb;
    source_bus.req_priv      = PRIV_M;
    source_bus.req_rob_seq   = 8'h10;
    source_bus.req_committed = src_req_write;
    source_bus.req_device    = 1'b0;
    source_bus.rsp_ready     = 1'b1;

    target_bus.req_ready  = !target_rsp_valid_q || target_bus.rsp_ready;
    target_bus.rsp_valid  = target_rsp_valid_q;
    target_bus.rsp_id     = target_rsp_id_q;
    target_bus.rsp_rdata  = target_rsp_data_q;
    target_bus.rsp_resp   = AXI_RESP_OKAY;
    target_bus.rsp_replay = MEM_REPLAY_NONE;
  end

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      target_rsp_valid_q  <= 1'b0;
      target_rsp_id_q     <= '0;
      target_rsp_data_q   <= '0;
      target_request_count <= 0;
      for (int unsigned index = 0; index < 16; index++)
        memory[index] <= '0;
    end else begin
      if (target_rsp_valid_q && target_bus.rsp_ready)
        target_rsp_valid_q <= 1'b0;
      if (target_bus.req_valid && target_bus.req_ready) begin
        target_rsp_valid_q   <= 1'b1;
        target_rsp_id_q      <= target_bus.req_id;
        target_rsp_data_q    <= memory[target_bus.req_addr[6:3]];
        target_request_count <= target_request_count + 1;
        if (target_bus.req_write) begin
          memory[target_bus.req_addr[6:3]] <=
            apply_strobe(memory[target_bus.req_addr[6:3]],
                         target_bus.req_wdata, target_bus.req_wstrb);
          target_rsp_data_q <= '0;
        end
      end
    end
  end

  rv_local_to_axi_bridge u_outbound (
    .clk_i     (clk),
    .rst_ni    (rst_n),
    .local_bus (source_bus),
    .axi_m     (axi_link)
  );

  rv_axi_to_local_bridge #(
    .AXI_ID_WIDTH     (4),
    .LOCAL_ID_WIDTH   (6),
    .TARGET_BASE_ADDR (DTIM_BASE_ADDR),
    .TARGET_SIZE_KB   (DTIM_SIZE_KB)
  ) u_inbound (
    .clk_i     (clk),
    .rst_ni    (rst_n),
    .axi_s     (axi_link),
    .local_bus (target_bus)
  );

  task automatic local_transfer(
    input logic [5:0] id,
    input logic [31:0] address,
    input logic write_request,
    input logic [63:0] write_data,
    input logic [7:0] write_strobe,
    output logic [63:0] response_data,
    output logic [1:0] response_code
  );
    @(negedge clk);
    src_req_valid = 1'b1;
    src_req_id    = id;
    src_req_addr  = address;
    src_req_write = write_request;
    src_req_size  = 3'd3;
    src_req_wdata = write_data;
    src_req_wstrb = write_strobe;
    do @(posedge clk); while (!source_bus.req_ready);
    @(negedge clk);
    src_req_valid = 1'b0;
    while (!source_bus.rsp_valid) @(negedge clk);
    response_data = source_bus.rsp_rdata;
    response_code = source_bus.rsp_resp;
    if (source_bus.rsp_id != id)
      $fatal(1, "local/AXI bridge response ID mismatch");
  endtask

  logic [63:0] response_data;
  logic [1:0] response_code;
  int unsigned request_count_before;

  initial begin : p_round_trip_test
    clk            = 1'b0;
    rst_n          = 1'b0;
    src_req_valid  = 1'b0;
    src_req_id     = '0;
    src_req_addr   = '0;
    src_req_write  = 1'b0;
    src_req_size   = 3'd3;
    src_req_wdata  = '0;
    src_req_wstrb  = '0;

    repeat (3) @(posedge clk);
    @(negedge clk);
    rst_n = 1'b1;

    local_transfer(6'h15, DTIM_BASE_ADDR + 32'h20, 1'b1,
                   64'h0123_4567_89ab_cdef, 8'hff,
                   response_data, response_code);
    if (response_code != AXI_RESP_OKAY)
      $fatal(1, "local-to-AXI write failed");

    local_transfer(6'h16, DTIM_BASE_ADDR + 32'h20, 1'b0,
                   '0, '0, response_data, response_code);
    if ((response_code != AXI_RESP_OKAY) ||
        (response_data != 64'h0123_4567_89ab_cdef))
      $fatal(1, "local-to-AXI readback failed");

    request_count_before = target_request_count;
    @(negedge clk);
    src_req_valid = 1'b1;
    src_req_id    = 6'h17;
    src_req_addr  = DTIM_BASE_ADDR + 32'h22;
    src_req_write = 1'b0;
    src_req_size  = 3'd2;
    do @(posedge clk); while (!source_bus.req_ready);
    @(negedge clk);
    src_req_valid = 1'b0;
    while (!source_bus.rsp_valid) @(negedge clk);
    if ((source_bus.rsp_resp == AXI_RESP_OKAY) ||
        (target_request_count != request_count_before))
      $fatal(1, "misaligned local request reached AXI target");

    $display("rv_axi_bridge_tb PASS");
    $finish;
  end
endmodule

module rv_axi_to_local_burst_tb;
  import rv_soc_pkg::*;

  logic clk;
  logic rst_n;
  logic aw_valid;
  logic [3:0] aw_id;
  logic [31:0] aw_addr;
  logic [7:0] aw_len;
  logic [2:0] aw_size;
  logic w_valid;
  logic [63:0] w_data;
  logic [7:0] w_strb;
  logic w_last;
  logic ar_valid;
  logic [3:0] ar_id;
  logic [31:0] ar_addr;
  logic [7:0] ar_len;
  logic [2:0] ar_size;

  logic target_rsp_valid_q;
  logic [5:0] target_rsp_id_q;
  logic [63:0] target_rsp_data_q;
  logic [63:0] memory [0:15];
  int unsigned local_request_count;

  rv_axi4_if #(.ID_WIDTH(4)) axi_bus (.clk_i(clk), .rst_ni(rst_n));
  rv_local_mem_if local_bus (.clk_i(clk), .rst_ni(rst_n));

  always #5 clk = ~clk;

  always_comb begin
    axi_bus.aw_id    = aw_id;
    axi_bus.aw_addr  = aw_addr;
    axi_bus.aw_len   = aw_len;
    axi_bus.aw_size  = aw_size;
    axi_bus.aw_burst = 2'b01;
    axi_bus.aw_prot  = 3'b001;
    axi_bus.aw_cache = '0;
    axi_bus.aw_qos   = '0;
    axi_bus.aw_valid = aw_valid;
    axi_bus.w_data   = w_data;
    axi_bus.w_strb   = w_strb;
    axi_bus.w_last   = w_last;
    axi_bus.w_valid  = w_valid;
    axi_bus.b_ready  = 1'b1;
    axi_bus.ar_id    = ar_id;
    axi_bus.ar_addr  = ar_addr;
    axi_bus.ar_len   = ar_len;
    axi_bus.ar_size  = ar_size;
    axi_bus.ar_burst = 2'b01;
    axi_bus.ar_prot  = 3'b001;
    axi_bus.ar_cache = '0;
    axi_bus.ar_qos   = '0;
    axi_bus.ar_valid = ar_valid;
    axi_bus.r_ready  = 1'b1;

    local_bus.req_ready  = !target_rsp_valid_q || local_bus.rsp_ready;
    local_bus.rsp_valid  = target_rsp_valid_q;
    local_bus.rsp_id     = target_rsp_id_q;
    local_bus.rsp_rdata  = target_rsp_data_q;
    local_bus.rsp_resp   = AXI_RESP_OKAY;
    local_bus.rsp_replay = MEM_REPLAY_NONE;
  end

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      target_rsp_valid_q <= 1'b0;
      target_rsp_id_q    <= '0;
      target_rsp_data_q  <= '0;
      local_request_count <= 0;
      for (int unsigned index = 0; index < 16; index++)
        memory[index] <= '0;
    end else begin
      if (target_rsp_valid_q && local_bus.rsp_ready)
        target_rsp_valid_q <= 1'b0;
      if (local_bus.req_valid && local_bus.req_ready) begin
        target_rsp_valid_q   <= 1'b1;
        target_rsp_id_q      <= local_bus.req_id;
        target_rsp_data_q    <= memory[local_bus.req_addr[6:3]];
        local_request_count  <= local_request_count + 1;
        if (local_bus.req_write) begin
          memory[local_bus.req_addr[6:3]] <= local_bus.req_wdata;
          target_rsp_data_q <= '0;
        end
      end
    end
  end

  rv_axi_to_local_bridge #(
    .AXI_ID_WIDTH     (4),
    .LOCAL_ID_WIDTH   (6),
    .TARGET_BASE_ADDR (DTIM_BASE_ADDR),
    .TARGET_SIZE_KB   (DTIM_SIZE_KB)
  ) u_dut (
    .clk_i     (clk),
    .rst_ni    (rst_n),
    .axi_s     (axi_bus),
    .local_bus
  );

  int unsigned request_count_before;

  initial begin : p_burst_test
    clk      = 1'b0;
    rst_n    = 1'b0;
    aw_valid = 1'b0;
    aw_id    = '0;
    aw_addr  = '0;
    aw_len   = '0;
    aw_size  = 3'd3;
    w_valid  = 1'b0;
    w_data   = '0;
    w_strb   = 8'hff;
    w_last   = 1'b0;
    ar_valid = 1'b0;
    ar_id    = '0;
    ar_addr  = '0;
    ar_len   = '0;
    ar_size  = 3'd3;

    repeat (3) @(posedge clk);
    @(negedge clk);
    rst_n = 1'b1;

    @(negedge clk);
    aw_valid = 1'b1;
    aw_id    = 4'h5;
    aw_addr  = DTIM_BASE_ADDR;
    aw_len   = 8'd3;
    do @(posedge clk); while (!axi_bus.aw_ready);
    @(negedge clk);
    aw_valid = 1'b0;

    for (int unsigned beat = 0; beat < 4; beat++) begin
      w_valid = 1'b1;
      w_data  = 64'h1000 + beat;
      w_last  = (beat == 3);
      do @(posedge clk); while (!axi_bus.w_ready);
      @(negedge clk);
      w_valid = 1'b0;
    end
    while (!axi_bus.b_valid) @(negedge clk);
    if ((axi_bus.b_id != 4'h5) || (axi_bus.b_resp != AXI_RESP_OKAY))
      $fatal(1, "four-beat inbound write burst failed");

    @(negedge clk);
    ar_valid = 1'b1;
    ar_id    = 4'h6;
    ar_addr  = DTIM_BASE_ADDR;
    ar_len   = 8'd3;
    do @(posedge clk); while (!axi_bus.ar_ready);
    @(negedge clk);
    ar_valid = 1'b0;
    for (int unsigned beat = 0; beat < 4; beat++) begin
      while (!axi_bus.r_valid) @(negedge clk);
      if ((axi_bus.r_id != 4'h6) ||
          (axi_bus.r_data != (64'h1000 + beat)) ||
          (axi_bus.r_last != (beat == 3)) ||
          (axi_bus.r_resp != AXI_RESP_OKAY))
        $fatal(1, "four-beat inbound read burst failed at beat %0d", beat);
      @(negedge clk);
    end

    request_count_before = local_request_count;
    ar_valid = 1'b1;
    ar_id    = 4'h7;
    ar_addr  = DTIM_BASE_ADDR + (DTIM_SIZE_KB * 1024) - 8;
    ar_len   = 8'd1;
    do @(posedge clk); while (!axi_bus.ar_ready);
    @(negedge clk);
    ar_valid = 1'b0;
    for (int unsigned beat = 0; beat < 2; beat++) begin
      while (!axi_bus.r_valid) @(negedge clk);
      if (axi_bus.r_resp == AXI_RESP_OKAY)
        $fatal(1, "window-crossing burst was not rejected");
      @(negedge clk);
    end
    if (local_request_count != request_count_before)
      $fatal(1, "invalid burst produced a partial local side effect");

    $display("rv_axi_to_local_burst_tb PASS");
    $finish;
  end
endmodule
