module rv_soc_dpi_tb;
  import rv_soc_pkg::*;

  logic clk, rst_n, soc_ready, boot_wait, load_done, load_failed;
  logic [PLIC_NUM_SOURCES-1:1] external_irq;
  logic [31:0] host_boot_entry, host_boot_flags;
  logic host_event_valid, host_event_ready;
  host_event_e host_event_kind;
  logic [31:0] host_event_data;
  logic [1:0] trace_valid;
  logic [1:0][31:0] trace_pc;
  logic [1:0][31:0] trace_instr;

  rv_axi4_if #(.ADDR_WIDTH(SOC_ADDR_WIDTH), .DATA_WIDTH(SOC_DATA_WIDTH),
               .ID_WIDTH(AXI_LOCAL_ID_WIDTH))
    host_axi (.clk_i(clk), .rst_ni(rst_n));

  always #5 clk = ~clk;

  rv_soc_top #(
    .BOOTROM_INIT_FILE("tb/data/bootrom_wait.hex")
  ) u_dut (
    .clk_i(clk), .rst_ni(rst_n), .external_irq_i(external_irq),
    .host_axi_s(host_axi), .soc_ready_o(soc_ready),
    .host_boot_entry_o(host_boot_entry), .host_boot_flags_o(host_boot_flags),
    .host_event_valid_o(host_event_valid),
    .host_event_ready_i(host_event_ready),
    .host_event_kind_o(host_event_kind), .host_event_data_o(host_event_data),
    .trace_valid_o(trace_valid), .trace_pc_o(trace_pc),
    .trace_instr_o(trace_instr)
  );

  rv_host_dpi #(
    .XLEN(32), .ADDR_WIDTH(SOC_ADDR_WIDTH), .DATA_WIDTH(SOC_DATA_WIDTH),
    .ID_WIDTH(AXI_LOCAL_ID_WIDTH), .BOOTROM_BASE_ADDR(BOOTROM_BASE_ADDR),
    .BOOTROM_SIZE_BYTES(BOOTROM_SIZE_BYTES), .ITIM_BASE_ADDR(ITIM_BASE_ADDR),
    .ITIM_SIZE_BYTES(ITIM_SIZE_BYTES), .DTIM_BASE_ADDR(DTIM_BASE_ADDR),
    .DTIM_SIZE_BYTES(DTIM_SIZE_BYTES), .CLINT_BASE_ADDR(CLINT_BASE_ADDR),
    .PLIC_BASE_ADDR(PLIC_BASE_ADDR), .HOSTIF_BASE_ADDR(HOSTIF_BASE_ADDR),
    .CLINT_MSIP_OFFSET(CLINT_MSIP_OFFSET),
    .HOSTIF_BOOT_ENTRY_OFFSET(HOSTIF_BOOT_ENTRY_OFF),
    .HOSTIF_BOOT_FLAGS_OFFSET(HOSTIF_BOOT_FLAGS_OFF)
  ) u_host (
    .clk_i(clk), .rst_ni(rst_n), .soc_ready_i(soc_ready),
    .boot_wait_i(boot_wait), .host_axi_m(host_axi),
    .host_event_valid_i(host_event_valid),
    .host_event_ready_o(host_event_ready),
    .host_event_kind_i(host_event_kind), .host_event_data_i(host_event_data),
    .load_done_o(load_done), .load_failed_o(load_failed)
  );

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      boot_wait <= 1'b0;
    end else begin
      for (int unsigned lane = 0; lane < 2; lane++)
        if (trace_valid[lane] && (trace_instr[lane] == 32'h1050_0073))
          boot_wait <= 1'b1;
      if (host_event_valid && host_event_ready &&
          (host_event_kind == HOST_EVENT_EXIT))
        $finish;
    end
  end

  initial begin
    clk = 1'b0;
    rst_n = 1'b0;
    external_irq = '0;
    boot_wait = 1'b0;
    repeat (3) @(posedge clk);
    @(negedge clk);
    rst_n = 1'b1;
    fork
      begin
        wait (load_done || load_failed);
        if (load_failed) $fatal(1, "DPI ELF load failed");
        $display("DPI ELF load complete entry=%h flags=%h",
                 host_boot_entry, host_boot_flags);
      end
      begin
        repeat (2_000_000) @(posedge clk);
        $fatal(1, "DPI SoC simulation timeout");
      end
    join_none
  end
endmodule
