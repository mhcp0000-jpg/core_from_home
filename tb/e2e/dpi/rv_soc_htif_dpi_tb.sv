// Xcelium/server-facing ELF test top.
// Runtime communication uses the 64-bit TOHOST/FROMHOST words in DTIM while
// the existing HostIF is used only as the Boot ROM entry mailbox.
module rv_soc_htif_dpi_tb;
  import rv_soc_pkg::*;

  localparam int unsigned IFU_PMP_PORTS = 8;

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
  logic commit_last_valid;
  logic [63:0] commit_retire_order;
  logic [63:0] commit_cycle;
  logic [63:0] commit_idle_cycles;
  logic [31:0] commit_last_pc;
  logic [31:0] commit_last_instr;
  integer timeout_cycles;

`ifdef RV_FSDB
  // FSDB is a server-debug feature.  RV_FSDB is defined only when the Xcelium
  // run enables waveform dumping, so ordinary simulators do not need to
  // recognize any of the vendor system tasks below.
  initial begin : p_fsdb_dump
    string fsdb_file;
    integer fsdb_dump_mda;
    integer fsdb_flush_cycles;
    fsdb_file = "binary.fsdb";
    fsdb_dump_mda = 0;
    fsdb_flush_cycles = 100_000;
    void'($value$plusargs("fsdbfile=%s", fsdb_file));
    void'($value$plusargs("fsdb_dump_mda=%d", fsdb_dump_mda));
    void'($value$plusargs("fsdb_flush_cycles=%d", fsdb_flush_cycles));
    $display("[FSDB][%0t] opening %s (mda=%0d flush_cycles=%0d)",
             $time, fsdb_file, fsdb_dump_mda, fsdb_flush_cycles);
    $fsdbDumpfile(fsdb_file);
    $fsdbDumpvars(0, rv_soc_htif_dpi_tb, "+all");
    if (fsdb_dump_mda != 0) begin
      $display("[FSDB][%0t] multidimensional-array dumping enabled", $time);
      $fsdbDumpMDA();
    end
    // Write the database header immediately so even an early zero-time stall
    // leaves a recognizable file on the server.
    $fsdbDumpflush;
    if (fsdb_flush_cycles > 0) begin
      forever begin
        repeat (fsdb_flush_cycles) @(posedge clk);
        $fsdbDumpflush;
        $display("[FSDB][%0t] waveform buffer flushed: %s", $time, fsdb_file);
      end
    end
  end
`endif

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

  rv_commit_trace_logger #(.XLEN(32)) u_trace_logger (
    .clk_i                 (clk),
    .rst_ni                (rst_n),
    .trace_valid_i         (trace_valid),
    .trace_pc_i            (trace_pc),
    .trace_instr_i         (trace_instr),
    .trace_rd_i            (trace_rd),
    .trace_rd_write_i      (trace_rd_write),
    .trace_rd_fp_i         (trace_rd_fp),
    .trace_rd_wdata_i      (trace_rd_wdata),
    .trace_trap_i          (trace_trap),
    .trace_cause_i         (trace_cause),
    .trace_tval_i          (trace_tval),
    .csr_commit_valid_i    (u_dut.u_core.u_backend.csr_commit &&
                            u_dut.u_core.u_backend.u_csr_file.csr_pending_q),
    .csr_commit_write_i    (u_dut.u_core.u_backend.u_csr_file.csr_pending_write_q),
    .csr_commit_addr_i     (u_dut.u_core.u_backend.u_csr_file.csr_pending_addr_q),
    .csr_commit_wdata_i    (u_dut.u_core.u_backend.u_csr_file.csr_pending_wdata_q),
    .last_commit_valid_o   (commit_last_valid),
    .retire_order_o        (commit_retire_order),
    .cycle_o               (commit_cycle),
    .cycles_since_commit_o (commit_idle_cycles),
    .last_commit_pc_o      (commit_last_pc),
    .last_commit_instr_o   (commit_last_instr)
  );

  // Server-side fetch-fault discriminator.  A commit trace reports architectural
  // cause=1 for both a PMP rejection and an instruction-fabric error; these
  // messages identify which path created the fault before it reaches decode.
  // Privilege encoding follows RISC-V: 0=U, 1=S, 3=M.
  always_ff @(posedge clk) begin
    if (rst_n) begin
      for (int unsigned parcel = 0; parcel < IFU_PMP_PORTS; parcel++) begin
        if (u_dut.u_core.ifu_pmp_check_valid[parcel] &&
            !u_dut.u_core.ifu_pmp_allow[parcel]) begin
          $display("[IFETCH-FAULT][%0t] source=PMP parcel=%0d addr=%08h block=%08h priv=%0d matched=%b pmpcfg=%h pmpaddr=%h",
            $time, parcel,
            u_dut.u_core.ifu_pmp_check_address[parcel],
            u_dut.u_core.u_frontend.queue_fill_addr,
            u_dut.u_core.current_privilege,
            u_dut.u_core.ifu_pmp_matched[parcel],
            u_dut.u_core.pmpcfg, u_dut.u_core.pmpaddr);
        end
      end
      if (u_dut.u_core.imem_rsp_valid_i &&
          u_dut.u_core.imem_rsp_ready_o &&
          (u_dut.u_core.imem_rsp_resp_i != 2'b00)) begin
        $display("[IFETCH-FAULT][%0t] source=I_FABRIC resp=%b id=%0d epoch=%0d priv=%0d",
          $time, u_dut.u_core.imem_rsp_resp_i,
          u_dut.u_core.imem_rsp_id_i, u_dut.u_core.imem_rsp_epoch_i,
          u_dut.u_core.current_privilege);
      end
    end
  end

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
        if (!boot_wait && trace_valid[lane] &&
            (trace_instr[lane] == 32'h1050_0073)) begin
          $display("[TB][%0t] Boot ROM WFI retired: lane=%0d pc=0x%08h",
                   $time, lane, trace_pc[lane]);
          boot_wait <= 1'b1;
        end
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
    $display("[TB][%0t] rv_soc_htif_dpi_tb started; timeout=%0d cycles",
             $time, timeout_cycles);
    repeat (3) @(posedge clk);
    @(negedge clk);
    rst_n = 1'b1;
    $display("[TB][%0t] reset deasserted", $time);
    repeat (timeout_cycles) @(posedge clk);
    $display("[TB][%0t] timeout state: soc_ready=%b boot_wait=%b load_done=%b load_failed=%b commits=%0d last_valid=%b last_pc=%08h last_instr=%08h idle_cycles=%0d",
             $time, soc_ready, boot_wait, load_done, load_failed,
             commit_retire_order, commit_last_valid, commit_last_pc,
             commit_last_instr, commit_idle_cycles);
    $fatal(1, "HTIF DPI simulation timeout");
  end

  initial begin : p_progress_heartbeat
    integer heartbeat_cycles;
    heartbeat_cycles = 100_000;
    void'($value$plusargs("heartbeat_cycles=%d", heartbeat_cycles));
    wait (rst_n);
    if (heartbeat_cycles > 0) begin
      forever begin
        repeat (heartbeat_cycles) @(posedge clk);
        $display("[TB][%0t] heartbeat: soc_ready=%b boot_wait=%b load_done=%b load_failed=%b commits=%0d commit_cycle=%0d last_valid=%b last_pc=%08h last_instr=%08h idle_cycles=%0d",
                 $time, soc_ready, boot_wait, load_done, load_failed,
                 commit_retire_order, commit_cycle, commit_last_valid,
                 commit_last_pc, commit_last_instr, commit_idle_cycles);
      end
    end
  end

  initial begin : p_boot_mailbox_monitor
    wait (rst_n && host_boot_flags[0]);
    $display("[TB][%0t] boot mailbox ready: entry=0x%08h flags=0x%08h",
             $time, host_boot_entry, host_boot_flags);
  end

  initial begin : p_software_interrupt_monitor
    wait (rst_n);
    @(posedge u_dut.msip);
    $display("[TB][%0t] CLINT MSIP asserted; software interrupt is pending",
             $time);
    @(negedge u_dut.msip);
    $display("[TB][%0t] CLINT MSIP cleared by Boot ROM handler", $time);
  end
endmodule
