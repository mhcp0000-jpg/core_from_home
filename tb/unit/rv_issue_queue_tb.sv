module rv_issue_queue_tb;
  import rv_ooo_pkg::*;

  localparam int unsigned ENTRIES = 4;
  localparam int unsigned TAG_WIDTH = 7;
  localparam int unsigned INDEX_WIDTH = $clog2(ENTRIES);
  localparam int unsigned COUNT_WIDTH = $clog2(ENTRIES + 1);

  logic clk;
  logic rst_n;
  logic [1:0] dispatch_valid;
  logic dispatch_ready;
  logic [1:0][INDEX_WIDTH-1:0] dispatch_index;
  logic [1:0][ROB_SEQ_WIDTH-1:0] dispatch_sequence;
  fu_class_e [1:0] dispatch_fu;
  logic [1:0][4:0] dispatch_port_mask;
  logic [1:0][2:0] dispatch_src_used;
  logic [1:0][2:0][TAG_WIDTH-1:0] dispatch_src_phys;
  logic [1:0][2:0] dispatch_src_ready;
  logic [1:0] dispatch_destination_valid;
  logic [1:0][TAG_WIDTH-1:0] dispatch_destination_phys;
  logic [1:0][31:0] dispatch_pc;
  logic [1:0][31:0] dispatch_instruction;
  logic [1:0][31:0] dispatch_immediate;
  logic [1:0][15:0] dispatch_operation;
  logic [1:0][4:0] dispatch_lq_index;
  logic [1:0][3:0] dispatch_sq_index;
  logic [1:0] writeback_valid;
  logic [1:0][TAG_WIDTH-1:0] writeback_phys;

  logic [1:0] candidate_valid;
  logic [1:0] candidate_accept;
  logic [1:0][INDEX_WIDTH-1:0] candidate_index;
  logic [1:0][ROB_SEQ_WIDTH-1:0] candidate_sequence;
  fu_class_e [1:0] candidate_fu;
  logic [1:0][4:0] candidate_port_mask;
  logic [1:0][2:0][TAG_WIDTH-1:0] candidate_src_phys;
  logic [1:0] candidate_destination_valid;
  logic [1:0][TAG_WIDTH-1:0] candidate_destination_phys;
  logic [1:0][31:0] candidate_pc;
  logic [1:0][31:0] candidate_instruction;
  logic [1:0][31:0] candidate_immediate;
  logic [1:0][15:0] candidate_operation;
  logic [1:0][4:0] candidate_lq_index;
  logic [1:0][3:0] candidate_sq_index;
  logic flush_all;
  logic flush_younger;
  logic [ROB_SEQ_WIDTH-1:0] flush_sequence;
  logic [COUNT_WIDTH-1:0] count;
  logic empty;
  logic full;

  always #5 clk = ~clk;

  rv_issue_queue #(
    .ENTRIES         (ENTRIES),
    .PHYS_TAG_WIDTH  (TAG_WIDTH),
    .WRITEBACK_PORTS (2)
  ) u_dut (
    .clk_i                     (clk),
    .rst_ni                    (rst_n),
    .dispatch_valid_i          (dispatch_valid),
    .dispatch_ready_o          (dispatch_ready),
    .dispatch_index_o          (dispatch_index),
    .dispatch_sequence_i       (dispatch_sequence),
    .dispatch_fu_i             (dispatch_fu),
    .dispatch_port_mask_i      (dispatch_port_mask),
    .dispatch_src_used_i       (dispatch_src_used),
    .dispatch_src_phys_i       (dispatch_src_phys),
    .dispatch_src_ready_i      (dispatch_src_ready),
    .dispatch_destination_valid_i(dispatch_destination_valid),
    .dispatch_destination_phys_i(dispatch_destination_phys),
    .dispatch_pc_i             (dispatch_pc),
    .dispatch_instruction_i    (dispatch_instruction),
    .dispatch_immediate_i      (dispatch_immediate),
    .dispatch_operation_i      (dispatch_operation),
    .dispatch_lq_index_i       (dispatch_lq_index),
    .dispatch_sq_index_i       (dispatch_sq_index),
    .writeback_valid_i         (writeback_valid),
    .writeback_phys_i          (writeback_phys),
    .candidate_valid_o         (candidate_valid),
    .candidate_accept_i        (candidate_accept),
    .candidate_index_o         (candidate_index),
    .candidate_sequence_o      (candidate_sequence),
    .candidate_fu_o            (candidate_fu),
    .candidate_port_mask_o     (candidate_port_mask),
    .candidate_src_phys_o      (candidate_src_phys),
    .candidate_destination_valid_o(candidate_destination_valid),
    .candidate_destination_phys_o(candidate_destination_phys),
    .candidate_pc_o            (candidate_pc),
    .candidate_instruction_o   (candidate_instruction),
    .candidate_immediate_o     (candidate_immediate),
    .candidate_operation_o     (candidate_operation),
    .candidate_lq_index_o      (candidate_lq_index),
    .candidate_sq_index_o      (candidate_sq_index),
    .flush_all_i               (flush_all),
    .flush_younger_i           (flush_younger),
    .flush_sequence_i          (flush_sequence),
    .count_o                   (count),
    .empty_o                   (empty),
    .full_o                    (full)
  );

  task automatic clear_inputs;
    dispatch_valid             = '0;
    dispatch_sequence          = '0;
    dispatch_fu                = '{default: FU_INT};
    dispatch_port_mask         = '1;
    dispatch_src_used          = '0;
    dispatch_src_phys          = '0;
    dispatch_src_ready         = '0;
    dispatch_destination_valid = '0;
    dispatch_destination_phys  = '0;
    dispatch_pc                = '0;
    dispatch_instruction       = '0;
    dispatch_immediate         = '0;
    dispatch_operation         = '0;
    dispatch_lq_index          = '0;
    dispatch_sq_index          = '0;
    writeback_valid            = '0;
    writeback_phys             = '0;
    candidate_accept           = '0;
    flush_all                  = 1'b0;
    flush_younger              = 1'b0;
    flush_sequence             = '0;
  endtask

  task automatic dispatch_ready_pair(
    input logic [ROB_SEQ_WIDTH-1:0] sequence0,
    input logic [ROB_SEQ_WIDTH-1:0] sequence1
  );
    @(negedge clk);
    clear_inputs();
    dispatch_valid       = 2'b11;
    dispatch_sequence[0] = sequence0;
    dispatch_sequence[1] = sequence1;
    dispatch_src_ready   = '1;
    #1;
    if (!dispatch_ready)
      $fatal(1, "Issue queue rejected a dispatch pair with capacity");
    @(posedge clk);
  endtask

  initial begin : p_issue_queue_test
    clk   = 1'b0;
    rst_n = 1'b0;
    clear_inputs();
    repeat (3) @(posedge clk);
    @(negedge clk);
    rst_n = 1'b1;
    @(negedge clk);
    if (!empty || (count != 0))
      $fatal(1, "Issue queue reset state is not empty");

    // seq10 waits for p5; younger seq11 is independently ready.
    dispatch_valid          = 2'b11;
    dispatch_sequence[0]    = 8'd10;
    dispatch_sequence[1]    = 8'd11;
    dispatch_src_used[0][0] = 1'b1;
    dispatch_src_phys[0][0] = 7'd5;
    dispatch_src_ready[0][0] = 1'b0;
    dispatch_src_ready[1]   = '1;
    #1;
    if (!dispatch_ready)
      $fatal(1, "Issue queue rejected initial dependency test pair");
    @(posedge clk);
    @(negedge clk);
    clear_inputs();
    #1;
    if ((candidate_valid != 2'b01) || (candidate_sequence[0] != 8'd11))
      $fatal(1, "Unready older uop blocked or issued incorrectly");

    // A same-cycle writeback wakes seq10, which must become oldest slot0.
    writeback_valid[0] = 1'b1;
    writeback_phys[0]  = 7'd5;
    #1;
    if ((candidate_valid != 2'b11) ||
        (candidate_sequence[0] != 8'd10) ||
        (candidate_sequence[1] != 8'd11))
      $fatal(1, "Writeback wakeup/oldest-ready dual select failed");
    candidate_accept = 2'b11;
    @(posedge clk);
    @(negedge clk);
    clear_inputs();
    #1;
    if (!empty)
      $fatal(1, "Accepted issue candidates were not removed");

    dispatch_ready_pair(8'd20, 8'd21);
    dispatch_ready_pair(8'd22, 8'd23);
    @(negedge clk);
    clear_inputs();
    #1;
    if (!full || (count != ENTRIES) ||
        (candidate_sequence[0] != 8'd20) ||
        (candidate_sequence[1] != 8'd21))
      $fatal(1, "Issue queue full/oldest state is wrong");

    // Reuse the two entries accepted this cycle for a new dispatch pair.
    candidate_accept       = 2'b11;
    dispatch_valid         = 2'b11;
    dispatch_sequence[0]   = 8'd24;
    dispatch_sequence[1]   = 8'd25;
    dispatch_src_ready     = '1;
    #1;
    if (!dispatch_ready)
      $fatal(1, "Issue+dispatch same-cycle slot reuse failed");
    @(posedge clk);
    @(negedge clk);
    clear_inputs();
    #1;
    if (!full || (candidate_sequence[0] != 8'd22) ||
        (candidate_sequence[1] != 8'd23))
      $fatal(1, "Issue queue replacement corrupted program age order");

    flush_younger  = 1'b1;
    flush_sequence = 8'd22;
    @(posedge clk);
    @(negedge clk);
    clear_inputs();
    #1;
    if ((count != 1) || (candidate_valid != 2'b01) ||
        (candidate_sequence[0] != 8'd22))
      $fatal(1, "Issue queue younger flush failed");

    $display("rv_issue_queue_tb PASS");
    $finish;
  end
endmodule
