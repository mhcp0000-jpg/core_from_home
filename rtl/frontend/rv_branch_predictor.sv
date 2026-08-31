module rv_branch_predictor #(
  parameter int unsigned XLEN = 32,
  parameter int unsigned BTB_ENTRIES = 256,
  parameter int unsigned BTB_WAYS = 4,
  parameter int unsigned PHT_ENTRIES = 2048,
  parameter int unsigned RAS_DEPTH = 16
) (
  input  logic                                  clk_i,
  input  logic                                  rst_ni,
  input  logic [1:0]                            query_valid_i,
  input  logic [1:0][XLEN-1:0]                  query_pc_i,
  input  logic [1:0][31:0]                      query_instruction_i,
  input  rv_ooo_pkg::inst_len_e [1:0]           query_inst_len_i,
  output logic [1:0]                            prediction_taken_o,
  output logic [1:0][XLEN-1:0]                  prediction_target_o,
  output rv_ooo_pkg::prediction_meta_t [1:0]    prediction_meta_o,
  input  logic [1:0]                            prediction_fire_i,

  input  logic                                  redirect_valid_i,
  input  logic                                  resolve_valid_i,
  input  logic [XLEN-1:0]                       resolve_pc_i,
  input  logic [31:0]                           resolve_instruction_i,
  input  rv_ooo_pkg::inst_len_e                 resolve_inst_len_i,
  input  logic                                  resolve_taken_i,
  input  logic [XLEN-1:0]                       resolve_target_i,
  input  logic                                  resolve_mispredict_i,
  input  rv_ooo_pkg::prediction_meta_t          resolve_prediction_i,

  input  logic [1:0]                            commit_valid_i,
  input  logic [1:0][XLEN-1:0]                  commit_pc_i,
  input  logic [1:0][31:0]                      commit_instruction_i,
  input  rv_ooo_pkg::inst_len_e [1:0]           commit_inst_len_i,
  input  logic [1:0]                            commit_taken_i
);

  import rv_ooo_pkg::*;

  localparam int unsigned BTB_SETS = BTB_ENTRIES / BTB_WAYS;
  localparam int unsigned BTB_SET_BITS = $clog2(BTB_SETS);
  localparam int unsigned BTB_TAG_BITS = XLEN - BTB_SET_BITS - 1;
  localparam int unsigned PHT_BITS = $clog2(PHT_ENTRIES);
  localparam int unsigned RAS_PTR_BITS = $clog2(RAS_DEPTH);

  typedef struct packed {
    logic                    valid;
    logic [BTB_TAG_BITS-1:0] tag;
    logic [XLEN-1:0]         target;
  } btb_entry_t;

  btb_entry_t btb_q [0:BTB_SETS-1][0:BTB_WAYS-1];
  logic [$clog2(BTB_WAYS)-1:0] btb_replace_q [0:BTB_SETS-1];
  logic [1:0] pht_q [0:PHT_ENTRIES-1];
  logic [PHT_BITS-1:0] speculative_history_q, committed_history_q;
  logic [XLEN-1:0] speculative_ras_q [0:RAS_DEPTH-1];
  logic [XLEN-1:0] committed_ras_q [0:RAS_DEPTH-1];
  logic [RAS_PTR_BITS-1:0] speculative_ras_pointer_q,
                           committed_ras_pointer_q;
  logic [RAS_PTR_BITS:0] speculative_ras_count_q, committed_ras_count_q;

  logic [1:0] query_conditional, query_direct_jump, query_indirect_jump;
  logic [1:0] query_call, query_return;
  logic [1:0][XLEN-1:0] query_sequential_pc, query_direct_target;
  logic [1:0][PHT_BITS-1:0] query_pht_index;
  logic [1:0][BTB_SET_BITS-1:0] query_btb_set;
  logic [1:0][BTB_TAG_BITS-1:0] query_btb_tag;
  logic [1:0] query_btb_hit;
  logic [1:0][XLEN-1:0] query_btb_target;
  logic [1:0][$clog2(BTB_WAYS)-1:0] query_btb_way;

  function automatic logic [XLEN-1:0] sign_extend_imm(
    input logic [31:0] immediate,
    input integer width
  );
    logic [XLEN-1:0] extended;
    extended = XLEN'(immediate);
    for (integer bit_index = width; bit_index < XLEN; bit_index++)
      extended[bit_index] = immediate[width-1];
    return extended;
  endfunction

  function automatic logic is_conditional_branch(
    input logic [31:0] instruction,
    input inst_len_e length
  );
    if (length == INST_LEN_16)
      return (instruction[1:0] == 2'b01) &&
             ((instruction[15:13] == 3'b110) ||
              (instruction[15:13] == 3'b111));
    return instruction[6:0] == 7'b1100011;
  endfunction

  function automatic logic is_direct_jump(
    input logic [31:0] instruction,
    input inst_len_e length
  );
    if (length == INST_LEN_16)
      return (instruction[1:0] == 2'b01) &&
             ((instruction[15:13] == 3'b101) ||
              ((XLEN == 32) && (instruction[15:13] == 3'b001)));
    return instruction[6:0] == 7'b1101111;
  endfunction

  function automatic logic is_indirect_jump(
    input logic [31:0] instruction,
    input inst_len_e length
  );
    if (length == INST_LEN_16)
      return (instruction[1:0] == 2'b10) &&
             ((instruction[15:12] == 4'b1000) ||
              (instruction[15:12] == 4'b1001)) &&
             (instruction[6:2] == 0) && (instruction[11:7] != 0);
    return (instruction[6:0] == 7'b1100111) &&
           (instruction[14:12] == 0);
  endfunction

  function automatic logic is_call_instruction(
    input logic [31:0] instruction,
    input inst_len_e length
  );
    logic [4:0] destination;
    if (length == INST_LEN_16)
      return ((XLEN == 32) && (instruction[1:0] == 2'b01) &&
              (instruction[15:13] == 3'b001)) ||
             ((instruction[1:0] == 2'b10) &&
              (instruction[15:12] == 4'b1001) &&
              (instruction[6:2] == 0) && (instruction[11:7] != 0));
    destination = instruction[11:7];
    return ((instruction[6:0] == 7'b1101111) ||
            (instruction[6:0] == 7'b1100111)) &&
           ((destination == 5'd1) || (destination == 5'd5));
  endfunction

  function automatic logic is_return_instruction(
    input logic [31:0] instruction,
    input inst_len_e length
  );
    logic [4:0] source;
    if (length == INST_LEN_16)
      return (instruction[1:0] == 2'b10) &&
             (instruction[15:12] == 4'b1000) &&
             (instruction[6:2] == 0) &&
             ((instruction[11:7] == 5'd1) ||
              (instruction[11:7] == 5'd5));
    source = instruction[19:15];
    return (instruction[6:0] == 7'b1100111) &&
           (instruction[14:12] == 0) &&
           (instruction[11:7] == 0) &&
           ((source == 5'd1) || (source == 5'd5)) &&
           (instruction[31:20] == 0);
  endfunction

  function automatic logic [XLEN-1:0] sequential_pc(
    input logic [XLEN-1:0] pc,
    input inst_len_e length
  );
    return pc + ((length == INST_LEN_16) ? XLEN'(2) : XLEN'(4));
  endfunction

  function automatic logic [XLEN-1:0] calculate_direct_target(
    input logic [XLEN-1:0] pc,
    input logic [31:0] instruction,
    input inst_len_e length
  );
    logic [31:0] immediate;
    immediate = '0;
    if (length == INST_LEN_16) begin
      if ((instruction[15:13] == 3'b110) ||
          (instruction[15:13] == 3'b111)) begin
        immediate[8] = instruction[12];
        immediate[7:6] = instruction[6:5];
        immediate[5] = instruction[2];
        immediate[4:3] = instruction[11:10];
        immediate[2:1] = instruction[4:3];
        immediate[0] = 1'b0;
        return pc + sign_extend_imm(immediate, 9);
      end
      immediate[11] = instruction[12];
      immediate[10] = instruction[8];
      immediate[9:8] = instruction[10:9];
      immediate[7] = instruction[6];
      immediate[6] = instruction[7];
      immediate[5:3] = instruction[5:3];
      immediate[2] = instruction[11];
      immediate[1] = instruction[2];
      immediate[0] = 1'b0;
      return pc + sign_extend_imm(immediate, 12);
    end
    if (instruction[6:0] == 7'b1100011) begin
      immediate[12] = instruction[31];
      immediate[11] = instruction[7];
      immediate[10:5] = instruction[30:25];
      immediate[4:1] = instruction[11:8];
      return pc + sign_extend_imm(immediate, 13);
    end
    immediate[20] = instruction[31];
    immediate[19:12] = instruction[19:12];
    immediate[11] = instruction[20];
    immediate[10:1] = instruction[30:21];
    return pc + sign_extend_imm(immediate, 21);
  endfunction

  function automatic logic [PHT_BITS-1:0] history_shift(
    input logic [PHT_BITS-1:0] history,
    input logic taken
  );
    return {history[PHT_BITS-2:0], taken};
  endfunction

  always_comb begin
    logic [PHT_BITS-1:0] history_work;
    logic [RAS_PTR_BITS-1:0] ras_pointer_work;
    logic [RAS_PTR_BITS:0] ras_count_work;
    history_work = speculative_history_q;
    ras_pointer_work = speculative_ras_pointer_q;
    ras_count_work = speculative_ras_count_q;
    prediction_taken_o = '0;
    prediction_target_o = '0;
    prediction_meta_o = '0;
    query_btb_hit = '0;
    query_btb_target = '0;
    query_btb_way = '0;

    for (integer lane = 0; lane < 2; lane++) begin
      query_conditional[lane] = is_conditional_branch(
        query_instruction_i[lane], query_inst_len_i[lane]);
      query_direct_jump[lane] = is_direct_jump(
        query_instruction_i[lane], query_inst_len_i[lane]);
      query_indirect_jump[lane] = is_indirect_jump(
        query_instruction_i[lane], query_inst_len_i[lane]);
      query_call[lane] = is_call_instruction(
        query_instruction_i[lane], query_inst_len_i[lane]);
      query_return[lane] = is_return_instruction(
        query_instruction_i[lane], query_inst_len_i[lane]);
      query_sequential_pc[lane] = sequential_pc(query_pc_i[lane],
                                                query_inst_len_i[lane]);
      query_direct_target[lane] = calculate_direct_target(
        query_pc_i[lane], query_instruction_i[lane], query_inst_len_i[lane]);
      query_pht_index[lane] = query_pc_i[lane][PHT_BITS:1] ^ history_work;
      query_btb_set[lane] = query_pc_i[lane][BTB_SET_BITS:1];
      query_btb_tag[lane] = query_pc_i[lane][XLEN-1:BTB_SET_BITS+1];
      for (integer way = 0; way < BTB_WAYS; way++) begin
        if (btb_q[query_btb_set[lane]][way].valid &&
            (btb_q[query_btb_set[lane]][way].tag == query_btb_tag[lane])) begin
          query_btb_hit[lane] = 1'b1;
          query_btb_target[lane] = btb_q[query_btb_set[lane]][way].target;
          query_btb_way[lane] = $clog2(BTB_WAYS)'(way);
        end
      end

      prediction_meta_o[lane].valid = query_valid_i[lane] &&
        (query_conditional[lane] || query_direct_jump[lane] ||
         query_indirect_jump[lane]);
      prediction_meta_o[lane].global_history = 11'(history_work);
      prediction_meta_o[lane].btb_index =
        8'({query_btb_set[lane], query_btb_way[lane]});
      prediction_meta_o[lane].ras_pointer = 4'(ras_pointer_work);
      prediction_meta_o[lane].ras_count = 5'(ras_count_work);
      prediction_meta_o[lane].is_call = query_call[lane];
      prediction_meta_o[lane].is_return = query_return[lane];

      prediction_target_o[lane] = query_sequential_pc[lane];
      if (query_valid_i[lane] && query_conditional[lane]) begin
        prediction_taken_o[lane] = pht_q[query_pht_index[lane]][1];
        if (prediction_taken_o[lane])
          prediction_target_o[lane] = query_direct_target[lane];
      end else if (query_valid_i[lane] && query_direct_jump[lane]) begin
        prediction_taken_o[lane] = 1'b1;
        prediction_target_o[lane] = query_direct_target[lane];
      end else if (query_valid_i[lane] && query_indirect_jump[lane]) begin
        if (query_return[lane] && (ras_count_work != 0)) begin
          prediction_taken_o[lane] = 1'b1;
          prediction_target_o[lane] = speculative_ras_q[
            (ras_pointer_work == 0) ? RAS_DEPTH-1 : ras_pointer_work-1'b1];
        end else if (query_btb_hit[lane]) begin
          prediction_taken_o[lane] = 1'b1;
          prediction_target_o[lane] = query_btb_target[lane];
        end
      end
      prediction_meta_o[lane].taken = prediction_taken_o[lane];
      prediction_meta_o[lane].target = 64'(prediction_target_o[lane]);

      // Build the second lane's prediction from the first lane's predicted
      // path, independent of downstream ready. Architectural speculative
      // state is still updated only by prediction_fire_i in always_ff below.
      // Keeping the query cone ready-independent avoids a frontend
      // valid->ready->prediction combinational loop.
      if (query_valid_i[lane]) begin
        if (query_conditional[lane])
          history_work = history_shift(history_work, prediction_taken_o[lane]);
        if (query_call[lane]) begin
          ras_pointer_work = ras_pointer_work + 1'b1;
          if (ras_count_work < RAS_DEPTH) ras_count_work = ras_count_work + 1'b1;
        end else if (query_return[lane] && (ras_count_work != 0)) begin
          ras_pointer_work = ras_pointer_work - 1'b1;
          ras_count_work = ras_count_work - 1'b1;
        end
      end
    end
  end

  always_ff @(posedge clk_i) begin
    if (!rst_ni) begin
      speculative_history_q <= '0;
      committed_history_q <= '0;
      speculative_ras_pointer_q <= '0;
      committed_ras_pointer_q <= '0;
      speculative_ras_count_q <= '0;
      committed_ras_count_q <= '0;
      for (integer set_index = 0; set_index < BTB_SETS; set_index++) begin
        btb_replace_q[set_index] <= '0;
        for (integer way = 0; way < BTB_WAYS; way++)
          btb_q[set_index][way] <= '0;
      end
      for (integer index = 0; index < PHT_ENTRIES; index++)
        pht_q[index] <= 2'b01;
      for (integer index = 0; index < RAS_DEPTH; index++) begin
        speculative_ras_q[index] <= '0;
        committed_ras_q[index] <= '0;
      end
    end else begin
      // Resolution trains direction and target state.  A mispredict restores
      // speculative history/RAS to the snapshot carried by that instruction.
      if (resolve_valid_i) begin
        logic [PHT_BITS-1:0] resolve_pht_index;
        logic [BTB_SET_BITS-1:0] resolve_set;
        logic [BTB_TAG_BITS-1:0] resolve_tag;
        logic [$clog2(BTB_WAYS)-1:0] update_way;
        resolve_pht_index = resolve_pc_i[PHT_BITS:1] ^
                            PHT_BITS'(resolve_prediction_i.global_history);
        resolve_set = resolve_pc_i[BTB_SET_BITS:1];
        resolve_tag = resolve_pc_i[XLEN-1:BTB_SET_BITS+1];
        update_way = btb_replace_q[resolve_set];
        for (integer way = 0; way < BTB_WAYS; way++)
          if (btb_q[resolve_set][way].valid &&
              (btb_q[resolve_set][way].tag == resolve_tag))
            update_way = $clog2(BTB_WAYS)'(way);
        if (is_conditional_branch(resolve_instruction_i,
                                  resolve_inst_len_i)) begin
          if (resolve_taken_i && (pht_q[resolve_pht_index] != 2'b11))
            pht_q[resolve_pht_index] <= pht_q[resolve_pht_index] + 1'b1;
          else if (!resolve_taken_i && (pht_q[resolve_pht_index] != 2'b00))
            pht_q[resolve_pht_index] <= pht_q[resolve_pht_index] - 1'b1;
        end
        if (resolve_taken_i) begin
          btb_q[resolve_set][update_way].valid <= 1'b1;
          btb_q[resolve_set][update_way].tag <= resolve_tag;
          btb_q[resolve_set][update_way].target <= resolve_target_i;
          btb_replace_q[resolve_set] <= update_way + 1'b1;
        end
        if (resolve_mispredict_i) begin
          speculative_history_q <=
            PHT_BITS'(resolve_prediction_i.global_history);
          if (is_conditional_branch(resolve_instruction_i,
                                    resolve_inst_len_i))
            speculative_history_q <= history_shift(
              PHT_BITS'(resolve_prediction_i.global_history), resolve_taken_i);
          speculative_ras_pointer_q <=
            RAS_PTR_BITS'(resolve_prediction_i.ras_pointer);
          speculative_ras_count_q <=
            (RAS_PTR_BITS+1)'(resolve_prediction_i.ras_count);
          if (is_call_instruction(resolve_instruction_i,
                                  resolve_inst_len_i)) begin
            speculative_ras_q[RAS_PTR_BITS'(
              resolve_prediction_i.ras_pointer)] <=
              sequential_pc(resolve_pc_i, resolve_inst_len_i);
            speculative_ras_pointer_q <= RAS_PTR_BITS'(
              resolve_prediction_i.ras_pointer) + 1'b1;
            if (resolve_prediction_i.ras_count < RAS_DEPTH)
              speculative_ras_count_q <= (RAS_PTR_BITS+1)'(
                resolve_prediction_i.ras_count) + 1'b1;
          end else if (is_return_instruction(resolve_instruction_i,
                                             resolve_inst_len_i) &&
                       (resolve_prediction_i.ras_count != 0)) begin
            speculative_ras_pointer_q <= RAS_PTR_BITS'(
              resolve_prediction_i.ras_pointer) - 1'b1;
            speculative_ras_count_q <= (RAS_PTR_BITS+1)'(
              resolve_prediction_i.ras_count) - 1'b1;
          end
        end
      end else if (redirect_valid_i) begin
        speculative_history_q <= committed_history_q;
        speculative_ras_pointer_q <= committed_ras_pointer_q;
        speculative_ras_count_q <= committed_ras_count_q;
        for (integer index = 0; index < RAS_DEPTH; index++)
          speculative_ras_q[index] <= committed_ras_q[index];
      end else begin
        logic [PHT_BITS-1:0] history_work;
        logic [RAS_PTR_BITS-1:0] pointer_work;
        logic [RAS_PTR_BITS:0] count_work;
        history_work = speculative_history_q;
        pointer_work = speculative_ras_pointer_q;
        count_work = speculative_ras_count_q;
        for (integer lane = 0; lane < 2; lane++) begin
          if (prediction_fire_i[lane] && query_conditional[lane])
            history_work = history_shift(history_work,
                                         prediction_taken_o[lane]);
          if (prediction_fire_i[lane] && query_call[lane]) begin
            speculative_ras_q[pointer_work] <= query_sequential_pc[lane];
            pointer_work = pointer_work + 1'b1;
            if (count_work < RAS_DEPTH) count_work = count_work + 1'b1;
          end else if (prediction_fire_i[lane] && query_return[lane] &&
                       (count_work != 0)) begin
            pointer_work = pointer_work - 1'b1;
            count_work = count_work - 1'b1;
          end
        end
        speculative_history_q <= history_work;
        speculative_ras_pointer_q <= pointer_work;
        speculative_ras_count_q <= count_work;
      end

      // Commit state is the precise fallback used by traps and interrupts.
      begin
        logic [PHT_BITS-1:0] committed_history_work;
        logic [RAS_PTR_BITS-1:0] committed_pointer_work;
        logic [RAS_PTR_BITS:0] committed_count_work;
        committed_history_work = committed_history_q;
        committed_pointer_work = committed_ras_pointer_q;
        committed_count_work = committed_ras_count_q;
        for (integer lane = 0; lane < 2; lane++) begin
          if (commit_valid_i[lane] && is_conditional_branch(
              commit_instruction_i[lane], commit_inst_len_i[lane]))
            committed_history_work = history_shift(committed_history_work,
                                                   commit_taken_i[lane]);
          if (commit_valid_i[lane] && is_call_instruction(
              commit_instruction_i[lane], commit_inst_len_i[lane])) begin
            committed_ras_q[committed_pointer_work] <=
              sequential_pc(commit_pc_i[lane], commit_inst_len_i[lane]);
            committed_pointer_work = committed_pointer_work + 1'b1;
            if (committed_count_work < RAS_DEPTH)
              committed_count_work = committed_count_work + 1'b1;
          end else if (commit_valid_i[lane] && is_return_instruction(
              commit_instruction_i[lane], commit_inst_len_i[lane]) &&
              (committed_count_work != 0)) begin
            committed_pointer_work = committed_pointer_work - 1'b1;
            committed_count_work = committed_count_work - 1'b1;
          end
        end
        committed_history_q <= committed_history_work;
        committed_ras_pointer_q <= committed_pointer_work;
        committed_ras_count_q <= committed_count_work;
      end
    end
  end

`ifndef SYNTHESIS
  always_comb begin
    assert (!(prediction_taken_o[0] && prediction_fire_i[1]));
    assert (speculative_ras_count_q <= RAS_DEPTH);
    assert (committed_ras_count_q <= RAS_DEPTH);
  end
`endif

  initial begin
    if ((XLEN != 32) && (XLEN != 64))
      $fatal(1, "Predictor XLEN must be 32 or 64");
    if ((BTB_ENTRIES < BTB_WAYS) || ((BTB_ENTRIES % BTB_WAYS) != 0) ||
        ((BTB_SETS & (BTB_SETS-1)) != 0))
      $fatal(1, "BTB geometry must be power-of-two sets");
    if ((PHT_ENTRIES < 2) || ((PHT_ENTRIES & (PHT_ENTRIES-1)) != 0))
      $fatal(1, "PHT_ENTRIES must be a power of two");
    if ((RAS_DEPTH != 16) || ((RAS_DEPTH & (RAS_DEPTH-1)) != 0))
      $fatal(1, "Baseline prediction metadata requires a 16-entry RAS");
  end
endmodule
