module rv_soc_peripheral_elab_smoke;
  logic clk;
  logic rst_n;
  logic [31:0] boot_entry;
  logic [31:0] boot_flags;
  logic event_valid;
  rv_soc_pkg::host_event_e event_kind;
  logic [31:0] event_data;
  logic [rv_soc_pkg::PLIC_NUM_SOURCES-1:1] plic_sources;
  logic meip;
  logic seip;

  rv_axi4_if #(.ID_WIDTH(6)) bootrom_axi (.clk_i(clk), .rst_ni(rst_n));
  rv_axi4_if #(.ID_WIDTH(6)) hostif_axi (.clk_i(clk), .rst_ni(rst_n));
  rv_axi4_if #(.ID_WIDTH(6)) plic_axi (.clk_i(clk), .rst_ni(rst_n));

  rv_bootrom #(
    .AXI_ID_WIDTH (6)
  ) u_bootrom (
    .clk_i  (clk),
    .rst_ni (rst_n),
    .axi_s  (bootrom_axi)
  );

  rv_hostif #(
    .AXI_ID_WIDTH (6)
  ) u_hostif (
    .clk_i         (clk),
    .rst_ni        (rst_n),
    .axi_s         (hostif_axi),
    .boot_entry_o  (boot_entry),
    .boot_flags_o  (boot_flags),
    .event_valid_o (event_valid),
    .event_ready_i (1'b0),
    .event_kind_o  (event_kind),
    .event_data_o  (event_data)
  );

  rv_plic #(
    .AXI_ID_WIDTH (6),
    .HAS_SMODE    (1'b1)
  ) u_plic (
    .clk_i     (clk),
    .rst_ni    (rst_n),
    .axi_s     (plic_axi),
    .source_i  (plic_sources),
    .meip_o    (meip),
    .seip_o    (seip)
  );

  initial begin
    clk   = 1'b0;
    rst_n = 1'b0;
    plic_sources = '0;
  end
endmodule
