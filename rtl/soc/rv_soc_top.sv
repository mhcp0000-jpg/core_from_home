module rv_soc_top #(
  parameter int unsigned XLEN               = 32,
  parameter int unsigned CLOCK_HZ           = 100_000_000,
  parameter int unsigned TIMEBASE_HZ        = rv_soc_pkg::TIMEBASE_HZ,
  parameter int unsigned AXI_LOCAL_ID_WIDTH = rv_soc_pkg::AXI_LOCAL_ID_WIDTH,
  parameter int unsigned AXI_XBAR_ID_WIDTH  = rv_soc_pkg::AXI_XBAR_ID_WIDTH,
  parameter bit          HAS_C              = 1'b1,
  parameter bit          HAS_F              = 1'b1,
  parameter bit          HAS_SMODE           = 1'b0,
  parameter int unsigned IF_TARGET_BUFFER_ENTRIES = 16,
  parameter string       BOOTROM_INIT_FILE   = "",
  parameter logic [31:0] BOOTROM_BASE_ADDR = rv_soc_pkg::BOOTROM_BASE_ADDR,
  parameter int unsigned BOOTROM_SIZE_KB   = rv_soc_pkg::BOOTROM_SIZE_KB,
  parameter logic [31:0] CLINT_BASE_ADDR   = rv_soc_pkg::CLINT_BASE_ADDR,
  parameter int unsigned CLINT_SIZE_KB     = rv_soc_pkg::CLINT_SIZE_KB,
  parameter logic [31:0] PLIC_BASE_ADDR    = rv_soc_pkg::PLIC_BASE_ADDR,
  parameter int unsigned PLIC_SIZE_KB      = rv_soc_pkg::PLIC_SIZE_KB,
  parameter logic [31:0] HOSTIF_BASE_ADDR  = rv_soc_pkg::HOSTIF_BASE_ADDR,
  parameter int unsigned HOSTIF_SIZE_KB    = rv_soc_pkg::HOSTIF_SIZE_KB,
  parameter logic [31:0] ITIM_BASE_ADDR    = rv_soc_pkg::ITIM_BASE_ADDR,
  parameter int unsigned ITIM_SIZE_KB      = rv_soc_pkg::ITIM_SIZE_KB,
  parameter logic [31:0] DTIM_BASE_ADDR    = rv_soc_pkg::DTIM_BASE_ADDR,
  parameter int unsigned DTIM_SIZE_KB      = rv_soc_pkg::DTIM_SIZE_KB,
  parameter logic [31:0] BOOT_MTVEC_ADDR   = ITIM_BASE_ADDR,
  parameter int unsigned PLIC_NUM_SOURCES  = rv_soc_pkg::PLIC_NUM_SOURCES
) (
  input  logic                          clk_i,
  input  logic                          rst_ni,
  input  logic [PLIC_NUM_SOURCES-1:1]   external_irq_i,
  rv_axi4_if.slave                      host_axi_s,
  output logic                          soc_ready_o,
  output logic [31:0]                   host_boot_entry_o,
  output logic [31:0]                   host_boot_flags_o,
  output logic                          host_event_valid_o,
  input  logic                          host_event_ready_i,
  output rv_soc_pkg::host_event_e       host_event_kind_o,
  output logic [31:0]                   host_event_data_o,
  output logic [1:0]                    trace_valid_o,
  output logic [1:0][XLEN-1:0]          trace_pc_o,
  output logic [1:0][31:0]              trace_instr_o,
  output logic [1:0][4:0]               trace_rd_o,
  output logic [1:0]                    trace_rd_write_o,
  output logic [1:0]                    trace_rd_fp_o,
  output logic [1:0][XLEN-1:0]          trace_rd_wdata_o,
  output logic [1:0]                    trace_trap_o,
  output logic [1:0][5:0]               trace_cause_o,
  output logic [1:0][XLEN-1:0]          trace_tval_o
);

  localparam int unsigned LOCAL_MEM_ID_WIDTH = 6;
  localparam int unsigned ROB_SEQ_WIDTH = rv_ooo_pkg::ROB_SEQ_WIDTH;
  localparam logic [XLEN-1:0] CORE_RESET_VECTOR = BOOTROM_BASE_ADDR;

  logic                       imem_req_valid;
  logic                       imem_req_ready;
  logic [31:0]                imem_req_addr;
  logic [3:0]                 imem_req_id;
  logic [3:0]                 imem_req_epoch;
  logic                       imem_rsp_valid;
  logic                       imem_rsp_ready;
  logic [3:0]                 imem_rsp_id;
  logic [3:0]                 imem_rsp_epoch;
  logic [127:0]               imem_rsp_data;
  logic [1:0]                 imem_rsp_resp;

  logic [1:0]                 dmem_req_valid;
  logic [1:0]                 dmem_req_ready;
  logic [1:0][5:0]            dmem_req_id;
  logic [1:0]                 dmem_req_write;
  logic [1:0][31:0]           dmem_req_addr;
  logic [1:0][2:0]            dmem_req_size;
  logic [1:0][63:0]           dmem_req_wdata;
  logic [1:0][7:0]            dmem_req_wstrb;
  logic [1:0][1:0]            dmem_req_priv;
  logic [1:0][ROB_SEQ_WIDTH-1:0] dmem_req_rob_seq;
  logic [1:0]                 dmem_req_committed;
  logic [1:0]                 dmem_req_device;
  logic [1:0]                 dmem_rsp_valid;
  logic [1:0]                 dmem_rsp_ready;
  logic [1:0][5:0]            dmem_rsp_id;
  logic [1:0][63:0]           dmem_rsp_rdata;
  logic [1:0][1:0]            dmem_rsp_resp;
  logic [1:0][2:0]            dmem_rsp_replay;

  logic                       msip;
  logic                       mtip;
  logic                       meip;
  logic                       seip;
  logic [63:0]                mtime;

  rv_local_mem_if #(
    .ID_WIDTH      (LOCAL_MEM_ID_WIDTH),
    .ROB_SEQ_WIDTH (ROB_SEQ_WIDTH)
  ) lsu0_bus (.clk_i, .rst_ni);
  rv_local_mem_if #(
    .ID_WIDTH      (LOCAL_MEM_ID_WIDTH),
    .ROB_SEQ_WIDTH (ROB_SEQ_WIDTH)
  ) lsu1_bus (.clk_i, .rst_ni);
  rv_local_mem_if #(
    .ID_WIDTH      (LOCAL_MEM_ID_WIDTH),
    .ROB_SEQ_WIDTH (ROB_SEQ_WIDTH)
  ) i_xbar_local_bus (.clk_i, .rst_ni);
  rv_local_mem_if #(
    .ID_WIDTH      (LOCAL_MEM_ID_WIDTH),
    .ROB_SEQ_WIDTH (ROB_SEQ_WIDTH)
  ) d_xbar_local_bus (.clk_i, .rst_ni);
  rv_local_mem_if #(
    .ID_WIDTH      (LOCAL_MEM_ID_WIDTH),
    .ROB_SEQ_WIDTH (ROB_SEQ_WIDTH)
  ) i_outbound_bus (.clk_i, .rst_ni);
  rv_local_mem_if #(
    .ID_WIDTH      (LOCAL_MEM_ID_WIDTH),
    .ROB_SEQ_WIDTH (ROB_SEQ_WIDTH)
  ) d_outbound_bus (.clk_i, .rst_ni);

  rv_axi4_if #(.ID_WIDTH(AXI_LOCAL_ID_WIDTH)) i_master_axi
    (.clk_i, .rst_ni);
  rv_axi4_if #(.ID_WIDTH(AXI_LOCAL_ID_WIDTH)) d_master_axi
    (.clk_i, .rst_ni);
  rv_axi4_if #(.ID_WIDTH(AXI_XBAR_ID_WIDTH)) i_target_axi
    (.clk_i, .rst_ni);
  rv_axi4_if #(.ID_WIDTH(AXI_XBAR_ID_WIDTH)) d_target_axi
    (.clk_i, .rst_ni);
  rv_axi4_if #(.ID_WIDTH(AXI_XBAR_ID_WIDTH)) plic_target_axi
    (.clk_i, .rst_ni);
  rv_axi4_if #(.ID_WIDTH(AXI_XBAR_ID_WIDTH)) reserved_error_axi
    (.clk_i, .rst_ni);
  rv_axi4_if #(.ID_WIDTH(AXI_XBAR_ID_WIDTH)) hostif_target_axi
    (.clk_i, .rst_ni);
  rv_axi4_if #(.ID_WIDTH(AXI_XBAR_ID_WIDTH)) default_error_axi
    (.clk_i, .rst_ni);

  rv_soc_map_check #(
    .BOOTROM_BASE_ADDR (BOOTROM_BASE_ADDR),
    .BOOTROM_SIZE_KB   (BOOTROM_SIZE_KB),
    .CLINT_BASE_ADDR   (CLINT_BASE_ADDR),
    .CLINT_SIZE_KB     (CLINT_SIZE_KB),
    .PLIC_BASE_ADDR    (PLIC_BASE_ADDR),
    .PLIC_SIZE_KB      (PLIC_SIZE_KB),
    .HOSTIF_BASE_ADDR  (HOSTIF_BASE_ADDR),
    .HOSTIF_SIZE_KB    (HOSTIF_SIZE_KB),
    .ITIM_BASE_ADDR    (ITIM_BASE_ADDR),
    .ITIM_SIZE_KB      (ITIM_SIZE_KB),
    .DTIM_BASE_ADDR    (DTIM_BASE_ADDR),
    .DTIM_SIZE_KB      (DTIM_SIZE_KB),
    .BOOT_MTVEC_ADDR   (BOOT_MTVEC_ADDR)
  ) u_map_check ();

  rv_ooo_core #(
    .XLEN           (XLEN),
    .PADDR_WIDTH    (32),
    .MEM_DATA_WIDTH (64),
    .HAS_C          (HAS_C),
    .HAS_F          (HAS_F),
    .HAS_SMODE      (HAS_SMODE),
    .FETCH_BYTES    (16),
    .IF_TARGET_BUFFER_ENTRIES(IF_TARGET_BUFFER_ENTRIES),
    .RESET_VECTOR   (CORE_RESET_VECTOR),
    .TRAP_VECTOR    (XLEN'(BOOT_MTVEC_ADDR)),
    .ITIM_BASE_ADDR (ITIM_BASE_ADDR),
    .ITIM_SIZE_KB   (ITIM_SIZE_KB),
    .DTIM_BASE_ADDR (DTIM_BASE_ADDR),
    .DTIM_SIZE_KB   (DTIM_SIZE_KB)
  ) u_core (
    .clk_i,
    .rst_ni,
    .imem_req_valid_o (imem_req_valid),
    .imem_req_ready_i (imem_req_ready),
    .imem_req_addr_o  (imem_req_addr),
    .imem_req_id_o    (imem_req_id),
    .imem_req_epoch_o (imem_req_epoch),
    .imem_rsp_valid_i (imem_rsp_valid),
    .imem_rsp_ready_o (imem_rsp_ready),
    .imem_rsp_id_i    (imem_rsp_id),
    .imem_rsp_epoch_i (imem_rsp_epoch),
    .imem_rsp_data_i  (imem_rsp_data),
    .imem_rsp_resp_i  (imem_rsp_resp),
    .dmem_req_valid_o (dmem_req_valid),
    .dmem_req_ready_i (dmem_req_ready),
    .dmem_req_id_o    (dmem_req_id),
    .dmem_req_write_o (dmem_req_write),
    .dmem_req_addr_o  (dmem_req_addr),
    .dmem_req_size_o  (dmem_req_size),
    .dmem_req_wdata_o (dmem_req_wdata),
    .dmem_req_wstrb_o (dmem_req_wstrb),
    .dmem_req_priv_o  (dmem_req_priv),
    .dmem_req_rob_seq_o (dmem_req_rob_seq),
    .dmem_req_committed_o (dmem_req_committed),
    .dmem_req_device_o (dmem_req_device),
    .dmem_rsp_valid_i (dmem_rsp_valid),
    .dmem_rsp_ready_o (dmem_rsp_ready),
    .dmem_rsp_id_i    (dmem_rsp_id),
    .dmem_rsp_rdata_i (dmem_rsp_rdata),
    .dmem_rsp_resp_i  (dmem_rsp_resp),
    .dmem_rsp_replay_i(dmem_rsp_replay),
    .irq_software_i   (msip),
    .irq_timer_i      (mtip),
    .irq_external_i   (meip),
    .mtime_i          (mtime),
    .debug_halt_req_i (1'b0),
    .trace_valid_o,
    .trace_pc_o,
    .trace_instr_o,
    .trace_rd_o,
    .trace_rd_write_o,
    .trace_rd_fp_o,
    .trace_rd_wdata_o,
    .trace_trap_o,
    .trace_cause_o,
    .trace_tval_o
  );

  assign lsu0_bus.req_valid     = dmem_req_valid[0];
  assign lsu0_bus.req_id        = dmem_req_id[0];
  assign lsu0_bus.req_addr      = dmem_req_addr[0];
  assign lsu0_bus.req_write     = dmem_req_write[0];
  assign lsu0_bus.req_size      = dmem_req_size[0];
  assign lsu0_bus.req_wdata     = dmem_req_wdata[0];
  assign lsu0_bus.req_wstrb     = dmem_req_wstrb[0];
  assign lsu0_bus.req_priv      = rv_soc_pkg::privilege_e'(dmem_req_priv[0]);
  assign lsu0_bus.req_rob_seq   = dmem_req_rob_seq[0];
  assign lsu0_bus.req_committed = dmem_req_committed[0];
  assign lsu0_bus.req_device    = dmem_req_device[0];
  assign lsu0_bus.rsp_ready     = dmem_rsp_ready[0];
  assign dmem_req_ready[0]      = lsu0_bus.req_ready;
  assign dmem_rsp_valid[0]      = lsu0_bus.rsp_valid;
  assign dmem_rsp_id[0]         = lsu0_bus.rsp_id;
  assign dmem_rsp_rdata[0]      = lsu0_bus.rsp_rdata;
  assign dmem_rsp_resp[0]       = lsu0_bus.rsp_resp;
  assign dmem_rsp_replay[0]     = lsu0_bus.rsp_replay;

  assign lsu1_bus.req_valid     = dmem_req_valid[1];
  assign lsu1_bus.req_id        = dmem_req_id[1];
  assign lsu1_bus.req_addr      = dmem_req_addr[1];
  assign lsu1_bus.req_write     = dmem_req_write[1];
  assign lsu1_bus.req_size      = dmem_req_size[1];
  assign lsu1_bus.req_wdata     = dmem_req_wdata[1];
  assign lsu1_bus.req_wstrb     = dmem_req_wstrb[1];
  assign lsu1_bus.req_priv      = rv_soc_pkg::privilege_e'(dmem_req_priv[1]);
  assign lsu1_bus.req_rob_seq   = dmem_req_rob_seq[1];
  assign lsu1_bus.req_committed = dmem_req_committed[1];
  assign lsu1_bus.req_device    = dmem_req_device[1];
  assign lsu1_bus.rsp_ready     = dmem_rsp_ready[1];
  assign dmem_req_ready[1]      = lsu1_bus.req_ready;
  assign dmem_rsp_valid[1]      = lsu1_bus.rsp_valid;
  assign dmem_rsp_id[1]         = lsu1_bus.rsp_id;
  assign dmem_rsp_rdata[1]      = lsu1_bus.rsp_rdata;
  assign dmem_rsp_resp[1]       = lsu1_bus.rsp_resp;
  assign dmem_rsp_replay[1]     = lsu1_bus.rsp_replay;

  rv_i_fabric #(
    .BOOTROM_BASE_ADDR (BOOTROM_BASE_ADDR),
    .BOOTROM_SIZE_KB   (BOOTROM_SIZE_KB),
    .BOOTROM_INIT_FILE (BOOTROM_INIT_FILE),
    .ITIM_BASE_ADDR    (ITIM_BASE_ADDR),
    .ITIM_SIZE_KB      (ITIM_SIZE_KB)
  ) u_i_fabric (
    .clk_i,
    .rst_ni,
    .if_req_valid_i (imem_req_valid),
    .if_req_ready_o (imem_req_ready),
    .if_req_addr_i  (imem_req_addr),
    .if_req_id_i    (imem_req_id),
    .if_req_epoch_i (imem_req_epoch),
    .if_rsp_valid_o (imem_rsp_valid),
    .if_rsp_ready_i (imem_rsp_ready),
    .if_rsp_id_o    (imem_rsp_id),
    .if_rsp_epoch_o (imem_rsp_epoch),
    .if_rsp_data_o  (imem_rsp_data),
    .if_rsp_resp_o  (imem_rsp_resp),
    .xbar_in_bus    (i_xbar_local_bus),
    .outbound_bus   (i_outbound_bus)
  );

  rv_d_fabric #(
    .DTIM_BASE_ADDR  (DTIM_BASE_ADDR),
    .DTIM_SIZE_KB    (DTIM_SIZE_KB),
    .CLINT_BASE_ADDR (CLINT_BASE_ADDR),
    .CLINT_SIZE_KB   (CLINT_SIZE_KB),
    .CLOCK_HZ        (CLOCK_HZ),
    .TIMEBASE_HZ     (TIMEBASE_HZ),
    .ROB_SEQ_WIDTH   (ROB_SEQ_WIDTH)
  ) u_d_fabric (
    .clk_i,
    .rst_ni,
    .lsu0_bus     (lsu0_bus),
    .lsu1_bus     (lsu1_bus),
    .xbar_in_bus  (d_xbar_local_bus),
    .outbound_bus (d_outbound_bus),
    .msip_o       (msip),
    .mtip_o       (mtip),
    .mtime_o      (mtime)
  );

  rv_local_to_axi_bridge #(
    .LOCAL_ID_WIDTH (LOCAL_MEM_ID_WIDTH),
    .AXI_ID_WIDTH   (AXI_LOCAL_ID_WIDTH),
    .ROB_SEQ_WIDTH  (ROB_SEQ_WIDTH),
    .IS_INSTRUCTION (1'b1)
  ) u_i_outbound_bridge (
    .clk_i,
    .rst_ni,
    .local_bus (i_outbound_bus),
    .axi_m     (i_master_axi)
  );

  rv_local_to_axi_bridge #(
    .LOCAL_ID_WIDTH (LOCAL_MEM_ID_WIDTH),
    .AXI_ID_WIDTH   (AXI_LOCAL_ID_WIDTH),
    .ROB_SEQ_WIDTH  (ROB_SEQ_WIDTH),
    .IS_INSTRUCTION (1'b0)
  ) u_d_outbound_bridge (
    .clk_i,
    .rst_ni,
    .local_bus (d_outbound_bus),
    .axi_m     (d_master_axi)
  );

  rv_axi_xbar #(
    .LOCAL_ID_WIDTH    (AXI_LOCAL_ID_WIDTH),
    .XBAR_ID_WIDTH     (AXI_XBAR_ID_WIDTH),
    .BOOTROM_BASE_ADDR (BOOTROM_BASE_ADDR),
    .BOOTROM_SIZE_KB   (BOOTROM_SIZE_KB),
    .CLINT_BASE_ADDR   (CLINT_BASE_ADDR),
    .CLINT_SIZE_KB     (CLINT_SIZE_KB),
    .PLIC_BASE_ADDR    (PLIC_BASE_ADDR),
    .PLIC_SIZE_KB      (PLIC_SIZE_KB),
    .HOSTIF_BASE_ADDR  (HOSTIF_BASE_ADDR),
    .HOSTIF_SIZE_KB    (HOSTIF_SIZE_KB),
    .ITIM_BASE_ADDR    (ITIM_BASE_ADDR),
    .ITIM_SIZE_KB      (ITIM_SIZE_KB),
    .DTIM_BASE_ADDR    (DTIM_BASE_ADDR),
    .DTIM_SIZE_KB      (DTIM_SIZE_KB)
  ) u_main_xbar (
    .clk_i,
    .rst_ni,
    .m0_s (i_master_axi),
    .m1_s (d_master_axi),
    .m2_s (host_axi_s),
    .s0_m (i_target_axi),
    .s1_m (d_target_axi),
    .s2_m (plic_target_axi),
    .s3_m (hostif_target_axi),
    .s4_m (reserved_error_axi),
    .s5_m (default_error_axi)
  );

  rv_axi_to_local_bridge #(
    .AXI_ID_WIDTH            (AXI_XBAR_ID_WIDTH),
    .LOCAL_ID_WIDTH          (LOCAL_MEM_ID_WIDTH),
    .ROB_SEQ_WIDTH           (ROB_SEQ_WIDTH),
    .TARGET_BASE_ADDR        (ITIM_BASE_ADDR),
    .TARGET_SIZE_KB          (ITIM_SIZE_KB),
    .TARGET_IS_DEVICE        (1'b0),
    .SECOND_TARGET_ENABLE    (1'b1),
    .SECOND_TARGET_BASE_ADDR (BOOTROM_BASE_ADDR),
    .SECOND_TARGET_SIZE_KB   (BOOTROM_SIZE_KB),
    .SECOND_TARGET_IS_DEVICE (1'b0),
    .MAX_BURST_BEATS         (16)
  ) u_i_inbound_bridge (
    .clk_i,
    .rst_ni,
    .axi_s     (i_target_axi),
    .local_bus (i_xbar_local_bus)
  );

  rv_axi_to_local_bridge #(
    .AXI_ID_WIDTH           (AXI_XBAR_ID_WIDTH),
    .LOCAL_ID_WIDTH         (LOCAL_MEM_ID_WIDTH),
    .ROB_SEQ_WIDTH          (ROB_SEQ_WIDTH),
    .TARGET_BASE_ADDR       (DTIM_BASE_ADDR),
    .TARGET_SIZE_KB         (DTIM_SIZE_KB),
    .TARGET_IS_DEVICE       (1'b0),
    .SECOND_TARGET_ENABLE   (1'b1),
    .SECOND_TARGET_BASE_ADDR(CLINT_BASE_ADDR),
    .SECOND_TARGET_SIZE_KB  (CLINT_SIZE_KB),
    .SECOND_TARGET_IS_DEVICE(1'b1),
    .MAX_BURST_BEATS        (16)
  ) u_d_inbound_bridge (
    .clk_i,
    .rst_ni,
    .axi_s     (d_target_axi),
    .local_bus (d_xbar_local_bus)
  );

  rv_plic #(
    .BASE_ADDR    (PLIC_BASE_ADDR),
    .SIZE_KB      (PLIC_SIZE_KB),
    .NUM_SOURCES  (PLIC_NUM_SOURCES),
    .HAS_SMODE    (HAS_SMODE),
    .AXI_ID_WIDTH (AXI_XBAR_ID_WIDTH)
  ) u_plic (
    .clk_i,
    .rst_ni,
    .axi_s    (plic_target_axi),
    .source_i (external_irq_i),
    .meip_o   (meip),
    .seip_o   (seip)
  );

  rv_hostif #(
    .BASE_ADDR    (HOSTIF_BASE_ADDR),
    .SIZE_KB      (HOSTIF_SIZE_KB),
    .AXI_ID_WIDTH (AXI_XBAR_ID_WIDTH)
  ) u_hostif (
    .clk_i,
    .rst_ni,
    .axi_s         (hostif_target_axi),
    .boot_entry_o  (host_boot_entry_o),
    .boot_flags_o  (host_boot_flags_o),
    .event_valid_o (host_event_valid_o),
    .event_ready_i (host_event_ready_i),
    .event_kind_o  (host_event_kind_o),
    .event_data_o  (host_event_data_o)
  );

  rv_axi_error_slave #(
    .ID_WIDTH (AXI_XBAR_ID_WIDTH)
  ) u_reserved_error_target (
    .clk_i,
    .rst_ni,
    .axi_s (reserved_error_axi)
  );

  rv_axi_error_slave #(
    .ID_WIDTH (AXI_XBAR_ID_WIDTH)
  ) u_default_error_target (
    .clk_i,
    .rst_ni,
    .axi_s (default_error_axi)
  );

  assign soc_ready_o = rst_ni;

`ifndef SYNTHESIS
  property p_ready_only_out_of_reset;
    @(posedge clk_i) soc_ready_o |-> rst_ni;
  endproperty
  assert property (p_ready_only_out_of_reset);
`endif

  initial begin : p_top_parameter_checks
    if (AXI_XBAR_ID_WIDTH < (AXI_LOCAL_ID_WIDTH + 2))
      $fatal(1, "AXI_XBAR_ID_WIDTH must include the two-bit master prefix");
  end

endmodule
