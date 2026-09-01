module rv_writeback_arbiter_tb;
  import rv_ooo_pkg::*;

  localparam int unsigned SOURCES = 5;
  logic [SOURCES-1:0] source_valid;
  logic [SOURCES-1:0] source_ready;
  logic [SOURCES-1:0] source_live;
  logic [SOURCES-1:0][7:0] source_sequence;
  logic [SOURCES-1:0] source_destination_valid;
  reg_class_e [SOURCES-1:0] source_destination_class;
  logic [SOURCES-1:0][6:0] source_destination_phys;
  logic [SOURCES-1:0][31:0] source_data;
  logic [SOURCES-1:0] source_exception_valid;
  exception_code_e [SOURCES-1:0] source_exception_cause;
  logic [SOURCES-1:0][31:0] source_exception_tval;
  logic [SOURCES-1:0] source_branch_mispredict;
  logic [SOURCES-1:0][31:0] source_branch_target;
  logic [SOURCES-1:0][4:0] source_fflags;
  logic flush_valid;
  logic flush_all;
  logic [7:0] flush_sequence;
  logic [1:0] int_wb_valid;
  logic [1:0][6:0] int_wb_phys;
  logic [1:0][31:0] int_wb_data;
  logic [1:0] fp_wb_valid;
  logic [1:0][6:0] fp_wb_phys;
  logic [3:0] wakeup_valid;
  logic [3:0] complete_valid;
  logic [3:0][7:0] complete_sequence;
  logic [3:0] complete_exception_valid;

  rv_writeback_arbiter #(
    .XLEN               (32),
    .SOURCE_COUNT       (SOURCES),
    .PHYS_TAG_WIDTH     (7),
    .ROB_SEQ_WIDTH      (8),
    .INT_WRITE_PORTS    (2),
    .FP_WRITE_PORTS     (2),
    .ROB_COMPLETE_PORTS (4)
  ) u_dut (
    .source_valid_i                 (source_valid),
    .source_ready_o                 (source_ready),
    .source_live_i                  (source_live),
    .source_sequence_i              (source_sequence),
    .source_destination_valid_i     (source_destination_valid),
    .source_destination_class_i     (source_destination_class),
    .source_destination_phys_i      (source_destination_phys),
    .source_data_i                  (source_data),
    .source_exception_valid_i       (source_exception_valid),
    .source_exception_cause_i       (source_exception_cause),
    .source_exception_tval_i        (source_exception_tval),
    .source_branch_mispredict_i     (source_branch_mispredict),
    .source_branch_target_i         (source_branch_target),
    .source_fflags_i                (source_fflags),
    .flush_valid_i                  (flush_valid),
    .flush_all_i                    (flush_all),
    .flush_sequence_i               (flush_sequence),
    .int_wb_valid_o                 (int_wb_valid),
    .int_wb_phys_o                  (int_wb_phys),
    .int_wb_data_o                  (int_wb_data),
    .fp_wb_valid_o                  (fp_wb_valid),
    .fp_wb_phys_o                   (fp_wb_phys),
    .wakeup_valid_o                 (wakeup_valid),
    .complete_valid_o               (complete_valid),
    .complete_sequence_o            (complete_sequence),
    .complete_exception_valid_o     (complete_exception_valid)
  );

  initial begin : p_writeback_test
    source_valid = '0;
    source_live = '1;
    source_sequence = '0;
    source_destination_valid = '0;
    source_destination_phys = '0;
    source_data = '0;
    source_exception_valid = '0;
    source_exception_tval = '0;
    source_branch_mispredict = '0;
    source_branch_target = '0;
    source_fflags = '0;
    flush_valid = 1'b0;
    flush_all = 1'b0;
    flush_sequence = '0;
    for (int unsigned source = 0; source < SOURCES; source++) begin
      source_destination_class[source] = REG_NONE;
      source_exception_cause[source] = EXC_ILLEGAL_INSTRUCTION;
    end

    source_valid = 5'b1_1111;
    source_destination_valid = 5'b1_1111;
    source_sequence[0] = 8'd1;
    source_sequence[1] = 8'd2;
    source_sequence[2] = 8'd3;
    source_sequence[3] = 8'd4;
    source_sequence[4] = 8'd0;
    source_destination_class[0] = REG_INT;
    source_destination_class[1] = REG_INT;
    source_destination_class[2] = REG_INT;
    source_destination_class[3] = REG_FP;
    source_destination_class[4] = REG_INT;
    source_destination_phys[0] = 7'd10;
    source_destination_phys[1] = 7'd11;
    source_destination_phys[2] = 7'd12;
    source_destination_phys[3] = 7'd13;
    source_destination_phys[4] = 7'd14;
    source_data[0] = 32'haaaa_0001;
    source_data[1] = 32'hbbbb_0002;
    source_data[2] = 32'hcccc_0003;
    source_data[3] = 32'hdddd_0004;
    source_exception_valid[4] = 1'b1;
    source_exception_cause[4] = EXC_LOAD_ACCESS_FAULT;
    #1;

    if (source_ready != 5'b1_1011)
      $fatal(1, "Oldest/resource-aware source grant failed");
    if (($countones(complete_valid) != 4) ||
        (complete_sequence[0] != 8'd0) ||
        !complete_exception_valid[0])
      $fatal(1, "ROB completion arbitration failed");
    if ((int_wb_valid != 2'b11) ||
        (int_wb_phys[0] != 7'd10) || (int_wb_phys[1] != 7'd11) ||
        (fp_wb_valid != 2'b01) || (fp_wb_phys[0] != 7'd13) ||
        ($countones(wakeup_valid) != 3))
      $fatal(1, "PRF write/wakeup packing failed");

    source_valid = 5'b0_0100;
    source_exception_valid = '0;
    #1;
    if (!source_ready[2] || !int_wb_valid[0] ||
        (int_wb_phys[0] != 7'd12))
      $fatal(1, "Backpressured source was not accepted later");

    source_valid = 5'b0_0001;
    source_sequence[0] = 8'd20;
    flush_valid = 1'b1;
    flush_sequence = 8'd10;
    #1;
    if (!source_ready[0] || (|complete_valid) || (|int_wb_valid))
      $fatal(1, "Flushed younger completion was not dropped");

    flush_valid = 1'b0;
    source_live[0] = 1'b0;
    #1;
    if (!source_ready[0] || (|complete_valid))
      $fatal(1, "Non-live completion was not drained safely");

    $display("rv_writeback_arbiter_tb PASS");
    $finish;
  end

endmodule
