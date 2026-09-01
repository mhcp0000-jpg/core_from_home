module rv_rob_tb;
  import rv_ooo_pkg::*;

  localparam int unsigned ROB_ENTRIES = 48;
  localparam int unsigned SEQ_WIDTH = ROB_SEQ_WIDTH;
  localparam int unsigned TAG_WIDTH = 7;
  localparam int unsigned SQ_WIDTH = 4;
  localparam int unsigned LQ_WIDTH = 5;
  localparam int unsigned ROB_INDEX_WIDTH = $clog2(ROB_ENTRIES);
  localparam int unsigned ROB_COUNT_WIDTH = $clog2(ROB_ENTRIES + 1);

  logic clk;
  logic rst_n;
  logic [1:0] alloc_valid;
  logic alloc_ready;
  logic [1:0][ROB_INDEX_WIDTH-1:0] alloc_index;
  logic [1:0][SEQ_WIDTH-1:0] alloc_sequence;
  logic [1:0][31:0] alloc_pc;
  logic [1:0][31:0] alloc_instruction;
  logic [1:0][1:0] alloc_instruction_length;
  logic [1:0] alloc_complete;
  logic [1:0] alloc_writes_destination;
  reg_class_e [1:0] alloc_destination_class;
  logic [1:0][4:0] alloc_destination_arch;
  logic [1:0][TAG_WIDTH-1:0] alloc_destination_phys;
  logic [1:0][TAG_WIDTH-1:0] alloc_stale_phys;
  logic [1:0][TAG_WIDTH-1:0] alloc_source0_phys;
  logic [1:0] alloc_is_store;
  logic [1:0] alloc_is_load;
  logic [1:0][LQ_WIDTH-1:0] alloc_lq_index;
  logic [1:0][SQ_WIDTH-1:0] alloc_sq_index;
  logic [1:0] alloc_is_branch;
  logic [1:0] alloc_serializing;
  logic [1:0] alloc_exception_valid;
  exception_code_e [1:0] alloc_exception_cause;
  logic [1:0][31:0] alloc_exception_tval;

  logic [1:0] complete_valid;
  logic [1:0][SEQ_WIDTH-1:0] complete_sequence;
  logic [1:0] complete_exception_valid;
  exception_code_e [1:0] complete_exception_cause;
  logic [1:0][31:0] complete_exception_tval;
  logic [1:0][4:0] complete_fflags;
  logic [1:0] complete_branch_mispredict;
  logic [1:0][31:0] complete_branch_target;
  logic [3:0][SEQ_WIDTH-1:0] live_query_sequence;
  logic [3:0] live_query_valid;

  logic [1:0] retire_valid;
  logic [1:0] retire_ready;
  logic [1:0][SEQ_WIDTH-1:0] retire_sequence;
  logic [1:0][31:0] retire_pc;
  logic [1:0][31:0] retire_instruction;
  logic [1:0][1:0] retire_instruction_length;
  logic [1:0][31:0] retire_next_pc;
  logic [1:0] retire_writes_destination;
  reg_class_e [1:0] retire_destination_class;
  logic [1:0][4:0] retire_destination_arch;
  logic [1:0][TAG_WIDTH-1:0] retire_destination_phys;
  logic [1:0][TAG_WIDTH-1:0] retire_stale_phys;
  logic [1:0] retire_is_store;
  logic [1:0] retire_is_load;
  logic [1:0][LQ_WIDTH-1:0] retire_lq_index;
  logic [1:0][SQ_WIDTH-1:0] retire_sq_index;
  logic [1:0][4:0] retire_fflags;
  logic head_valid;
  logic head_complete;
  logic [SEQ_WIDTH-1:0] head_sequence;
  logic [31:0] head_pc, head_instruction;
  logic [1:0] head_instruction_length;
  logic head_writes_destination;
  reg_class_e head_destination_class;
  logic [TAG_WIDTH-1:0] head_destination_phys, head_source0_phys;
  logic trap_valid;
  logic trap_ready;
  logic [SEQ_WIDTH-1:0] trap_sequence;
  logic [31:0] trap_pc;
  exception_code_e trap_cause;
  logic [31:0] trap_tval;
  logic flush_all;
  logic flush_younger;
  logic [SEQ_WIDTH-1:0] flush_sequence;
  logic [ROB_COUNT_WIDTH-1:0] count;
  logic empty;
  logic full;

  logic [1:0][SEQ_WIDTH-1:0] first_sequence;
  logic [1:0][SEQ_WIDTH-1:0] second_sequence;
  logic [SEQ_WIDTH-1:0] third_sequence;

  always #5 clk = ~clk;

  rv_rob #(
    .ROB_ENTRIES    (ROB_ENTRIES),
    .SEQ_WIDTH      (SEQ_WIDTH),
    .PHYS_TAG_WIDTH (TAG_WIDTH),
    .LQ_INDEX_WIDTH (LQ_WIDTH),
    .SQ_INDEX_WIDTH (SQ_WIDTH),
    .COMPLETE_PORTS  (2),
    .LIVE_QUERY_PORTS(4)
  ) u_dut (
    .clk_i                     (clk),
    .rst_ni                    (rst_n),
    .alloc_valid_i             (alloc_valid),
    .alloc_ready_o             (alloc_ready),
    .alloc_index_o             (alloc_index),
    .alloc_sequence_o          (alloc_sequence),
    .alloc_pc_i                (alloc_pc),
    .alloc_instruction_i       (alloc_instruction),
    .alloc_instruction_length_i(alloc_instruction_length),
    .alloc_complete_i          (alloc_complete),
    .alloc_writes_destination_i(alloc_writes_destination),
    .alloc_destination_class_i (alloc_destination_class),
    .alloc_destination_arch_i  (alloc_destination_arch),
    .alloc_destination_phys_i  (alloc_destination_phys),
    .alloc_stale_phys_i        (alloc_stale_phys),
    .alloc_source0_phys_i      (alloc_source0_phys),
    .alloc_is_store_i          (alloc_is_store),
    .alloc_is_load_i           (alloc_is_load),
    .alloc_lq_index_i          (alloc_lq_index),
    .alloc_sq_index_i          (alloc_sq_index),
    .alloc_is_branch_i         (alloc_is_branch),
    .alloc_serializing_i       (alloc_serializing),
    .alloc_exception_valid_i   (alloc_exception_valid),
    .alloc_exception_cause_i   (alloc_exception_cause),
    .alloc_exception_tval_i    (alloc_exception_tval),
    .complete_valid_i          (complete_valid),
    .complete_sequence_i       (complete_sequence),
    .complete_exception_valid_i(complete_exception_valid),
    .complete_exception_cause_i(complete_exception_cause),
    .complete_exception_tval_i (complete_exception_tval),
    .complete_fflags_i         (complete_fflags),
    .complete_branch_mispredict_i(complete_branch_mispredict),
    .complete_branch_target_i  (complete_branch_target),
    .live_query_sequence_i     (live_query_sequence),
    .live_query_valid_o        (live_query_valid),
    .retire_valid_o            (retire_valid),
    .retire_ready_i            (retire_ready),
    .retire_sequence_o         (retire_sequence),
    .retire_pc_o               (retire_pc),
    .retire_instruction_o      (retire_instruction),
    .retire_instruction_length_o(retire_instruction_length),
    .retire_next_pc_o          (retire_next_pc),
    .retire_writes_destination_o(retire_writes_destination),
    .retire_destination_class_o(retire_destination_class),
    .retire_destination_arch_o (retire_destination_arch),
    .retire_destination_phys_o (retire_destination_phys),
    .retire_stale_phys_o       (retire_stale_phys),
    .retire_is_store_o         (retire_is_store),
    .retire_is_load_o          (retire_is_load),
    .retire_lq_index_o         (retire_lq_index),
    .retire_sq_index_o         (retire_sq_index),
    .retire_fflags_o           (retire_fflags),
    .head_valid_o              (head_valid),
    .head_complete_o           (head_complete),
    .head_sequence_o           (head_sequence),
    .head_pc_o                 (head_pc),
    .head_instruction_o        (head_instruction),
    .head_instruction_length_o (head_instruction_length),
    .head_writes_destination_o (head_writes_destination),
    .head_destination_class_o  (head_destination_class),
    .head_destination_phys_o   (head_destination_phys),
    .head_source0_phys_o       (head_source0_phys),
    .trap_valid_o              (trap_valid),
    .trap_ready_i              (trap_ready),
    .trap_sequence_o           (trap_sequence),
    .trap_pc_o                 (trap_pc),
    .trap_cause_o              (trap_cause),
    .trap_tval_o               (trap_tval),
    .flush_all_i               (flush_all),
    .flush_younger_i           (flush_younger),
    .flush_sequence_i          (flush_sequence),
    .count_o                   (count),
    .empty_o                   (empty),
    .full_o                    (full)
  );

  task automatic clear_inputs;
    alloc_valid                 = '0;
    alloc_pc                    = '0;
    alloc_instruction           = '0;
    alloc_instruction_length    = '0;
    alloc_complete              = '0;
    alloc_writes_destination    = '0;
    alloc_destination_class     = '0;
    alloc_destination_arch      = '0;
    alloc_destination_phys      = '0;
    alloc_stale_phys            = '0;
    alloc_source0_phys           = '0;
    alloc_is_store              = '0;
    alloc_is_load               = '0;
    alloc_lq_index              = '0;
    alloc_sq_index              = '0;
    alloc_is_branch             = '0;
    alloc_serializing           = '0;
    alloc_exception_valid       = '0;
    alloc_exception_cause       = '0;
    alloc_exception_tval        = '0;
    complete_valid              = '0;
    complete_sequence           = '0;
    complete_exception_valid    = '0;
    complete_exception_cause    = '0;
    complete_exception_tval     = '0;
    complete_fflags             = '0;
    complete_branch_mispredict  = '0;
    complete_branch_target      = '0;
    live_query_sequence          = '0;
    retire_ready                = '0;
    trap_ready                  = 1'b0;
    flush_all                   = 1'b0;
    flush_younger               = 1'b0;
    flush_sequence              = '0;
  endtask

  initial begin : p_rob_test
    clk   = 1'b0;
    rst_n = 1'b0;
    clear_inputs();
    repeat (3) @(posedge clk);
    @(negedge clk);
    rst_n = 1'b1;
    @(negedge clk);
    if (!empty || (count != 0))
      $fatal(1, "ROB reset state is not empty");

    // Younger complete instruction must wait behind incomplete head.
    alloc_valid              = 2'b11;
    alloc_pc[0]              = 32'h1000;
    alloc_pc[1]              = 32'h1004;
    alloc_instruction[0]     = 32'h0010_0293;
    alloc_instruction[1]     = 32'h0020_0313;
    alloc_instruction_length[0] = INST_LEN_32;
    alloc_instruction_length[1] = INST_LEN_32;
    alloc_complete           = 2'b10;
    alloc_writes_destination = 2'b11;
    alloc_destination_class[0] = REG_INT;
    alloc_destination_class[1] = REG_INT;
    alloc_destination_arch[0] = 5;
    alloc_destination_arch[1] = 6;
    alloc_destination_phys[0] = 32;
    alloc_destination_phys[1] = 33;
    alloc_stale_phys[0]       = 5;
    alloc_stale_phys[1]       = 6;
    #1;
    if (!alloc_ready)
      $fatal(1, "ROB rejected initial dual allocation");
    first_sequence = alloc_sequence;
    @(posedge clk);
    @(negedge clk);
    clear_inputs();
    live_query_sequence[0] = first_sequence[0];
    live_query_sequence[1] = first_sequence[1];
    #1;
    if ((count != 2) || (retire_valid != 0))
      $fatal(1, "Younger ROB completion bypassed incomplete head");
    if (live_query_valid[1:0] != 2'b11)
      $fatal(1, "ROB live sequence query missed allocated entries");

    complete_valid[0]    = 1'b1;
    complete_sequence[0] = first_sequence[0];
    @(posedge clk);
    @(negedge clk);
    clear_inputs();
    #1;
    if (retire_valid != 2'b11)
      $fatal(1, "Completed ROB head pair did not become dual-retire ready");
    if ((retire_pc[0] != 32'h1000) || (retire_pc[1] != 32'h1004))
      $fatal(1, "ROB retire order or metadata is wrong");
    retire_ready = 2'b11;
    @(posedge clk);
    @(negedge clk);
    clear_inputs();
    #1;
    if (!empty || (count != 0))
      $fatal(1, "ROB dual retire did not remove both entries");

    // A precise exception is exposed only at the head and cannot retire.
    alloc_valid                = 2'b11;
    alloc_pc[0]                = 32'h2000;
    alloc_pc[1]                = 32'h2004;
    alloc_instruction_length[0] = INST_LEN_32;
    alloc_instruction_length[1] = INST_LEN_32;
    alloc_complete             = 2'b10;
    alloc_exception_valid[0]   = 1'b1;
    alloc_exception_cause[0]   = EXC_ILLEGAL_INSTRUCTION;
    alloc_exception_tval[0]    = 32'hffff_ffff;
    #1;
    second_sequence            = alloc_sequence;
    @(posedge clk);
    @(negedge clk);
    clear_inputs();
    #1;
    if (!trap_valid || (trap_pc != 32'h2000) ||
        (trap_cause != EXC_ILLEGAL_INSTRUCTION) ||
        (retire_valid != 0))
      $fatal(1, "ROB precise head exception behavior failed");
    flush_all = 1'b1;
    @(posedge clk);
    @(negedge clk);
    clear_inputs();
    #1;
    if (!empty)
      $fatal(1, "ROB full flush did not clear exception and younger entry");

    // Keep the boundary entry and invalidate only younger instructions.
    alloc_valid              = 2'b11;
    alloc_pc[0]              = 32'h3000;
    alloc_pc[1]              = 32'h3004;
    alloc_instruction_length[0] = INST_LEN_32;
    alloc_instruction_length[1] = INST_LEN_32;
    alloc_complete           = 2'b11;
    #1;
    second_sequence          = alloc_sequence;
    @(posedge clk);
    @(negedge clk);
    clear_inputs();
    alloc_valid              = 2'b01;
    alloc_pc[0]              = 32'h3008;
    alloc_instruction_length[0] = 2'd2;
    alloc_complete[0]        = 1'b1;
    #1;
    third_sequence           = alloc_sequence[0];
    @(posedge clk);
    @(negedge clk);
    clear_inputs();
    flush_younger  = 1'b1;
    flush_sequence = second_sequence[1];
    live_query_sequence[0] = second_sequence[0];
    live_query_sequence[1] = second_sequence[1];
    live_query_sequence[2] = third_sequence;
    #1;
    if (live_query_valid[2:0] != 3'b111)
      $fatal(1, "ROB live query must report pre-flush resident entries");
    @(posedge clk);
    @(negedge clk);
    clear_inputs();
    #1;
    if ((count != 2) || (retire_sequence[0] != second_sequence[0]) ||
        (retire_sequence[1] != second_sequence[1]) ||
        (third_sequence == second_sequence[1]))
      $fatal(1, "ROB younger-only flush failed");
    live_query_sequence[0] = third_sequence;
    #1;
    if (live_query_valid[0])
      $fatal(1, "ROB live query retained a flushed sequence");

    $display("rv_rob_tb PASS");
    $finish;
  end
endmodule
