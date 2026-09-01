module rv_branch_recovery_tb;
  logic trap_valid;
  logic [31:0] trap_pc;
  logic resolve_valid;
  logic resolve_live;
  logic [7:0] resolve_sequence;
  logic [2:0] resolve_checkpoint;
  logic resolve_mispredict;
  logic [31:0] resolve_next_pc;
  logic redirect_valid;
  logic [31:0] redirect_pc;
  logic flush_valid;
  logic flush_all;
  logic [7:0] flush_sequence;
  logic restore_valid;
  logic [2:0] restore_id;
  logic release_valid;
  logic [2:0] release_id;
  logic resolve_drop;

  rv_branch_recovery #(
    .XLEN                (32),
    .ROB_SEQ_WIDTH       (8),
    .CHECKPOINT_ID_WIDTH (3)
  ) u_dut (
    .trap_redirect_valid_i      (trap_valid),
    .trap_redirect_pc_i         (trap_pc),
    .resolve_valid_i            (resolve_valid),
    .resolve_live_i             (resolve_live),
    .resolve_sequence_i         (resolve_sequence),
    .resolve_checkpoint_id_i    (resolve_checkpoint),
    .resolve_mispredict_i       (resolve_mispredict),
    .resolve_next_pc_i          (resolve_next_pc),
    .redirect_valid_o           (redirect_valid),
    .redirect_pc_o              (redirect_pc),
    .flush_valid_o              (flush_valid),
    .flush_all_o                (flush_all),
    .flush_sequence_o           (flush_sequence),
    .checkpoint_restore_valid_o (restore_valid),
    .checkpoint_restore_id_o    (restore_id),
    .checkpoint_release_valid_o (release_valid),
    .checkpoint_release_id_o    (release_id),
    .resolve_drop_o             (resolve_drop)
  );

  initial begin
    trap_valid = 1'b0;
    trap_pc = 32'h8000_0100;
    resolve_valid = 1'b1;
    resolve_live = 1'b1;
    resolve_sequence = 8'd12;
    resolve_checkpoint = 3'd3;
    resolve_mispredict = 1'b0;
    resolve_next_pc = 32'h8000_0040;
    #1;
    if (!release_valid || restore_valid || redirect_valid)
      $fatal(1, "Correct prediction checkpoint release failed");

    resolve_mispredict = 1'b1;
    #1;
    if (!redirect_valid || (redirect_pc != resolve_next_pc) ||
        !flush_valid || flush_all || (flush_sequence != 8'd12) ||
        !restore_valid || (restore_id != 3'd3) || release_valid)
      $fatal(1, "Mispredict recovery bundle failed");

    trap_valid = 1'b1;
    #1;
    if (!redirect_valid || (redirect_pc != trap_pc) ||
        !flush_valid || !flush_all || restore_valid || !resolve_drop)
      $fatal(1, "Trap redirect priority failed");

    trap_valid = 1'b0;
    resolve_live = 1'b0;
    #1;
    if (redirect_valid || flush_valid || release_valid || !resolve_drop)
      $fatal(1, "Non-live branch result was not dropped");

    $display("rv_branch_recovery_tb PASS");
    $finish;
  end
endmodule
