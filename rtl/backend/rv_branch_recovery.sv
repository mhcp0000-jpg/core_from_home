module rv_branch_recovery #(
  parameter int unsigned XLEN                = 32,
  parameter int unsigned ROB_SEQ_WIDTH       = rv_ooo_pkg::ROB_SEQ_WIDTH,
  parameter int unsigned CHECKPOINT_ID_WIDTH = 3
) (
  input  logic                               trap_redirect_valid_i,
  input  logic [XLEN-1:0]                    trap_redirect_pc_i,

  input  logic                               resolve_valid_i,
  input  logic                               resolve_live_i,
  input  logic [ROB_SEQ_WIDTH-1:0]           resolve_sequence_i,
  input  logic [CHECKPOINT_ID_WIDTH-1:0]     resolve_checkpoint_id_i,
  input  logic                               resolve_mispredict_i,
  input  logic [XLEN-1:0]                    resolve_next_pc_i,

  output logic                               redirect_valid_o,
  output logic [XLEN-1:0]                    redirect_pc_o,
  output logic                               flush_valid_o,
  output logic                               flush_all_o,
  output logic [ROB_SEQ_WIDTH-1:0]           flush_sequence_o,
  output logic                               checkpoint_restore_valid_o,
  output logic [CHECKPOINT_ID_WIDTH-1:0]     checkpoint_restore_id_o,
  output logic                               checkpoint_release_valid_o,
  output logic [CHECKPOINT_ID_WIDTH-1:0]     checkpoint_release_id_o,
  output logic                               resolve_drop_o
);

  always_comb begin
    redirect_valid_o = 1'b0;
    redirect_pc_o = '0;
    flush_valid_o = 1'b0;
    flush_all_o = 1'b0;
    flush_sequence_o = '0;
    checkpoint_restore_valid_o = 1'b0;
    checkpoint_restore_id_o = resolve_checkpoint_id_i;
    checkpoint_release_valid_o = 1'b0;
    checkpoint_release_id_o = resolve_checkpoint_id_i;
    resolve_drop_o = resolve_valid_i && !resolve_live_i;

    if (trap_redirect_valid_i) begin
      redirect_valid_o = 1'b1;
      redirect_pc_o = trap_redirect_pc_i;
      flush_valid_o = 1'b1;
      flush_all_o = 1'b1;
      resolve_drop_o = resolve_valid_i;
    end else if (resolve_valid_i && resolve_live_i) begin
      if (resolve_mispredict_i) begin
        redirect_valid_o = 1'b1;
        redirect_pc_o = resolve_next_pc_i;
        flush_valid_o = 1'b1;
        flush_all_o = 1'b0;
        flush_sequence_o = resolve_sequence_i;
        checkpoint_restore_valid_o = 1'b1;
      end else begin
        checkpoint_release_valid_o = 1'b1;
      end
    end
  end

`ifndef SYNTHESIS
  always_comb begin
    assert (!(checkpoint_restore_valid_o && checkpoint_release_valid_o));
    if (checkpoint_restore_valid_o)
      assert (flush_valid_o && !flush_all_o && redirect_valid_o);
    if (trap_redirect_valid_i)
      assert (flush_all_o && redirect_valid_o);
  end
`endif

  initial begin : p_parameter_checks
    if ((XLEN != 32) && (XLEN != 64))
      $fatal(1, "Branch recovery XLEN must be 32 or 64");
    if ((ROB_SEQ_WIDTH < 2) || (CHECKPOINT_ID_WIDTH == 0))
      $fatal(1, "Branch recovery widths are invalid");
  end

endmodule
