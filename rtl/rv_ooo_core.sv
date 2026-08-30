module rv_ooo_core #(
  parameter int unsigned XLEN             = 32,
  parameter int unsigned PADDR_WIDTH      = 32,
  parameter int unsigned MEM_DATA_WIDTH   = 64,
  parameter int unsigned FETCH_BYTES      = 16,
  parameter int unsigned ROB_ENTRIES      = 48,
  parameter int unsigned ROB_SEQ_WIDTH    = rv_ooo_pkg::ROB_SEQ_WIDTH,
  parameter int unsigned INT_PHYS_REGS    = 80,
  parameter int unsigned FP_PHYS_REGS     = 80,
  parameter int unsigned INT_IQ_ENTRIES   = 24,
  parameter int unsigned MEM_IQ_ENTRIES   = 16,
  parameter int unsigned FP_IQ_ENTRIES    = 16,
  parameter int unsigned LQ_ENTRIES       = 24,
  parameter int unsigned SQ_ENTRIES       = 16,
  parameter int unsigned STORE_BUFFER_ENTRIES = 16,
  parameter int unsigned BR_CHECKPOINTS   = 8,
  parameter logic [XLEN-1:0] RESET_VECTOR = 'h8000_0000,
  parameter logic [XLEN-1:0] TRAP_VECTOR  = 'h8000_0000,
  parameter logic [PADDR_WIDTH-1:0] ITIM_BASE_ADDR = 'h8000_0000,
  parameter int unsigned ITIM_SIZE_KB     = 128,
  parameter logic [PADDR_WIDTH-1:0] DTIM_BASE_ADDR = 'h8002_0000,
  parameter int unsigned DTIM_SIZE_KB     = 128
) (
  input  logic                         clk_i,
  input  logic                         rst_ni,

  output logic                         imem_req_valid_o,
  input  logic                         imem_req_ready_i,
  output logic [PADDR_WIDTH-1:0]       imem_req_addr_o,
  output logic [3:0]                   imem_req_id_o,
  output logic [3:0]                   imem_req_epoch_o,
  input  logic                         imem_rsp_valid_i,
  output logic                         imem_rsp_ready_o,
  input  logic [3:0]                   imem_rsp_id_i,
  input  logic [3:0]                   imem_rsp_epoch_i,
  input  logic [FETCH_BYTES*8-1:0]     imem_rsp_data_i,
  input  logic [1:0]                   imem_rsp_resp_i,

  output logic [1:0]                   dmem_req_valid_o,
  input  logic [1:0]                   dmem_req_ready_i,
  output logic [1:0][5:0]              dmem_req_id_o,
  output logic [1:0]                   dmem_req_write_o,
  output logic [1:0][PADDR_WIDTH-1:0]  dmem_req_addr_o,
  output logic [1:0][2:0]              dmem_req_size_o,
  output logic [1:0][MEM_DATA_WIDTH-1:0] dmem_req_wdata_o,
  output logic [1:0][MEM_DATA_WIDTH/8-1:0] dmem_req_wstrb_o,
  output logic [1:0][1:0]              dmem_req_priv_o,
  output logic [1:0][ROB_SEQ_WIDTH-1:0] dmem_req_rob_seq_o,
  output logic [1:0]                   dmem_req_committed_o,
  output logic [1:0]                   dmem_req_device_o,
  input  logic [1:0]                   dmem_rsp_valid_i,
  output logic [1:0]                   dmem_rsp_ready_o,
  input  logic [1:0][5:0]              dmem_rsp_id_i,
  input  logic [1:0][MEM_DATA_WIDTH-1:0] dmem_rsp_rdata_i,
  input  logic [1:0][1:0]              dmem_rsp_resp_i,
  input  logic [1:0][2:0]              dmem_rsp_replay_i,

  input  logic                         irq_software_i,
  input  logic                         irq_timer_i,
  input  logic                         irq_external_i,
  input  logic                         debug_halt_req_i,

  output logic [1:0]                   trace_valid_o,
  output logic [1:0][XLEN-1:0]         trace_pc_o,
  output logic [1:0][31:0]             trace_instr_o,
  output logic [1:0][4:0]              trace_rd_o,
  output logic [1:0]                   trace_rd_write_o,
  output logic [1:0][XLEN-1:0]         trace_rd_wdata_o,
  output logic [1:0]                   trace_trap_o
);

  import rv_ooo_pkg::*;

  logic [1:0]                    fe_valid;
  logic [1:0]                    fe_ready;
  logic [1:0][XLEN-1:0]          fe_pc;
  logic [1:0][31:0]              fe_instr;
  inst_len_e [1:0]               fe_inst_len;
  prediction_meta_t [1:0]        fe_prediction;
  logic [1:0]                    fe_fetch_fault;

  logic                          redirect_valid;
  logic [XLEN-1:0]               redirect_pc;

  initial begin : p_parameter_checks
    if (!is_supported_xlen(XLEN))
      $fatal(1, "XLEN must be 32 or 64");
    if ((FETCH_BYTES < 8) || ((FETCH_BYTES & (FETCH_BYTES-1)) != 0))
      $fatal(1, "FETCH_BYTES must be a power of two and at least 8");
    if (PADDR_WIDTH == 0)
      $fatal(1, "PADDR_WIDTH must be greater than zero");
    if ((MEM_DATA_WIDTH < XLEN) || ((MEM_DATA_WIDTH % 8) != 0))
      $fatal(1, "MEM_DATA_WIDTH must cover XLEN and contain whole bytes");
    if (ROB_ENTRIES < 8)
      $fatal(1, "ROB_ENTRIES is too small for the baseline pipeline");
    if (ROB_ENTRIES >= (1 << (ROB_SEQ_WIDTH-1)))
      $fatal(1, "ROB_ENTRIES must be less than half the ROB sequence space");
    if (INT_PHYS_REGS < ARCH_INT_REGS)
      $fatal(1, "INT_PHYS_REGS must cover all architectural registers");
    if (FP_PHYS_REGS < ARCH_FP_REGS)
      $fatal(1, "FP_PHYS_REGS must cover all architectural registers");
    if ((INT_IQ_ENTRIES == 0) || (MEM_IQ_ENTRIES == 0) || (FP_IQ_ENTRIES == 0))
      $fatal(1, "Issue queues must contain at least one entry");
    if ((LQ_ENTRIES == 0) || (SQ_ENTRIES == 0) ||
        (STORE_BUFFER_ENTRIES == 0) || (BR_CHECKPOINTS == 0))
      $fatal(1, "LQ, SQ, store buffer, and branch checkpoints cannot be empty");
  end

  rv_frontend #(
    .XLEN         (XLEN),
    .PADDR_WIDTH  (PADDR_WIDTH),
    .FETCH_BYTES  (FETCH_BYTES),
    .RESET_VECTOR (RESET_VECTOR)
  ) u_frontend (
    .clk_i,
    .rst_ni,
    .redirect_valid_i     (redirect_valid),
    .redirect_pc_i        (redirect_pc),
    .fetch_valid_o        (fe_valid),
    .fetch_ready_i        (fe_ready),
    .fetch_pc_o           (fe_pc),
    .fetch_instr_o        (fe_instr),
    .fetch_inst_len_o     (fe_inst_len),
    .fetch_prediction_o   (fe_prediction),
    .fetch_fault_o        (fe_fetch_fault),
    .imem_req_valid_o,
    .imem_req_ready_i,
    .imem_req_addr_o,
    .imem_req_id_o,
    .imem_req_epoch_o,
    .imem_rsp_valid_i,
    .imem_rsp_ready_o,
    .imem_rsp_id_i,
    .imem_rsp_epoch_i,
    .imem_rsp_data_i,
    .imem_rsp_resp_i
  );

  rv_backend #(
    .XLEN            (XLEN),
    .PADDR_WIDTH     (PADDR_WIDTH),
    .MEM_DATA_WIDTH  (MEM_DATA_WIDTH),
    .ROB_ENTRIES     (ROB_ENTRIES),
    .ROB_SEQ_WIDTH   (ROB_SEQ_WIDTH),
    .INT_PHYS_REGS   (INT_PHYS_REGS),
    .FP_PHYS_REGS    (FP_PHYS_REGS),
    .INT_IQ_ENTRIES  (INT_IQ_ENTRIES),
    .MEM_IQ_ENTRIES  (MEM_IQ_ENTRIES),
    .FP_IQ_ENTRIES   (FP_IQ_ENTRIES),
    .LQ_ENTRIES      (LQ_ENTRIES),
    .SQ_ENTRIES      (SQ_ENTRIES),
    .STORE_BUFFER_ENTRIES (STORE_BUFFER_ENTRIES),
    .BR_CHECKPOINTS  (BR_CHECKPOINTS),
    .ITIM_BASE_ADDR  (ITIM_BASE_ADDR),
    .ITIM_SIZE_KB    (ITIM_SIZE_KB),
    .DTIM_BASE_ADDR  (DTIM_BASE_ADDR),
    .DTIM_SIZE_KB    (DTIM_SIZE_KB),
    .TRAP_VECTOR     (TRAP_VECTOR)
  ) u_backend (
    .clk_i,
    .rst_ni,
    .fetch_valid_i       (fe_valid),
    .fetch_ready_o       (fe_ready),
    .fetch_pc_i          (fe_pc),
    .fetch_instr_i       (fe_instr),
    .fetch_inst_len_i    (fe_inst_len),
    .fetch_prediction_i  (fe_prediction),
    .fetch_fault_i       (fe_fetch_fault),
    .redirect_valid_o    (redirect_valid),
    .redirect_pc_o       (redirect_pc),
    .dmem_req_valid_o,
    .dmem_req_ready_i,
    .dmem_req_id_o,
    .dmem_req_write_o,
    .dmem_req_addr_o,
    .dmem_req_size_o,
    .dmem_req_wdata_o,
    .dmem_req_wstrb_o,
    .dmem_req_priv_o,
    .dmem_req_rob_seq_o,
    .dmem_req_committed_o,
    .dmem_req_device_o,
    .dmem_rsp_valid_i,
    .dmem_rsp_ready_o,
    .dmem_rsp_id_i,
    .dmem_rsp_rdata_i,
    .dmem_rsp_resp_i,
    .dmem_rsp_replay_i,
    .irq_software_i,
    .irq_timer_i,
    .irq_external_i,
    .debug_halt_req_i,
    .trace_valid_o,
    .trace_pc_o,
    .trace_instr_o,
    .trace_rd_o,
    .trace_rd_write_o,
    .trace_rd_wdata_o,
    .trace_trap_o
  );

endmodule
