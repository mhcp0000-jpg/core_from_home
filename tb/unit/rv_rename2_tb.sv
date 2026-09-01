module rv_rename2_tb;
  import rv_ooo_pkg::*;

  localparam int unsigned TAG_WIDTH = 7;
  localparam int unsigned CHECKPOINTS = 8;
  localparam int unsigned CHECKPOINT_ID_WIDTH = $clog2(CHECKPOINTS);

  logic clk;
  logic rst_n;
  logic [1:0] rename_valid;
  logic dispatch_accept;
  reg_class_e [1:0] src0_class;
  reg_class_e [1:0] src1_class;
  reg_class_e [1:0] src2_class;
  logic [1:0][4:0] src0_arch;
  logic [1:0][4:0] src1_arch;
  logic [1:0][4:0] src2_arch;
  logic [1:0] writes_destination;
  reg_class_e [1:0] destination_class;
  logic [1:0][4:0] destination_arch;
  logic rename_can_accept;
  logic rename_fire;
  logic [1:0][TAG_WIDTH-1:0] src0_phys;
  logic [1:0][TAG_WIDTH-1:0] src1_phys;
  logic [1:0][TAG_WIDTH-1:0] src2_phys;
  logic [1:0] writes_destination_renamed;
  logic [1:0][TAG_WIDTH-1:0] destination_phys;
  logic [1:0][TAG_WIDTH-1:0] stale_phys;

  logic [1:0] commit_valid;
  logic [1:0] commit_writes_destination;
  reg_class_e [1:0] commit_destination_class;
  logic [1:0][4:0] commit_destination_arch;
  logic [1:0][TAG_WIDTH-1:0] commit_destination_phys;
  logic [1:0][TAG_WIDTH-1:0] commit_stale_phys;
  logic recover_committed;
  logic restore_checkpoint;
  logic [CHECKPOINT_ID_WIDTH-1:0] restore_checkpoint_id;
  logic [1:0] checkpoint_save;
  logic [1:0][CHECKPOINT_ID_WIDTH-1:0] checkpoint_save_id;
  logic checkpoint_release;
  logic [CHECKPOINT_ID_WIDTH-1:0] checkpoint_release_id;
  logic [CHECKPOINTS-1:0] checkpoint_clear_mask;
  logic [CHECKPOINTS-1:0] checkpoint_valid;
  logic [6:0] int_free_count;
  logic [6:0] fp_free_count;

  logic [1:0][TAG_WIDTH-1:0] first_destination;
  logic [1:0][TAG_WIDTH-1:0] first_stale;
  logic [TAG_WIDTH-1:0] checkpoint_x6_phys;

  always #5 clk = ~clk;

  rv_rename2 u_dut (
    .clk_i                     (clk),
    .rst_ni                    (rst_n),
    .rename_valid_i            (rename_valid),
    .dispatch_accept_i         (dispatch_accept),
    .src0_class_i              (src0_class),
    .src1_class_i              (src1_class),
    .src2_class_i              (src2_class),
    .src0_arch_i               (src0_arch),
    .src1_arch_i               (src1_arch),
    .src2_arch_i               (src2_arch),
    .writes_destination_i      (writes_destination),
    .destination_class_i       (destination_class),
    .destination_arch_i        (destination_arch),
    .rename_can_accept_o       (rename_can_accept),
    .rename_fire_o             (rename_fire),
    .src0_phys_o               (src0_phys),
    .src1_phys_o               (src1_phys),
    .src2_phys_o               (src2_phys),
    .writes_destination_o      (writes_destination_renamed),
    .destination_phys_o        (destination_phys),
    .stale_phys_o              (stale_phys),
    .commit_valid_i            (commit_valid),
    .commit_writes_destination_i(commit_writes_destination),
    .commit_destination_class_i(commit_destination_class),
    .commit_destination_arch_i (commit_destination_arch),
    .commit_destination_phys_i (commit_destination_phys),
    .commit_stale_phys_i       (commit_stale_phys),
    .recover_committed_i       (recover_committed),
    .restore_checkpoint_i      (restore_checkpoint),
    .restore_checkpoint_id_i   (restore_checkpoint_id),
    .checkpoint_save_i         (checkpoint_save),
    .checkpoint_save_id_i      (checkpoint_save_id),
    .checkpoint_release_i      (checkpoint_release),
    .checkpoint_release_id_i   (checkpoint_release_id),
    .checkpoint_clear_mask_i   (checkpoint_clear_mask),
    .checkpoint_valid_o        (checkpoint_valid),
    .int_free_count_o          (int_free_count),
    .fp_free_count_o           (fp_free_count)
  );

  task automatic clear_inputs;
    rename_valid             = '0;
    dispatch_accept          = 1'b0;
    src0_class               = '0;
    src1_class               = '0;
    src2_class               = '0;
    src0_arch                = '0;
    src1_arch                = '0;
    src2_arch                = '0;
    writes_destination       = '0;
    destination_class        = '0;
    destination_arch         = '0;
    commit_valid             = '0;
    commit_writes_destination = '0;
    commit_destination_class = '0;
    commit_destination_arch  = '0;
    commit_destination_phys  = '0;
    commit_stale_phys        = '0;
    recover_committed        = 1'b0;
    restore_checkpoint       = 1'b0;
    restore_checkpoint_id    = '0;
    checkpoint_save          = '0;
    checkpoint_save_id       = '0;
    checkpoint_release       = 1'b0;
    checkpoint_release_id    = '0;
    checkpoint_clear_mask    = '0;
  endtask

  initial begin : p_rename_test
    clk   = 1'b0;
    rst_n = 1'b0;
    clear_inputs();
    repeat (3) @(posedge clk);
    @(negedge clk);
    rst_n = 1'b1;
    @(negedge clk);

    if ((int_free_count != 48) || (fp_free_count != 48))
      $fatal(1, "Rename free-list reset state is wrong");

    // lane0: x5<-p32, lane1 consumes p32 and then x5<-p33.
    rename_valid        = 2'b11;
    dispatch_accept     = 1'b1;
    writes_destination  = 2'b11;
    destination_class[0] = REG_INT;
    destination_class[1] = REG_INT;
    destination_arch[0] = 5;
    destination_arch[1] = 5;
    src0_class[1]       = REG_INT;
    src0_arch[1]        = 5;
    #1;
    if (!rename_fire || (destination_phys[0] != 32) ||
        (destination_phys[1] != 33) || (stale_phys[0] != 5) ||
        (stale_phys[1] != 32) || (src0_phys[1] != 32))
      $fatal(1, "Dual-lane RAW/WAW rename bypass failed");
    first_destination = destination_phys;
    first_stale       = stale_phys;
    @(posedge clk);
    @(negedge clk);
    clear_inputs();
    #1;
    if (int_free_count != 46)
      $fatal(1, "Dual integer allocation did not consume two tags");

    // Commit in order. Lane1's stale tag is lane0's just-committed p32.
    commit_valid                  = 2'b11;
    commit_writes_destination     = 2'b11;
    commit_destination_class[0]   = REG_INT;
    commit_destination_class[1]   = REG_INT;
    commit_destination_arch[0]    = 5;
    commit_destination_arch[1]    = 5;
    commit_destination_phys       = first_destination;
    commit_stale_phys             = first_stale;
    @(posedge clk);
    @(negedge clk);
    clear_inputs();
    #1;
    if (int_free_count != 48)
      $fatal(1, "Commit did not return both stale tags");

    // Save checkpoint0 after lane0. Lane1 must be removed by restore.
    rename_valid        = 2'b11;
    dispatch_accept     = 1'b1;
    writes_destination  = 2'b11;
    destination_class[0] = REG_INT;
    destination_class[1] = REG_INT;
    destination_arch[0] = 6;
    destination_arch[1] = 7;
    checkpoint_save[0]  = 1'b1;
    checkpoint_save_id[0] = 0;
    #1;
    checkpoint_x6_phys = destination_phys[0];
    @(posedge clk);
    @(negedge clk);
    clear_inputs();
    #1;
    if (!checkpoint_valid[0])
      $fatal(1, "Branch checkpoint was not saved");

    restore_checkpoint    = 1'b1;
    restore_checkpoint_id = 0;
    checkpoint_clear_mask = 8'hff;
    @(posedge clk);
    @(negedge clk);
    clear_inputs();

    rename_valid    = 2'b11;
    src0_class[0]   = REG_INT;
    src0_class[1]   = REG_INT;
    src0_arch[0]    = 6;
    src0_arch[1]    = 7;
    #1;
    if ((src0_phys[0] != checkpoint_x6_phys) || (src0_phys[1] != 7))
      $fatal(1, "Checkpoint restore did not preserve lane0/remove lane1");

    @(negedge clk);
    clear_inputs();
    recover_committed = 1'b1;
    @(posedge clk);
    @(negedge clk);
    clear_inputs();
    rename_valid = 2'b11;
    src0_class[0] = REG_INT;
    src0_class[1] = REG_INT;
    src0_arch[0] = 5;
    src0_arch[1] = 6;
    #1;
    if ((src0_phys[0] != 33) || (src0_phys[1] != 6) ||
        (int_free_count != 48))
      $fatal(1, "RRAT committed-state recovery failed");

    $display("rv_rename2_tb PASS");
    $finish;
  end
endmodule
