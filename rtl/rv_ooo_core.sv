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
  input  logic [63:0]                  mtime_i,
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
  logic                          bp_resolve_valid;
  logic [XLEN-1:0]               bp_resolve_pc, bp_resolve_target;
  logic [31:0]                   bp_resolve_instruction;
  inst_len_e                     bp_resolve_inst_len;
  logic                          bp_resolve_taken, bp_resolve_mispredict;
  prediction_meta_t              bp_resolve_prediction;
  logic [1:0]                    bp_commit_valid, bp_commit_taken;
  logic [1:0][XLEN-1:0]          bp_commit_pc;
  logic [1:0][31:0]              bp_commit_instruction;
  inst_len_e [1:0]               bp_commit_inst_len;
  privilege_e                    current_privilege;
  logic [7:0][7:0]               pmpcfg;
  logic [7:0][PADDR_WIDTH-3:0]   pmpaddr;

  logic                          fe_imem_req_valid, fe_imem_req_ready;
  logic [PADDR_WIDTH-1:0]        fe_imem_req_addr;
  logic [3:0]                    fe_imem_req_id, fe_imem_req_epoch;
  logic                          fe_imem_rsp_valid, fe_imem_rsp_ready;
  logic [3:0]                    fe_imem_rsp_id, fe_imem_rsp_epoch;
  logic [FETCH_BYTES*8-1:0]      fe_imem_rsp_data;
  logic [1:0]                    fe_imem_rsp_resp;
  logic                          ifu_pmp_allow, ifu_pmp_matched;
  logic [PADDR_WIDTH-1:0]        ifu_pmp_fault_address;
  privilege_e [0:0]              ifu_pmp_privilege;
  logic                          ifu_pmp_fault_pending_q;
  logic [3:0]                    ifu_pmp_fault_id_q, ifu_pmp_fault_epoch_q;

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
    .predictor_resolve_valid_i(bp_resolve_valid),
    .predictor_resolve_pc_i(bp_resolve_pc),
    .predictor_resolve_instruction_i(bp_resolve_instruction),
    .predictor_resolve_inst_len_i(bp_resolve_inst_len),
    .predictor_resolve_taken_i(bp_resolve_taken),
    .predictor_resolve_target_i(bp_resolve_target),
    .predictor_resolve_mispredict_i(bp_resolve_mispredict),
    .predictor_resolve_prediction_i(bp_resolve_prediction),
    .predictor_commit_valid_i(bp_commit_valid),
    .predictor_commit_pc_i(bp_commit_pc),
    .predictor_commit_instruction_i(bp_commit_instruction),
    .predictor_commit_inst_len_i(bp_commit_inst_len),
    .predictor_commit_taken_i(bp_commit_taken),
    .fetch_valid_o        (fe_valid),
    .fetch_ready_i        (fe_ready),
    .fetch_pc_o           (fe_pc),
    .fetch_instr_o        (fe_instr),
    .fetch_inst_len_o     (fe_inst_len),
    .fetch_prediction_o   (fe_prediction),
    .fetch_fault_o        (fe_fetch_fault),
    .imem_req_valid_o    (fe_imem_req_valid),
    .imem_req_ready_i    (fe_imem_req_ready),
    .imem_req_addr_o     (fe_imem_req_addr),
    .imem_req_id_o       (fe_imem_req_id),
    .imem_req_epoch_o    (fe_imem_req_epoch),
    .imem_rsp_valid_i    (fe_imem_rsp_valid),
    .imem_rsp_ready_o    (fe_imem_rsp_ready),
    .imem_rsp_id_i       (fe_imem_rsp_id),
    .imem_rsp_epoch_i    (fe_imem_rsp_epoch),
    .imem_rsp_data_i     (fe_imem_rsp_data),
    .imem_rsp_resp_i     (fe_imem_rsp_resp)
  );

  assign ifu_pmp_privilege[0] = current_privilege;
  rv_pmp #(
    .PADDR_WIDTH(PADDR_WIDTH), .PMP_ENTRIES(8), .CHECK_PORTS(1)
  ) u_ifu_pmp (
    .pmpcfg_i(pmpcfg), .pmpaddr_i(pmpaddr),
    .check_valid_i(fe_imem_req_valid), .check_address_i(fe_imem_req_addr),
    .check_size_i(3'($clog2(FETCH_BYTES))), .check_access_i(3'b100),
    .check_privilege_i(ifu_pmp_privilege), .allow_o(ifu_pmp_allow),
    .matched_o(ifu_pmp_matched), .fault_address_o(ifu_pmp_fault_address)
  );

  // A denied fetch is completed locally as an instruction access fault. The
  // frontend still observes its original ID/epoch and therefore applies the
  // same stale-response rules as a memory response after a redirect.
  assign imem_req_valid_o = fe_imem_req_valid && ifu_pmp_allow;
  assign imem_req_addr_o = fe_imem_req_addr;
  assign imem_req_id_o = fe_imem_req_id;
  assign imem_req_epoch_o = fe_imem_req_epoch;
  assign fe_imem_req_ready = ifu_pmp_allow ? imem_req_ready_i :
                             !ifu_pmp_fault_pending_q;
  assign fe_imem_rsp_valid = ifu_pmp_fault_pending_q ? 1'b1 : imem_rsp_valid_i;
  assign fe_imem_rsp_id = ifu_pmp_fault_pending_q ?
                          ifu_pmp_fault_id_q : imem_rsp_id_i;
  assign fe_imem_rsp_epoch = ifu_pmp_fault_pending_q ?
                             ifu_pmp_fault_epoch_q : imem_rsp_epoch_i;
  assign fe_imem_rsp_data = ifu_pmp_fault_pending_q ? '0 : imem_rsp_data_i;
  assign fe_imem_rsp_resp = ifu_pmp_fault_pending_q ? 2'b10 : imem_rsp_resp_i;
  assign imem_rsp_ready_o = !ifu_pmp_fault_pending_q && fe_imem_rsp_ready;

  always_ff @(posedge clk_i) begin
    if (!rst_ni) begin
      ifu_pmp_fault_pending_q <= 1'b0;
      ifu_pmp_fault_id_q <= '0;
      ifu_pmp_fault_epoch_q <= '0;
    end else begin
      if (fe_imem_req_valid && fe_imem_req_ready && !ifu_pmp_allow) begin
        ifu_pmp_fault_pending_q <= 1'b1;
        ifu_pmp_fault_id_q <= fe_imem_req_id;
        ifu_pmp_fault_epoch_q <= fe_imem_req_epoch;
      end
      if (ifu_pmp_fault_pending_q && fe_imem_rsp_ready)
        ifu_pmp_fault_pending_q <= 1'b0;
    end
  end

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
    .RESET_VECTOR    (RESET_VECTOR),
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
    .mtime_i,
    .debug_halt_req_i,
    .trace_valid_o,
    .trace_pc_o,
    .trace_instr_o,
    .trace_rd_o,
    .trace_rd_write_o,
    .trace_rd_wdata_o,
    .trace_trap_o,
    .current_privilege_o (current_privilege),
    .pmpcfg_o            (pmpcfg),
    .pmpaddr_o           (pmpaddr),
    .bp_resolve_valid_o  (bp_resolve_valid),
    .bp_resolve_pc_o     (bp_resolve_pc),
    .bp_resolve_instruction_o(bp_resolve_instruction),
    .bp_resolve_inst_len_o(bp_resolve_inst_len),
    .bp_resolve_taken_o  (bp_resolve_taken),
    .bp_resolve_target_o (bp_resolve_target),
    .bp_resolve_mispredict_o(bp_resolve_mispredict),
    .bp_resolve_prediction_o(bp_resolve_prediction),
    .bp_commit_valid_o   (bp_commit_valid),
    .bp_commit_pc_o      (bp_commit_pc),
    .bp_commit_instruction_o(bp_commit_instruction),
    .bp_commit_inst_len_o(bp_commit_inst_len),
    .bp_commit_taken_o   (bp_commit_taken)
  );

  logic unused_ifu_pmp;
  always_comb unused_ifu_pmp = ifu_pmp_matched ^ (^ifu_pmp_fault_address);

`ifndef SYNTHESIS
  property p_denied_fetch_never_reaches_memory;
    @(posedge clk_i) disable iff (!rst_ni)
      fe_imem_req_valid && !ifu_pmp_allow |-> !imem_req_valid_o;
  endproperty
  assert property (p_denied_fetch_never_reaches_memory);

  property p_pmp_fault_response_keeps_identity;
    @(posedge clk_i) disable iff (!rst_ni)
      ifu_pmp_fault_pending_q && !fe_imem_rsp_ready |=>
        ifu_pmp_fault_pending_q &&
        $stable({ifu_pmp_fault_id_q, ifu_pmp_fault_epoch_q});
  endproperty
  assert property (p_pmp_fault_response_keeps_identity);
`endif

endmodule
