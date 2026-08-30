module rv_ooo_elab_smoke #(
  parameter int unsigned XLEN        = 32,
  parameter int unsigned PADDR_WIDTH = 32
);

  localparam int unsigned FETCH_BYTES = 16;
  localparam int unsigned MEM_DATA_WIDTH = 64;
  localparam int unsigned ROB_SEQ_WIDTH = rv_ooo_pkg::ROB_SEQ_WIDTH;

  logic                         clk;
  logic                         rst_n;
  logic                         imem_req_valid;
  logic                         imem_req_ready;
  logic [PADDR_WIDTH-1:0]       imem_req_addr;
  logic [3:0]                   imem_req_id;
  logic [3:0]                   imem_req_epoch;
  logic                         imem_rsp_valid;
  logic                         imem_rsp_ready;
  logic [3:0]                   imem_rsp_id;
  logic [3:0]                   imem_rsp_epoch;
  logic [FETCH_BYTES*8-1:0]     imem_rsp_data;
  logic [1:0]                   imem_rsp_resp;
  logic [1:0]                   dmem_req_valid;
  logic [1:0]                   dmem_req_ready;
  logic [1:0][5:0]              dmem_req_id;
  logic [1:0]                   dmem_req_write;
  logic [1:0][PADDR_WIDTH-1:0]  dmem_req_addr;
  logic [1:0][2:0]              dmem_req_size;
  logic [1:0][MEM_DATA_WIDTH-1:0] dmem_req_wdata;
  logic [1:0][MEM_DATA_WIDTH/8-1:0] dmem_req_wstrb;
  logic [1:0][1:0]              dmem_req_priv;
  logic [1:0][ROB_SEQ_WIDTH-1:0] dmem_req_rob_seq;
  logic [1:0]                   dmem_req_committed;
  logic [1:0]                   dmem_req_device;
  logic [1:0]                   dmem_rsp_valid;
  logic [1:0]                   dmem_rsp_ready;
  logic [1:0][5:0]              dmem_rsp_id;
  logic [1:0][MEM_DATA_WIDTH-1:0] dmem_rsp_rdata;
  logic [1:0][1:0]              dmem_rsp_resp;
  logic [1:0][2:0]              dmem_rsp_replay;
  logic [1:0]                   trace_valid;
  logic [1:0][XLEN-1:0]         trace_pc;
  logic [1:0][31:0]             trace_instr;
  logic [1:0][4:0]              trace_rd;
  logic [1:0]                   trace_rd_write;
  logic [1:0][XLEN-1:0]         trace_rd_wdata;
  logic [1:0]                   trace_trap;

  initial begin
    clk             = 1'b0;
    rst_n           = 1'b0;
    imem_req_ready  = 1'b0;
    imem_rsp_valid  = 1'b0;
    imem_rsp_id     = '0;
    imem_rsp_epoch  = '0;
    imem_rsp_data   = '0;
    imem_rsp_resp   = '0;
    dmem_req_ready  = '0;
    dmem_rsp_valid  = '0;
    dmem_rsp_id     = '0;
    dmem_rsp_rdata  = '0;
    dmem_rsp_resp   = '0;
    dmem_rsp_replay = '0;
  end

  rv_ooo_core #(
    .XLEN        (XLEN),
    .PADDR_WIDTH (PADDR_WIDTH),
    .MEM_DATA_WIDTH (MEM_DATA_WIDTH),
    .FETCH_BYTES (FETCH_BYTES)
  ) u_dut (
    .clk_i                  (clk),
    .rst_ni                 (rst_n),
    .imem_req_valid_o       (imem_req_valid),
    .imem_req_ready_i       (imem_req_ready),
    .imem_req_addr_o        (imem_req_addr),
    .imem_req_id_o          (imem_req_id),
    .imem_req_epoch_o       (imem_req_epoch),
    .imem_rsp_valid_i       (imem_rsp_valid),
    .imem_rsp_ready_o       (imem_rsp_ready),
    .imem_rsp_id_i          (imem_rsp_id),
    .imem_rsp_epoch_i       (imem_rsp_epoch),
    .imem_rsp_data_i        (imem_rsp_data),
    .imem_rsp_resp_i        (imem_rsp_resp),
    .dmem_req_valid_o       (dmem_req_valid),
    .dmem_req_ready_i       (dmem_req_ready),
    .dmem_req_id_o          (dmem_req_id),
    .dmem_req_write_o       (dmem_req_write),
    .dmem_req_addr_o        (dmem_req_addr),
    .dmem_req_size_o        (dmem_req_size),
    .dmem_req_wdata_o       (dmem_req_wdata),
    .dmem_req_wstrb_o       (dmem_req_wstrb),
    .dmem_req_priv_o        (dmem_req_priv),
    .dmem_req_rob_seq_o     (dmem_req_rob_seq),
    .dmem_req_committed_o   (dmem_req_committed),
    .dmem_req_device_o      (dmem_req_device),
    .dmem_rsp_valid_i       (dmem_rsp_valid),
    .dmem_rsp_ready_o       (dmem_rsp_ready),
    .dmem_rsp_id_i          (dmem_rsp_id),
    .dmem_rsp_rdata_i       (dmem_rsp_rdata),
    .dmem_rsp_resp_i        (dmem_rsp_resp),
    .dmem_rsp_replay_i      (dmem_rsp_replay),
    .irq_software_i         (1'b0),
    .irq_timer_i            (1'b0),
    .irq_external_i         (1'b0),
    .mtime_i                (64'b0),
    .debug_halt_req_i       (1'b0),
    .trace_valid_o          (trace_valid),
    .trace_pc_o             (trace_pc),
    .trace_instr_o          (trace_instr),
    .trace_rd_o             (trace_rd),
    .trace_rd_write_o       (trace_rd_write),
    .trace_rd_wdata_o       (trace_rd_wdata),
    .trace_trap_o           (trace_trap)
  );

endmodule

module rv32_default_smoke;
  rv_ooo_elab_smoke #(.XLEN(32), .PADDR_WIDTH(32)) u_smoke ();
endmodule

module rv32_paddr34_smoke;
  rv_ooo_elab_smoke #(.XLEN(32), .PADDR_WIDTH(34)) u_smoke ();
endmodule

module rv64_smoke;
  rv_ooo_elab_smoke #(.XLEN(64), .PADDR_WIDTH(56)) u_smoke ();
endmodule
