// Xcelium/server-facing ELF test top.
// Runtime communication uses the 64-bit TOHOST/FROMHOST words in DTIM while
// the existing HostIF is used only as the Boot ROM entry mailbox.
module rv_soc_htif_dpi_tb;
  import rv_soc_pkg::*;

  logic clk;
  logic rst_n;
  logic soc_ready;
  logic boot_wait;
  logic load_done;
  logic load_failed;
  logic htif_exit_valid;
  logic [31:0] htif_exit_code;
  logic [PLIC_NUM_SOURCES-1:1] external_irq;
  logic [31:0] host_boot_entry;
  logic [31:0] host_boot_flags;
  logic host_event_valid;
  logic host_event_ready;
  host_event_e host_event_kind;
  logic [31:0] host_event_data;
  logic [1:0] trace_valid;
  logic [1:0][31:0] trace_pc;
  logic [1:0][31:0] trace_instr;
  logic [1:0][4:0] trace_rd;
  logic [1:0] trace_rd_write;
  logic [1:0] trace_rd_fp;
  logic [1:0][31:0] trace_rd_wdata;
  logic [1:0] trace_trap;
  logic [1:0][5:0] trace_cause;
  logic [1:0][31:0] trace_tval;
  integer timeout_cycles;

  rv_axi4_if #(
    .ADDR_WIDTH (SOC_ADDR_WIDTH),
    .DATA_WIDTH (SOC_DATA_WIDTH),
    .ID_WIDTH   (AXI_LOCAL_ID_WIDTH)
  ) host_axi (
    .clk_i  (clk),
    .rst_ni (rst_n)
  );

  always #5 clk = ~clk;

  rv_soc_top #(
    // This ROM wakes on MSIP, clears CLINT.msip, reads HOSTIF.BOOT_ENTRY and
    // jumps there. Consequently the ELF entry need not contain a trap stub.
    .BOOTROM_INIT_FILE ("tb/fixtures/bootrom/bootrom_host_jump.hex")
  ) u_dut (
    .clk_i                (clk),
    .rst_ni               (rst_n),
    .external_irq_i       (external_irq),
    .host_axi_s           (host_axi),
    .soc_ready_o          (soc_ready),
    .host_boot_entry_o    (host_boot_entry),
    .host_boot_flags_o    (host_boot_flags),
    .host_event_valid_o   (host_event_valid),
    .host_event_ready_i   (host_event_ready),
    .host_event_kind_o    (host_event_kind),
    .host_event_data_o    (host_event_data),
    .trace_valid_o        (trace_valid),
    .trace_pc_o           (trace_pc),
    .trace_instr_o        (trace_instr),
    .trace_rd_o           (trace_rd),
    .trace_rd_write_o     (trace_rd_write),
    .trace_rd_fp_o        (trace_rd_fp),
    .trace_rd_wdata_o     (trace_rd_wdata),
    .trace_trap_o         (trace_trap),
    .trace_cause_o        (trace_cause),
    .trace_tval_o         (trace_tval)
  );

  rv_host_dpi #(
    .XLEN                       (32),
    .ADDR_WIDTH                 (SOC_ADDR_WIDTH),
    .DATA_WIDTH                 (SOC_DATA_WIDTH),
    .ID_WIDTH                   (AXI_LOCAL_ID_WIDTH),
    .BOOTROM_BASE_ADDR          (BOOTROM_BASE_ADDR),
    .BOOTROM_SIZE_BYTES         (BOOTROM_SIZE_BYTES),
    .ITIM_BASE_ADDR             (ITIM_BASE_ADDR),
    .ITIM_SIZE_BYTES            (ITIM_SIZE_BYTES),
    .DTIM_BASE_ADDR             (DTIM_BASE_ADDR),
    .DTIM_SIZE_BYTES            (DTIM_SIZE_BYTES),
    .CLINT_BASE_ADDR            (CLINT_BASE_ADDR),
    .PLIC_BASE_ADDR             (PLIC_BASE_ADDR),
    .HOSTIF_BASE_ADDR           (HOSTIF_BASE_ADDR),
    .CLINT_MSIP_OFFSET          (CLINT_MSIP_OFFSET),
    .HOSTIF_BOOT_ENTRY_OFFSET   (HOSTIF_BOOT_ENTRY_OFF),
    .HOSTIF_BOOT_FLAGS_OFFSET   (HOSTIF_BOOT_FLAGS_OFF),
    .HTIF_ENABLE                (1'b1),
    .TOHOST_ADDR                (TOHOST_ADDR),
    .FROMHOST_ADDR              (FROMHOST_ADDR)
  ) u_host (
    .clk_i                (clk),
    .rst_ni               (rst_n),
    .soc_ready_i          (soc_ready),
    .boot_wait_i          (boot_wait),
    .host_axi_m           (host_axi),
    .host_event_valid_i   (host_event_valid),
    .host_event_ready_o   (host_event_ready),
    .host_event_kind_i    (host_event_kind),
    .host_event_data_i    (host_event_data),
    .load_done_o          (load_done),
    .load_failed_o        (load_failed),
    .htif_exit_valid_o    (htif_exit_valid),
    .htif_exit_code_o     (htif_exit_code)
  );

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      boot_wait <= 1'b0;
    end else begin
      for (int unsigned lane = 0; lane < 2; lane++) begin
        if (trace_valid[lane] && (trace_instr[lane] == 32'h1050_0073))
          boot_wait <= 1'b1;
      end
      if (load_failed)
        $fatal(1, "HTIF DPI ELF load/AXI transaction failed");
      if (htif_exit_valid) begin
        if (htif_exit_code == 0) begin
          $display("HTIF TEST PASS");
          $finish;
        end else begin
          $fatal(1, "HTIF TEST FAIL code=%0d (0x%08h)",
                 htif_exit_code, htif_exit_code);
        end
      end
    end
  end

  initial begin
    clk = 1'b0;
    rst_n = 1'b0;
    external_irq = '0;
    timeout_cycles = 2_000_000;
    void'($value$plusargs("timeout_cycles=%d", timeout_cycles));
    repeat (3) @(posedge clk);
    @(negedge clk);
    rst_n = 1'b1;
    repeat (timeout_cycles) @(posedge clk);
    $fatal(1, "HTIF DPI simulation timeout");
  end
endmodule
