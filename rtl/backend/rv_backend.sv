module rv_backend #(
  parameter int unsigned XLEN            = 32,
  parameter int unsigned PADDR_WIDTH     = 32,
  parameter int unsigned MEM_DATA_WIDTH  = 64,
  parameter int unsigned ROB_ENTRIES     = 48,
  parameter int unsigned ROB_SEQ_WIDTH   = rv_ooo_pkg::ROB_SEQ_WIDTH,
  parameter int unsigned INT_PHYS_REGS   = 80,
  parameter int unsigned FP_PHYS_REGS    = 80,
  parameter int unsigned INT_IQ_ENTRIES  = 24,
  parameter int unsigned MEM_IQ_ENTRIES  = 16,
  parameter int unsigned FP_IQ_ENTRIES   = 16,
  parameter int unsigned LQ_ENTRIES      = 24,
  parameter int unsigned SQ_ENTRIES      = 16,
  parameter int unsigned STORE_BUFFER_ENTRIES = 16,
  parameter int unsigned BR_CHECKPOINTS  = 8
) (
  input  logic                                  clk_i,
  input  logic                                  rst_ni,

  input  logic [1:0]                            fetch_valid_i,
  output logic [1:0]                            fetch_ready_o,
  input  logic [1:0][XLEN-1:0]                  fetch_pc_i,
  input  logic [1:0][31:0]                      fetch_instr_i,
  input  rv_ooo_pkg::inst_len_e [1:0]           fetch_inst_len_i,
  input  rv_ooo_pkg::prediction_meta_t [1:0]    fetch_prediction_i,
  input  logic [1:0]                            fetch_fault_i,

  output logic                                  redirect_valid_o,
  output logic [XLEN-1:0]                       redirect_pc_o,

  output logic [1:0]                            dmem_req_valid_o,
  input  logic [1:0]                            dmem_req_ready_i,
  output logic [1:0][5:0]                       dmem_req_id_o,
  output logic [1:0]                            dmem_req_write_o,
  output logic [1:0][PADDR_WIDTH-1:0]           dmem_req_addr_o,
  output logic [1:0][2:0]                       dmem_req_size_o,
  output logic [1:0][MEM_DATA_WIDTH-1:0]        dmem_req_wdata_o,
  output logic [1:0][MEM_DATA_WIDTH/8-1:0]      dmem_req_wstrb_o,
  output logic [1:0][1:0]                       dmem_req_priv_o,
  output logic [1:0][ROB_SEQ_WIDTH-1:0]         dmem_req_rob_seq_o,
  output logic [1:0]                            dmem_req_committed_o,
  output logic [1:0]                            dmem_req_device_o,
  input  logic [1:0]                            dmem_rsp_valid_i,
  output logic [1:0]                            dmem_rsp_ready_o,
  input  logic [1:0][5:0]                       dmem_rsp_id_i,
  input  logic [1:0][MEM_DATA_WIDTH-1:0]        dmem_rsp_rdata_i,
  input  logic [1:0][1:0]                       dmem_rsp_resp_i,
  input  logic [1:0][2:0]                       dmem_rsp_replay_i,

  input  logic                                  irq_software_i,
  input  logic                                  irq_timer_i,
  input  logic                                  irq_external_i,
  input  logic                                  debug_halt_req_i,

  output logic [1:0]                            trace_valid_o,
  output logic [1:0][XLEN-1:0]                  trace_pc_o,
  output logic [1:0][31:0]                      trace_instr_o,
  output logic [1:0][4:0]                       trace_rd_o,
  output logic [1:0]                            trace_rd_write_o,
  output logic [1:0][XLEN-1:0]                  trace_rd_wdata_o,
  output logic [1:0]                            trace_trap_o
);

  // M0 architecture shell. Decode, rename, ROB, issue, execute, LSU, and
  // commit are introduced in later milestones. No architectural side effect is
  // produced until the commit spine exists.
  always_comb begin
    fetch_ready_o        = 2'b11;
    redirect_valid_o     = 1'b0;
    redirect_pc_o        = '0;
    dmem_req_valid_o     = '0;
    dmem_req_id_o        = '0;
    dmem_req_write_o     = '0;
    dmem_req_addr_o      = '0;
    dmem_req_size_o      = '0;
    dmem_req_wdata_o     = '0;
    dmem_req_wstrb_o     = '0;
    dmem_req_priv_o      = '0;
    dmem_req_rob_seq_o   = '0;
    dmem_req_committed_o = '0;
    dmem_req_device_o    = '0;
    dmem_rsp_ready_o     = '0;
    trace_valid_o        = '0;
    trace_pc_o           = '0;
    trace_instr_o        = '0;
    trace_rd_o           = '0;
    trace_rd_write_o     = '0;
    trace_rd_wdata_o     = '0;
    trace_trap_o         = '0;
  end

  logic unused_inputs;
  always_comb begin
    unused_inputs = clk_i ^ rst_ni ^ (^fetch_valid_i) ^ (^fetch_pc_i) ^
                    (^fetch_instr_i) ^ (^fetch_inst_len_i) ^
                    (^fetch_prediction_i) ^ (^fetch_fault_i) ^
                    (^dmem_req_ready_i) ^ (^dmem_rsp_valid_i) ^
                    (^dmem_rsp_id_i) ^ (^dmem_rsp_rdata_i) ^
                    (^dmem_rsp_resp_i) ^ (^dmem_rsp_replay_i) ^ irq_software_i ^
                    irq_timer_i ^ irq_external_i ^ debug_halt_req_i;
  end

  logic unused_parameters;
  always_comb begin
    unused_parameters = (ROB_ENTRIES == 0) ^ (INT_PHYS_REGS == 0) ^
                        (FP_PHYS_REGS == 0) ^ (INT_IQ_ENTRIES == 0) ^
                        (MEM_IQ_ENTRIES == 0) ^ (FP_IQ_ENTRIES == 0) ^
                        (LQ_ENTRIES == 0) ^ (SQ_ENTRIES == 0) ^
                        (STORE_BUFFER_ENTRIES == 0) ^
                        (BR_CHECKPOINTS == 0) ^ (ROB_SEQ_WIDTH == 0);
  end

endmodule
