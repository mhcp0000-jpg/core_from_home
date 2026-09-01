module rv_soc_top_elab_smoke;
  logic clk;
  logic rst_n;
  logic [31:1] external_irq;
  logic soc_ready;
  logic [1:0] trace_valid;
  logic [1:0][31:0] trace_pc;
  logic [1:0][31:0] trace_instr;
  logic [31:0] host_boot_entry;
  logic [31:0] host_boot_flags;
  logic host_event_valid;
  rv_soc_pkg::host_event_e host_event_kind;
  logic [31:0] host_event_data;

  rv_axi4_if #(
    .ADDR_WIDTH (32),
    .DATA_WIDTH (64),
    .ID_WIDTH   (rv_soc_pkg::AXI_LOCAL_ID_WIDTH)
  ) host_axi (
    .clk_i (clk),
    .rst_ni (rst_n)
  );

  initial begin
    clk          = 1'b0;
    rst_n        = 1'b0;
    external_irq = '0;
  end

  rv_soc_top u_soc (
    .clk_i           (clk),
    .rst_ni          (rst_n),
    .external_irq_i  (external_irq),
    .host_axi_s      (host_axi),
    .soc_ready_o     (soc_ready),
    .host_boot_entry_o(host_boot_entry),
    .host_boot_flags_o(host_boot_flags),
    .host_event_valid_o(host_event_valid),
    .host_event_ready_i(1'b1),
    .host_event_kind_o(host_event_kind),
    .host_event_data_o(host_event_data),
    .trace_valid_o   (trace_valid),
    .trace_pc_o      (trace_pc),
    .trace_instr_o   (trace_instr)
  );

endmodule

module rv_soc_top_rv64_relocated_elab_smoke;
  logic clk;
  logic rst_n;
  logic [31:1] external_irq;
  logic soc_ready;
  logic [31:0] host_boot_entry;
  logic [31:0] host_boot_flags;
  logic host_event_valid;
  rv_soc_pkg::host_event_e host_event_kind;
  logic [31:0] host_event_data;
  logic [1:0] trace_valid;
  logic [1:0][63:0] trace_pc;
  logic [1:0][31:0] trace_instr;

  rv_axi4_if #(
    .ID_WIDTH (rv_soc_pkg::AXI_LOCAL_ID_WIDTH)
  ) host_axi (.clk_i(clk), .rst_ni(rst_n));

  rv_soc_top #(
    .XLEN              (64),
    .BOOTROM_BASE_ADDR (32'h0001_0000),
    .BOOTROM_SIZE_KB   (4),
    .CLINT_BASE_ADDR   (32'h0100_0000),
    .CLINT_SIZE_KB     (64),
    .PLIC_BASE_ADDR    (32'h1000_0000),
    .PLIC_SIZE_KB      (4096),
    .HOSTIF_BASE_ADDR  (32'h2000_0000),
    .HOSTIF_SIZE_KB    (4),
    .ITIM_BASE_ADDR    (32'h4000_0000),
    .ITIM_SIZE_KB      (128),
    .DTIM_BASE_ADDR    (32'h4004_0000),
    .DTIM_SIZE_KB      (128),
    .BOOT_MTVEC_ADDR   (32'h4000_0000),
    .HAS_SMODE         (1'b1)
  ) u_soc (
    .clk_i             (clk),
    .rst_ni            (rst_n),
    .external_irq_i    (external_irq),
    .host_axi_s        (host_axi),
    .soc_ready_o       (soc_ready),
    .host_boot_entry_o (host_boot_entry),
    .host_boot_flags_o (host_boot_flags),
    .host_event_valid_o(host_event_valid),
    .host_event_ready_i(1'b1),
    .host_event_kind_o (host_event_kind),
    .host_event_data_o (host_event_data),
    .trace_valid_o     (trace_valid),
    .trace_pc_o        (trace_pc),
    .trace_instr_o     (trace_instr)
  );

  initial begin
    clk          = 1'b0;
    rst_n        = 1'b0;
    external_irq = '0;
  end
endmodule
