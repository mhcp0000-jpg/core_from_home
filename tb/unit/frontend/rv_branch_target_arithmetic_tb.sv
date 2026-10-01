// Pure target arithmetic check. Stateful BTB/history/RAS policy is tested by
// rv_branch_predictor_tb and the cross-block/full SoC regressions separately.
module rv_branch_target_arithmetic_case #(parameter int XLEN=32)(output logic done);
  import rv_ooo_pkg::*;
  logic clk=0, rst_n=0;
  always #5 clk=~clk;
  rv_branch_predictor #(.XLEN(XLEN), .BTB_ENTRIES(4), .BTB_WAYS(2),
    .PHT_ENTRIES(8), .RAS_DEPTH(16)) u_dut (
    .clk_i(clk), .rst_ni(rst_n), .query_valid_i('0), .query_pc_i('0),
    .query_instruction_i('0), .query_inst_len_i('{default:INST_LEN_32}),
    .prediction_taken_o(), .prediction_target_o(), .prediction_lookup_target_o(),
    .prediction_meta_o(), .prediction_fire_i('0), .redirect_valid_i(1'b0),
    .resolve_valid_i(1'b0), .resolve_pc_i('0), .resolve_instruction_i('0),
    .resolve_inst_len_i(INST_LEN_32), .resolve_taken_i(1'b0), .resolve_target_i('0),
    .resolve_mispredict_i(1'b0), .resolve_prediction_i('0), .commit_valid_i('0),
    .commit_pc_i('0), .commit_instruction_i('0),
    .commit_inst_len_i('{default:INST_LEN_32}), .commit_taken_i('0));

  // Concatenation-based oracle, independent of the DUT's bit assignments,
  // sign-extension helper and adder implementation. Include invalid encodings
  // because the inactive lookup payload still has deterministic arithmetic.
  function automatic logic [XLEN-1:0] oracle(
    input logic [XLEN-1:0] pc, input logic [31:0] ins, input inst_len_e len
  );
    logic [XLEN-1:0] delta;
    if (len==INST_LEN_16) begin
      if (ins[15:13]==3'b110 || ins[15:13]==3'b111)
        delta={{(XLEN-9){ins[12]}},ins[12],ins[6:5],ins[2],ins[11:10],ins[4:3],1'b0};
      else
        delta={{(XLEN-12){ins[12]}},ins[12],ins[8],ins[10:9],ins[6],ins[7],ins[2],ins[11],ins[5:3],1'b0};
    end else if (ins[6:0]==7'b1100011)
      delta={{(XLEN-13){ins[31]}},ins[31],ins[7],ins[30:25],ins[11:8],1'b0};
    else
      delta={{(XLEN-21){ins[31]}},ins[31],ins[19:12],ins[20],ins[30:21],1'b0};
    return pc+delta;
  endfunction

  task automatic check(input logic [XLEN-1:0] pc, input logic [31:0] ins, input inst_len_e len);
    if (u_dut.calculate_direct_target(pc,ins,len) !== oracle(pc,ins,len))
      $fatal(1,"Target arithmetic XLEN=%0d pc=%h instr=%h len=%0d",XLEN,pc,ins,len);
  endtask

  logic [63:0] random_state;
  logic [XLEN-1:0] pc;
  logic [31:0] ins;
  initial begin
    done=0;
    random_state=64'hd1b5_4a32_d192_ed03 ^ 64'(XLEN);
    repeat (2) @(posedge clk);
    @(negedge clk); rst_n=1;
    for (int encoding=0; encoding<65536; encoding++) begin
      check('0,32'(encoding),INST_LEN_16);
      check('1,32'(encoding),INST_LEN_16);
      check(XLEN'(64'h8000_000e),32'(encoding),INST_LEN_16);
    end
    for (int n=0; n<100000; n++) begin
      random_state^=random_state<<13;
      random_state^=random_state>>7;
      random_state^=random_state<<17;
      pc=XLEN'(random_state);
      ins=random_state[63:32] ^ random_state[31:0];
      // Ensure branch, JAL and all other opcode cases receive equal coverage.
      if (n%3==0) ins[6:0]=7'b1100011;
      if (n%3==1) ins[6:0]=7'b1101111;
      check(pc,ins,INST_LEN_32);
    end
    $display("Branch target arithmetic PASS XLEN=%0d (296608 vectors)",XLEN);
    done=1;
  end
endmodule

module rv_branch_target_arithmetic_tb;
  wire done32,done64;
  rv_branch_target_arithmetic_case #(.XLEN(32)) c32(done32);
  rv_branch_target_arithmetic_case #(.XLEN(64)) c64(done64);
  initial begin wait(done32&&done64); $finish; end
endmodule
