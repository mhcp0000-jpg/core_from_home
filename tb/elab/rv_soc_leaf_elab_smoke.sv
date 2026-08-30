module rv_soc_leaf_elab_smoke;
  logic clk;
  logic rst_n;
  logic msip;
  logic mtip;
  logic [63:0] mtime;
  logic d_msip;
  logic d_mtip;
  logic [63:0] d_mtime;
  logic sram_read_valid;
  logic [63:0] sram_read_data;

  rv_local_mem_if clint_bus (
    .clk_i (clk),
    .rst_ni (rst_n)
  );

  rv_local_mem_if lsu0_bus (.clk_i(clk), .rst_ni(rst_n));
  rv_local_mem_if lsu1_bus (.clk_i(clk), .rst_ni(rst_n));
  rv_local_mem_if xbar_d_bus (.clk_i(clk), .rst_ni(rst_n));
  rv_local_mem_if outbound_bus (.clk_i(clk), .rst_ni(rst_n));

  rv_clint u_clint (
    .clk_i  (clk),
    .rst_ni (rst_n),
    .bus    (clint_bus),
    .msip_o (msip),
    .mtip_o (mtip),
    .mtime_o(mtime)
  );

  rv_sram_1r1w #(
    .DATA_WIDTH (64),
    .DEPTH      (8192)
  ) u_sram (
    .clk_i          (clk),
    .rst_ni         (rst_n),
    .read_en_i      (1'b0),
    .read_addr_i    ('0),
    .read_valid_o   (sram_read_valid),
    .read_data_o    (sram_read_data),
    .write_en_i     (1'b0),
    .write_addr_i   ('0),
    .write_data_i   ('0),
    .write_strb_i   ('0)
  );

  logic [31:0] decode_addr;
  rv_soc_pkg::soc_target_e decode_target;
  rv_soc_addr_decode u_decode (
    .addr_i   (decode_addr),
    .target_o (decode_target)
  );

  rv_d_fabric u_d_fabric (
    .clk_i         (clk),
    .rst_ni        (rst_n),
    .lsu0_bus,
    .lsu1_bus,
    .xbar_in_bus   (xbar_d_bus),
    .outbound_bus,
    .msip_o        (d_msip),
    .mtip_o        (d_mtip),
    .mtime_o       (d_mtime)
  );

  always_comb begin
    outbound_bus.req_ready  = 1'b0;
    outbound_bus.rsp_valid  = 1'b0;
    outbound_bus.rsp_id     = '0;
    outbound_bus.rsp_rdata  = '0;
    outbound_bus.rsp_resp   = rv_soc_pkg::AXI_RESP_DECERR;
    outbound_bus.rsp_replay = rv_soc_pkg::MEM_REPLAY_NONE;
  end

  initial begin
    clk         = 1'b0;
    rst_n       = 1'b0;
    decode_addr = '0;
  end

endmodule

module rv_i_fabric_elab_smoke;
  logic clk;
  logic rst_n;
  logic if_req_ready;
  logic if_rsp_valid;
  logic [3:0] if_rsp_id;
  logic [3:0] if_rsp_epoch;
  logic [127:0] if_rsp_data;
  logic [1:0] if_rsp_resp;

  rv_local_mem_if xbar_i_bus (.clk_i(clk), .rst_ni(rst_n));
  rv_local_mem_if i_outbound_bus (.clk_i(clk), .rst_ni(rst_n));

  rv_i_fabric u_i_fabric (
    .clk_i          (clk),
    .rst_ni         (rst_n),
    .if_req_valid_i (1'b0),
    .if_req_ready_o (if_req_ready),
    .if_req_addr_i  ('0),
    .if_req_id_i    ('0),
    .if_req_epoch_i ('0),
    .if_rsp_valid_o (if_rsp_valid),
    .if_rsp_ready_i (1'b0),
    .if_rsp_id_o    (if_rsp_id),
    .if_rsp_epoch_o (if_rsp_epoch),
    .if_rsp_data_o  (if_rsp_data),
    .if_rsp_resp_o  (if_rsp_resp),
    .xbar_in_bus    (xbar_i_bus),
    .outbound_bus   (i_outbound_bus)
  );

  always_comb begin
    i_outbound_bus.req_ready  = 1'b0;
    i_outbound_bus.rsp_valid  = 1'b0;
    i_outbound_bus.rsp_id     = '0;
    i_outbound_bus.rsp_rdata  = '0;
    i_outbound_bus.rsp_resp   = rv_soc_pkg::AXI_RESP_DECERR;
    i_outbound_bus.rsp_replay = rv_soc_pkg::MEM_REPLAY_NONE;
  end

  initial begin
    clk   = 1'b0;
    rst_n = 1'b0;
  end
endmodule
