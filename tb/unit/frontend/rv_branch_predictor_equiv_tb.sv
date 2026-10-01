// Stateful, all-public-output cycle comparison against an immutable Git RTL
// reference renamed rv_branch_predictor_ref by the runner. Not an ISA oracle.
module rv_branch_predictor_equiv_tb #(
  parameter int unsigned XLEN=32,
  parameter int unsigned PHT_ENTRIES=2048,
  parameter int unsigned BTB_ENTRIES=256,
  parameter int unsigned BTB_WAYS=4,
  parameter int unsigned CYCLES=100000,
  parameter bit SEQUENTIAL_QUERIES=1'b0
);
  import rv_ooo_pkg::*;
  logic clk=0, rst_n=0;
  always #5 clk=~clk;
  logic [1:0] query_valid, fire, commit_valid, commit_taken;
  logic [1:0][XLEN-1:0] query_pc, commit_pc;
  logic [1:0][31:0] query_instruction, commit_instruction;
  inst_len_e [1:0] query_length, commit_length;
  logic redirect_valid, resolve_valid, resolve_taken, resolve_mispredict;
  logic [XLEN-1:0] resolve_pc, resolve_target;
  logic [31:0] resolve_instruction;
  inst_len_e resolve_length;
  prediction_meta_t resolve_prediction;
  logic [1:0] taken_dut, taken_ref;
  logic [1:0][XLEN-1:0] target_dut, target_ref, lookup_dut, lookup_ref;
  prediction_meta_t [1:0] meta_dut, meta_ref;
  logic [31:0] rng=32'h527a130d ^ XLEN ^ PHT_ENTRIES;
  int unsigned comparisons=0, unshifted=0, shifted_zero=0, shifted_one=0;
  int unsigned resets=0, redirects=0, recoveries=0;

`define BP_EQ_INPUTS \
    .clk_i(clk), .rst_ni(rst_n), .query_valid_i(query_valid), \
    .query_pc_i(query_pc), .query_instruction_i(query_instruction), \
    .query_inst_len_i(query_length), .prediction_fire_i(fire), \
    .redirect_valid_i(redirect_valid), .resolve_valid_i(resolve_valid), \
    .resolve_pc_i(resolve_pc), .resolve_instruction_i(resolve_instruction), \
    .resolve_inst_len_i(resolve_length), .resolve_taken_i(resolve_taken), \
    .resolve_target_i(resolve_target), .resolve_mispredict_i(resolve_mispredict), \
    .resolve_prediction_i(resolve_prediction), .commit_valid_i(commit_valid), \
    .commit_pc_i(commit_pc), .commit_instruction_i(commit_instruction), \
    .commit_inst_len_i(commit_length), .commit_taken_i(commit_taken)

  rv_branch_predictor #(.XLEN(XLEN), .PHT_ENTRIES(PHT_ENTRIES),
    .BTB_ENTRIES(BTB_ENTRIES), .BTB_WAYS(BTB_WAYS), .SEQUENTIAL_QUERIES(SEQUENTIAL_QUERIES)) dut (
    `BP_EQ_INPUTS, .prediction_taken_o(taken_dut), .prediction_target_o(target_dut),
    .prediction_lookup_target_o(lookup_dut), .prediction_meta_o(meta_dut));
  rv_branch_predictor_ref #(.XLEN(XLEN), .PHT_ENTRIES(PHT_ENTRIES),
    .BTB_ENTRIES(BTB_ENTRIES), .BTB_WAYS(BTB_WAYS)) reference (
    `BP_EQ_INPUTS, .prediction_taken_o(taken_ref), .prediction_target_o(target_ref),
    .prediction_lookup_target_o(lookup_ref), .prediction_meta_o(meta_ref));
`undef BP_EQ_INPUTS

  function automatic logic [31:0] random32();
    rng ^= rng << 13; rng ^= rng >> 17; rng ^= rng << 5;
    return rng;
  endfunction

  task automatic random_instruction(output logic [31:0] instruction,
                                     output inst_len_e length);
    logic [31:0] value;
    value=random32();
    length=INST_LEN_32;
    case(random32()%14)
      0,1,2: instruction=(value & 32'hfffff000) | 32'h00000063; // B
      3: instruction=(value & 32'hfffff000) | 32'h000000ef; // JAL x1
      4: instruction=32'h00008067; // return via x1
      5: instruction=32'h00028067; // return via x5
      6: instruction=32'h000300e7; // indirect call, BTB target
      7: begin length=INST_LEN_16; instruction=(value & 32'h00001ffc)|32'hc001; end
      8: begin length=INST_LEN_16; instruction=(value & 32'h00001ffc)|32'he001; end
      9: begin length=INST_LEN_16; instruction=(value & 32'h00001ffc)|32'ha001; end
      10: begin length=INST_LEN_16; instruction=(value & 32'h00001ffc)|32'h2001; end
      11: begin length=INST_LEN_16; instruction=32'h8082; end
      12: begin length=INST_LEN_16; instruction=32'h9082; end
      default: instruction=(value & 32'hfffff000)|32'h00000013;
    endcase
  endtask

  task automatic compare_outputs(input string phase);
    if ({taken_dut,target_dut,lookup_dut,meta_dut} !==
        {taken_ref,target_ref,lookup_ref,meta_ref}) begin
      $display("XLEN=%0d PHT=%0d trial=%0d %s pc=%h ins=%h valid=%b",
               XLEN,PHT_ENTRIES,comparisons,phase,query_pc,query_instruction,query_valid);
      $display("taken=%b/%b target=%h/%h meta=%h/%h",taken_dut,taken_ref,
               target_dut,target_ref,meta_dut,meta_ref);
      $fatal(1,"Predictor cycle-equivalence mismatch");
    end
    comparisons++;
  endtask

  initial begin
    query_valid=0; query_pc=0; query_instruction=0;
    query_length='{default:INST_LEN_32}; fire=0;
    commit_valid=0; commit_taken=0; commit_pc=0; commit_instruction=0;
    commit_length='{default:INST_LEN_32}; redirect_valid=0;
    resolve_valid=0; resolve_taken=0; resolve_mispredict=0;
    resolve_pc=0; resolve_instruction=0; resolve_target=0;
    resolve_length=INST_LEN_32; resolve_prediction='0;
    repeat(2) @(negedge clk);
    rst_n=1;
    for (int unsigned cycle=0; cycle<CYCLES; cycle++) begin
      @(negedge clk);
      rst_n=(cycle%8192 != 8191);
      if(!rst_n) resets++;
      query_valid=2'(random32()); // Includes inactive lane0 / active lane1.
      for (int lane=0; lane<2; lane++) begin
        query_pc[lane]=XLEN'('h80000000 | (random32() & 'h3ffe));
        if(XLEN==64 && cycle%13==0) query_pc[lane][XLEN-1:32]=32'(random32());
        random_instruction(query_instruction[lane],query_length[lane]);
        commit_pc[lane]=XLEN'('h80000000 | (random32() & 'h3ffe));
        random_instruction(commit_instruction[lane],commit_length[lane]);
      end
      if (SEQUENTIAL_QUERIES)
        query_pc[1]=query_pc[0]+((query_length[0]==INST_LEN_16) ? XLEN'(2) : XLEN'(4));
      if (SEQUENTIAL_QUERIES && cycle%257==0) begin
        // Exercise full-XLEN wrap/tag carries, not only low address aliases.
        query_pc[0]='1-XLEN'(1+2*(cycle%4));
        query_pc[1]=query_pc[0]+((query_length[0]==INST_LEN_16) ? XLEN'(2) : XLEN'(4));
      end
      commit_valid=2'(random32()); commit_taken=2'(random32());
      redirect_valid=(random32()%19==0);
      resolve_valid=(random32()%3==0);
      resolve_mispredict=(random32()%5==0);
      resolve_taken=1'(random32());
      resolve_pc=XLEN'('h80000000 | (random32() & 'h3ffe));
      resolve_target=XLEN'('h80000000 | (random32() & 'h3ffe));
      random_instruction(resolve_instruction,resolve_length);
      // Arbitrary legal recovery snapshots exercise aliasing/training beyond
      // simple sequential query/resolve pairs, identically in both models.
      resolve_prediction='0;
      resolve_prediction.global_history=11'(random32());
      resolve_prediction.ras_pointer=4'(random32());
      resolve_prediction.ras_count=5'(random32()%17);
      resolve_prediction.bimodal_taken=1'(random32());
      resolve_prediction.global_taken=1'(random32());
      resolve_prediction.use_global=1'(random32());
      #1;
      fire[0]=rst_n && query_valid[0] && 1'(random32());
      fire[1]=rst_n && fire[0] && query_valid[1] && !taken_ref[0] && 1'(random32());
      if(!rst_n) begin resolve_valid=0; commit_valid=0; redirect_valid=0; end
      #1;
      compare_outputs("before edge");
      if(query_valid[0] && reference.query_conditional[0]) begin
        if(taken_ref[0]) shifted_one++; else shifted_zero++;
      end else unshifted++;
      if(redirect_valid) redirects++;
      if(resolve_valid && resolve_mispredict) recoveries++;
      @(posedge clk); #1;
      compare_outputs("after edge");
    end
    if(!unshifted || !shifted_zero || !shifted_one || !resets || !recoveries || !redirects)
      $fatal(1,"Predictor equivalence test missed a required scenario");
    $display("Predictor full-output equivalence PASS XLEN=%0d PHT=%0d sequential=%0d compares=%0d history=%0d/%0d/%0d resets=%0d redirects=%0d recoveries=%0d",
             XLEN,PHT_ENTRIES,SEQUENTIAL_QUERIES,comparisons,unshifted,shifted_zero,shifted_one,resets,redirects,recoveries);
    $finish;
  end
endmodule
