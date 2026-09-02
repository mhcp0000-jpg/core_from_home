module rv_branch_predictor_tb;
  import rv_ooo_pkg::*;

  logic clk, rst_n;
  logic [1:0] query_valid, prediction_taken, prediction_fire;
  logic [1:0][31:0] query_pc, query_instruction, prediction_target;
  inst_len_e [1:0] query_inst_len;
  prediction_meta_t [1:0] prediction_meta;
  logic redirect_valid, resolve_valid, resolve_taken, resolve_mispredict;
  logic [31:0] resolve_pc, resolve_instruction, resolve_target;
  inst_len_e resolve_inst_len;
  prediction_meta_t resolve_prediction;
  logic [1:0] commit_valid, commit_taken;
  logic [1:0][31:0] commit_pc, commit_instruction;
  inst_len_e [1:0] commit_inst_len;

  always #5 clk = ~clk;

  rv_branch_predictor #(
    .XLEN(32), .BTB_ENTRIES(16), .BTB_WAYS(2),
    .PHT_ENTRIES(32), .RAS_DEPTH(16)
  ) u_dut (
    .clk_i(clk), .rst_ni(rst_n), .query_valid_i(query_valid),
    .query_pc_i(query_pc), .query_instruction_i(query_instruction),
    .query_inst_len_i(query_inst_len),
    .prediction_taken_o(prediction_taken),
    .prediction_target_o(prediction_target),
    .prediction_meta_o(prediction_meta),
    .prediction_fire_i(prediction_fire), .redirect_valid_i(redirect_valid),
    .resolve_valid_i(resolve_valid), .resolve_pc_i(resolve_pc),
    .resolve_instruction_i(resolve_instruction),
    .resolve_inst_len_i(resolve_inst_len), .resolve_taken_i(resolve_taken),
    .resolve_target_i(resolve_target),
    .resolve_mispredict_i(resolve_mispredict),
    .resolve_prediction_i(resolve_prediction),
    .commit_valid_i(commit_valid), .commit_pc_i(commit_pc),
    .commit_instruction_i(commit_instruction),
    .commit_inst_len_i(commit_inst_len), .commit_taken_i(commit_taken)
  );

  task automatic clear_inputs;
    query_valid = '0;
    query_pc = '0;
    query_instruction = '0;
    query_inst_len[0] = INST_LEN_32;
    query_inst_len[1] = INST_LEN_32;
    prediction_fire = '0;
    redirect_valid = 1'b0;
    resolve_valid = 1'b0;
    resolve_pc = '0;
    resolve_instruction = '0;
    resolve_inst_len = INST_LEN_32;
    resolve_taken = 1'b0;
    resolve_target = '0;
    resolve_mispredict = 1'b0;
    resolve_prediction = '0;
    commit_valid = '0;
    commit_pc = '0;
    commit_instruction = '0;
    commit_inst_len[0] = INST_LEN_32;
    commit_inst_len[1] = INST_LEN_32;
    commit_taken = '0;
  endtask

  initial begin
    prediction_meta_t branch_meta;
    clk = 1'b0;
    rst_n = 1'b0;
    clear_inputs();
    repeat (3) @(posedge clk);
    @(negedge clk);
    rst_n = 1'b1;

    // C.J +4 uses the CJ immediate permutation, not the CB permutation.
    query_valid[0] = 1'b1;
    query_pc[0] = 32'h0000_0100;
    query_instruction[0] = 32'h0000_a011;
    query_inst_len[0] = INST_LEN_16;
    #1;
    if (!prediction_taken[0] || (prediction_target[0] != 32'h0000_0104))
      $fatal(1, "C.J target prediction failed: %h", prediction_target[0]);

    // A predicted call pushes the sequential PC onto the speculative RAS.
    @(negedge clk);
    clear_inputs();
    query_valid[0] = 1'b1;
    query_pc[0] = 32'h0000_0200;
    query_instruction[0] = 32'h0080_00ef; // jal x1,+8
    query_inst_len[0] = INST_LEN_32;
    prediction_fire[0] = 1'b1;
    #1;
    if (!prediction_taken[0] || (prediction_target[0] != 32'h0000_0208))
      $fatal(1, "JAL prediction failed");
    @(posedge clk);
    @(negedge clk);
    clear_inputs();
    query_valid[0] = 1'b1;
    query_pc[0] = 32'h0000_0300;
    query_instruction[0] = 32'h0000_8067; // jalr x0,0(x1)
    #1;
    if (!prediction_taken[0] || (prediction_target[0] != 32'h0000_0204))
      $fatal(1, "Speculative RAS return prediction failed");

    // A precise redirect restores the committed (empty) RAS.
    @(negedge clk);
    clear_inputs();
    redirect_valid = 1'b1;
    @(posedge clk);
    @(negedge clk);
    clear_inputs();
    query_valid[0] = 1'b1;
    query_pc[0] = 32'h0000_0300;
    query_instruction[0] = 32'h0000_8067;
    #1;
    if (prediction_taken[0])
      $fatal(1, "Redirect did not restore committed RAS state");

    // Train a conditional branch from weak-not-taken to weak-taken.
    @(negedge clk);
    clear_inputs();
    query_valid[0] = 1'b1;
    query_pc[0] = 32'h0000_0400;
    query_instruction[0] = 32'h0000_1463; // bne x0,x0,+8
    #1;
    if (prediction_taken[0] || (prediction_target[0] != 32'h0000_0404))
      $fatal(1, "Conditional reset prediction was not weak-not-taken");
    branch_meta = prediction_meta[0];

    @(negedge clk);
    clear_inputs();
    resolve_valid = 1'b1;
    resolve_pc = 32'h0000_0400;
    resolve_instruction = 32'h0000_1463;
    resolve_inst_len = INST_LEN_32;
    resolve_taken = 1'b1;
    resolve_target = 32'h0000_0408;
    resolve_mispredict = 1'b1;
    resolve_prediction = branch_meta;
    @(posedge clk);

    // Restore committed history so the query addresses the trained PHT row.
    @(negedge clk);
    clear_inputs();
    redirect_valid = 1'b1;
    @(posedge clk);
    @(negedge clk);
    clear_inputs();
    query_valid[0] = 1'b1;
    query_pc[0] = 32'h0000_0400;
    query_instruction[0] = 32'h0000_1463;
    #1;
    if (!prediction_taken[0] || (prediction_target[0] != 32'h0000_0408))
      $fatal(1, "Conditional PHT/target training failed");

    // Resolve receives the raw 16-bit encoding, not its canonical 32-bit
    // expansion.  A taken C.BNEZ must therefore train the same PHT entry used
    // by the frontend query and recover history as a conditional branch.
    @(negedge clk);
    clear_inputs();
    query_valid[0] = 1'b1;
    query_pc[0] = 32'h0000_0502;
    query_instruction[0] = 32'h0000_fb69; // c.bnez a4,-46
    query_inst_len[0] = INST_LEN_16;
    #1;
    if (prediction_taken[0])
      $fatal(1, "Compressed conditional reset prediction was not weak-not-taken");
    branch_meta = prediction_meta[0];

    @(negedge clk);
    clear_inputs();
    resolve_valid = 1'b1;
    resolve_pc = 32'h0000_0502;
    resolve_instruction = 32'h0000_fb69;
    resolve_inst_len = INST_LEN_16;
    resolve_taken = 1'b1;
    resolve_target = 32'h0000_04d4;
    resolve_mispredict = 1'b1;
    resolve_prediction = branch_meta;
    @(posedge clk);

    @(negedge clk);
    clear_inputs();
    redirect_valid = 1'b1;
    @(posedge clk);
    @(negedge clk);
    clear_inputs();
    query_valid[0] = 1'b1;
    query_pc[0] = 32'h0000_0502;
    query_instruction[0] = 32'h0000_fb69;
    query_inst_len[0] = INST_LEN_16;
    #1;
    if (!prediction_taken[0] || (prediction_target[0] != 32'h0000_04d4))
      $fatal(1, "Compressed conditional PHT training failed");

    // The tournament chooser moves only when the component predictions
    // disagree.  Two globally-correct samples cross the weak-bimodal reset
    // state; two bimodal-correct samples move it back.
    repeat (2) begin
      @(negedge clk);
      clear_inputs();
      resolve_valid = 1'b1;
      resolve_pc = 32'h0000_0440;
      resolve_instruction = 32'h0000_1463;
      resolve_inst_len = INST_LEN_32;
      resolve_taken = 1'b1;
      resolve_target = 32'h0000_0448;
      resolve_prediction = '0;
      resolve_prediction.bimodal_taken = 1'b0;
      resolve_prediction.global_taken = 1'b1;
      @(posedge clk);
    end
    @(negedge clk);
    clear_inputs();
    query_valid[0] = 1'b1;
    query_pc[0] = 32'h0000_0440;
    query_instruction[0] = 32'h0000_1463;
    #1;
    if (!prediction_meta[0].use_global)
      $fatal(1, "Tournament chooser did not select global predictor");

    repeat (2) begin
      @(negedge clk);
      clear_inputs();
      resolve_valid = 1'b1;
      resolve_pc = 32'h0000_0440;
      resolve_instruction = 32'h0000_1463;
      resolve_inst_len = INST_LEN_32;
      resolve_taken = 1'b0;
      resolve_target = 32'h0000_0444;
      resolve_prediction = '0;
      resolve_prediction.bimodal_taken = 1'b0;
      resolve_prediction.global_taken = 1'b1;
      @(posedge clk);
    end
    @(negedge clk);
    clear_inputs();
    query_valid[0] = 1'b1;
    query_pc[0] = 32'h0000_0440;
    query_instruction[0] = 32'h0000_1463;
    #1;
    if (prediction_meta[0].use_global)
      $fatal(1, "Tournament chooser did not return to bimodal predictor");

    $display("rv_branch_predictor_tb PASS");
    $finish;
  end
endmodule
