module rv_axi_bridge_elab_smoke;
  logic clk;
  logic rst_n;

  rv_local_mem_if local_out_bus (.clk_i(clk), .rst_ni(rst_n));
  rv_axi4_if #(.ID_WIDTH(4)) axi_out_bus (.clk_i(clk), .rst_ni(rst_n));

  rv_local_to_axi_bridge #(
    .LOCAL_ID_WIDTH (6),
    .AXI_ID_WIDTH   (4)
  ) u_local_to_axi (
    .clk_i     (clk),
    .rst_ni    (rst_n),
    .local_bus (local_out_bus),
    .axi_m     (axi_out_bus)
  );

  rv_axi4_if #(.ID_WIDTH(6)) axi_in_bus (.clk_i(clk), .rst_ni(rst_n));
  rv_local_mem_if local_in_bus (.clk_i(clk), .rst_ni(rst_n));

  rv_axi_to_local_bridge #(
    .AXI_ID_WIDTH    (6),
    .LOCAL_ID_WIDTH  (6),
    .TARGET_BASE_ADDR(rv_soc_pkg::DTIM_BASE_ADDR),
    .TARGET_SIZE_KB  (rv_soc_pkg::DTIM_SIZE_KB)
  ) u_axi_to_local (
    .clk_i     (clk),
    .rst_ni    (rst_n),
    .axi_s     (axi_in_bus),
    .local_bus (local_in_bus)
  );

  always_comb begin
    axi_out_bus.aw_ready = 1'b0;
    axi_out_bus.w_ready  = 1'b0;
    axi_out_bus.b_id     = '0;
    axi_out_bus.b_resp   = rv_soc_pkg::AXI_RESP_OKAY;
    axi_out_bus.b_valid  = 1'b0;
    axi_out_bus.ar_ready = 1'b0;
    axi_out_bus.r_id     = '0;
    axi_out_bus.r_data   = '0;
    axi_out_bus.r_resp   = rv_soc_pkg::AXI_RESP_OKAY;
    axi_out_bus.r_last   = 1'b0;
    axi_out_bus.r_valid  = 1'b0;

    local_in_bus.req_ready  = 1'b0;
    local_in_bus.rsp_valid  = 1'b0;
    local_in_bus.rsp_id     = '0;
    local_in_bus.rsp_rdata  = '0;
    local_in_bus.rsp_resp   = rv_soc_pkg::AXI_RESP_OKAY;
    local_in_bus.rsp_replay = rv_soc_pkg::MEM_REPLAY_NONE;
  end

  initial begin
    clk   = 1'b0;
    rst_n = 1'b0;
  end
endmodule
