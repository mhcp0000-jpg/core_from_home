module rv_backend #(
  parameter bit AGU_LOAD_BYPASS = rv_ooo_pkg::CORE_CFG_AGU_LOAD_BYPASS,
  parameter bit EARLY_LOAD_SELECT = rv_ooo_pkg::CORE_CFG_EARLY_LOAD_SELECT,
  parameter bit COMPATIBLE_PAIR_SELECT = rv_ooo_pkg::CORE_CFG_COMPATIBLE_PAIR_SELECT,
  // Central default profile; explicit top/instance overrides still win.
  parameter bit BRANCH_TAG_PIPELINE = rv_ooo_pkg::CORE_CFG_BRANCH_TAG_PIPELINE,
  // Optional DIV-only raw-tag boundary; leaves normal ALU/load latency alone.
  parameter bit DIV_TAG_PIPELINE = rv_ooo_pkg::CORE_CFG_DIV_TAG_PIPELINE,
  parameter bit INT_ISSUE_PIPELINE = rv_ooo_pkg::CORE_CFG_INT_ISSUE_PIPELINE,
  parameter int unsigned XLEN = 32,
  parameter int unsigned PADDR_WIDTH = 32,
  parameter int unsigned MEM_DATA_WIDTH = 64,
  parameter bit HAS_C = 1'b1,
  parameter bit HAS_F = 1'b1,
  parameter bit HAS_SMODE = 1'b0,
  parameter int unsigned ROB_ENTRIES = 48,
  parameter int unsigned ROB_SEQ_WIDTH = rv_ooo_pkg::ROB_SEQ_WIDTH,
  parameter int unsigned INT_PHYS_REGS = 80,
  parameter int unsigned FP_PHYS_REGS = 80,
  parameter int unsigned INT_IQ_ENTRIES = 24,
  parameter int unsigned MEM_IQ_ENTRIES = 16,
  parameter int unsigned FP_IQ_ENTRIES = 16,
  parameter int unsigned LQ_ENTRIES = 24,
  parameter int unsigned SQ_ENTRIES = 16,
  parameter int unsigned STORE_BUFFER_ENTRIES = 16,
  parameter int unsigned BR_CHECKPOINTS = rv_ooo_pkg::CORE_CFG_BR_CHECKPOINTS,
  parameter logic [PADDR_WIDTH-1:0] ITIM_BASE_ADDR = 'h8000_0000,
  parameter int unsigned ITIM_SIZE_KB = 128,
  parameter logic [PADDR_WIDTH-1:0] DTIM_BASE_ADDR = 'h8002_0000,
  parameter int unsigned DTIM_SIZE_KB = 128,
  parameter logic [XLEN-1:0] RESET_VECTOR = 'h0000_1000,
  parameter logic [XLEN-1:0] TRAP_VECTOR = 'h8000_0000
) (
  input logic clk_i, input logic rst_ni,
  input logic [1:0] fetch_valid_i, output logic [1:0] fetch_ready_o,
  input logic [1:0][XLEN-1:0] fetch_pc_i,
  input logic [1:0][31:0] fetch_instr_i,
  input rv_ooo_pkg::inst_len_e [1:0] fetch_inst_len_i,
  input rv_ooo_pkg::prediction_meta_t [1:0] fetch_prediction_i,
  input logic [1:0] fetch_fault_i,
  output logic redirect_valid_o, output logic [XLEN-1:0] redirect_pc_o,
  output logic [1:0] dmem_req_valid_o, input logic [1:0] dmem_req_ready_i,
  output logic [1:0][5:0] dmem_req_id_o,
  output logic [1:0] dmem_req_write_o,
  output logic [1:0][PADDR_WIDTH-1:0] dmem_req_addr_o,
  output logic [1:0][2:0] dmem_req_size_o,
  output logic [1:0][MEM_DATA_WIDTH-1:0] dmem_req_wdata_o,
  output logic [1:0][MEM_DATA_WIDTH/8-1:0] dmem_req_wstrb_o,
  output logic [1:0][1:0] dmem_req_priv_o,
  output logic [1:0][ROB_SEQ_WIDTH-1:0] dmem_req_rob_seq_o,
  output logic [1:0] dmem_req_committed_o,
  output logic [1:0] dmem_req_device_o,
  input logic [1:0] dmem_rsp_valid_i, output logic [1:0] dmem_rsp_ready_o,
  input logic [1:0][5:0] dmem_rsp_id_i,
  input logic [1:0][MEM_DATA_WIDTH-1:0] dmem_rsp_rdata_i,
  input logic [1:0][1:0] dmem_rsp_resp_i,
  input logic [1:0][2:0] dmem_rsp_replay_i,
  input logic irq_software_i, input logic irq_timer_i,
  input logic irq_external_i, input logic debug_halt_req_i,
  input logic [63:0] mtime_i,
  output logic [1:0] trace_valid_o,
  output logic [1:0][XLEN-1:0] trace_pc_o,
  output logic [1:0][31:0] trace_instr_o,
  output logic [1:0][4:0] trace_rd_o,
  output logic [1:0] trace_rd_write_o,
  output logic [1:0] trace_rd_fp_o,
  output logic [1:0][XLEN-1:0] trace_rd_wdata_o,
  output logic [1:0] trace_trap_o,
  output logic [1:0][5:0] trace_cause_o,
  output logic [1:0][XLEN-1:0] trace_tval_o,
  output rv_ooo_pkg::privilege_e current_privilege_o,
  output logic [7:0][7:0] pmpcfg_o,
  output logic [7:0][PADDR_WIDTH-3:0] pmpaddr_o,
  output logic bp_resolve_valid_o,
  output logic [XLEN-1:0] bp_resolve_pc_o,
  output logic [31:0] bp_resolve_instruction_o,
  output rv_ooo_pkg::inst_len_e bp_resolve_inst_len_o,
  output logic bp_resolve_taken_o,
  output logic [XLEN-1:0] bp_resolve_target_o,
  output logic bp_resolve_mispredict_o,
  output rv_ooo_pkg::prediction_meta_t bp_resolve_prediction_o,
  output logic [1:0] bp_commit_valid_o,
  output logic [1:0][XLEN-1:0] bp_commit_pc_o,
  output logic [1:0][31:0] bp_commit_instruction_o,
  output rv_ooo_pkg::inst_len_e [1:0] bp_commit_inst_len_o,
  output logic [1:0] bp_commit_taken_o
);
  import rv_ooo_pkg::*;

  localparam int unsigned PHYS_TAG_WIDTH =
    $clog2((INT_PHYS_REGS > FP_PHYS_REGS) ? INT_PHYS_REGS : FP_PHYS_REGS);
  localparam int unsigned CP_WIDTH = $clog2(BR_CHECKPOINTS);
  localparam int unsigned IQ_ENTRIES = INT_IQ_ENTRIES + MEM_IQ_ENTRIES +
                                       FP_IQ_ENTRIES;
  localparam int unsigned IQ_COUNT_WIDTH = $clog2(IQ_ENTRIES + 1);
  localparam int unsigned ROB_COUNT_WIDTH = $clog2(ROB_ENTRIES + 1);
  localparam int unsigned LQ_WIDTH = $clog2(LQ_ENTRIES);
  localparam int unsigned SQ_WIDTH = $clog2(SQ_ENTRIES);
  localparam int unsigned WB_SOURCES = 11;
  localparam int unsigned WB_PORTS = 4;
  localparam int unsigned EXEC_PORTS = 5;
  localparam int unsigned SEQ_SPACE = 1 << ROB_SEQ_WIDTH;
  localparam logic [15:0] SYS_ECALL = 16'h0100;
  localparam logic [15:0] SYS_MRET  = 16'h0102;
  localparam logic [15:0] SYS_WFI   = 16'h0104;

  function automatic logic sequence_after_backend(
    input logic [ROB_SEQ_WIDTH-1:0] lhs,
    input logic [ROB_SEQ_WIDTH-1:0] rhs
  );
    logic signed [ROB_SEQ_WIDTH-1:0] difference;
    difference = $signed(lhs-rhs);
    return difference > 0;
  endfunction

  // Decode contract.
  logic [1:0] dec_ready, dec_valid;  // dec_* = registered dispatch-stage bundle
  logic [1:0][XLEN-1:0] dec_pc, dec_immediate, dec_exception_tval;
  logic [1:0][31:0] dec_raw, dec_instruction;
  inst_len_e [1:0] dec_len;
  prediction_meta_t [1:0] dec_prediction;
  fu_class_e [1:0] dec_fu;
  logic [1:0][15:0] dec_operation;
  logic [1:0][4:0] dec_port_mask;
  reg_class_e [1:0][2:0] dec_src_class;
  logic [1:0][2:0][4:0] dec_src_arch;
  logic [1:0][2:0] dec_src_used;
  reg_class_e [1:0] dec_dst_class;
  logic [1:0][4:0] dec_dst_arch;
  logic [1:0] dec_writes_dst;
  logic [1:0][2:0] dec_mem_size, dec_rounding_mode;
  logic [1:0] dec_mem_unsigned, dec_use_pc, dec_use_immediate;
  logic [1:0] dec_word_operation, dec_is_load, dec_is_store, dec_is_branch;
  logic [1:0] dec_is_csr, dec_is_fence, dec_is_fence_i, dec_serializing;
  logic [1:0] dec_exception_valid;
  exception_code_e [1:0] dec_exception_cause;
  logic [1:0][11:0] dec_csr_addr;
  logic [1:0] dec_csr_immediate;
  logic [1:0][3:0] dec_fence_predecessor, dec_fence_successor;
  logic [XLEN-1:0] csr_mstatus;

  // Raw decoder outputs (before the decode->dispatch uop register).
  logic [1:0] dd_valid;
  logic [1:0][XLEN-1:0] dd_pc;
  logic [1:0][31:0] dd_raw;
  logic [1:0][31:0] dd_instruction;
  inst_len_e [1:0] dd_len;
  prediction_meta_t [1:0] dd_prediction;
  fu_class_e [1:0] dd_fu;
  logic [1:0][15:0] dd_operation;
  logic [1:0][4:0] dd_port_mask;
  reg_class_e [1:0][2:0] dd_src_class;
  logic [1:0][2:0][4:0] dd_src_arch;
  logic [1:0][2:0] dd_src_used;
  reg_class_e [1:0] dd_dst_class;
  logic [1:0][4:0] dd_dst_arch;
  logic [1:0] dd_writes_dst;
  logic [1:0][XLEN-1:0] dd_immediate;
  logic [1:0][2:0] dd_mem_size;
  logic [1:0] dd_mem_unsigned;
  logic [1:0][11:0] dd_csr_addr;
  logic [1:0][2:0] dd_rounding_mode;
  logic [1:0][3:0] dd_fence_predecessor;
  logic [1:0][3:0] dd_fence_successor;
  logic [1:0] dd_use_pc;
  logic [1:0] dd_use_immediate;
  logic [1:0] dd_word_operation;
  logic [1:0] dd_csr_immediate;
  logic [1:0] dd_is_load;
  logic [1:0] dd_is_store;
  logic [1:0] dd_is_branch;
  logic [1:0] dd_is_csr;
  logic [1:0] dd_is_fence;
  logic [1:0] dd_is_fence_i;
  logic [1:0] dd_serializing;
  logic [1:0] dd_exception_valid;
  exception_code_e [1:0] dd_exception_cause;
  logic [1:0][XLEN-1:0] dd_exception_tval;
  typedef struct packed {
    logic [XLEN-1:0] pc;
    logic [31:0] raw;
    logic [31:0] instruction;
    inst_len_e len;
    prediction_meta_t prediction;
    fu_class_e fu;
    logic [15:0] operation;
    logic [4:0] port_mask;
    reg_class_e [2:0] src_class;
    logic [2:0][4:0] src_arch;
    logic [2:0] src_used;
    reg_class_e dst_class;
    logic [4:0] dst_arch;
    logic writes_dst;
    logic [XLEN-1:0] immediate;
    logic [2:0] mem_size;
    logic mem_unsigned;
    logic [11:0] csr_addr;
    logic [2:0] rounding_mode;
    logic [3:0] fence_predecessor;
    logic [3:0] fence_successor;
    logic use_pc;
    logic use_immediate;
    logic word_operation;
    logic csr_immediate;
    logic is_load;
    logic is_store;
    logic is_branch;
    logic is_csr;
    logic is_fence;
    logic is_fence_i;
    logic serializing;
    logic exception_valid;
    exception_code_e exception_cause;
    logic [XLEN-1:0] exception_tval;
  } dec_lane_t;
  // Decode -> dispatch pipeline register (v1.18.8).
  //
  // The decoder is purely combinational, so fetch-queue state previously
  // reached rename, the free lists, ROB/IQ/LSQ allocation and the IQ age
  // matrix in one cycle.  The bundle is now captured here and dispatched from
  // registered fields.
  //   * Occupancy is one bundle; uq_ready = empty || dispatching, so steady
  //     state throughput is unchanged (no bubble).
  //   * Every flush kills the bundle: it has no ROB sequence yet, so it is
  //     younger than every live ROB entry.  flush_valid always coincides with
  //     redirect_valid_o (rv_branch_recovery), so the frontend refetches it.
  //   * Decode-time mstatus.FS: see uq_hold below.  In addition an mstatus
  //     write forces an architectural refetch at retire
  //     (retire_is_decode_state_write) whose flush kills this bundle.
  logic uq_ready;
  logic [1:0] uq_valid_q;
  dec_lane_t [1:0] uq_in, uq_q;
  always_comb begin
    for (int unsigned lane = 0; lane < 2; lane++) begin
      uq_in[lane].pc = dd_pc[lane];
      uq_in[lane].raw = dd_raw[lane];
      uq_in[lane].instruction = dd_instruction[lane];
      uq_in[lane].len = dd_len[lane];
      uq_in[lane].prediction = dd_prediction[lane];
      uq_in[lane].fu = dd_fu[lane];
      uq_in[lane].operation = dd_operation[lane];
      uq_in[lane].port_mask = dd_port_mask[lane];
      uq_in[lane].src_class = dd_src_class[lane];
      uq_in[lane].src_arch = dd_src_arch[lane];
      uq_in[lane].src_used = dd_src_used[lane];
      uq_in[lane].dst_class = dd_dst_class[lane];
      uq_in[lane].dst_arch = dd_dst_arch[lane];
      uq_in[lane].writes_dst = dd_writes_dst[lane];
      uq_in[lane].immediate = dd_immediate[lane];
      uq_in[lane].mem_size = dd_mem_size[lane];
      uq_in[lane].mem_unsigned = dd_mem_unsigned[lane];
      uq_in[lane].csr_addr = dd_csr_addr[lane];
      uq_in[lane].rounding_mode = dd_rounding_mode[lane];
      uq_in[lane].fence_predecessor = dd_fence_predecessor[lane];
      uq_in[lane].fence_successor = dd_fence_successor[lane];
      uq_in[lane].use_pc = dd_use_pc[lane];
      uq_in[lane].use_immediate = dd_use_immediate[lane];
      uq_in[lane].word_operation = dd_word_operation[lane];
      uq_in[lane].csr_immediate = dd_csr_immediate[lane];
      uq_in[lane].is_load = dd_is_load[lane];
      uq_in[lane].is_store = dd_is_store[lane];
      uq_in[lane].is_branch = dd_is_branch[lane];
      uq_in[lane].is_csr = dd_is_csr[lane];
      uq_in[lane].is_fence = dd_is_fence[lane];
      uq_in[lane].is_fence_i = dd_is_fence_i[lane];
      uq_in[lane].serializing = dd_serializing[lane];
      uq_in[lane].exception_valid = dd_exception_valid[lane];
      uq_in[lane].exception_cause = dd_exception_cause[lane];
      uq_in[lane].exception_tval = dd_exception_tval[lane];
    end
  end
  rv_decode2 #(.XLEN(XLEN), .HAS_C(HAS_C), .HAS_F(HAS_F), .HAS_SMODE(HAS_SMODE)) u_decode (
    .in_valid_i(fetch_valid_i), .in_ready_o(fetch_ready_o),
    .in_pc_i(fetch_pc_i), .in_instruction_i(fetch_instr_i),
    .in_inst_len_i(fetch_inst_len_i), .in_prediction_i(fetch_prediction_i),
    .in_fetch_fault_i(fetch_fault_i),
    .fp_state_enabled_i(HAS_F && (csr_mstatus[14:13] != 2'b00)),
    .uop_valid_o(dd_valid),
    .uop_ready_i({2{uq_ready}}), .uop_pc_o(dd_pc),
    .uop_raw_instruction_o(dd_raw),
    .uop_canonical_instruction_o(dd_instruction), .uop_inst_len_o(dd_len),
    .uop_prediction_o(dd_prediction), .uop_fu_o(dd_fu),
    .uop_operation_o(dd_operation), .uop_exec_port_mask_o(dd_port_mask),
    .uop_src_class_o(dd_src_class), .uop_src_arch_o(dd_src_arch),
    .uop_src_used_o(dd_src_used), .uop_dst_class_o(dd_dst_class),
    .uop_dst_arch_o(dd_dst_arch), .uop_writes_dst_o(dd_writes_dst),
    .uop_immediate_o(dd_immediate), .uop_mem_size_o(dd_mem_size),
    .uop_mem_unsigned_o(dd_mem_unsigned), .uop_csr_addr_o(dd_csr_addr),
    .uop_rounding_mode_o(dd_rounding_mode),
    .uop_fence_predecessor_o(dd_fence_predecessor),
    .uop_fence_successor_o(dd_fence_successor), .uop_use_pc_o(dd_use_pc),
    .uop_use_immediate_o(dd_use_immediate),
    .uop_word_operation_o(dd_word_operation),
    .uop_csr_immediate_o(dd_csr_immediate), .uop_is_load_o(dd_is_load),
    .uop_is_store_o(dd_is_store), .uop_is_branch_o(dd_is_branch),
    .uop_is_csr_o(dd_is_csr), .uop_is_fence_o(dd_is_fence),
    .uop_is_fence_i_o(dd_is_fence_i),
    .uop_is_serializing_o(dd_serializing),
    .uop_exception_valid_o(dd_exception_valid),
    .uop_exception_cause_o(dd_exception_cause),
    .uop_exception_tval_o(dd_exception_tval)
  );

  logic [1:0] executable, backend_exception;
  exception_code_e [1:0] backend_exception_cause;
  logic [1:0][XLEN-1:0] backend_exception_tval;
  logic [2:0] dispatch_count, iq_need;
  always_comb begin
    backend_exception = dec_exception_valid;
    backend_exception_cause = dec_exception_cause;
    backend_exception_tval = dec_exception_tval;
    executable = '0;
    for (int unsigned lane = 0; lane < 2; lane++) begin
      executable[lane] = dec_valid[lane] &&
        ((dec_fu[lane] == FU_INT) || (dec_fu[lane] == FU_BRANCH) ||
         (dec_fu[lane] == FU_MUL) || (dec_fu[lane] == FU_DIV) ||
         (dec_fu[lane] == FU_LOAD) || (dec_fu[lane] == FU_STORE) ||
         (dec_fu[lane] == FU_FP));
      // CSR/system/fence operations execute only when they reach the ROB
      // head. All ordinary execution classes, including FP, enter the IQ.
      if (dec_valid[lane] && !dec_exception_valid[lane] &&
          !executable[lane] && (dec_fu[lane] != FU_CSR) &&
          (dec_fu[lane] != FU_FENCE)) begin
        backend_exception[lane] = 1'b1;
        backend_exception_cause[lane] = EXC_ILLEGAL_INSTRUCTION;
        backend_exception_tval[lane] = XLEN'(dec_instruction[lane]);
      end
    end
    dispatch_count = {2'b0, dec_valid[0]} + {2'b0, dec_valid[1]};
    iq_need = {2'b0, executable[0]} + {2'b0, executable[1]};
  end

  // Recovery/retirement signals are declared early because rename owns RRAT.
  logic flush_valid, flush_all;
  logic [ROB_SEQ_WIDTH-1:0] flush_sequence;
  logic cp_restore_valid, cp_release_valid;
  logic [CP_WIDTH-1:0] cp_restore_id, cp_release_id;
  logic [BR_CHECKPOINTS-1:0] cp_clear_mask;
  logic [1:0] retire_valid, retire_ready, retire_fire;
  logic [1:0][ROB_SEQ_WIDTH-1:0] retire_sequence;
  logic [1:0][XLEN-1:0] retire_pc;
  logic [1:0][31:0] retire_instruction;
  logic [1:0][1:0] retire_instruction_length;
  logic [1:0][XLEN-1:0] retire_next_pc;
  logic [1:0] retire_writes_dst, retire_is_store;
  logic [1:0] retire_is_load;
  reg_class_e [1:0] retire_dst_class;
  logic [1:0][4:0] retire_dst_arch;
  logic [1:0][PHYS_TAG_WIDTH-1:0] retire_dst_phys, retire_stale_phys;
  logic [1:0][SQ_WIDTH-1:0] retire_sq_index;
  logic [1:0][LQ_WIDTH-1:0] retire_lq_index;
  logic [1:0][4:0] retire_fflags;
  logic [2:0] csr_frm;
  logic rob_head_valid, rob_head_complete;
  logic [ROB_SEQ_WIDTH-1:0] rob_head_sequence;
  logic [XLEN-1:0] rob_head_pc;
  logic [31:0] rob_head_instruction;
  logic [1:0] rob_head_instruction_length;
  logic rob_head_writes_dst;
  reg_class_e rob_head_dst_class;
  logic [PHYS_TAG_WIDTH-1:0] rob_head_dst_phys, rob_head_src0_phys;
  logic head_is_csr_instruction, head_is_special_instruction;

  // Rename and branch checkpoint allocation.
  logic rename_can_accept, rename_fire;
  logic [1:0][PHYS_TAG_WIDTH-1:0] src0_phys, src1_phys, src2_phys;
  reg_class_e [1:0] rename_src0_class, rename_src1_class,
                        rename_src2_class;
  logic [1:0][4:0] rename_src0_arch, rename_src1_arch, rename_src2_arch;
  logic [1:0] renamed_writes_dst;
  logic [1:0][PHYS_TAG_WIDTH-1:0] renamed_dst_phys, stale_phys;
  logic [BR_CHECKPOINTS-1:0] cp_valid, cp_free_work;
  logic [1:0] cp_save;
  logic [1:0][CP_WIDTH-1:0] cp_save_id;
  logic branch_capacity_ok;
  logic [ROB_SEQ_WIDTH-1:0] cp_sequence_q [0:BR_CHECKPOINTS-1];

  always_comb begin
    for (int unsigned lane = 0; lane < 2; lane++) begin
      rename_src0_class[lane] = dec_src_class[lane][0];
      rename_src1_class[lane] = dec_src_class[lane][1];
      rename_src2_class[lane] = dec_src_class[lane][2];
      rename_src0_arch[lane] = dec_src_arch[lane][0];
      rename_src1_arch[lane] = dec_src_arch[lane][1];
      rename_src2_arch[lane] = dec_src_arch[lane][2];
    end
  end

  always_comb begin
    cp_free_work = ~cp_valid;
    cp_save = '0;
    cp_save_id = '0;
    branch_capacity_ok = 1'b1;
    for (int unsigned lane = 0; lane < 2; lane++) begin
      logic found;
      found = 1'b0;
      if (dec_valid[lane] && dec_is_branch[lane] &&
          !backend_exception[lane]) begin
        cp_save[lane] = 1'b1;
        for (int unsigned checkpoint = 0;
             checkpoint < BR_CHECKPOINTS; checkpoint++) begin
          if (cp_free_work[checkpoint] && !found) begin
            cp_save_id[lane] = CP_WIDTH'(checkpoint);
            cp_free_work[checkpoint] = 1'b0;
            found = 1'b1;
          end
        end
        if (!found) branch_capacity_ok = 1'b0;
      end
    end
  end

  logic [ROB_COUNT_WIDTH-1:0] rob_count;
  logic [IQ_COUNT_WIDTH-1:0] iq_count;
  logic dispatch_resources_ready, dispatch_fire, lsq_dispatch_ready;
  logic [1:0] serial_barrier_valid_q;
  logic [1:0][ROB_SEQ_WIDTH-1:0] serial_barrier_sequence_q;
  logic system_redirect_pending_q, wfi_sleep_q;
  logic csr_interrupt_pending;
  always_comb begin
    dispatch_resources_ready = rename_can_accept && branch_capacity_ok &&
      ((ROB_ENTRIES - $unsigned(rob_count)) >= $unsigned(dispatch_count)) &&
      ((IQ_ENTRIES - $unsigned(iq_count)) >= $unsigned(iq_need)) &&
      lsq_dispatch_ready &&
      !(|serial_barrier_valid_q) && !system_redirect_pending_q &&
      !wfi_sleep_q && !csr_interrupt_pending &&
      !flush_valid && !debug_halt_req_i;
    dec_ready = {2{dispatch_resources_ready}};
    dispatch_fire = dispatch_resources_ready && (|dec_valid);
  end

  // No bundle is decoded while an older serializing operation is still in
  // flight (in this register, behind the barrier, or awaiting its
  // architectural refetch).  Decode therefore observes exactly the
  // post-serialization CSR state it saw when decode and dispatch shared a
  // cycle (mstatus.FS in particular), independent of the refetch.  Costs one
  // cycle after each serializing op, which already drains the ROB.
  logic uq_hold;
  logic uq_split;
  assign uq_split = (&uq_valid_q) && uq_q[0].serializing;
  assign uq_hold = (|serial_barrier_valid_q) || system_redirect_pending_q ||
                   (|(uq_valid_q & dec_serializing));
  assign uq_ready = (!(|uq_valid_q) || dispatch_fire) && !uq_hold;
  always_ff @(posedge clk_i) begin
    if (!rst_ni) begin
      uq_valid_q <= '0;
      uq_q <= '0;
    end else if (flush_valid) begin
      uq_valid_q <= '0;
    end else if (uq_ready) begin
      uq_valid_q <= dd_valid;
      if (|dd_valid) uq_q <= uq_in;
    end else if (dispatch_fire) begin
      // Dispatching a serializing bundle: drain without refilling.  A split
      // bundle (lane0 serializing) keeps its lane1 uop, moved to lane 0.
      if (uq_split) begin
        uq_valid_q <= 2'b01;
        uq_q[0] <= uq_q[1];
      end else begin
        uq_valid_q <= '0;
      end
    end
  end
  always_comb begin
    // Split a bundle whose lane 0 is serializing: lane 1 dispatches only
    // after that barrier retires.  Every dispatched uop is then older than
    // (or is) the live serial barrier, so issue selection never needs the
    // barrier sequence comparison (checked by assertion below).
    dec_valid = uq_split ? 2'b01 : uq_valid_q;
    for (int unsigned lane = 0; lane < 2; lane++) begin
      dec_pc[lane] = uq_q[lane].pc;
      dec_raw[lane] = uq_q[lane].raw;
      dec_instruction[lane] = uq_q[lane].instruction;
      dec_len[lane] = uq_q[lane].len;
      dec_prediction[lane] = uq_q[lane].prediction;
      dec_fu[lane] = uq_q[lane].fu;
      dec_operation[lane] = uq_q[lane].operation;
      dec_port_mask[lane] = uq_q[lane].port_mask;
      dec_src_class[lane] = uq_q[lane].src_class;
      dec_src_arch[lane] = uq_q[lane].src_arch;
      dec_src_used[lane] = uq_q[lane].src_used;
      dec_dst_class[lane] = uq_q[lane].dst_class;
      dec_dst_arch[lane] = uq_q[lane].dst_arch;
      dec_writes_dst[lane] = uq_q[lane].writes_dst;
      dec_immediate[lane] = uq_q[lane].immediate;
      dec_mem_size[lane] = uq_q[lane].mem_size;
      dec_mem_unsigned[lane] = uq_q[lane].mem_unsigned;
      dec_csr_addr[lane] = uq_q[lane].csr_addr;
      dec_rounding_mode[lane] = uq_q[lane].rounding_mode;
      dec_fence_predecessor[lane] = uq_q[lane].fence_predecessor;
      dec_fence_successor[lane] = uq_q[lane].fence_successor;
      dec_use_pc[lane] = uq_q[lane].use_pc;
      dec_use_immediate[lane] = uq_q[lane].use_immediate;
      dec_word_operation[lane] = uq_q[lane].word_operation;
      dec_csr_immediate[lane] = uq_q[lane].csr_immediate;
      dec_is_load[lane] = uq_q[lane].is_load;
      dec_is_store[lane] = uq_q[lane].is_store;
      dec_is_branch[lane] = uq_q[lane].is_branch;
      dec_is_csr[lane] = uq_q[lane].is_csr;
      dec_is_fence[lane] = uq_q[lane].is_fence;
      dec_is_fence_i[lane] = uq_q[lane].is_fence_i;
      dec_serializing[lane] = uq_q[lane].serializing;
      dec_exception_valid[lane] = uq_q[lane].exception_valid;
      dec_exception_cause[lane] = uq_q[lane].exception_cause;
      dec_exception_tval[lane] = uq_q[lane].exception_tval;
    end
  end


  rv_rename2 #(
    .INT_PHYS_REGS(INT_PHYS_REGS), .FP_PHYS_REGS(FP_PHYS_REGS),
    .PHYS_TAG_WIDTH(PHYS_TAG_WIDTH), .BR_CHECKPOINTS(BR_CHECKPOINTS)
  ) u_rename (
    .clk_i, .rst_ni, .rename_valid_i(dec_valid),
    .dispatch_accept_i(dispatch_fire),
    .src0_class_i(rename_src0_class),
    .src1_class_i(rename_src1_class),
    .src2_class_i(rename_src2_class),
    .src0_arch_i(rename_src0_arch),
    .src1_arch_i(rename_src1_arch),
    .src2_arch_i(rename_src2_arch),
    .writes_destination_i(dec_writes_dst),
    .destination_class_i(dec_dst_class), .destination_arch_i(dec_dst_arch),
    .rename_can_accept_o(rename_can_accept), .rename_fire_o(rename_fire),
    .src0_phys_o(src0_phys), .src1_phys_o(src1_phys), .src2_phys_o(src2_phys),
    .writes_destination_o(renamed_writes_dst),
    .destination_phys_o(renamed_dst_phys), .stale_phys_o(stale_phys),
    .commit_valid_i(retire_fire),
    .commit_writes_destination_i(retire_writes_dst),
    .commit_destination_class_i(retire_dst_class),
    .commit_destination_arch_i(retire_dst_arch),
    .commit_destination_phys_i(retire_dst_phys),
    .commit_stale_phys_i(retire_stale_phys),
    .recover_committed_i(flush_valid && flush_all),
    .restore_checkpoint_i(cp_restore_valid),
    .restore_checkpoint_id_i(cp_restore_id), .checkpoint_save_i(cp_save),
    .checkpoint_save_id_i(cp_save_id),
    .checkpoint_release_i(cp_release_valid),
    .checkpoint_release_id_i(cp_release_id),
    .checkpoint_clear_mask_i(cp_clear_mask), .checkpoint_valid_o(cp_valid),
    .int_free_count_o(), .fp_free_count_o()
  );

  // PRFs: three operands for each issue candidate plus two retirement probes.
  // The branch prototype adds two INT read ports AFTER its raw-tag register.
  // Capturing values here instead would leave wake/select/PRF in one cycle.
  typedef struct packed {
    logic [ROB_SEQ_WIDTH-1:0] sequence_id;
    logic [1:0][PHYS_TAG_WIDTH-1:0] src_phys;
    reg_class_e [1:0] src_class;
    branch_op_e operation;
    // INT pipeline mode captures any in-flight forwarding value at issue.
    // A source already in the PRF remains a registered tag/read afterwards.
    // In particular no combinational ALU preview may feed the BRU in execute.
    logic [1:0] read_prf;
    logic [1:0][XLEN-1:0] forwarded_operand;
    logic [XLEN-1:0] pc, immediate;
    inst_len_e inst_len;
    prediction_meta_t prediction;
    logic dst_valid;
    reg_class_e dst_class;
    logic [PHYS_TAG_WIDTH-1:0] dst_phys;
  } branch_issue_t;
  branch_issue_t branch_issue_q;
  logic branch_issue_valid_q;
  logic branch_slot_ready, branch_execute_valid;
  logic [ROB_SEQ_WIDTH-1:0] branch_execute_sequence;
  typedef struct packed {
    logic [ROB_SEQ_WIDTH-1:0] sequence_id;
    logic [1:0][PHYS_TAG_WIDTH-1:0] src_phys;
    reg_class_e [1:0] src_class;
    divide_op_e operation;
    logic word_operation, dst_valid;
    logic [PHYS_TAG_WIDTH-1:0] dst_phys;
  } div_issue_t;
  div_issue_t div_issue_q;
  logic div_issue_valid_q, div_slot_ready, div_execute_valid;
  localparam int unsigned DIV_READ_BASE = 8 + (BRANCH_TAG_PIPELINE ? 2 : 0);
  localparam int unsigned INT_ALU_READ_BASE = DIV_READ_BASE + (DIV_TAG_PIPELINE ? 2 : 0);
  localparam int unsigned INT_READ_PORTS = INT_ALU_READ_BASE + (INT_ISSUE_PIPELINE ? 4 : 0);
  logic [3:0][PHYS_TAG_WIDTH-1:0] int_exec_read_addr;
  logic [7:0][PHYS_TAG_WIDTH-1:0] int_read_addr, fp_read_addr;
  logic [INT_READ_PORTS-1:0][PHYS_TAG_WIDTH-1:0] int_prf_read_addr;
  logic [INT_READ_PORTS-1:0][XLEN-1:0] int_read_data;
  logic [7:0][31:0] fp_read_data;
  logic [INT_READ_PORTS-1:0] int_read_ready;
  logic [7:0] fp_read_ready;
  logic [5:0][PHYS_TAG_WIDTH-1:0] int_query_addr, fp_query_addr;
  logic [5:0] int_query_ready, fp_query_ready;
  logic [1:0] int_wb_valid, fp_wb_valid, int_alloc_valid, fp_alloc_valid;
  logic [1:0][PHYS_TAG_WIDTH-1:0] int_wb_phys, fp_wb_phys;
  logic [1:0][XLEN-1:0] int_wb_data;
  logic [1:0][31:0] fp_wb_data;
  logic [1:0][2:0] dispatch_src_ready;

  assign int_prf_read_addr[7:0] = int_read_addr;
  if(INT_ISSUE_PIPELINE) begin:g_int_exec_read_ports
    assign int_prf_read_addr[INT_ALU_READ_BASE+:4]=int_exec_read_addr;
  end
  if (BRANCH_TAG_PIPELINE) begin : g_branch_read_addresses
    assign int_prf_read_addr[8+:2] = branch_issue_q.src_phys;
  end
  if (DIV_TAG_PIPELINE) begin : g_div_read_addresses
    assign int_prf_read_addr[DIV_READ_BASE+:2] = div_issue_q.src_phys;
  end

  always_comb begin
    for (int unsigned lane = 0; lane < 2; lane++) begin
      int_query_addr[lane*3] = src0_phys[lane];
      int_query_addr[lane*3+1] = src1_phys[lane];
      int_query_addr[lane*3+2] = src2_phys[lane];
      fp_query_addr[lane*3] = src0_phys[lane];
      fp_query_addr[lane*3+1] = src1_phys[lane];
      fp_query_addr[lane*3+2] = src2_phys[lane];
      for (int unsigned source = 0; source < 3; source++) begin
        case (dec_src_class[lane][source])
          REG_INT: dispatch_src_ready[lane][source] =
            int_query_ready[lane*3+source];
          REG_FP: dispatch_src_ready[lane][source] =
            fp_query_ready[lane*3+source];
          default: dispatch_src_ready[lane][source] = 1'b1;
        endcase
      end
      int_alloc_valid[lane] = dispatch_fire && dec_valid[lane] &&
        renamed_writes_dst[lane] && (dec_dst_class[lane] == REG_INT);
      fp_alloc_valid[lane] = dispatch_fire && dec_valid[lane] &&
        renamed_writes_dst[lane] && (dec_dst_class[lane] == REG_FP);
    end
  end

  rv_phys_regfile #(
    .DATA_WIDTH(XLEN), .PHYS_REGS(INT_PHYS_REGS),
    .TAG_WIDTH(PHYS_TAG_WIDTH), .READ_PORTS(INT_READ_PORTS), .QUERY_PORTS(6),
    .WRITE_PORTS(2), .ALLOC_PORTS(2), .INITIAL_MAPPED_REGS(32),
    .ZERO_REGISTER(1'b1), .WRITE_BYPASS(1'b0)
  ) u_int_prf (
    .clk_i, .rst_ni,
    .read_addr_i(int_prf_read_addr),
    .read_data_o(int_read_data),
    .read_ready_o(int_read_ready), .query_addr_i(int_query_addr),
    .query_ready_o(int_query_ready), .write_valid_i(int_wb_valid),
    .write_addr_i(int_wb_phys), .write_data_i(int_wb_data),
    .allocate_valid_i(int_alloc_valid), .allocate_addr_i(renamed_dst_phys),
    .probe_addr_i('0), .probe_ready_o()
  );
  rv_phys_regfile #(
    .DATA_WIDTH(32), .PHYS_REGS(FP_PHYS_REGS), .TAG_WIDTH(PHYS_TAG_WIDTH),
    .READ_PORTS(8), .QUERY_PORTS(6), .WRITE_PORTS(2), .ALLOC_PORTS(2),
    .INITIAL_MAPPED_REGS(32), .ZERO_REGISTER(1'b0), .WRITE_BYPASS(1'b0)
  ) u_fp_prf (
    .clk_i, .rst_ni, .read_addr_i(fp_read_addr), .read_data_o(fp_read_data),
    .read_ready_o(fp_read_ready), .query_addr_i(fp_query_addr),
    .query_ready_o(fp_query_ready), .write_valid_i(fp_wb_valid),
    .write_addr_i(fp_wb_phys), .write_data_i(fp_wb_data),
    .allocate_valid_i(fp_alloc_valid), .allocate_addr_i(renamed_dst_phys),
    .probe_addr_i('0), .probe_ready_o()
  );

  // ROB allocation sequence is the common age key for all backend structures.
  logic rob_alloc_ready;
  logic [1:0][$clog2(ROB_ENTRIES)-1:0] rob_alloc_index;
  logic [1:0][ROB_SEQ_WIDTH-1:0] rob_alloc_sequence;
  logic rob_trap_valid, rob_trap_ready;
  logic [ROB_SEQ_WIDTH-1:0] rob_trap_sequence;
  logic [XLEN-1:0] rob_trap_pc, rob_trap_tval;
  exception_code_e rob_trap_cause;
  logic rob_empty, rob_full;

  // Pack only executable original lanes into the IQ.
  logic [1:0] iq_dispatch_valid;
  logic [1:0][ROB_SEQ_WIDTH-1:0] iq_dispatch_sequence;
  fu_class_e [1:0] iq_dispatch_fu;
  logic [1:0][4:0] iq_dispatch_port_mask;
  logic [1:0][2:0] iq_dispatch_src_used, iq_dispatch_src_ready;
  reg_class_e [1:0][2:0] iq_dispatch_src_class;
  logic [1:0][2:0][PHYS_TAG_WIDTH-1:0] iq_dispatch_src_phys;
  logic [1:0] iq_dispatch_dst_valid;
  reg_class_e [1:0] iq_dispatch_dst_class;
  logic [1:0][PHYS_TAG_WIDTH-1:0] iq_dispatch_dst_phys;
  logic [1:0][XLEN-1:0] iq_dispatch_pc, iq_dispatch_immediate;
  logic [1:0][31:0] iq_dispatch_instruction;
  inst_len_e [1:0] iq_dispatch_len;
  prediction_meta_t [1:0] iq_dispatch_prediction;
  logic [1:0][15:0] iq_dispatch_operation;
  logic [1:0] iq_dispatch_use_pc, iq_dispatch_use_immediate;
  logic [1:0] iq_dispatch_word, iq_dispatch_mem_unsigned;
  logic [1:0][2:0] iq_dispatch_mem_size, iq_dispatch_rounding;
  logic [1:0] iq_dispatch_cp_valid;
  logic [1:0][CP_WIDTH-1:0] iq_dispatch_cp_id;
  logic [1:0][LQ_WIDTH-1:0] iq_dispatch_lq_index;
  logic [1:0][SQ_WIDTH-1:0] iq_dispatch_sq_index;
  logic [1:0] lsq_dispatch_lq_valid, lsq_dispatch_sq_valid;
  logic [1:0][LQ_WIDTH-1:0] lsq_dispatch_lq_index;
  logic [1:0][SQ_WIDTH-1:0] lsq_dispatch_sq_index;
  logic iq_dispatch_ready, iq_empty, iq_full;

  always_comb begin
    iq_dispatch_valid='0; iq_dispatch_sequence='0;
    iq_dispatch_fu='0; iq_dispatch_port_mask='0;
    iq_dispatch_src_used='0; iq_dispatch_src_ready='0;
    iq_dispatch_src_class='0; iq_dispatch_src_phys='0;
    iq_dispatch_dst_valid='0; iq_dispatch_dst_class='0;
    iq_dispatch_dst_phys='0; iq_dispatch_pc='0; iq_dispatch_immediate='0;
    iq_dispatch_instruction='0; iq_dispatch_len='0;
    iq_dispatch_prediction='0; iq_dispatch_operation='0;
    iq_dispatch_use_pc='0; iq_dispatch_use_immediate='0;
    iq_dispatch_word='0; iq_dispatch_mem_unsigned='0;
    iq_dispatch_mem_size='0; iq_dispatch_rounding='0;
    iq_dispatch_cp_valid='0; iq_dispatch_cp_id='0;
    iq_dispatch_lq_index='0; iq_dispatch_sq_index='0;
    begin
      int unsigned packed_lane;
      packed_lane = 0;
      for (int unsigned lane = 0; lane < 2; lane++) begin
        if (dispatch_fire && executable[lane]) begin
          iq_dispatch_valid[packed_lane]=1'b1;
          iq_dispatch_sequence[packed_lane]=rob_alloc_sequence[lane];
          iq_dispatch_fu[packed_lane]=dec_fu[lane];
          iq_dispatch_port_mask[packed_lane]=dec_port_mask[lane];
          iq_dispatch_src_used[packed_lane]=dec_src_used[lane];
          iq_dispatch_src_class[packed_lane]=dec_src_class[lane];
          iq_dispatch_src_phys[packed_lane][0]=src0_phys[lane];
          iq_dispatch_src_phys[packed_lane][1]=src1_phys[lane];
          iq_dispatch_src_phys[packed_lane][2]=src2_phys[lane];
          iq_dispatch_src_ready[packed_lane]=dispatch_src_ready[lane];
          iq_dispatch_dst_valid[packed_lane]=renamed_writes_dst[lane];
          iq_dispatch_dst_class[packed_lane]=dec_dst_class[lane];
          iq_dispatch_dst_phys[packed_lane]=renamed_dst_phys[lane];
          iq_dispatch_pc[packed_lane]=dec_pc[lane];
          iq_dispatch_instruction[packed_lane]=dec_instruction[lane];
          iq_dispatch_len[packed_lane]=dec_len[lane];
          iq_dispatch_prediction[packed_lane]=dec_prediction[lane];
          iq_dispatch_immediate[packed_lane]=dec_immediate[lane];
          iq_dispatch_operation[packed_lane]=dec_operation[lane];
          iq_dispatch_use_pc[packed_lane]=dec_use_pc[lane];
          iq_dispatch_use_immediate[packed_lane]=dec_use_immediate[lane];
          iq_dispatch_word[packed_lane]=dec_word_operation[lane];
          iq_dispatch_mem_size[packed_lane]=dec_mem_size[lane];
          iq_dispatch_mem_unsigned[packed_lane]=dec_mem_unsigned[lane];
          iq_dispatch_rounding[packed_lane]=dec_rounding_mode[lane];
          iq_dispatch_cp_valid[packed_lane]=cp_save[lane];
          iq_dispatch_cp_id[packed_lane]=cp_save_id[lane];
          iq_dispatch_lq_index[packed_lane]=lsq_dispatch_lq_index[lane];
          iq_dispatch_sq_index[packed_lane]=lsq_dispatch_sq_index[lane];
          packed_lane = packed_lane + 1;
        end
      end
    end
  end

  // Candidate metadata from the unified baseline issue window.
  logic [WB_PORTS-1:0] wakeup_valid;
  reg_class_e [WB_PORTS-1:0] wakeup_class;
  logic [WB_PORTS-1:0][PHYS_TAG_WIDTH-1:0] wakeup_phys;

  // ---------------------------------------------------------------------
  // Producer-side wakeup (v1.18.7).
  //
  // Each destination-writing writeback source wakes its consumers directly
  // and, until the writeback arbiter writes the PRF, supplies the value
  // through an operand bypass.  The arbiter is no longer between a producer
  // and its consumer's selection:
  //
  //   before: FU reg -> WB arbiter -> IQ wakeup/select -> PRF -> FU
  //   after : FU reg ------------------> IQ wakeup/select -> PRF|bypass -> FU
  //
  // The wakeup cycle of every source equals the arbiter-granted wakeup it
  // replaces (or is earlier, when the arbiter would have deferred the
  // write), so dependent issue distance is unchanged.
  //
  // Invariant: a source that raises a direct wakeup keeps presenting the same
  // result until the arbiter consumes it.  Sources 2..9 pass through a
  // one-entry skid (below) and the fast result buffers are two-deep, so the
  // invariant holds regardless of how each producer reacts to backpressure,
  // and producer readiness depends only on registered occupancy.
  // Ports 0..6 are the direct sources.  Port 7 is the ROB-head system op
  // (CSR read), woken one cycle after its arbiter grant from a register:
  // its valid is produced by the fence/flush/trap control at the ROB head,
  // and waking directly from it would put that control chain in front of
  // IQ selection.  CSR results are serialized at the head, so the extra
  // cycle is not on any throughput path.
  localparam int unsigned DIRECT_SOURCE_PORTS = 7;
  localparam int unsigned DIRECT_BYPASS_PORTS = DIRECT_SOURCE_PORTS +
                                                (INT_ISSUE_PIPELINE ? 4 : 0);
  localparam int unsigned DIRECT_WAKE_PORTS = DIRECT_BYPASS_PORTS + 1;
  localparam int unsigned DIRECT_WAKE_SOURCE [DIRECT_SOURCE_PORTS] =
    '{0, 1, 2, 3, 4, 7, 8};
  localparam int unsigned SYSTEM_SOURCE = 10;
  logic [DIRECT_WAKE_PORTS-1:0] direct_wake_valid;
  reg_class_e [DIRECT_WAKE_PORTS-1:0] direct_wake_class;
  logic [DIRECT_WAKE_PORTS-1:0][PHYS_TAG_WIDTH-1:0] direct_wake_phys;
  logic [DIRECT_WAKE_PORTS-1:0][XLEN-1:0] direct_wake_data;
  typedef struct packed {
    logic [ROB_SEQ_WIDTH-1:0] sequence_id;
    logic [XLEN-1:0] operand_a,operand_b;
    logic read_prf_a,read_prf_b;
    logic [PHYS_TAG_WIDTH-1:0] src_phys_a,src_phys_b;
    logic [3:0] operation;
    logic word_operation,dst_valid;
    reg_class_e dst_class;
    logic [PHYS_TAG_WIDTH-1:0] dst_phys;
  } int_issue_payload_t;
  int_issue_payload_t [1:0] int_issue_q;
  logic [1:0] int_issue_valid_q,int_issue_ready,int_issue_take;
  for(genvar lane=0;lane<2;lane++) begin:g_int_exec_read_address
    assign int_exec_read_addr[lane*2]=int_issue_q[lane].src_phys_a;
    assign int_exec_read_addr[lane*2+1]=int_issue_q[lane].src_phys_b;
  end
  logic [1:0] cand_valid, cand_accept;
  logic [1:0][ROB_SEQ_WIDTH-1:0] cand_sequence;
  fu_class_e [1:0] cand_fu;
  logic [1:0][(1 << $bits(fu_class_e))-1:0] cand_fu_onehot;
  logic [1:0][4:0] cand_port_mask;
  logic [1:0][2:0][PHYS_TAG_WIDTH-1:0] cand_src_phys;
  reg_class_e [1:0][2:0] cand_src_class;
  logic [1:0] cand_dst_valid;
  reg_class_e [1:0] cand_dst_class;
  logic [1:0][PHYS_TAG_WIDTH-1:0] cand_dst_phys;
  logic [1:0][XLEN-1:0] cand_pc, cand_immediate;
  logic [1:0][31:0] cand_instruction;
  inst_len_e [1:0] cand_len;
  prediction_meta_t [1:0] cand_prediction;
  logic [1:0][15:0] cand_operation;
  logic [1:0] cand_use_pc, cand_use_immediate, cand_word;
  logic [1:0][2:0] cand_mem_size, cand_rounding;
  logic [1:0] cand_mem_unsigned, cand_cp_valid;
  logic [1:0][CP_WIDTH-1:0] cand_cp_id;
  logic [1:0][LQ_WIDTH-1:0] cand_lq_index;
  logic [1:0][SQ_WIDTH-1:0] cand_sq_index;
  logic [1:0] cand_store_address_valid, cand_store_data_valid;

  rv_issue_queue #(
    .COMPATIBLE_PAIR_SELECT(COMPATIBLE_PAIR_SELECT),
    .XLEN(XLEN), .ENTRIES(IQ_ENTRIES), .PHYS_TAG_WIDTH(PHYS_TAG_WIDTH),
    .ROB_SEQ_WIDTH(ROB_SEQ_WIDTH), .WRITEBACK_PORTS(DIRECT_WAKE_PORTS),
    .SELECT_WIDTH(2), .EXEC_PORTS(EXEC_PORTS), .LQ_INDEX_WIDTH(LQ_WIDTH),
    .SQ_INDEX_WIDTH(SQ_WIDTH), .CHECKPOINT_ID_WIDTH(CP_WIDTH)
  ) u_iq (
    .clk_i,.rst_ni,.dispatch_valid_i(iq_dispatch_valid),
    .dispatch_ready_o(iq_dispatch_ready),.dispatch_index_o(),
    .dispatch_sequence_i(iq_dispatch_sequence),.dispatch_fu_i(iq_dispatch_fu),
    .dispatch_port_mask_i(iq_dispatch_port_mask),
    .dispatch_src_used_i(iq_dispatch_src_used),
    .dispatch_src_class_i(iq_dispatch_src_class),
    .dispatch_src_phys_i(iq_dispatch_src_phys),
    .dispatch_src_ready_i(iq_dispatch_src_ready),
    .dispatch_destination_valid_i(iq_dispatch_dst_valid),
    .dispatch_destination_class_i(iq_dispatch_dst_class),
    .dispatch_destination_phys_i(iq_dispatch_dst_phys),
    .dispatch_pc_i(iq_dispatch_pc),.dispatch_instruction_i(iq_dispatch_instruction),
    .dispatch_inst_len_i(iq_dispatch_len),
    .dispatch_prediction_i(iq_dispatch_prediction),
    .dispatch_immediate_i(iq_dispatch_immediate),
    .dispatch_operation_i(iq_dispatch_operation),
    .dispatch_use_pc_i(iq_dispatch_use_pc),
    .dispatch_use_immediate_i(iq_dispatch_use_immediate),
    .dispatch_word_operation_i(iq_dispatch_word),
    .dispatch_mem_size_i(iq_dispatch_mem_size),
    .dispatch_mem_unsigned_i(iq_dispatch_mem_unsigned),
    .dispatch_rounding_mode_i(iq_dispatch_rounding),
    .dispatch_checkpoint_valid_i(iq_dispatch_cp_valid),
    .dispatch_checkpoint_id_i(iq_dispatch_cp_id),
    .dispatch_lq_index_i(iq_dispatch_lq_index),
    .dispatch_sq_index_i(iq_dispatch_sq_index),
    .writeback_valid_i(direct_wake_valid),.writeback_class_i(direct_wake_class),
    .writeback_phys_i(direct_wake_phys),.candidate_valid_o(cand_valid),
    .candidate_accept_i(cand_accept),.candidate_index_o(),
    .candidate_sequence_o(cand_sequence),.candidate_fu_o(cand_fu),
    .candidate_fu_onehot_o(cand_fu_onehot),
    .candidate_port_mask_o(cand_port_mask),.candidate_src_phys_o(cand_src_phys),
    .candidate_src_class_o(cand_src_class),
    .candidate_destination_valid_o(cand_dst_valid),
    .candidate_destination_class_o(cand_dst_class),
    .candidate_destination_phys_o(cand_dst_phys),.candidate_pc_o(cand_pc),
    .candidate_instruction_o(cand_instruction),.candidate_inst_len_o(cand_len),
    .candidate_prediction_o(cand_prediction),
    .candidate_immediate_o(cand_immediate),
    .candidate_operation_o(cand_operation),.candidate_use_pc_o(cand_use_pc),
    .candidate_use_immediate_o(cand_use_immediate),
    .candidate_word_operation_o(cand_word),.candidate_mem_size_o(cand_mem_size),
    .candidate_mem_unsigned_o(cand_mem_unsigned),
    .candidate_rounding_mode_o(cand_rounding),
    .candidate_checkpoint_valid_o(cand_cp_valid),
    .candidate_checkpoint_id_o(cand_cp_id),.candidate_lq_index_o(cand_lq_index),
    .candidate_sq_index_o(cand_sq_index),
    .candidate_store_address_valid_o(cand_store_address_valid),
    .candidate_store_data_valid_o(cand_store_data_valid),
    .flush_all_i(flush_valid&&flush_all),
    .flush_younger_i(flush_valid&&!flush_all),.flush_sequence_i(flush_sequence),
    .count_o(iq_count),.empty_o(iq_empty),.full_o(iq_full)
  );

  // Asynchronous PRF reads for the two candidates.  A value that has woken a
  // consumer but has not yet been written to the PRF comes from the
  // producer's presented result through the direct-wakeup bypass.
  logic [1:0][XLEN-1:0] cand_operand0, cand_operand1, cand_operand2;
  function automatic logic [XLEN-1:0] bypass_or_prf(
    input reg_class_e cls,
    input logic [PHYS_TAG_WIDTH-1:0] tag,
    input logic [XLEN-1:0] int_value,
    input logic [31:0] fp_value
  );
    logic [XLEN-1:0] value;
    logic [XLEN-1:0] forwarded;
    logic hit,match;
    case (cls)
      REG_INT: value = int_value;
      REG_FP:  value = {{(XLEN-32){1'b0}}, fp_value};
      default: value = '0;
    endcase
    // At most one live producer owns a physical tag, so the hits are
    // mutually exclusive and the loop order is irrelevant.
    forwarded='0;hit=1'b0;
    for (int unsigned w = 0; w < DIRECT_BYPASS_PORTS; w++) begin
      match=direct_wake_valid[w] && (direct_wake_class[w] == cls) &&
            (cls != REG_NONE) && (direct_wake_phys[w] == tag);
      hit |= match;
      forwarded |= direct_wake_data[w] & {XLEN{match}};
    end
    return hit ? forwarded : value;
  endfunction
  always_comb begin
    for (int unsigned candidate=0; candidate<2; candidate++) begin
      int_read_addr[candidate*3]=cand_src_phys[candidate][0];
      int_read_addr[candidate*3+1]=cand_src_phys[candidate][1];
      int_read_addr[candidate*3+2]=cand_src_phys[candidate][2];
      fp_read_addr[candidate*3]=cand_src_phys[candidate][0];
      fp_read_addr[candidate*3+1]=cand_src_phys[candidate][1];
      fp_read_addr[candidate*3+2]=cand_src_phys[candidate][2];
      cand_operand0[candidate]=bypass_or_prf(cand_src_class[candidate][0],
        cand_src_phys[candidate][0], int_read_data[candidate*3],
        fp_read_data[candidate*3]);
      cand_operand1[candidate]=bypass_or_prf(cand_src_class[candidate][1],
        cand_src_phys[candidate][1], int_read_data[candidate*3+1],
        fp_read_data[candidate*3+1]);
      cand_operand2[candidate]=bypass_or_prf(cand_src_class[candidate][2],
        cand_src_phys[candidate][2], int_read_data[candidate*3+2],
        fp_read_data[candidate*3+2]);
    end
    int_read_addr[6]=retire_dst_phys[0];
    int_read_addr[7]=head_is_csr_instruction ? rob_head_src0_phys :
                                               retire_dst_phys[1];
    fp_read_addr[6]=retire_dst_phys[0]; fp_read_addr[7]=retire_dst_phys[1];
  end

  // Global issue selection with FU-specific backpressure folded into masks.
  logic [1:0] fast_req_ready, lsu_issue_ready;
  logic mul_req_ready, div_req_ready, fpu_req_ready;
  assign branch_slot_ready = !branch_issue_valid_q || fast_req_ready[0];
  assign div_slot_ready = !div_issue_valid_q || div_req_ready;
  logic [1:0][4:0] effective_mask;
  logic fpu_issue_valid_q;
  logic [ROB_SEQ_WIDTH-1:0] fpu_issue_sequence_q;
  logic [XLEN-1:0] fpu_issue_operand0_q, fpu_issue_operand1_q,
                   fpu_issue_operand2_q;
  logic [31:0] fpu_issue_instruction_q;
  logic [2:0] fpu_issue_rounding_q;
  logic fpu_issue_dst_valid_q;
  reg_class_e fpu_issue_dst_class_q;
  logic [PHYS_TAG_WIDTH-1:0] fpu_issue_dst_phys_q;
  always_comb begin
    effective_mask='0;
    for(int unsigned candidate=0;candidate<2;candidate++) begin
      // Class decode runs from registered IQ entries in parallel with wakeup
      // and age selection, not after selecting/encoding the class payload.
      effective_mask[candidate][0] = cand_port_mask[candidate][0] &&
        ((cand_fu_onehot[candidate][FU_INT] &&
          (INT_ISSUE_PIPELINE ? int_issue_ready[0] :
            (fast_req_ready[0] && (!BRANCH_TAG_PIPELINE || !branch_issue_valid_q)))) ||
         (cand_fu_onehot[candidate][FU_BRANCH] &&
          (BRANCH_TAG_PIPELINE ? branch_slot_ready :
            (fast_req_ready[0] && (!INT_ISSUE_PIPELINE || !int_issue_valid_q[0])))));
      effective_mask[candidate][1] = cand_port_mask[candidate][1] &&
        ((cand_fu_onehot[candidate][FU_INT] &&
          (INT_ISSUE_PIPELINE ? int_issue_ready[1] : fast_req_ready[1])) ||
         (cand_fu_onehot[candidate][FU_MUL] && mul_req_ready) ||
         (cand_fu_onehot[candidate][FU_DIV] &&
          (DIV_TAG_PIPELINE ? div_slot_ready : div_req_ready)));
      effective_mask[candidate][2] = cand_port_mask[candidate][2] &&
        (cand_fu_onehot[candidate][FU_LOAD] || cand_fu_onehot[candidate][FU_STORE]) &&
        lsu_issue_ready[0];
      effective_mask[candidate][3] = cand_port_mask[candidate][3] &&
        (cand_fu_onehot[candidate][FU_LOAD] || cand_fu_onehot[candidate][FU_STORE]) &&
        lsu_issue_ready[1];
      effective_mask[candidate][4] = cand_port_mask[candidate][4] &&
        cand_fu_onehot[candidate][FU_FP] && (!fpu_issue_valid_q || fpu_req_ready);
`ifndef SYNTHESIS
      // Bundles are split at a serializing lane 0 (see uq_split), so no
      // issue candidate can be younger than the live serial barrier.
      if (rst_ni && cand_valid[candidate] && serial_barrier_valid_q[0])
        assert (!sequence_after_backend(cand_sequence[candidate],
                                        serial_barrier_sequence_q[0]))
          else $error("issue candidate younger than the serial barrier");
`endif
    end
  end
`ifndef SYNTHESIS
  // Clocked equality avoids comparing old/new upstream bundles during a
  // simulator delta-cycle settle. The one-hot mask must match the independent
  // class-based resource model for the selected RTL pipeline configuration.
  function automatic logic [4:0] legacy_resource_mask(
    input fu_class_e fu, input logic [4:0] static_mask
  );
    logic [4:0] resource;
    resource = '0;
    case (fu)
      FU_INT: begin
        if (INT_ISSUE_PIPELINE) resource[1:0] = int_issue_ready;
        else begin
          resource[1:0] = fast_req_ready;
          resource[0] &= !BRANCH_TAG_PIPELINE || !branch_issue_valid_q;
        end
      end
      FU_BRANCH: resource[0] = BRANCH_TAG_PIPELINE ? branch_slot_ready :
        (fast_req_ready[0] && (!INT_ISSUE_PIPELINE || !int_issue_valid_q[0]));
      FU_MUL: resource[1] = mul_req_ready;
      FU_DIV: resource[1] = DIV_TAG_PIPELINE ? div_slot_ready : div_req_ready;
      FU_LOAD, FU_STORE: resource[3:2] = lsu_issue_ready;
      FU_FP: resource[4] = !fpu_issue_valid_q || fpu_req_ready;
      default: resource = '0;
    endcase
    return static_mask & resource;
  endfunction
  for (genvar candidate = 0; candidate < 2; candidate++) begin : g_resource_mask_equal
    assert property (@(posedge clk_i) disable iff (!rst_ni)
      cand_valid[candidate] |-> effective_mask[candidate] ==
        legacy_resource_mask(cand_fu[candidate], cand_port_mask[candidate]));
  end
`endif
  logic [1:0] cand_grant;
  logic [1:0][2:0] cand_grant_port;
  logic [4:0] selected_port_valid;
  logic [4:0] port_valid;
  logic [4:0] port_candidate;
  logic [1:0] issue_valid, issue_candidate;
  logic [1:0][2:0] issue_port;
  rv_issue_arbiter #(.CANDIDATE_COUNT(2),.EXEC_PORTS(5),.ISSUE_WIDTH(2),.AGE_ORDERED(1'b1),
                     .ROB_SEQ_WIDTH(ROB_SEQ_WIDTH)) u_select (
    .candidate_valid_i(cand_valid),.candidate_sequence_i(cand_sequence),
    .candidate_port_mask_i(effective_mask),.port_ready_i('1),
    .candidate_grant_o(cand_grant),.candidate_port_o(cand_grant_port),
    .port_valid_o(selected_port_valid),.port_candidate_o(port_candidate),
    .issue_valid_o(issue_valid),.issue_candidate_o(issue_candidate),
    .issue_port_o(issue_port)
  );
  assign cand_accept=cand_grant;

  // Route selected candidate payloads onto logical execution ports.
  logic [4:0][ROB_SEQ_WIDTH-1:0] port_sequence;
  fu_class_e [4:0] port_fu;
  logic [4:0][XLEN-1:0] port_pc,port_operand0,port_operand1,port_operand2,
                         port_immediate;
  logic [4:0][31:0] port_instruction;
  logic [4:0][15:0] port_operation;
  logic [4:0] port_dst_valid,port_use_pc,port_use_immediate,port_word;
  logic [4:0] port_mem_unsigned;
  logic [4:0][2:0] port_mem_size;
  logic [4:0][2:0] port_rounding;
  logic [4:0][LQ_WIDTH-1:0] port_lq_index;
  logic [4:0][SQ_WIDTH-1:0] port_sq_index;
  logic [4:0] port_store_address_valid, port_store_data_valid;
  reg_class_e [4:0] port_dst_class;
  logic [4:0][PHYS_TAG_WIDTH-1:0] port_dst_phys;
  inst_len_e [4:0] port_len;
  prediction_meta_t [4:0] port_prediction;

  // Keep the integer, branch and memory ports fall-through for CoreMark IPC.
  // The synthesis-reported endpoint was the FPU payload register, so only P4
  // receives an elastic issue/operand register.  It can consume and refill on
  // the same edge and therefore preserves a pipelined FP throughput of one
  // request/cycle while breaking IQ/PRF -> FPU input timing.
  always_comb begin
    port_valid='0;port_sequence='0;port_fu='0;port_pc='0;port_operand0='0;
    port_operand1='0;port_operand2='0;port_immediate='0;port_instruction='0;
    port_operation='0;port_dst_valid='0;
    port_use_pc='0;port_use_immediate='0;port_word='0;port_mem_unsigned='0;
    port_mem_size='0;port_rounding='0;port_lq_index='0;port_sq_index='0;
    port_store_address_valid='0;port_store_data_valid='0;
    port_dst_class='0;port_dst_phys='0;port_len='0;port_prediction='0;
    for(int unsigned port=0;port<4;port++) if(selected_port_valid[port] &&
                                                    !flush_valid) begin
      port_valid[port]=1'b1;
      port_sequence[port]=cand_sequence[port_candidate[port]];
      port_fu[port]=cand_fu[port_candidate[port]];
      port_pc[port]=cand_pc[port_candidate[port]];
      port_operand0[port]=cand_operand0[port_candidate[port]];
      port_operand1[port]=cand_operand1[port_candidate[port]];
      port_operand2[port]=cand_operand2[port_candidate[port]];
      port_instruction[port]=cand_instruction[port_candidate[port]];
      port_immediate[port]=cand_immediate[port_candidate[port]];
      port_operation[port]=cand_operation[port_candidate[port]];
      port_dst_valid[port]=cand_dst_valid[port_candidate[port]];
      port_dst_class[port]=cand_dst_class[port_candidate[port]];
      port_dst_phys[port]=cand_dst_phys[port_candidate[port]];
      port_use_pc[port]=cand_use_pc[port_candidate[port]];
      port_use_immediate[port]=cand_use_immediate[port_candidate[port]];
      port_word[port]=cand_word[port_candidate[port]];
      port_len[port]=cand_len[port_candidate[port]];
      port_prediction[port]=cand_prediction[port_candidate[port]];
      port_mem_size[port]=cand_mem_size[port_candidate[port]];
      port_rounding[port]=cand_rounding[port_candidate[port]];
      port_mem_unsigned[port]=cand_mem_unsigned[port_candidate[port]];
      port_lq_index[port]=cand_lq_index[port_candidate[port]];
      port_sq_index[port]=cand_sq_index[port_candidate[port]];
      port_store_address_valid[port]=
        cand_store_address_valid[port_candidate[port]];
      port_store_data_valid[port]=
        cand_store_data_valid[port_candidate[port]];
    end
    port_valid[4]=fpu_issue_valid_q&&!flush_valid;
    port_sequence[4]=fpu_issue_sequence_q;
    port_fu[4]=FU_FP;
    port_operand0[4]=fpu_issue_operand0_q;
    port_operand1[4]=fpu_issue_operand1_q;
    port_operand2[4]=fpu_issue_operand2_q;
    port_instruction[4]=fpu_issue_instruction_q;
    port_rounding[4]=fpu_issue_rounding_q;
    port_dst_valid[4]=fpu_issue_dst_valid_q;
    port_dst_class[4]=fpu_issue_dst_class_q;
    port_dst_phys[4]=fpu_issue_dst_phys_q;
  end

  always_ff @(posedge clk_i) begin
    if (!rst_ni) begin
      fpu_issue_valid_q <= 1'b0;
      fpu_issue_sequence_q <= '0;
      fpu_issue_operand0_q <= '0;
      fpu_issue_operand1_q <= '0;
      fpu_issue_operand2_q <= '0;
      fpu_issue_instruction_q <= '0;
      fpu_issue_rounding_q <= '0;
      fpu_issue_dst_valid_q <= 1'b0;
      fpu_issue_dst_class_q <= REG_NONE;
      fpu_issue_dst_phys_q <= '0;
    end else if (flush_valid) begin
      if (fpu_issue_valid_q &&
          (flush_all || sequence_after_backend(fpu_issue_sequence_q,
                                               flush_sequence)))
        fpu_issue_valid_q <= 1'b0;
    end else begin
      if (selected_port_valid[4]) begin
        fpu_issue_valid_q <= 1'b1;
        fpu_issue_sequence_q <= cand_sequence[port_candidate[4]];
        fpu_issue_operand0_q <= cand_operand0[port_candidate[4]];
        fpu_issue_operand1_q <= cand_operand1[port_candidate[4]];
        fpu_issue_operand2_q <= cand_operand2[port_candidate[4]];
        fpu_issue_instruction_q <= cand_instruction[port_candidate[4]];
        fpu_issue_rounding_q <= cand_rounding[port_candidate[4]];
        fpu_issue_dst_valid_q <= cand_dst_valid[port_candidate[4]];
        fpu_issue_dst_class_q <= cand_dst_class[port_candidate[4]];
        fpu_issue_dst_phys_q <= cand_dst_phys[port_candidate[4]];
      end else if (fpu_issue_valid_q && fpu_req_ready) begin
        fpu_issue_valid_q <= 1'b0;
      end
    end
  end

  // Prepare PC/immediate selection per IQ candidate, before late port
  // arbitration. Invalid payloads are don't-care ONLY here: fast_req_valid,
  // flush and result-buffer push still exclusively authorize side effects.
  // In particular, do not put selected_port_valid/flush gating before the
  // XLEN-wide ALU datapath. This retains two ALUs and the existing latency.
  logic [1:0][XLEN-1:0] cand_alu_a,cand_alu_b;
  logic [1:0][1:0] cand_int_forward_hit;
  logic [1:0][1:0][XLEN-1:0] cand_int_forward_data;
  logic [1:0][XLEN-1:0] alu_a,alu_b,alu_result;
  logic [1:0][3:0] alu_operation;
  logic [1:0] alu_word;
  always_comb begin
    for(int unsigned candidate=0;candidate<2;candidate++) begin
      for(int source=0;source<2;source++) begin
        cand_int_forward_hit[candidate][source]=1'b0;
        for(int w=0;w<DIRECT_BYPASS_PORTS;w++)
          cand_int_forward_hit[candidate][source] |= direct_wake_valid[w] &&
            (direct_wake_class[w]==cand_src_class[candidate][source]) &&
            (cand_src_class[candidate][source]!=REG_NONE) &&
            (direct_wake_phys[w]==cand_src_phys[candidate][source]);
        // Only forwarded values are captured here. Ready PRF values are read
        // AFTER tag capture, removing IQ select -> PRF -> stage-D timing.
        cand_int_forward_data[candidate][source]=bypass_or_prf(
          cand_src_class[candidate][source],cand_src_phys[candidate][source],'0,'0);
      end
      cand_alu_a[candidate]=cand_use_pc[candidate] ?
        cand_pc[candidate] : cand_operand0[candidate];
      cand_alu_b[candidate]=cand_use_immediate[candidate] ?
        cand_immediate[candidate] : cand_operand1[candidate];
    end
    for(int unsigned port=0;port<2;port++) begin
      alu_a[port]=INT_ISSUE_PIPELINE ?
          (int_issue_q[port].read_prf_a ? int_read_data[INT_ALU_READ_BASE+port*2] : int_issue_q[port].operand_a) :
                                    cand_alu_a[port_candidate[port]];
      alu_b[port]=INT_ISSUE_PIPELINE ?
          (int_issue_q[port].read_prf_b ? int_read_data[INT_ALU_READ_BASE+port*2+1] : int_issue_q[port].operand_b) :
                                    cand_alu_b[port_candidate[port]];
      alu_operation[port]=INT_ISSUE_PIPELINE ? int_issue_q[port].operation :
                                      cand_operation[port_candidate[port]][3:0];
      alu_word[port]=INT_ISSUE_PIPELINE ? int_issue_q[port].word_operation :
                                       cand_word[port_candidate[port]];
    end
  end
  rv_int_alu #(.XLEN(XLEN)) u_alu0(.operand_a_i(alu_a[0]),.operand_b_i(alu_b[0]),
    .operation_i(int_alu_op_e'(alu_operation[0])),
    .word_operation_i(alu_word[0]),.result_o(alu_result[0]));
  rv_int_alu #(.XLEN(XLEN)) u_alu1(.operand_a_i(alu_a[1]),.operand_b_i(alu_b[1]),
    .operation_i(int_alu_op_e'(alu_operation[1])),
    .word_operation_i(alu_word[1]),.result_o(alu_result[1]));

`ifndef SYNTHESIS
  if (!INT_ISSUE_PIPELINE) for(genvar port=0;port<2;port++) begin : g_alu_route_check
    // Check against the original gated port routing at the sampling edge,
    // not during combinational delta-cycle settling. No comparison is needed
    // for invalid ports or branch-link results that do not consume the ALU.
    assert property (@(posedge clk_i) disable iff (!rst_ni)
      (port_valid[port] && (port_fu[port]==FU_INT)) |->
        ((alu_a[port] == (port_use_pc[port] ? port_pc[port] : port_operand0[port])) &&
         (alu_b[port] == (port_use_immediate[port] ? port_immediate[port] : port_operand1[port])) &&
         (alu_operation[port] == port_operation[port][3:0]) &&
         (alu_word[port] == port_word[port])))
      else $error("ALU input routing differs on a valid integer issue");
  end
`endif

  if (INT_ISSUE_PIPELINE) begin : g_int_operand_pipeline
    for(genvar lane=0;lane<2;lane++) begin : g_lane
      assign int_issue_take[lane]=int_issue_valid_q[lane] && fast_req_ready[lane] &&
        !flush_valid && ((lane==1) || !BRANCH_TAG_PIPELINE || !branch_issue_valid_q);
      assign int_issue_ready[lane]=!int_issue_valid_q[lane] || int_issue_take[lane];
      always_ff @(posedge clk_i) begin
        if (!rst_ni) begin
          int_issue_valid_q[lane]<=1'b0;
          int_issue_q[lane]<='0;
        end else if (flush_valid) begin
          if (flush_all || (int_issue_valid_q[lane] &&
              sequence_after_backend(int_issue_q[lane].sequence_id,flush_sequence)))
            int_issue_valid_q[lane]<=1'b0;
        end else if (selected_port_valid[lane] &&
                     cand_fu_onehot[port_candidate[lane]][FU_INT]) begin
          int_issue_valid_q[lane]<=1'b1;
          int_issue_q[lane].sequence_id<=cand_sequence[port_candidate[lane]];
          int_issue_q[lane].operand_a<=cand_use_pc[port_candidate[lane]] ?
            cand_pc[port_candidate[lane]] : cand_int_forward_data[port_candidate[lane]][0];
          int_issue_q[lane].operand_b<=cand_use_immediate[port_candidate[lane]] ?
            cand_immediate[port_candidate[lane]] : cand_int_forward_data[port_candidate[lane]][1];
          int_issue_q[lane].read_prf_a<=!cand_use_pc[port_candidate[lane]] &&
            cand_src_class[port_candidate[lane]][0]==REG_INT && !cand_int_forward_hit[port_candidate[lane]][0];
          int_issue_q[lane].read_prf_b<=!cand_use_immediate[port_candidate[lane]] &&
            cand_src_class[port_candidate[lane]][1]==REG_INT && !cand_int_forward_hit[port_candidate[lane]][1];
          int_issue_q[lane].src_phys_a<=cand_src_phys[port_candidate[lane]][0];
          int_issue_q[lane].src_phys_b<=cand_src_phys[port_candidate[lane]][1];
          int_issue_q[lane].operation<=cand_operation[port_candidate[lane]][3:0];
          int_issue_q[lane].word_operation<=cand_word[port_candidate[lane]];
          int_issue_q[lane].dst_valid<=cand_dst_valid[port_candidate[lane]];
          int_issue_q[lane].dst_class<=cand_dst_class[port_candidate[lane]];
          int_issue_q[lane].dst_phys<=cand_dst_phys[port_candidate[lane]];
        end else if (int_issue_take[lane]) begin
          int_issue_valid_q[lane]<=1'b0;
        end
      end
`ifndef SYNTHESIS
      assert property (@(posedge clk_i) disable iff (!rst_ni || flush_valid)
        selected_port_valid[lane] && cand_fu_onehot[port_candidate[lane]][FU_INT] |->
          cand_src_class[port_candidate[lane]][0]!=REG_FP &&
          cand_src_class[port_candidate[lane]][1]!=REG_FP);
      // Projection to the original same-cycle operand values checks both
      // forwarded-data capture and post-tag PRF reads (without ISA shortcuts).
      assert property (@(posedge clk_i) disable iff (!rst_ni || flush_valid)
        selected_port_valid[lane] && cand_fu_onehot[port_candidate[lane]][FU_INT] |=>
          int_issue_valid_q[lane] &&
          alu_a[lane]==$past(cand_alu_a[port_candidate[lane]]) &&
          alu_b[lane]==$past(cand_alu_b[port_candidate[lane]]));
      assert property (@(posedge clk_i) disable iff (!rst_ni || flush_valid)
        int_issue_valid_q[lane] && int_issue_q[lane].read_prf_a |->
          int_read_ready[INT_ALU_READ_BASE+lane*2]);
      assert property (@(posedge clk_i) disable iff (!rst_ni || flush_valid)
        int_issue_valid_q[lane] && int_issue_q[lane].read_prf_b |->
          int_read_ready[INT_ALU_READ_BASE+lane*2+1]);
      assert property (@(posedge clk_i) disable iff (!rst_ni || flush_valid)
        selected_port_valid[lane] && cand_fu_onehot[port_candidate[lane]][FU_INT]
          |-> int_issue_ready[lane]);
      assert property (@(posedge clk_i) disable iff (!rst_ni || flush_valid)
        int_issue_valid_q[lane] && !int_issue_take[lane]
          |=> int_issue_valid_q[lane] && $stable(int_issue_q[lane]));
`endif
    end
  end else begin : g_int_operand_fallthrough
    assign int_issue_q='0;
    assign int_issue_valid_q='0;
    assign int_issue_ready='0;
    assign int_issue_take='0;
  end

  logic branch_taken,branch_mispredict,branch_misaligned;
  logic [XLEN-1:0] branch_target,branch_next_pc,branch_link;
  logic [1:0] candidate_branch_taken, candidate_branch_mispredict,
              candidate_branch_misaligned;
  logic [1:0][XLEN-1:0] candidate_branch_target, candidate_branch_next_pc,
                       candidate_branch_link;
  // Evaluate the two available operands in parallel with port arbitration.
  // Selecting a boolean after comparison avoids port assignment -> XLEN-wide
  // operand mux -> compare -> mispredict in series. This is still one branch
  // issue port and two global candidates; no extra issue/read bandwidth.
  if (!BRANCH_TAG_PIPELINE) begin : g_branch_fallthrough
  assign branch_issue_valid_q = 1'b0;
  assign branch_issue_q = '0;
  for (genvar candidate = 0; candidate < 2; candidate++) begin : g_candidate_branch
    rv_branch_unit #(.XLEN(XLEN)) u_branch(
      .valid_i(cand_valid[candidate] && (cand_fu[candidate] == FU_BRANCH)),
      .operation_i(branch_op_e'(cand_operation[candidate][3:0])),
      .pc_i(cand_pc[candidate]),
      .operand_a_i(cand_operand0[candidate]),.operand_b_i(cand_operand1[candidate]),
      .immediate_i(cand_immediate[candidate]),
      .instruction_bytes_i((cand_len[candidate] == INST_LEN_16) ? 3'd2 : 3'd4),
      .predicted_taken_i(cand_prediction[candidate].taken),
      .predicted_target_i(cand_prediction[candidate].target[XLEN-1:0]),
      .taken_o(candidate_branch_taken[candidate]),
      .target_o(candidate_branch_target[candidate]),
      .next_pc_o(candidate_branch_next_pc[candidate]),
      .link_value_o(candidate_branch_link[candidate]),
      .target_misaligned_o(candidate_branch_misaligned[candidate]),
      .mispredict_o(candidate_branch_mispredict[candidate]));
  end
  assign branch_taken = candidate_branch_taken[port_candidate[0]];
  assign branch_target = candidate_branch_target[port_candidate[0]];
  assign branch_next_pc = candidate_branch_next_pc[port_candidate[0]];
  assign branch_link = candidate_branch_link[port_candidate[0]];
  assign branch_misaligned = candidate_branch_misaligned[port_candidate[0]];
  assign branch_mispredict = candidate_branch_mispredict[port_candidate[0]];
  end else begin : g_branch_tag_pipeline
    logic [XLEN-1:0] operand0, operand1;
    if (INT_ISSUE_PIPELINE) begin : g_captured_forward
      assign operand0 = branch_issue_q.read_prf[0] ? int_read_data[8] :
                        branch_issue_q.forwarded_operand[0];
      assign operand1 = branch_issue_q.read_prf[1] ? int_read_data[9] :
                        branch_issue_q.forwarded_operand[1];
    end else begin : g_legacy_forward
      assign operand0 = bypass_or_prf(branch_issue_q.src_class[0],
        branch_issue_q.src_phys[0], int_read_data[8], 32'b0);
      assign operand1 = bypass_or_prf(branch_issue_q.src_class[1],
        branch_issue_q.src_phys[1], int_read_data[9], 32'b0);
    end
    rv_branch_unit #(.XLEN(XLEN)) u_branch(
      .valid_i(branch_execute_valid), .operation_i(branch_issue_q.operation),
      .pc_i(branch_issue_q.pc), .operand_a_i(operand0), .operand_b_i(operand1),
      .immediate_i(branch_issue_q.immediate),
      .instruction_bytes_i(branch_issue_q.inst_len == INST_LEN_16 ? 3'd2 : 3'd4),
      .predicted_taken_i(branch_issue_q.prediction.taken),
      .predicted_target_i(branch_issue_q.prediction.target[XLEN-1:0]),
      .taken_o(branch_taken), .target_o(branch_target), .next_pc_o(branch_next_pc),
      .link_value_o(branch_link), .target_misaligned_o(branch_misaligned),
      .mispredict_o(branch_mispredict));
    // One-entry elastic raw-tag slot. Branches may consume/refill together.
    // P0 INT is blocked while the old branch owns its result-buffer input;
    // otherwise two completions would contend for one physical input.
    always_ff @(posedge clk_i) begin
      if (!rst_ni) begin
        branch_issue_valid_q <= 1'b0;
        branch_issue_q <= '0;
      end else if (flush_valid) begin
        if (branch_issue_valid_q && (flush_all ||
            sequence_after_backend(branch_issue_q.sequence_id,flush_sequence)))
          branch_issue_valid_q <= 1'b0;
      end else if (selected_port_valid[0] &&
          cand_fu_onehot[port_candidate[0]][FU_BRANCH]) begin
        branch_issue_valid_q <= 1'b1;
        branch_issue_q.sequence_id <= port_sequence[0];
        branch_issue_q.src_phys <= cand_src_phys[port_candidate[0]][1:0];
        branch_issue_q.src_class <= cand_src_class[port_candidate[0]][1:0];
        for (int source=0;source<2;source++) begin
          branch_issue_q.read_prf[source] <= INT_ISSUE_PIPELINE &&
            cand_src_class[port_candidate[0]][source]==REG_INT &&
            !cand_int_forward_hit[port_candidate[0]][source];
          branch_issue_q.forwarded_operand[source] <= INT_ISSUE_PIPELINE ?
            cand_int_forward_data[port_candidate[0]][source] : '0;
        end
        branch_issue_q.operation <= branch_op_e'(port_operation[0][3:0]);
        branch_issue_q.pc <= port_pc[0];
        branch_issue_q.immediate <= port_immediate[0];
        branch_issue_q.inst_len <= port_len[0];
        branch_issue_q.prediction <= port_prediction[0];
        branch_issue_q.dst_valid <= port_dst_valid[0];
        branch_issue_q.dst_class <= port_dst_class[0];
        branch_issue_q.dst_phys <= port_dst_phys[0];
      end else if (branch_issue_valid_q && fast_req_ready[0]) begin
        branch_issue_valid_q <= 1'b0;
      end
    end
`ifndef SYNTHESIS
    function automatic logic source_available(input int unsigned source);
      logic available;
      if (INT_ISSUE_PIPELINE)
        return !branch_issue_q.read_prf[source] || int_read_ready[8+source];
      available = branch_issue_q.src_class[source] == REG_NONE ||
                  (branch_issue_q.src_class[source] == REG_INT && int_read_ready[8+source]);
      for (int unsigned w = 0; w < DIRECT_BYPASS_PORTS; w++)
        available |= branch_issue_q.src_class[source] == REG_INT && direct_wake_valid[w] &&
          (direct_wake_class[w] == branch_issue_q.src_class[source]) &&
          (direct_wake_phys[w] == branch_issue_q.src_phys[source]);
      return available;
    endfunction
    if (INT_ISSUE_PIPELINE) begin : g_operand_projection
      assert property (@(posedge clk_i) disable iff (!rst_ni || flush_valid)
        selected_port_valid[0] && cand_fu_onehot[port_candidate[0]][FU_BRANCH] |->
          cand_src_class[port_candidate[0]][0]!=REG_FP &&
          cand_src_class[port_candidate[0]][1]!=REG_FP);
      assert property (@(posedge clk_i) disable iff (!rst_ni || flush_valid)
        selected_port_valid[0] && cand_fu_onehot[port_candidate[0]][FU_BRANCH] |=>
          branch_issue_valid_q &&
          operand0==$past(cand_operand0[port_candidate[0]]) &&
          operand1==$past(cand_operand1[port_candidate[0]]));
    end
    // Tags cannot be recycled before their live consumer retires. If the
    // original wake came from a held producer not yet granted PRF writeback,
    // that producer must still provide the value through direct bypass.
    assert property (@(posedge clk_i) disable iff (!rst_ni)
      branch_execute_valid && fast_req_ready[0] |->
        source_available(0) && source_available(1));
    assert property (@(posedge clk_i) disable iff (!rst_ni)
      branch_issue_valid_q && !fast_req_ready[0] && !flush_valid |=>
        flush_valid || (branch_issue_valid_q && $stable(branch_issue_q)));
    assert property (@(posedge clk_i) disable iff (!rst_ni)
      branch_issue_valid_q && !flush_valid |->
        (!(port_valid[0] && (port_fu[0] == FU_INT)) ||
         (INT_ISSUE_PIPELINE && !int_issue_valid_q[0])));
    assert property (@(posedge clk_i) disable iff (!rst_ni)
      INT_ISSUE_PIPELINE && branch_issue_valid_q && !flush_valid |->
        !int_issue_take[0]);
`endif
  end
  assign branch_execute_valid = !flush_valid &&
    (BRANCH_TAG_PIPELINE ? branch_issue_valid_q :
      (port_valid[0] && (port_fu[0] == FU_BRANCH)));
  assign branch_execute_sequence = BRANCH_TAG_PIPELINE ?
    branch_issue_q.sequence_id : port_sequence[0];

`ifndef SYNTHESIS
  if (!BRANCH_TAG_PIPELINE) begin : g_branch_legacy_equal
  // Check this retiming-free factoring against the original post-port-mux
  // evaluation on every actually issued branch. Inactive payload is don't-care.
  logic reference_branch_taken, reference_branch_mispredict, reference_branch_misaligned;
  logic [XLEN-1:0] reference_branch_target, reference_branch_next_pc, reference_branch_link;
  rv_branch_unit #(.XLEN(XLEN)) u_branch_post_select_reference(
    .valid_i(port_valid[0] && (port_fu[0] == FU_BRANCH)),
    .operation_i(branch_op_e'(port_operation[0][3:0])), .pc_i(port_pc[0]),
    .operand_a_i(port_operand0[0]), .operand_b_i(port_operand1[0]),
    .immediate_i(port_immediate[0]),
    .instruction_bytes_i((port_len[0] == INST_LEN_16) ? 3'd2 : 3'd4),
    .predicted_taken_i(port_prediction[0].taken),
    .predicted_target_i(port_prediction[0].target[XLEN-1:0]),
    .taken_o(reference_branch_taken), .target_o(reference_branch_target),
    .next_pc_o(reference_branch_next_pc), .link_value_o(reference_branch_link),
    .target_misaligned_o(reference_branch_misaligned), .mispredict_o(reference_branch_mispredict));
  assert property (@(posedge clk_i) disable iff (!rst_ni)
    port_valid[0] && (port_fu[0] == FU_BRANCH) |->
      {branch_taken, branch_target, branch_next_pc, branch_link,
       branch_misaligned, branch_mispredict} ==
      {reference_branch_taken, reference_branch_target, reference_branch_next_pc,
       reference_branch_link, reference_branch_misaligned, reference_branch_mispredict});
  end
`endif

  // One elastic result buffer per single-cycle integer port.
  logic [1:0] fast_req_valid,fast_result_valid,fast_result_ready;
  logic [1:0] fast_req_at_head_next;
  logic [1:0] fast_pending_valid,fast_pending_dst_valid,fast_pending_exception;
  logic [1:0][ROB_SEQ_WIDTH-1:0] fast_pending_sequence;
  reg_class_e [1:0] fast_pending_dst_class;
  logic [1:0][PHYS_TAG_WIDTH-1:0] fast_pending_dst_phys;
  logic [1:0][XLEN-1:0] fast_pending_data;
  logic [1:0][XLEN-1:0] fast_req_data;
  logic [1:0] fast_req_exception,fast_req_mispredict;
  logic [1:0][XLEN-1:0] fast_req_tval,fast_req_target;
  exception_code_e [1:0] fast_req_cause;
  logic [1:0][ROB_SEQ_WIDTH-1:0] fast_req_sequence;
  logic [1:0] fast_req_dst_valid;
  reg_class_e [1:0] fast_req_dst_class;
  logic [1:0][PHYS_TAG_WIDTH-1:0] fast_req_dst_phys;
  always_comb begin
    fast_req_sequence=port_sequence[1:0];
    fast_req_dst_valid=port_dst_valid[1:0];
    fast_req_dst_class=port_dst_class[1:0];
    fast_req_dst_phys=port_dst_phys[1:0];
    fast_req_valid[0]=BRANCH_TAG_PIPELINE ?
      (selected_port_valid[0] && !flush_valid &&
       cand_fu_onehot[port_candidate[0]][FU_INT]) : port_valid[0];
    fast_req_valid[1]=port_valid[1]&&(port_fu[1]==FU_INT);
    fast_req_data[0]=BRANCH_TAG_PIPELINE ? alu_result[0] :
      ((port_fu[0]==FU_BRANCH)?branch_link:alu_result[0]);
    fast_req_data[1]=alu_result[1];fast_req_exception='0;
    fast_req_exception[0]=!BRANCH_TAG_PIPELINE &&
      (port_fu[0]==FU_BRANCH)&&branch_misaligned;
    fast_req_cause='0;fast_req_tval='0;
    fast_req_tval[0]=branch_target;fast_req_mispredict='0;
    fast_req_mispredict[0]=!BRANCH_TAG_PIPELINE &&
      (port_fu[0]==FU_BRANCH)&&branch_mispredict;
    fast_req_target='0;fast_req_target[0]=branch_next_pc;
    if (INT_ISSUE_PIPELINE) begin
      for(int lane=0;lane<2;lane++) begin
        fast_req_valid[lane]=int_issue_valid_q[lane] && !flush_valid;
        fast_req_sequence[lane]=int_issue_q[lane].sequence_id;
        fast_req_dst_valid[lane]=int_issue_q[lane].dst_valid;
        fast_req_dst_class[lane]=int_issue_q[lane].dst_class;
        fast_req_dst_phys[lane]=int_issue_q[lane].dst_phys;
        fast_req_data[lane]=alu_result[lane];
      end
      if (!BRANCH_TAG_PIPELINE && port_valid[0] && (port_fu[0]==FU_BRANCH)) begin
        fast_req_valid[0]=1'b1;
        fast_req_sequence[0]=port_sequence[0];
        fast_req_dst_valid[0]=port_dst_valid[0];
        fast_req_dst_class[0]=port_dst_class[0];
        fast_req_dst_phys[0]=port_dst_phys[0];
        fast_req_data[0]=branch_link;
      end
    end
    if (BRANCH_TAG_PIPELINE && branch_issue_valid_q) begin
      fast_req_valid[0]=branch_execute_valid;
      fast_req_sequence[0]=branch_issue_q.sequence_id;
      fast_req_dst_valid[0]=branch_issue_q.dst_valid;
      fast_req_dst_class[0]=branch_issue_q.dst_class;
      fast_req_dst_phys[0]=branch_issue_q.dst_phys;
      fast_req_data[0]=branch_link;
      fast_req_exception[0]=branch_misaligned;
      fast_req_mispredict[0]=branch_mispredict;
    end
  end
  logic [1:0][ROB_SEQ_WIDTH-1:0] fast_result_sequence;
  logic [1:0] fast_result_dst_valid,fast_result_exception,fast_result_mispredict;
  reg_class_e [1:0] fast_result_dst_class;
  logic [1:0][PHYS_TAG_WIDTH-1:0] fast_result_dst_phys;
  logic [1:0][XLEN-1:0] fast_result_data,fast_result_tval,fast_result_target;
  exception_code_e [1:0] fast_result_cause;
  logic [1:0][4:0] fast_result_fflags;
  for(genvar fast=0;fast<2;fast++) begin:g_fast
    rv_exec_result_buffer #(.XLEN(XLEN),.ROB_SEQ_WIDTH(ROB_SEQ_WIDTH),.DEPTH(2),
      .PHYS_TAG_WIDTH(PHYS_TAG_WIDTH)) u_buffer(
      .clk_i,.rst_ni,.request_valid_i(fast_req_valid[fast]),
      .request_ready_o(fast_req_ready[fast]),.request_sequence_i(fast_req_sequence[fast]),
      .request_at_head_next_o(fast_req_at_head_next[fast]),
      .pending_valid_o(fast_pending_valid[fast]),
      .pending_sequence_o(fast_pending_sequence[fast]),
      .pending_destination_valid_o(fast_pending_dst_valid[fast]),
      .pending_destination_class_o(fast_pending_dst_class[fast]),
      .pending_destination_phys_o(fast_pending_dst_phys[fast]),
      .pending_data_o(fast_pending_data[fast]),
      .pending_exception_valid_o(fast_pending_exception[fast]),
      .request_destination_valid_i(fast_req_dst_valid[fast]),
      .request_destination_class_i(fast_req_dst_class[fast]),
      .request_destination_phys_i(fast_req_dst_phys[fast]),
      .request_data_i(fast_req_data[fast]),
      .request_exception_valid_i(fast_req_exception[fast]),
      .request_exception_cause_i(fast_req_cause[fast]),
      .request_exception_tval_i(fast_req_tval[fast]),
      .request_branch_mispredict_i(fast_req_mispredict[fast]),
      .request_branch_target_i(fast_req_target[fast]),.request_fflags_i(5'b0),
      .flush_valid_i(flush_valid),.flush_all_i(flush_all),
      .flush_sequence_i(flush_sequence),.result_valid_o(fast_result_valid[fast]),
      .result_ready_i(fast_result_ready[fast]),
      .result_sequence_o(fast_result_sequence[fast]),
      .result_destination_valid_o(fast_result_dst_valid[fast]),
      .result_destination_class_o(fast_result_dst_class[fast]),
      .result_destination_phys_o(fast_result_dst_phys[fast]),
      .result_data_o(fast_result_data[fast]),
      .result_exception_valid_o(fast_result_exception[fast]),
      .result_exception_cause_o(fast_result_cause[fast]),
      .result_exception_tval_o(fast_result_tval[fast]),
      .result_branch_mispredict_o(fast_result_mispredict[fast]),
      .result_branch_target_o(fast_result_target[fast]),
      .result_fflags_o(fast_result_fflags[fast]));
  end

  logic mul_result_valid,mul_result_ready,mul_result_dst_valid;
  logic [XLEN-1:0] mul_result_data;
  logic [ROB_SEQ_WIDTH-1:0] mul_result_sequence;
  logic [PHYS_TAG_WIDTH-1:0] mul_result_dst_phys;
  rv_multiplier #(.XLEN(XLEN),.ROB_SEQ_WIDTH(ROB_SEQ_WIDTH),
    .PHYS_TAG_WIDTH(PHYS_TAG_WIDTH)) u_mul(
    .clk_i,.rst_ni,.request_valid_i(port_valid[1]&&(port_fu[1]==FU_MUL)),
    .request_ready_o(mul_req_ready),.operand_a_i(port_operand0[1]),
    .operand_b_i(port_operand1[1]),
    .operation_i(multiply_op_e'(port_operation[1][1:0])),
    .word_operation_i(port_word[1]),.sequence_i(port_sequence[1]),
    .destination_valid_i(port_dst_valid[1]),.destination_phys_i(port_dst_phys[1]),
    .flush_valid_i(flush_valid),.flush_all_i(flush_all),
    .flush_sequence_i(flush_sequence),.result_valid_o(mul_result_valid),
    .result_ready_i(mul_result_ready),.result_o(mul_result_data),
    .result_sequence_o(mul_result_sequence),
    .result_destination_valid_o(mul_result_dst_valid),
    .result_destination_phys_o(mul_result_dst_phys));

  logic div_result_valid,div_result_ready,div_result_dst_valid;
  logic [XLEN-1:0] div_result_data;
  logic [ROB_SEQ_WIDTH-1:0] div_result_sequence;
  logic [PHYS_TAG_WIDTH-1:0] div_result_dst_phys;
  logic [XLEN-1:0] div_operand0, div_operand1;
  logic [ROB_SEQ_WIDTH-1:0] div_execute_sequence;
  logic div_execute_word, div_execute_dst_valid;
  logic [PHYS_TAG_WIDTH-1:0] div_execute_dst_phys;
  divide_op_e div_execute_operation;
  if (!DIV_TAG_PIPELINE) begin : g_div_fallthrough
    assign div_issue_valid_q = 1'b0;
    assign div_issue_q = '0;
    assign div_operand0 = port_operand0[1];
    assign div_operand1 = port_operand1[1];
    assign div_execute_valid = port_valid[1] && (port_fu[1] == FU_DIV);
    assign div_execute_sequence = port_sequence[1];
    assign div_execute_word = port_word[1];
    assign div_execute_dst_valid = port_dst_valid[1];
    assign div_execute_dst_phys = port_dst_phys[1];
    assign div_execute_operation = divide_op_e'(port_operation[1][1:0]);
  end else begin : g_div_tag_pipeline
    // Select tags in cycle S; read/bypass operands and start the unchanged
    // divider in S+1. The slot can wait while an older division executes.
    // Consuming/refilling is safe: DIV has its own FU/result, unlike BRU/P0.
    assign div_operand0 = bypass_or_prf(div_issue_q.src_class[0],
      div_issue_q.src_phys[0], int_read_data[DIV_READ_BASE], 32'b0);
    assign div_operand1 = bypass_or_prf(div_issue_q.src_class[1],
      div_issue_q.src_phys[1], int_read_data[DIV_READ_BASE+1], 32'b0);
    assign div_execute_valid = div_issue_valid_q && !flush_valid;
    assign div_execute_sequence = div_issue_q.sequence_id;
    assign div_execute_word = div_issue_q.word_operation;
    assign div_execute_dst_valid = div_issue_q.dst_valid;
    assign div_execute_dst_phys = div_issue_q.dst_phys;
    assign div_execute_operation = div_issue_q.operation;
    always_ff @(posedge clk_i) begin
      if (!rst_ni) begin
        div_issue_valid_q <= 1'b0;
        div_issue_q <= '0;
      end else if (flush_valid) begin
        if (div_issue_valid_q && (flush_all ||
            sequence_after_backend(div_issue_q.sequence_id, flush_sequence)))
          div_issue_valid_q <= 1'b0;
      end else if (selected_port_valid[1] &&
                   cand_fu_onehot[port_candidate[1]][FU_DIV]) begin
        div_issue_valid_q <= 1'b1;
        div_issue_q.sequence_id <= port_sequence[1];
        div_issue_q.src_phys <= cand_src_phys[port_candidate[1]][1:0];
        div_issue_q.src_class <= cand_src_class[port_candidate[1]][1:0];
        div_issue_q.operation <= divide_op_e'(port_operation[1][1:0]);
        div_issue_q.word_operation <= port_word[1];
        div_issue_q.dst_valid <= port_dst_valid[1];
        div_issue_q.dst_phys <= port_dst_phys[1];
      end else if (div_issue_valid_q && div_req_ready) begin
        div_issue_valid_q <= 1'b0;
      end
    end
`ifndef SYNTHESIS
    function automatic logic source_available(input int unsigned source);
      logic available;
      available = div_issue_q.src_class[source] == REG_NONE ||
        (div_issue_q.src_class[source] == REG_INT && int_read_ready[DIV_READ_BASE+source]);
      for (int unsigned w = 0; w < DIRECT_BYPASS_PORTS; w++)
        available |= div_issue_q.src_class[source] == REG_INT && direct_wake_valid[w] &&
          (direct_wake_class[w] == div_issue_q.src_class[source]) &&
          (direct_wake_phys[w] == div_issue_q.src_phys[source]);
      return available;
    endfunction
    // Every accepted raw-tag consumer still owns live source mappings. A
    // wakeup producer delayed by WB remains on bypass until PRF is written.
    assert property (@(posedge clk_i) disable iff (!rst_ni)
      div_execute_valid && div_req_ready |-> source_available(0) && source_available(1));
    assert property (@(posedge clk_i) disable iff (!rst_ni)
      div_issue_valid_q && !div_req_ready && !flush_valid |=>
        flush_valid || (div_issue_valid_q && $stable(div_issue_q)));
    assert property (@(posedge clk_i) disable iff (!rst_ni)
      selected_port_valid[1] && !flush_valid &&
      cand_fu_onehot[port_candidate[1]][FU_DIV] |-> div_slot_ready);
    assert property (@(posedge clk_i) disable iff (!rst_ni)
      div_issue_valid_q |-> div_issue_q.src_class[0] inside {REG_NONE, REG_INT} &&
                           div_issue_q.src_class[1] inside {REG_NONE, REG_INT});
`endif
  end
  rv_divider #(.XLEN(XLEN),.ROB_SEQ_WIDTH(ROB_SEQ_WIDTH),
    .PHYS_TAG_WIDTH(PHYS_TAG_WIDTH)) u_div(
    .clk_i,.rst_ni,.request_valid_i(div_execute_valid),
    .request_ready_o(div_req_ready),.operand_a_i(div_operand0),
    .operand_b_i(div_operand1),.operation_i(div_execute_operation),
    .word_operation_i(div_execute_word),.request_rob_sequence_i(div_execute_sequence),
    .request_destination_valid_i(div_execute_dst_valid),
    .request_destination_phys_i(div_execute_dst_phys),
    .flush_valid_i(flush_valid),.flush_all_i(flush_all),
    .flush_sequence_i(flush_sequence),.result_valid_o(div_result_valid),
    .result_ready_i(div_result_ready),.result_o(div_result_data),
    .result_rob_sequence_o(div_result_sequence),
     .result_destination_valid_o(div_result_dst_valid),
     .result_destination_phys_o(div_result_dst_phys));

  // One RV32F cluster accepts one operation per cycle.  Every completion,
  // including fflags, remains speculative until its ROB entry retires.
  logic fpu_result_valid, fpu_result_ready, fpu_result_dst_valid;
  logic fpu_result_exception;
  logic [ROB_SEQ_WIDTH-1:0] fpu_result_sequence;
  reg_class_e fpu_result_dst_class;
  logic [PHYS_TAG_WIDTH-1:0] fpu_result_dst_phys;
  logic [XLEN-1:0] fpu_result_data, fpu_result_tval;
  logic [4:0] fpu_result_fflags;
  exception_code_e fpu_result_cause;
  rv_fpu #(
    .XLEN(XLEN), .ROB_SEQ_WIDTH(ROB_SEQ_WIDTH),
    .PHYS_TAG_WIDTH(PHYS_TAG_WIDTH), .LATENCY(5)
  ) u_fpu (
    .clk_i, .rst_ni,
    .request_valid_i(port_valid[4] && (port_fu[4] == FU_FP)),
    .request_ready_o(fpu_req_ready), .instruction_i(port_instruction[4]),
    .operand_a_i(port_operand0[4]), .operand_b_i(port_operand1[4]),
    .operand_c_i(port_operand2[4]), .rounding_mode_i(port_rounding[4]),
    .frm_i(csr_frm), .sequence_i(port_sequence[4]),
    .destination_valid_i(port_dst_valid[4]),
    .destination_class_i(port_dst_class[4]),
    .destination_phys_i(port_dst_phys[4]),
    .flush_valid_i(flush_valid), .flush_all_i(flush_all),
    .flush_sequence_i(flush_sequence), .result_valid_o(fpu_result_valid),
    .result_ready_i(fpu_result_ready),
    .result_sequence_o(fpu_result_sequence),
    .result_destination_valid_o(fpu_result_dst_valid),
    .result_destination_class_o(fpu_result_dst_class),
    .result_destination_phys_o(fpu_result_dst_phys),
    .result_data_o(fpu_result_data), .result_fflags_o(fpu_result_fflags),
    .result_exception_valid_o(fpu_result_exception),
    .result_exception_cause_o(fpu_result_cause),
    .result_exception_tval_o(fpu_result_tval)
  );

  // Two address-generation pipes feed one age-ordered LSQ. Loads may forward
  // from the youngest older SQ/SB entry; stores become externally visible only
  // when the corresponding ROB head commits into the store buffer.
  logic [1:0] lsu_issue_valid, lsu_issue_is_load, lsu_issue_is_store;
  logic [1:0] lsu_issue_address_valid, lsu_issue_store_data_valid;
  logic [1:0][ROB_SEQ_WIDTH-1:0] lsu_issue_sequence;
  logic [1:0] lsu_issue_lq_valid, lsu_issue_sq_valid;
  logic [1:0][LQ_WIDTH-1:0] lsu_issue_lq_index;
  logic [1:0][SQ_WIDTH-1:0] lsu_issue_sq_index;
  logic [1:0][XLEN-1:0] lsu_issue_base, lsu_issue_immediate,
                         lsu_issue_store_data;
  logic [1:0][2:0] lsu_issue_size;
  logic [1:0] lsu_commit_ready;
  logic [4:0] lsu_completion_valid, lsu_completion_ready,
              lsu_completion_dst_valid, lsu_completion_exception;
  logic [4:0][ROB_SEQ_WIDTH-1:0] lsu_completion_sequence;
  reg_class_e [4:0] lsu_completion_dst_class;
  logic [4:0][PHYS_TAG_WIDTH-1:0] lsu_completion_dst_phys;
  logic [4:0][XLEN-1:0] lsu_completion_data, lsu_completion_tval;
  exception_code_e [4:0] lsu_completion_cause;

  logic store_buffer_empty, lsu_memory_idle, store_machine_check;
  privilege_e current_privilege, effective_data_privilege;
  logic [7:0][7:0] csr_pmpcfg;
  logic [7:0][PADDR_WIDTH-3:0] csr_pmpaddr;

  always_comb begin
    for (int unsigned lane = 0; lane < 2; lane++) begin
      lsu_issue_valid[lane] = port_valid[2+lane] &&
        ((port_fu[2+lane] == FU_LOAD) || (port_fu[2+lane] == FU_STORE));
      lsu_issue_sequence[lane] = port_sequence[2+lane];
      lsu_issue_is_load[lane] = port_fu[2+lane] == FU_LOAD;
      lsu_issue_is_store[lane] = port_fu[2+lane] == FU_STORE;
      lsu_issue_address_valid[lane] = lsu_issue_is_load[lane] ||
        port_store_address_valid[2+lane];
      lsu_issue_store_data_valid[lane] =
        lsu_issue_is_store[lane] && port_store_data_valid[2+lane];
      lsu_issue_lq_valid[lane] = port_fu[2+lane] == FU_LOAD;
      lsu_issue_lq_index[lane] = port_lq_index[2+lane];
      lsu_issue_sq_valid[lane] = port_fu[2+lane] == FU_STORE;
      lsu_issue_sq_index[lane] = port_sq_index[2+lane];
      lsu_issue_base[lane] = port_operand0[2+lane];
      lsu_issue_immediate[lane] = port_immediate[2+lane];
      lsu_issue_store_data[lane] = port_operand1[2+lane];
      lsu_issue_size[lane] = port_mem_size[2+lane];
    end
  end

  rv_lsu_cluster #(
    .XLEN(XLEN), .PADDR_WIDTH(PADDR_WIDTH),
    .MEM_DATA_WIDTH(MEM_DATA_WIDTH), .ROB_SEQ_WIDTH(ROB_SEQ_WIDTH),
    .PHYS_TAG_WIDTH(PHYS_TAG_WIDTH), .LQ_ENTRIES(LQ_ENTRIES),
    .SQ_ENTRIES(SQ_ENTRIES), .STORE_BUFFER_ENTRIES(STORE_BUFFER_ENTRIES),
    .ITIM_BASE_ADDR(ITIM_BASE_ADDR), .ITIM_SIZE_KB(ITIM_SIZE_KB),
    .DTIM_BASE_ADDR(DTIM_BASE_ADDR), .DTIM_SIZE_KB(DTIM_SIZE_KB),
    // Two-entry AGU buffers: LSU issue_ready no longer carries the
    // PMP check / completion-port decision into issue selection.
    .AGU_DEPTH(2), .EARLY_LOAD_SELECT(EARLY_LOAD_SELECT), .AGU_LOAD_BYPASS(AGU_LOAD_BYPASS)
  ) u_lsu_cluster (
    .clk_i, .rst_ni,
    .dispatch_valid_i(dec_valid & (dec_is_load | dec_is_store)),
    .dispatch_accept_i(dispatch_fire), .dispatch_ready_o(lsq_dispatch_ready),
    .dispatch_is_load_i(dec_is_load), .dispatch_is_store_i(dec_is_store),
    .dispatch_sequence_i(rob_alloc_sequence),
    .dispatch_destination_valid_i(renamed_writes_dst),
    .dispatch_destination_class_i(dec_dst_class),
    .dispatch_destination_phys_i(renamed_dst_phys),
    .dispatch_size_i(dec_mem_size), .dispatch_unsigned_i(dec_mem_unsigned),
    .dispatch_lq_valid_o(lsq_dispatch_lq_valid),
    .dispatch_lq_index_o(lsq_dispatch_lq_index),
    .dispatch_sq_valid_o(lsq_dispatch_sq_valid),
    .dispatch_sq_index_o(lsq_dispatch_sq_index),
    .issue_valid_i(lsu_issue_valid), .issue_ready_o(lsu_issue_ready),
    .issue_sequence_i(lsu_issue_sequence),
    .issue_is_load_i(lsu_issue_is_load), .issue_is_store_i(lsu_issue_is_store),
    .issue_address_valid_i(lsu_issue_address_valid),
    .issue_store_data_valid_i(lsu_issue_store_data_valid),
    .issue_lq_valid_i(lsu_issue_lq_valid), .issue_lq_index_i(lsu_issue_lq_index),
    .issue_sq_valid_i(lsu_issue_sq_valid), .issue_sq_index_i(lsu_issue_sq_index),
    .issue_base_i(lsu_issue_base), .issue_immediate_i(lsu_issue_immediate),
    .issue_store_data_i(lsu_issue_store_data), .issue_size_i(lsu_issue_size),
    .current_privilege_i(effective_data_privilege),
    .pmpcfg_i(csr_pmpcfg), .pmpaddr_i(csr_pmpaddr),
    .rob_head_valid_i(rob_head_valid), .rob_head_sequence_i(rob_head_sequence),
    .commit_valid_i(retire_valid),
    .commit_is_load_i(retire_is_load), .commit_is_store_i(retire_is_store),
    .commit_sequence_i(retire_sequence), .commit_lq_index_i(retire_lq_index),
    .commit_sq_index_i(retire_sq_index), .commit_ready_o(lsu_commit_ready),
    .completion_valid_o(lsu_completion_valid),
    .completion_ready_i(lsu_completion_ready),
    .completion_sequence_o(lsu_completion_sequence),
    .completion_destination_valid_o(lsu_completion_dst_valid),
    .completion_destination_class_o(lsu_completion_dst_class),
    .completion_destination_phys_o(lsu_completion_dst_phys),
    .completion_data_o(lsu_completion_data),
    .completion_exception_valid_o(lsu_completion_exception),
    .completion_exception_cause_o(lsu_completion_cause),
    .completion_exception_tval_o(lsu_completion_tval),
    .flush_valid_i(flush_valid), .flush_all_i(flush_all),
    .flush_sequence_i(flush_sequence),
    .dmem_req_valid_o, .dmem_req_ready_i, .dmem_req_id_o,
    .dmem_req_write_o, .dmem_req_addr_o, .dmem_req_size_o,
    .dmem_req_wdata_o, .dmem_req_wstrb_o, .dmem_req_priv_o,
    .dmem_req_rob_seq_o, .dmem_req_committed_o, .dmem_req_device_o,
    .dmem_rsp_valid_i, .dmem_rsp_ready_o, .dmem_rsp_id_i,
    .dmem_rsp_rdata_i, .dmem_rsp_resp_i, .dmem_rsp_replay_i,
    .store_buffer_empty_o(store_buffer_empty),
    .memory_idle_o(lsu_memory_idle),
    .store_machine_check_o(store_machine_check)
  );

  // Gather completion sources and filter every result against ROB liveness.
  logic [WB_SOURCES-1:0] source_valid,source_ready,source_live,source_dst_valid;
  logic [WB_SOURCES-1:0][ROB_SEQ_WIDTH-1:0] source_sequence;
  reg_class_e [WB_SOURCES-1:0] source_dst_class;
  logic [WB_SOURCES-1:0][PHYS_TAG_WIDTH-1:0] source_dst_phys;
  logic [WB_SOURCES-1:0][XLEN-1:0] source_data,source_exception_tval,
                                            source_branch_target;
  logic [WB_SOURCES-1:0] source_exception,source_mispredict;
  exception_code_e [WB_SOURCES-1:0] source_exception_cause;
  logic [WB_SOURCES-1:0][4:0] source_fflags;

  // What the writeback arbiter sees.  Sources 0/1 (two-deep result buffers)
  // and 10 (ROB-head system op) are presented directly; 2..9 pass through a
  // one-entry skid, so `source_ready` returned to those producers is the
  // registered skid occupancy instead of this cycle's arbitration.
  localparam int unsigned SKID_FIRST = 2;
  localparam int unsigned SKID_LAST  = 9;
  typedef struct packed {
    logic [ROB_SEQ_WIDTH-1:0]  sequence_id;
    logic                      dst_valid;
    reg_class_e                dst_class;
    logic [PHYS_TAG_WIDTH-1:0] dst_phys;
    logic [XLEN-1:0]           data;
    logic                      exception;
    exception_code_e           cause;
    logic [XLEN-1:0]           tval;
    logic                      mispredict;
    logic [XLEN-1:0]           branch_target;
    logic [4:0]                fflags;
  } wb_payload_t;
  wb_payload_t [WB_SOURCES-1:0] raw_payload, wb_payload;
  logic [WB_SOURCES-1:0] skid_valid_q;
  wb_payload_t [WB_SOURCES-1:0] skid_q;
  logic [WB_SOURCES-1:0] wb_source_valid, wb_source_ready, wb_source_live;
  logic [WB_SOURCES-1:0][ROB_SEQ_WIDTH-1:0] wb_source_sequence;
  reg_class_e [WB_SOURCES-1:0] wb_source_dst_class;
  logic [WB_SOURCES-1:0][PHYS_TAG_WIDTH-1:0] wb_source_dst_phys;
  logic [WB_SOURCES-1:0][XLEN-1:0] wb_source_data, wb_source_exception_tval,
                                   wb_source_branch_target;
  logic [WB_SOURCES-1:0] wb_source_dst_valid, wb_source_exception,
                         wb_source_mispredict;
  exception_code_e [WB_SOURCES-1:0] wb_source_exception_cause;
  logic [WB_SOURCES-1:0][4:0] wb_source_fflags;
  logic [3:0] complete_valid,complete_exception,complete_mispredict;
  logic [3:0][ROB_SEQ_WIDTH-1:0] complete_sequence;
  exception_code_e [3:0] complete_cause;
  logic [3:0][XLEN-1:0] complete_tval,complete_target;
  logic [3:0][4:0] complete_fflags;

  logic head_is_ecall, head_is_mret, head_is_wfi, head_is_fence,
        head_is_fence_i, head_special_request;
  logic retire_is_csr, retire_is_mret, retire_is_wfi, retire_is_fence_i;
  logic retire_is_pmp_write, retire_is_decode_state_write;
  csr_cmd_e head_csr_cmd;
  logic [XLEN-1:0] head_csr_operand, csr_rdata;
  logic csr_ready, csr_illegal, csr_write_effect, csr_execute, csr_commit;
  logic csr_trap_valid, csr_trap_ready, csr_trap_is_interrupt;
  logic [XLEN-1:0] csr_trap_pc, csr_trap_tval, csr_trap_next_pc,
                   csr_trap_vector;
  logic [5:0] csr_trap_cause, csr_interrupt_cause;
  logic csr_mret_ready, csr_mret_illegal, csr_wfi_illegal, csr_wfi_wake;
  logic [XLEN-1:0] csr_mret_pc, csr_mtvec, csr_mepc;
  logic [4:0] csr_fflags;
  logic [4:0] commit_fflags;
  logic commit_fflags_valid;
  logic system_completion_valid, system_completion_fire,
        system_completion_exception;
  exception_code_e system_completion_cause;
  logic [XLEN-1:0] system_completion_tval;
  logic [XLEN-1:0] architectural_next_pc_q;
  logic architectural_redirect_valid;
  logic [XLEN-1:0] architectural_redirect_pc;
  logic fence_completion_valid;
  logic [ROB_SEQ_WIDTH-1:0] fence_completion_sequence;

  assign head_is_csr_instruction = rob_head_valid &&
    (rob_head_instruction[6:0] == 7'b1110011) &&
    (rob_head_instruction[14:12] != 3'b000);
  assign head_is_ecall = rob_head_valid &&
    (rob_head_instruction == 32'h0000_0073);
  assign head_is_mret = rob_head_valid &&
    (rob_head_instruction == 32'h3020_0073);
  assign head_is_wfi = rob_head_valid &&
    (rob_head_instruction == 32'h1050_0073);
  assign head_is_fence = rob_head_valid &&
    (rob_head_instruction[6:0] == 7'b0001111) &&
    (rob_head_instruction[14:12] == 3'b000);
  assign head_is_fence_i = rob_head_valid &&
    (rob_head_instruction[6:0] == 7'b0001111) &&
    (rob_head_instruction[14:12] == 3'b001);
  assign head_is_special_instruction = head_is_csr_instruction ||
    head_is_ecall || head_is_mret || head_is_wfi || head_is_fence ||
    head_is_fence_i;
  assign head_special_request = head_is_special_instruction &&
    !rob_head_complete && !flush_valid && !system_redirect_pending_q;

  always_comb begin
    case (rob_head_instruction[13:12])
      2'b01: head_csr_cmd = CSR_CMD_WRITE;
      2'b10: head_csr_cmd = CSR_CMD_SET;
      2'b11: head_csr_cmd = CSR_CMD_CLEAR;
      default: head_csr_cmd = CSR_CMD_NONE;
    endcase
    head_csr_operand = rob_head_instruction[14] ?
      XLEN'(rob_head_instruction[19:15]) : int_read_data[7];
  end

  assign commit_fflags = (retire_fire[0] ? retire_fflags[0] : 5'b0) |
                         (retire_fire[1] ? retire_fflags[1] : 5'b0);
  assign commit_fflags_valid = |commit_fflags;

  assign retire_is_csr = retire_valid[0] &&
    (retire_instruction[0][6:0] == 7'b1110011) &&
    (retire_instruction[0][14:12] != 3'b000);
  assign retire_is_mret = retire_valid[0] &&
    (retire_instruction[0] == 32'h3020_0073);
  assign retire_is_wfi = retire_valid[0] &&
    (retire_instruction[0] == 32'h1050_0073);
  assign retire_is_fence_i = retire_valid[0] &&
    (retire_instruction[0][6:0] == 7'b0001111) &&
    (retire_instruction[0][14:12] == 3'b001);

  assign csr_execute = system_completion_fire && head_is_csr_instruction &&
                       !csr_illegal;
  assign csr_commit = retire_fire[0] && retire_is_csr;

  // A PMP write changes the authority under which prefetched bytes were read.
  // Classify write intent from the retiring instruction (not a later decode).
  // CSRRW[I] writes even for rs1/zimm=0; CSRRS/RC[I] with zero only reads.
  assign retire_is_pmp_write = retire_is_csr &&
    ((retire_instruction[0][31:20] >= 12'h3a0) &&
     (retire_instruction[0][31:20] <= 12'h3bf)) &&
    ((retire_instruction[0][13:12] == 2'b01) ||
     (retire_instruction[0][19:15] != 5'b0));

  // mstatus.FS changes whether prefetched FP operations are legal. Refetch
  // after a committed mstatus write so younger uops decoded under the old
  // state cannot survive the serializing CSR.
  assign retire_is_decode_state_write = retire_is_csr &&
    (retire_instruction[0][31:20] == 12'h300) &&
    ((retire_instruction[0][13:12] == 2'b01) ||
     (retire_instruction[0][19:15] != 5'b0));

  rv_csr_file #(
    .XLEN(XLEN), .PADDR_WIDTH(PADDR_WIDTH), .HAS_C(HAS_C), .HAS_F(HAS_F),
    .HAS_SMODE(HAS_SMODE), .PMP_ENTRIES(8),
    .RESET_MTVEC(TRAP_VECTOR), .HART_ID('0)
  ) u_csr_file (
    .clk_i, .rst_ni, .csr_valid_i(head_special_request &&
                                  head_is_csr_instruction),
    .csr_execute_i(csr_execute), .csr_commit_i(csr_commit),
    .csr_addr_i(rob_head_instruction[31:20]), .csr_cmd_i(head_csr_cmd),
    .csr_operand_i(head_csr_operand),
    .csr_rs1_is_zero_i(rob_head_instruction[19:15] == 0),
    .csr_ready_o(csr_ready), .csr_rdata_o(csr_rdata),
    .csr_illegal_o(csr_illegal), .csr_write_effect_o(csr_write_effect),
    .trap_valid_i(csr_trap_valid), .trap_ready_o(csr_trap_ready),
    .trap_pc_i(csr_trap_pc), .trap_cause_i(csr_trap_cause),
    .trap_tval_i(csr_trap_tval), .trap_is_interrupt_i(csr_trap_is_interrupt),
    .trap_next_pc_i(csr_trap_next_pc), .trap_vector_o(csr_trap_vector),
    .mret_valid_i(head_is_mret),
    .mret_commit_i(retire_fire[0] && retire_is_mret),
    .mret_ready_o(csr_mret_ready), .mret_pc_o(csr_mret_pc),
    .mret_illegal_o(csr_mret_illegal),
    .wfi_valid_i(head_special_request && head_is_wfi),
    .wfi_illegal_o(csr_wfi_illegal), .wfi_wake_o(csr_wfi_wake),
    .irq_software_i, .irq_timer_i, .irq_external_i, .mtime_i,
    .interrupt_pending_o(csr_interrupt_pending),
    .interrupt_cause_o(csr_interrupt_cause),
    .retire_count_i({1'b0,retire_fire[0]} + {1'b0,retire_fire[1]}),
    .fflags_accrue_valid_i(commit_fflags_valid),
    .fflags_accrue_i(commit_fflags),
    .flush_all_i(flush_valid && flush_all), .privilege_o(current_privilege),
    .mstatus_o(csr_mstatus), .mtvec_o(csr_mtvec), .mepc_o(csr_mepc),
    .frm_o(csr_frm), .fflags_o(csr_fflags), .pmpcfg_o(csr_pmpcfg),
    .pmpaddr_o(csr_pmpaddr)
  );

  rv_trap_controller #(
    .XLEN(XLEN), .RESET_VECTOR(RESET_VECTOR)
  ) u_trap_controller (
    .clk_i, .rst_ni,
    .rob_trap_valid_i(rob_trap_valid),
    .rob_trap_pc_i(rob_trap_pc),
    .rob_trap_cause_i(rob_trap_cause),
    .rob_trap_tval_i(rob_trap_tval),
    .rob_empty_i(rob_empty),
    .interrupt_pending_i(csr_interrupt_pending),
    .interrupt_cause_i(csr_interrupt_cause),
    .csr_trap_valid_o(csr_trap_valid),
    .csr_trap_ready_i(csr_trap_ready),
    .csr_trap_pc_o(csr_trap_pc),
    .csr_trap_cause_o(csr_trap_cause),
    .csr_trap_tval_o(csr_trap_tval),
    .csr_trap_is_interrupt_o(csr_trap_is_interrupt),
    .csr_trap_next_pc_o(csr_trap_next_pc),
    .csr_trap_vector_i(csr_trap_vector),
    .retire_fire_i(retire_fire),
    .retire_next_pc_i(retire_next_pc),
    .retire_is_mret_i(retire_is_mret),
    .retire_is_wfi_i(retire_is_wfi),
    .retire_is_fence_i_i(retire_is_fence_i),
    .retire_is_pmp_write_i(retire_is_pmp_write),
    .retire_is_decode_state_write_i(retire_is_decode_state_write),
    .mret_pc_i(csr_mret_pc),
    .wfi_wake_i(csr_wfi_wake),
    .architectural_redirect_valid_o(architectural_redirect_valid),
    .architectural_redirect_pc_o(architectural_redirect_pc),
    .redirect_pending_o(system_redirect_pending_q),
    .architectural_next_pc_o(architectural_next_pc_q),
    .wfi_sleep_o(wfi_sleep_q)
  );

  always_comb begin
    effective_data_privilege = current_privilege;
    if ((current_privilege == PRIV_M) && csr_mstatus[17])
      effective_data_privilege = privilege_e'(csr_mstatus[12:11]);
  end
  assign current_privilege_o = current_privilege;
  assign pmpcfg_o = csr_pmpcfg;
  assign pmpaddr_o = csr_pmpaddr;

  rv_fence_controller #(
    .XLEN(XLEN), .ROB_SEQ_WIDTH(ROB_SEQ_WIDTH)
  ) u_fence_controller (
    .request_valid_i(head_special_request),
    .request_is_fence_i(head_is_fence),
    .request_is_fence_i_i(head_is_fence_i),
    .predecessor_i(rob_head_instruction[27:24]),
    .successor_i(rob_head_instruction[23:20]),
    .sequence_i(rob_head_sequence),
    .next_pc_i(rob_head_pc +
      ((rob_head_instruction_length == INST_LEN_16) ? XLEN'(2) : XLEN'(4))),
    .lsu_memory_idle_i(lsu_memory_idle),
    .i_fabric_idle_i(1'b1),
    .request_ready_o(),
    .completion_valid_o(fence_completion_valid),
    .completion_sequence_o(fence_completion_sequence),
    .frontend_flush_required_o(),
    .frontend_redirect_pc_o()
  );

  always_comb begin
    system_completion_valid = head_special_request;
    if (head_is_fence || head_is_fence_i)
      system_completion_valid = fence_completion_valid;
    system_completion_exception = 1'b0;
    system_completion_cause = EXC_ILLEGAL_INSTRUCTION;
    system_completion_tval = '0;
    if (head_is_csr_instruction && csr_illegal) begin
      system_completion_exception = 1'b1;
      system_completion_tval = XLEN'(rob_head_instruction);
    end else if (head_is_ecall) begin
      system_completion_exception = 1'b1;
      case (current_privilege)
        PRIV_U: system_completion_cause = EXC_ECALL_U;
        PRIV_S: system_completion_cause = EXC_ECALL_S;
        default: system_completion_cause = EXC_ECALL_M;
      endcase
    end else if (head_is_mret && csr_mret_illegal) begin
      system_completion_exception = 1'b1;
      system_completion_tval = XLEN'(rob_head_instruction);
    end else if (head_is_wfi && csr_wfi_illegal) begin
      system_completion_exception = 1'b1;
      system_completion_tval = XLEN'(rob_head_instruction);
    end
    system_completion_fire = system_completion_valid && source_ready[10];
  end

  always_comb begin
    source_valid='0; source_sequence='0; source_dst_valid='0;
    source_dst_class='{default:REG_NONE}; source_dst_phys='0; source_data='0;
    source_exception='0; source_exception_cause=
      '{default:EXC_ILLEGAL_INSTRUCTION}; source_exception_tval='0;
    source_mispredict='0; source_branch_target='0; source_fflags='0;
    source_valid[0]=fast_result_valid[0];
    source_valid[1]=fast_result_valid[1];
    source_valid[2]=mul_result_valid;
    source_valid[3]=div_result_valid;
    source_valid[4]=fpu_result_valid;
    source_sequence[0]=fast_result_sequence[0];
    source_sequence[1]=fast_result_sequence[1];
    source_sequence[2]=mul_result_sequence;
    source_sequence[3]=div_result_sequence;
    source_sequence[4]=fpu_result_sequence;
    source_dst_valid[0]=fast_result_dst_valid[0];
    source_dst_valid[1]=fast_result_dst_valid[1];
    source_dst_valid[2]=mul_result_dst_valid;
    source_dst_valid[3]=div_result_dst_valid;
    source_dst_valid[4]=fpu_result_dst_valid;
    source_dst_class[0]=fast_result_dst_class[0];
    source_dst_class[1]=fast_result_dst_class[1];
    source_dst_class[2]=REG_INT;
    source_dst_class[3]=REG_INT;
    source_dst_class[4]=fpu_result_dst_class;
    source_dst_phys[0]=fast_result_dst_phys[0];
    source_dst_phys[1]=fast_result_dst_phys[1];
    source_dst_phys[2]=mul_result_dst_phys;
    source_dst_phys[3]=div_result_dst_phys;
    source_dst_phys[4]=fpu_result_dst_phys;
    source_data[0]=fast_result_data[0];
    source_data[1]=fast_result_data[1];
    source_data[2]=mul_result_data;
    source_data[3]=div_result_data;
    source_data[4]=fpu_result_data;
    source_exception[0]=fast_result_exception[0];
    source_exception[1]=fast_result_exception[1];
    source_exception_cause[0]=fast_result_cause[0];
    source_exception_cause[1]=fast_result_cause[1];
    source_exception_tval[1]=fast_result_tval[1];
    source_exception_tval[0]=fast_result_tval[0];
    source_mispredict[0]=fast_result_mispredict[0];
    source_mispredict[1]=fast_result_mispredict[1];
    source_branch_target[1]=fast_result_target[1];
    source_branch_target[0]=fast_result_target[0];
    source_fflags[1]=fast_result_fflags[1];
    source_fflags[0]=fast_result_fflags[0];
    source_exception[4]=fpu_result_exception;
    source_exception_cause[4]=fpu_result_cause;
    source_exception_tval[4]=fpu_result_tval;
    source_fflags[4]=fpu_result_fflags;
    for(int unsigned lsu_source=0;lsu_source<5;lsu_source++) begin
      source_valid[5+lsu_source]=lsu_completion_valid[lsu_source];
      source_sequence[5+lsu_source]=lsu_completion_sequence[lsu_source];
      source_dst_valid[5+lsu_source]=lsu_completion_dst_valid[lsu_source];
      source_dst_class[5+lsu_source]=lsu_completion_dst_class[lsu_source];
      source_dst_phys[5+lsu_source]=lsu_completion_dst_phys[lsu_source];
      source_data[5+lsu_source]=lsu_completion_data[lsu_source];
      source_exception[5+lsu_source]=lsu_completion_exception[lsu_source];
      source_exception_cause[5+lsu_source]=lsu_completion_cause[lsu_source];
      source_exception_tval[5+lsu_source]=lsu_completion_tval[lsu_source];
    end
    source_valid[10]=system_completion_valid;
    source_sequence[10]=(head_is_fence || head_is_fence_i) ?
      fence_completion_sequence : rob_head_sequence;
    source_dst_valid[10]=head_is_csr_instruction && !csr_illegal &&
      rob_head_writes_dst;
    source_dst_class[10]=head_is_csr_instruction ? rob_head_dst_class : REG_NONE;
    source_dst_phys[10]=rob_head_dst_phys;
    source_data[10]=csr_rdata;
    source_exception[10]=system_completion_exception;
    source_exception_cause[10]=system_completion_cause;
    source_exception_tval[10]=system_completion_tval;
    fast_result_ready=source_ready[1:0];mul_result_ready=source_ready[2];
    div_result_ready=source_ready[3];
    fpu_result_ready=source_ready[4];
    lsu_completion_ready=source_ready[9:5];
  end

  always_comb begin
    for (int unsigned src = 0; src < WB_SOURCES; src++) begin
      raw_payload[src].sequence_id   = source_sequence[src];
      raw_payload[src].dst_valid     = source_dst_valid[src];
      raw_payload[src].dst_class     = source_dst_class[src];
      raw_payload[src].dst_phys      = source_dst_phys[src];
      raw_payload[src].data          = source_data[src];
      raw_payload[src].exception     = source_exception[src];
      raw_payload[src].cause         = source_exception_cause[src];
      raw_payload[src].tval          = source_exception_tval[src];
      raw_payload[src].mispredict    = source_mispredict[src];
      raw_payload[src].branch_target = source_branch_target[src];
      raw_payload[src].fflags        = source_fflags[src];
      if ((src >= SKID_FIRST) && (src <= SKID_LAST) && skid_valid_q[src]) begin
        wb_source_valid[src] = 1'b1;
        wb_payload[src]      = skid_q[src];
        source_ready[src]    = 1'b0;
      end else begin
        wb_source_valid[src] = source_valid[src];
        wb_payload[src]      = raw_payload[src];
        source_ready[src]    = ((src >= SKID_FIRST) && (src <= SKID_LAST)) ?
                               1'b1 : wb_source_ready[src];
      end
      wb_source_sequence[src]        = wb_payload[src].sequence_id;
      wb_source_dst_valid[src]       = wb_payload[src].dst_valid;
      wb_source_dst_class[src]       = wb_payload[src].dst_class;
      wb_source_dst_phys[src]        = wb_payload[src].dst_phys;
      wb_source_data[src]            = wb_payload[src].data;
      wb_source_exception[src]       = wb_payload[src].exception;
      wb_source_exception_cause[src] = wb_payload[src].cause;
      wb_source_exception_tval[src]  = wb_payload[src].tval;
      wb_source_mispredict[src]      = wb_payload[src].mispredict;
      wb_source_branch_target[src]   = wb_payload[src].branch_target;
      wb_source_fflags[src]          = wb_payload[src].fflags;
    end
  end

  // A presented result that the arbiter does not take (write or discard) is
  // captured and presented from the skid until it is taken.  The arbiter's
  // ready already covers flush and ROB-liveness discards.
  always_ff @(posedge clk_i) begin
    if (!rst_ni) begin
      skid_valid_q <= '0;
      skid_q <= '0;
    end else begin
      for (int unsigned src = SKID_FIRST; src <= SKID_LAST; src++) begin
        if (skid_valid_q[src]) begin
          if (wb_source_ready[src])
            skid_valid_q[src] <= 1'b0;
        end else if (source_valid[src] && !wb_source_ready[src]) begin
          skid_valid_q[src] <= 1'b1;
          skid_q[src] <= raw_payload[src];
        end
      end
    end
  end

  // Direct wakeup is qualified like a live arbiter write minus the port grant:
  // valid, claims a destination, no exception.  No source presents a
  // squashed result after its flush cycle: the FU result registers and the
  // FPU issue register kill squashed work in the flush cycle, the skids are
  // drained by the arbiter's flush discard, and a load response for a
  // request squashed while outstanding arrives with its destination claim
  // cleared (rv_lsu_cluster.load_meta_live_q).  So ROB liveness -- a 48-entry
  // CAM per query -- is not needed in front of issue selection.

  // No flush gate: a granted system op is the ROB head, so it survives any
  // flush, and a consumer between it and the flush boundary survives too and
  // must still be woken.
  logic system_wake_valid_q;
  reg_class_e system_wake_class_q;
  logic [PHYS_TAG_WIDTH-1:0] system_wake_phys_q;
  always_ff @(posedge clk_i) begin
    if (!rst_ni) begin
      system_wake_valid_q <= 1'b0;
      system_wake_class_q <= REG_NONE;
      system_wake_phys_q <= '0;
    end else begin
      system_wake_valid_q <= wb_source_valid[SYSTEM_SOURCE] &&
        wb_source_ready[SYSTEM_SOURCE] && wb_source_live[SYSTEM_SOURCE] &&
        wb_source_dst_valid[SYSTEM_SOURCE] &&
        !wb_source_exception[SYSTEM_SOURCE] &&
        (wb_source_dst_class[SYSTEM_SOURCE] != REG_NONE);
      system_wake_class_q <= wb_source_dst_class[SYSTEM_SOURCE];
      system_wake_phys_q <= wb_source_dst_phys[SYSTEM_SOURCE];
    end
  end

  always_comb begin
    for (int unsigned w = 0; w < DIRECT_SOURCE_PORTS; w++) begin
      direct_wake_valid[w] =
        wb_source_valid[DIRECT_WAKE_SOURCE[w]] &&
        wb_source_dst_valid[DIRECT_WAKE_SOURCE[w]] &&
        !wb_source_exception[DIRECT_WAKE_SOURCE[w]] &&
        (wb_source_dst_class[DIRECT_WAKE_SOURCE[w]] != REG_NONE);
      direct_wake_class[w] = wb_source_dst_class[DIRECT_WAKE_SOURCE[w]];
      direct_wake_phys[w]  = wb_source_dst_phys[DIRECT_WAKE_SOURCE[w]];
      direct_wake_data[w]  = wb_source_data[DIRECT_WAKE_SOURCE[w]];
    end
    // The system result is already in the PRF when this wakeup is seen, so
    // it never needs to act as a bypass source.
    if (INT_ISSUE_PIPELINE) begin
      for(int lane=0;lane<2;lane++) begin
        // Operand-stage -> FIFO head OR tail -> PRF has continuous bypass.
        // Never put this cycle's WB grant/ROB CAM in front of IQ wakeup.
        direct_wake_valid[DIRECT_SOURCE_PORTS+lane]=int_issue_valid_q[lane] &&
          !flush_valid && int_issue_q[lane].dst_valid &&
          (int_issue_q[lane].dst_class != REG_NONE);
        direct_wake_class[DIRECT_SOURCE_PORTS+lane]=int_issue_q[lane].dst_class;
        direct_wake_phys[DIRECT_SOURCE_PORTS+lane]=int_issue_q[lane].dst_phys;
        direct_wake_data[DIRECT_SOURCE_PORTS+lane]=alu_result[lane];
        direct_wake_valid[DIRECT_SOURCE_PORTS+2+lane]=fast_pending_valid[lane] &&
          fast_pending_dst_valid[lane] && !fast_pending_exception[lane] &&
          (fast_pending_dst_class[lane]!=REG_NONE);
        direct_wake_class[DIRECT_SOURCE_PORTS+2+lane]=fast_pending_dst_class[lane];
        direct_wake_phys[DIRECT_SOURCE_PORTS+2+lane]=fast_pending_dst_phys[lane];
        direct_wake_data[DIRECT_SOURCE_PORTS+2+lane]=fast_pending_data[lane];
      end
    end
    direct_wake_valid[DIRECT_BYPASS_PORTS] = system_wake_valid_q;
    direct_wake_class[DIRECT_BYPASS_PORTS] = system_wake_class_q;
    direct_wake_phys[DIRECT_BYPASS_PORTS]  = system_wake_phys_q;
    direct_wake_data[DIRECT_BYPASS_PORTS]  = '0;
  end

`ifndef SYNTHESIS
  if (INT_ISSUE_PIPELINE) begin : g_preview_persistence
    for (genvar lane=0;lane<2;lane++) begin : g_lane
      // If the stage holds, preview persists; otherwise its result remains
      // at the head or tail. Flush invalidates the promise only for killed work.
      assert property (@(posedge clk_i) disable iff (!rst_ni || flush_valid)
        direct_wake_valid[DIRECT_SOURCE_PORTS+lane] |=>
          (direct_wake_valid[lane] &&
           direct_wake_phys[lane] == $past(direct_wake_phys[DIRECT_SOURCE_PORTS+lane]) &&
           direct_wake_data[lane] == $past(direct_wake_data[DIRECT_SOURCE_PORTS+lane])) ||
          (direct_wake_valid[DIRECT_SOURCE_PORTS+lane] &&
           direct_wake_phys[DIRECT_SOURCE_PORTS+lane] == $past(direct_wake_phys[DIRECT_SOURCE_PORTS+lane]) &&
           direct_wake_data[DIRECT_SOURCE_PORTS+lane] == $past(direct_wake_data[DIRECT_SOURCE_PORTS+lane])) ||
          (direct_wake_valid[DIRECT_SOURCE_PORTS+2+lane] &&
           direct_wake_phys[DIRECT_SOURCE_PORTS+2+lane] == $past(direct_wake_phys[DIRECT_SOURCE_PORTS+lane]) &&
           direct_wake_data[DIRECT_SOURCE_PORTS+2+lane] == $past(direct_wake_data[DIRECT_SOURCE_PORTS+lane])));
    end
  end
  for (genvar lhs = 0; lhs < DIRECT_BYPASS_PORTS; lhs++) begin : g_direct_unique_lhs
    for (genvar rhs = lhs + 1; rhs < DIRECT_BYPASS_PORTS; rhs++) begin : g_direct_unique_rhs
      property p_direct_unique_tag;
        @(posedge clk_i) disable iff (!rst_ni || flush_valid)
          direct_wake_valid[lhs] && direct_wake_valid[rhs] &&
          (direct_wake_class[lhs] == direct_wake_class[rhs]) |->
          (direct_wake_phys[lhs] != direct_wake_phys[rhs]);
      endproperty
      assert property (p_direct_unique_tag);
    end
  end
  // No direct wakeup may come from a result the ROB no longer holds.
  always_ff @(posedge clk_i) begin
    if (!rst_ni) begin
    end else begin
      for (int unsigned w = 0; w < DIRECT_SOURCE_PORTS; w++)
        if (direct_wake_valid[w] && !flush_valid)
          assert (wb_source_live[DIRECT_WAKE_SOURCE[w]])
            else $error("direct wake from non-live source %0d seq %0d",
                        DIRECT_WAKE_SOURCE[w],
                        wb_source_sequence[DIRECT_WAKE_SOURCE[w]]);
    end
  end
`endif

  rv_writeback_arbiter #(.XLEN(XLEN),.SOURCE_COUNT(WB_SOURCES),
    .PHYS_TAG_WIDTH(PHYS_TAG_WIDTH),.ROB_SEQ_WIDTH(ROB_SEQ_WIDTH),
    .INT_WRITE_PORTS(2),.FP_WRITE_PORTS(2),.ROB_COMPLETE_PORTS(4)) u_wb(
    .source_valid_i(wb_source_valid),.source_ready_o(wb_source_ready),
    .source_live_i(wb_source_live),.source_sequence_i(wb_source_sequence),
    .source_destination_valid_i(wb_source_dst_valid),
    .source_destination_class_i(wb_source_dst_class),
    .source_destination_phys_i(wb_source_dst_phys),.source_data_i(wb_source_data),
    .source_exception_valid_i(wb_source_exception),
    .source_exception_cause_i(wb_source_exception_cause),
    .source_exception_tval_i(wb_source_exception_tval),
    .source_branch_mispredict_i(wb_source_mispredict),
    .source_branch_target_i(wb_source_branch_target),.source_fflags_i(wb_source_fflags),
    .flush_valid_i(flush_valid),.flush_all_i(flush_all),
    .flush_sequence_i(flush_sequence),.int_wb_valid_o(int_wb_valid),
    .int_wb_phys_o(int_wb_phys),.int_wb_data_o(int_wb_data),
    .fp_wb_valid_o(fp_wb_valid),.fp_wb_phys_o(fp_wb_phys),
    .fp_wb_data_o(fp_wb_data),.wakeup_valid_o(wakeup_valid),
    .wakeup_class_o(wakeup_class),.wakeup_phys_o(wakeup_phys),
    .complete_valid_o(complete_valid),.complete_sequence_o(complete_sequence),
    .complete_exception_valid_o(complete_exception),
    .complete_exception_cause_o(complete_cause),
    .complete_exception_tval_o(complete_tval),
    .complete_branch_mispredict_o(complete_mispredict),
    .complete_branch_target_o(complete_target),.complete_fflags_o(complete_fflags));

  rv_rob #(.XLEN(XLEN),.ROB_ENTRIES(ROB_ENTRIES),.SEQ_WIDTH(ROB_SEQ_WIDTH),
    .PHYS_TAG_WIDTH(PHYS_TAG_WIDTH),.LQ_INDEX_WIDTH(LQ_WIDTH),
    .SQ_INDEX_WIDTH(SQ_WIDTH),.COMPLETE_PORTS(4),
    .LIVE_QUERY_PORTS(WB_SOURCES)) u_rob(
    .clk_i,.rst_ni,.alloc_valid_i(dec_valid&{2{dispatch_fire}}),
    .alloc_ready_o(rob_alloc_ready),.alloc_index_o(rob_alloc_index),
    .alloc_sequence_o(rob_alloc_sequence),.alloc_pc_i(dec_pc),
    .alloc_instruction_i(dec_raw),.alloc_instruction_length_i(dec_len),
    .alloc_complete_i(backend_exception),
    .alloc_writes_destination_i(renamed_writes_dst),
    .alloc_destination_class_i(dec_dst_class),.alloc_destination_arch_i(dec_dst_arch),
    .alloc_destination_phys_i(renamed_dst_phys),.alloc_stale_phys_i(stale_phys),
    .alloc_source0_phys_i(src0_phys),
    .alloc_is_store_i(dec_is_store),.alloc_is_load_i(dec_is_load),
    .alloc_lq_index_i(lsq_dispatch_lq_index),
    .alloc_sq_index_i(lsq_dispatch_sq_index),.alloc_is_branch_i(dec_is_branch),
    .alloc_serializing_i(dec_serializing),
    .alloc_exception_valid_i(backend_exception),
    .alloc_exception_cause_i(backend_exception_cause),
    .alloc_exception_tval_i(backend_exception_tval),.complete_valid_i(complete_valid),
    .complete_sequence_i(complete_sequence),
    .complete_exception_valid_i(complete_exception),
    .complete_exception_cause_i(complete_cause),
    .complete_exception_tval_i(complete_tval),
    .complete_fflags_i(complete_fflags),
    .complete_branch_mispredict_i(complete_mispredict),
    .complete_branch_target_i(complete_target),
    .live_query_sequence_i(wb_source_sequence),.live_query_valid_o(wb_source_live),
    .retire_valid_o(retire_valid),.retire_ready_i(retire_ready),
    .retire_sequence_o(retire_sequence),.retire_pc_o(retire_pc),
    .retire_instruction_o(retire_instruction),
    .retire_instruction_length_o(retire_instruction_length),
    .retire_next_pc_o(retire_next_pc),
    .retire_writes_destination_o(retire_writes_dst),
    .retire_destination_class_o(retire_dst_class),
    .retire_destination_arch_o(retire_dst_arch),
    .retire_destination_phys_o(retire_dst_phys),
    .retire_stale_phys_o(retire_stale_phys),.retire_is_store_o(retire_is_store),
    .retire_is_load_o(retire_is_load),.retire_lq_index_o(retire_lq_index),
    .retire_sq_index_o(retire_sq_index),.retire_fflags_o(retire_fflags),
    .head_valid_o(rob_head_valid),
    .head_complete_o(rob_head_complete),
    .head_sequence_o(rob_head_sequence),.head_pc_o(rob_head_pc),
    .head_instruction_o(rob_head_instruction),
    .head_instruction_length_o(rob_head_instruction_length),
    .head_writes_destination_o(rob_head_writes_dst),
    .head_destination_class_o(rob_head_dst_class),
    .head_destination_phys_o(rob_head_dst_phys),
    .head_source0_phys_o(rob_head_src0_phys),
    .trap_valid_o(rob_trap_valid),
    .trap_ready_i(rob_trap_ready),.trap_sequence_o(rob_trap_sequence),
    .trap_pc_o(rob_trap_pc),.trap_cause_o(rob_trap_cause),
    .trap_tval_o(rob_trap_tval),.flush_all_i(flush_valid&&flush_all),
    .flush_younger_i(flush_valid&&!flush_all),.flush_sequence_i(flush_sequence),
    .count_o(rob_count),.empty_o(rob_empty),.full_o(rob_full));

  // Branch sequence metadata allows one-time checkpoint restore/release.
  logic branch_valid_q[0:SEQ_SPACE-1],branch_resolved_q[0:SEQ_SPACE-1];
  logic [CP_WIDTH-1:0] branch_cp_q[0:SEQ_SPACE-1];
  logic [XLEN-1:0] branch_pc_q[0:SEQ_SPACE-1];
  logic [31:0] branch_instruction_q[0:SEQ_SPACE-1];
  inst_len_e branch_inst_len_q[0:SEQ_SPACE-1];
  prediction_meta_t branch_prediction_q[0:SEQ_SPACE-1];
  logic branch_actual_taken_q[0:SEQ_SPACE-1];
  logic [XLEN-1:0] branch_actual_target_q[0:SEQ_SPACE-1];
  logic branch_resolve_valid,branch_resolve_live,branch_resolve_drop;
  assign branch_resolve_valid=fast_result_valid[0]&&
    branch_valid_q[fast_result_sequence[0]]&&!branch_resolved_q[fast_result_sequence[0]];
  assign branch_resolve_live=wb_source_live[0];
  always_comb begin
    bp_resolve_valid_o = branch_resolve_valid && branch_resolve_live;
    bp_resolve_pc_o = branch_pc_q[fast_result_sequence[0]];
    bp_resolve_instruction_o = branch_instruction_q[fast_result_sequence[0]];
    bp_resolve_inst_len_o = branch_inst_len_q[fast_result_sequence[0]];
    bp_resolve_taken_o = branch_actual_taken_q[fast_result_sequence[0]];
    bp_resolve_target_o = branch_actual_target_q[fast_result_sequence[0]];
    bp_resolve_mispredict_o = fast_result_mispredict[0];
    bp_resolve_prediction_o = branch_prediction_q[fast_result_sequence[0]];
    bp_commit_valid_o = '0;
    bp_commit_pc_o = retire_pc;
    bp_commit_instruction_o = retire_instruction;
    bp_commit_inst_len_o = retire_instruction_length;
    bp_commit_taken_o = '0;
    for (int unsigned lane = 0; lane < 2; lane++) begin
      bp_commit_valid_o[lane] = retire_fire[lane] &&
        branch_valid_q[retire_sequence[lane]];
      bp_commit_taken_o[lane] =
        branch_actual_taken_q[retire_sequence[lane]];
    end
  end
  rv_branch_recovery #(.XLEN(XLEN),.ROB_SEQ_WIDTH(ROB_SEQ_WIDTH),
    .CHECKPOINT_ID_WIDTH(CP_WIDTH)) u_recovery(
    .trap_redirect_valid_i(architectural_redirect_valid),
    .trap_redirect_pc_i(architectural_redirect_pc),
    .resolve_valid_i(branch_resolve_valid),.resolve_live_i(branch_resolve_live),
    .resolve_sequence_i(fast_result_sequence[0]),
    .resolve_checkpoint_id_i(branch_cp_q[fast_result_sequence[0]]),
    .resolve_mispredict_i(fast_result_mispredict[0]),
    .resolve_next_pc_i(fast_result_target[0]),.redirect_valid_o(redirect_valid_o),
    .redirect_pc_o(redirect_pc_o),.flush_valid_o(flush_valid),
    .flush_all_o(flush_all),.flush_sequence_o(flush_sequence),
    .checkpoint_restore_valid_o(cp_restore_valid),
    .checkpoint_restore_id_o(cp_restore_id),
    .checkpoint_release_valid_o(cp_release_valid),
    .checkpoint_release_id_o(cp_release_id),.resolve_drop_o(branch_resolve_drop));

  always_comb begin
    cp_clear_mask='0;
    if(cp_restore_valid) for(int unsigned checkpoint=0;
      checkpoint<BR_CHECKPOINTS;checkpoint++)
      if(cp_valid[checkpoint]&&((cp_sequence_q[checkpoint]==flush_sequence)||
         sequence_after_backend(cp_sequence_q[checkpoint],flush_sequence)))
        cp_clear_mask[checkpoint]=1'b1;
  end
  always_ff @(posedge clk_i) begin
    if(!rst_ni) begin
      for(int unsigned seq_index=0;seq_index<SEQ_SPACE;seq_index++) begin
        branch_valid_q[seq_index]<=1'b0;branch_resolved_q[seq_index]<=1'b0;
        branch_cp_q[seq_index]<='0;
        branch_pc_q[seq_index]<='0;
        branch_instruction_q[seq_index]<='0;
        branch_inst_len_q[seq_index]<=INST_LEN_NONE;
        branch_prediction_q[seq_index]<='0;
        branch_actual_taken_q[seq_index]<=1'b0;
        branch_actual_target_q[seq_index]<='0;
      end
      for(int unsigned checkpoint=0;checkpoint<BR_CHECKPOINTS;checkpoint++)
        cp_sequence_q[checkpoint]<='0;
    end else begin
      if(dispatch_fire) for(int unsigned lane=0;lane<2;lane++) if(dec_valid[lane]) begin
        branch_valid_q[rob_alloc_sequence[lane]]<=cp_save[lane];
        branch_resolved_q[rob_alloc_sequence[lane]]<=1'b0;
        branch_cp_q[rob_alloc_sequence[lane]]<=cp_save_id[lane];
        branch_pc_q[rob_alloc_sequence[lane]]<=dec_pc[lane];
        // The predictor classifies compressed control flow from the original
        // 16-bit encoding together with INST_LEN_16.  Execution uses the
        // canonical expansion in the IQ, but resolve/training must retain the
        // raw instruction or C.Bxx/C.J/C.JR/C.JALR silently miss all predictor
        // training and speculative-history recovery.
        branch_instruction_q[rob_alloc_sequence[lane]]<=dec_raw[lane];
        branch_inst_len_q[rob_alloc_sequence[lane]]<=dec_len[lane];
        branch_prediction_q[rob_alloc_sequence[lane]]<=dec_prediction[lane];
        if(cp_save[lane])cp_sequence_q[cp_save_id[lane]]<=rob_alloc_sequence[lane];
      end
      if(branch_resolve_valid&&branch_resolve_live)
        branch_resolved_q[fast_result_sequence[0]]<=1'b1;
      if (branch_execute_valid && fast_req_ready[0]) begin
        branch_actual_taken_q[branch_execute_sequence] <= branch_taken;
        branch_actual_target_q[branch_execute_sequence] <= branch_target;
      end
    end
  end

  // At most one decode bundle can introduce serializing operations while no
  // older barrier is live, so a two-entry ordered tracker covers both lanes.
  // Younger IQ entries may be allocated, but cannot issue across the oldest
  // CSR/system/fence barrier.
  always_ff @(posedge clk_i) begin
    if (!rst_ni || (flush_valid && flush_all)) begin
      serial_barrier_valid_q <= '0;
      serial_barrier_sequence_q <= '0;
    end else if (flush_valid && !flush_all) begin
      if (serial_barrier_valid_q[0] &&
          sequence_after_backend(serial_barrier_sequence_q[0],
                                 flush_sequence)) begin
        serial_barrier_valid_q <= '0;
      end else if (serial_barrier_valid_q[1] &&
                   sequence_after_backend(serial_barrier_sequence_q[1],
                                          flush_sequence)) begin
        serial_barrier_valid_q[1] <= 1'b0;
      end
    end else begin
      if (serial_barrier_valid_q[0] &&
          ((retire_fire[0] &&
            (retire_sequence[0] == serial_barrier_sequence_q[0])) ||
           (retire_fire[1] &&
            (retire_sequence[1] == serial_barrier_sequence_q[0])))) begin
        serial_barrier_valid_q[0] <= serial_barrier_valid_q[1];
        serial_barrier_sequence_q[0] <= serial_barrier_sequence_q[1];
        serial_barrier_valid_q[1] <= 1'b0;
      end

      if (dispatch_fire && !(|serial_barrier_valid_q)) begin
        case ({dec_valid[1] && dec_serializing[1],
               dec_valid[0] && dec_serializing[0]})
          2'b01: begin
            serial_barrier_valid_q <= 2'b01;
            serial_barrier_sequence_q[0] <= rob_alloc_sequence[0];
          end
          2'b10: begin
            serial_barrier_valid_q <= 2'b01;
            serial_barrier_sequence_q[0] <= rob_alloc_sequence[1];
          end
          2'b11: begin
            serial_barrier_valid_q <= 2'b11;
            serial_barrier_sequence_q[0] <= rob_alloc_sequence[0];
            serial_barrier_sequence_q[1] <= rob_alloc_sequence[1];
          end
          default: begin end
        endcase
      end
    end
  end

  // Precise commit and architectural trace.
  always_comb begin
    retire_ready[0]=!flush_valid&&!rob_trap_valid&&lsu_commit_ready[0];
    retire_ready[1]=!flush_valid&&!rob_trap_valid&&lsu_commit_ready[1];
    retire_fire[0]=retire_valid[0]&&retire_ready[0];
    retire_fire[1]=retire_valid[1]&&retire_ready[1]&&retire_fire[0];
    rob_trap_ready=rob_trap_valid&&csr_trap_valid&&csr_trap_ready&&
      flush_valid&&flush_all;
    trace_valid_o=retire_fire;trace_pc_o=retire_pc;trace_instr_o=retire_instruction;
    trace_rd_o=retire_dst_arch;trace_rd_write_o=retire_fire&retire_writes_dst;
    trace_rd_wdata_o='0;trace_rd_fp_o='0;trace_trap_o='0;
    trace_cause_o='0;trace_tval_o='0;
    for(int unsigned lane=0;lane<2;lane++) begin
      case(retire_dst_class[lane])
        REG_INT:trace_rd_wdata_o[lane]=int_read_data[6+lane];
        REG_FP:begin
          trace_rd_wdata_o[lane]={{(XLEN-32){1'b0}},fp_read_data[6+lane]};
          trace_rd_fp_o[lane]=trace_rd_write_o[lane];
        end
        default:trace_rd_wdata_o[lane]='0;
      endcase
    end
    if(rob_trap_valid) begin
      trace_valid_o=2'b01;trace_pc_o[0]=rob_trap_pc;
      trace_instr_o[0]=retire_instruction[0];trace_rd_o[0]='0;
      trace_rd_write_o[0]=1'b0;trace_rd_fp_o[0]=1'b0;
      trace_rd_wdata_o[0]='0;trace_trap_o[0]=1'b1;
      trace_cause_o[0]=csr_trap_cause;trace_tval_o[0]=rob_trap_tval;
    end else if(csr_trap_valid && csr_trap_is_interrupt) begin
      trace_valid_o=2'b01;trace_pc_o[0]=architectural_next_pc_q;
      trace_instr_o[0]='0;trace_rd_o[0]='0;
      trace_rd_write_o[0]=1'b0;trace_rd_fp_o[0]=1'b0;
      trace_rd_wdata_o[0]='0;trace_trap_o[0]=1'b1;
      trace_cause_o[0]=csr_trap_cause;trace_tval_o[0]='0;
    end
  end

  logic unused;
  always_comb unused=irq_software_i^
    irq_timer_i^irq_external_i^rename_fire^rob_alloc_ready^iq_dispatch_ready^
    iq_empty^iq_full^rob_empty^rob_full^(^rob_alloc_index)^(^complete_fflags)^
    (^retire_sequence)^(^retire_is_store)^(^retire_is_load)^
    (^retire_lq_index)^(^retire_sq_index)^
    (^rob_trap_sequence)^(^rob_trap_cause)^(^rob_trap_tval)^branch_resolve_drop^
    branch_taken^(^dec_csr_addr)^(^dec_csr_immediate)^(^dec_is_load)^
    (^dec_is_store)^(^dec_is_csr)^(^dec_is_fence_i)^
    (^dec_fence_predecessor)^(^dec_fence_successor)^(^cand_instruction)^
    (^cand_mem_size)^(^cand_mem_unsigned)^(^cand_rounding)^(^cand_cp_valid)^
    (^cand_cp_id)^(^cand_lq_index)^(^cand_sq_index)^(^issue_valid)^
    (^issue_candidate)^(^issue_port)^(^int_read_ready)^(^fp_read_ready)^
    (^cand_grant_port)^store_buffer_empty^store_machine_check^
    (^port_mem_unsigned)^
    (^lsq_dispatch_lq_valid)^(^lsq_dispatch_sq_valid);

`ifndef SYNTHESIS
  // An eligible interrupt stops younger dispatch and lets the ROB drain to
  // the precise architectural boundary selected by rv_trap_controller.
  property p_interrupt_quiesces_dispatch;
    @(posedge clk_i) disable iff (!rst_ni)
      csr_interrupt_pending |-> !dispatch_fire;
  endproperty
  assert property (p_interrupt_quiesces_dispatch);

  property p_wfi_sleep_quiesces_dispatch;
    @(posedge clk_i) disable iff (!rst_ni)
      wfi_sleep_q |-> !dispatch_fire;
  endproperty
  assert property (p_wfi_sleep_quiesces_dispatch);

  property p_head_exception_blocks_normal_retire;
    @(posedge clk_i) disable iff (!rst_ni)
      rob_trap_valid |-> !(|retire_fire);
  endproperty
  assert property (p_head_exception_blocks_normal_retire);
`endif

  initial begin
    if((XLEN!=32)&&(XLEN!=64))$fatal(1,"Backend XLEN must be 32 or 64");
    if(ROB_ENTRIES>=(1<<(ROB_SEQ_WIDTH-1)))$fatal(1,"ROB sequence space too small");
    if((INT_PHYS_REGS<32)||(FP_PHYS_REGS<32))$fatal(1,"PRFs too small");
    if((BR_CHECKPOINTS<2)||(LQ_ENTRIES<2)||(SQ_ENTRIES<2)||
       (STORE_BUFFER_ENTRIES<2))$fatal(1,"Backend structures too small");
  end
endmodule
