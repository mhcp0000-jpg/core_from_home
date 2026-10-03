module rv_issue_queue #(
  // Experimental lookahead without extra candidates/PRF read ports: when
  // oldest has one static port, choose the oldest second uop that can use
  // another port. All alternatives are formed in parallel with oldest.
  parameter bit COMPATIBLE_PAIR_SELECT = 1'b0,
  parameter int unsigned XLEN = 32,
  parameter int unsigned ENTRIES = 24,
  parameter int unsigned PHYS_TAG_WIDTH = 7,
  parameter int unsigned ROB_SEQ_WIDTH = rv_ooo_pkg::ROB_SEQ_WIDTH,
  parameter int unsigned WRITEBACK_PORTS = 4,
  parameter int unsigned SELECT_WIDTH = 2,
  parameter int unsigned EXEC_PORTS = 5,
  parameter int unsigned OP_WIDTH = 16,
  parameter int unsigned LQ_INDEX_WIDTH = 5,
  parameter int unsigned SQ_INDEX_WIDTH = 4,
  parameter int unsigned CHECKPOINT_ID_WIDTH = 3,
  localparam int unsigned INDEX_WIDTH = $clog2(ENTRIES),
  localparam int unsigned COUNT_WIDTH = $clog2(ENTRIES + 1),
  localparam int unsigned FU_ONEHOT_WIDTH = 1 << $bits(rv_ooo_pkg::fu_class_e)
) (
  input  logic                                  clk_i,
  input  logic                                  rst_ni,

  input  logic [1:0]                            dispatch_valid_i,
  output logic                                  dispatch_ready_o,
  output logic [1:0][INDEX_WIDTH-1:0]           dispatch_index_o,
  input  logic [1:0][ROB_SEQ_WIDTH-1:0]         dispatch_sequence_i,
  input  rv_ooo_pkg::fu_class_e [1:0]           dispatch_fu_i,
  input  logic [1:0][EXEC_PORTS-1:0]            dispatch_port_mask_i,
  input  logic [1:0][2:0]                       dispatch_src_used_i,
  input  rv_ooo_pkg::reg_class_e [1:0][2:0]    dispatch_src_class_i,
  input  logic [1:0][2:0][PHYS_TAG_WIDTH-1:0]   dispatch_src_phys_i,
  input  logic [1:0][2:0]                       dispatch_src_ready_i,
  input  logic [1:0]                            dispatch_destination_valid_i,
  input  rv_ooo_pkg::reg_class_e [1:0]          dispatch_destination_class_i,
  input  logic [1:0][PHYS_TAG_WIDTH-1:0]        dispatch_destination_phys_i,
  input  logic [1:0][XLEN-1:0]                  dispatch_pc_i,
  input  logic [1:0][31:0]                      dispatch_instruction_i,
  input  rv_ooo_pkg::inst_len_e [1:0]           dispatch_inst_len_i,
  input  rv_ooo_pkg::prediction_meta_t [1:0]    dispatch_prediction_i,
  input  logic [1:0][XLEN-1:0]                  dispatch_immediate_i,
  input  logic [1:0][OP_WIDTH-1:0]              dispatch_operation_i,
  input  logic [1:0]                            dispatch_use_pc_i,
  input  logic [1:0]                            dispatch_use_immediate_i,
  input  logic [1:0]                            dispatch_word_operation_i,
  input  logic [1:0][2:0]                       dispatch_mem_size_i,
  input  logic [1:0]                            dispatch_mem_unsigned_i,
  input  logic [1:0][2:0]                       dispatch_rounding_mode_i,
  input  logic [1:0]                            dispatch_checkpoint_valid_i,
  input  logic [1:0][CHECKPOINT_ID_WIDTH-1:0]   dispatch_checkpoint_id_i,
  input  logic [1:0][LQ_INDEX_WIDTH-1:0]        dispatch_lq_index_i,
  input  logic [1:0][SQ_INDEX_WIDTH-1:0]        dispatch_sq_index_i,

  input  logic [WRITEBACK_PORTS-1:0]            writeback_valid_i,
  input  rv_ooo_pkg::reg_class_e [WRITEBACK_PORTS-1:0]
                                                   writeback_class_i,
  input  logic [WRITEBACK_PORTS-1:0][PHYS_TAG_WIDTH-1:0]
                                                   writeback_phys_i,

  output logic [SELECT_WIDTH-1:0]               candidate_valid_o,
  input  logic [SELECT_WIDTH-1:0]               candidate_accept_i,
  output logic [SELECT_WIDTH-1:0][INDEX_WIDTH-1:0]
                                                   candidate_index_o,
  output logic [SELECT_WIDTH-1:0][ROB_SEQ_WIDTH-1:0]
                                                   candidate_sequence_o,
  output rv_ooo_pkg::fu_class_e [SELECT_WIDTH-1:0]
                                                   candidate_fu_o,
  // Decode each registered entry's class before the late oldest-ready select.
  // No new state; the encoded class remains available for execution payload.
  output logic [SELECT_WIDTH-1:0][FU_ONEHOT_WIDTH-1:0]
                                                   candidate_fu_onehot_o,
  output logic [SELECT_WIDTH-1:0][EXEC_PORTS-1:0]
                                                   candidate_port_mask_o,
  output logic [SELECT_WIDTH-1:0][2:0][PHYS_TAG_WIDTH-1:0]
                                                   candidate_src_phys_o,
  output rv_ooo_pkg::reg_class_e [SELECT_WIDTH-1:0][2:0]
                                                   candidate_src_class_o,
  output logic [SELECT_WIDTH-1:0]
                                                   candidate_destination_valid_o,
  output rv_ooo_pkg::reg_class_e [SELECT_WIDTH-1:0]
                                                   candidate_destination_class_o,
  output logic [SELECT_WIDTH-1:0][PHYS_TAG_WIDTH-1:0]
                                                   candidate_destination_phys_o,
  output logic [SELECT_WIDTH-1:0][XLEN-1:0]     candidate_pc_o,
  output logic [SELECT_WIDTH-1:0][31:0]         candidate_instruction_o,
  output rv_ooo_pkg::inst_len_e [SELECT_WIDTH-1:0]
                                                   candidate_inst_len_o,
  output rv_ooo_pkg::prediction_meta_t [SELECT_WIDTH-1:0]
                                                   candidate_prediction_o,
  output logic [SELECT_WIDTH-1:0][XLEN-1:0]     candidate_immediate_o,
  output logic [SELECT_WIDTH-1:0][OP_WIDTH-1:0] candidate_operation_o,
  output logic [SELECT_WIDTH-1:0]               candidate_use_pc_o,
  output logic [SELECT_WIDTH-1:0]               candidate_use_immediate_o,
  output logic [SELECT_WIDTH-1:0]               candidate_word_operation_o,
  output logic [SELECT_WIDTH-1:0][2:0]          candidate_mem_size_o,
  output logic [SELECT_WIDTH-1:0]               candidate_mem_unsigned_o,
  output logic [SELECT_WIDTH-1:0][2:0]          candidate_rounding_mode_o,
  output logic [SELECT_WIDTH-1:0]               candidate_checkpoint_valid_o,
  output logic [SELECT_WIDTH-1:0][CHECKPOINT_ID_WIDTH-1:0]
                                                   candidate_checkpoint_id_o,
  output logic [SELECT_WIDTH-1:0][LQ_INDEX_WIDTH-1:0]
                                                   candidate_lq_index_o,
  output logic [SELECT_WIDTH-1:0][SQ_INDEX_WIDTH-1:0]
                                                   candidate_sq_index_o,
  output logic [SELECT_WIDTH-1:0]
                                                   candidate_store_address_valid_o,
  output logic [SELECT_WIDTH-1:0]
                                                   candidate_store_data_valid_o,

  input  logic                                  flush_all_i,
  input  logic                                  flush_younger_i,
  input  logic [ROB_SEQ_WIDTH-1:0]              flush_sequence_i,
  output logic [COUNT_WIDTH-1:0]                count_o,
  output logic                                  empty_o,
  output logic                                  full_o
);

  import rv_ooo_pkg::*;

  localparam int unsigned SELECT_TREE_LEVELS = $clog2(ENTRIES);
  localparam int unsigned SELECT_TREE_LEAVES = 1 << SELECT_TREE_LEVELS;

  typedef struct packed {
    logic                         valid;
    logic [ROB_SEQ_WIDTH-1:0]     sequence_id;
    logic [INDEX_WIDTH-1:0]       index;
  } select_node_t;

  // Parallel arrays avoid tool-specific limitations around variable indexing
  // of packed structs while retaining the same physical entry semantics.
  logic valid_q [0:ENTRIES-1];
  logic [ROB_SEQ_WIDTH-1:0] sequence_q [0:ENTRIES-1];
  fu_class_e fu_q [0:ENTRIES-1];
  logic [EXEC_PORTS-1:0] port_mask_q [0:ENTRIES-1];
  logic [2:0] src_used_q [0:ENTRIES-1];
  reg_class_e src0_class_q [0:ENTRIES-1];
  reg_class_e src1_class_q [0:ENTRIES-1];
  reg_class_e src2_class_q [0:ENTRIES-1];
  logic [2:0][PHYS_TAG_WIDTH-1:0] src_phys_q [0:ENTRIES-1];
  logic [2:0] src_ready_q [0:ENTRIES-1];
  logic destination_valid_q [0:ENTRIES-1];
  reg_class_e destination_class_q [0:ENTRIES-1];
  logic [PHYS_TAG_WIDTH-1:0] destination_phys_q [0:ENTRIES-1];
  logic [XLEN-1:0] pc_q [0:ENTRIES-1];
  logic [31:0] instruction_q [0:ENTRIES-1];
  inst_len_e inst_len_q [0:ENTRIES-1];
  prediction_meta_t prediction_q [0:ENTRIES-1];
  logic [XLEN-1:0] immediate_q [0:ENTRIES-1];
  logic [OP_WIDTH-1:0] operation_q [0:ENTRIES-1];
  logic use_pc_q [0:ENTRIES-1];
  logic use_immediate_q [0:ENTRIES-1];
  logic word_operation_q [0:ENTRIES-1];
  logic [2:0] mem_size_q [0:ENTRIES-1];
  logic mem_unsigned_q [0:ENTRIES-1];
  logic [2:0] rounding_mode_q [0:ENTRIES-1];
  logic checkpoint_valid_q [0:ENTRIES-1];
  logic [CHECKPOINT_ID_WIDTH-1:0] checkpoint_id_q [0:ENTRIES-1];
  logic [LQ_INDEX_WIDTH-1:0] lq_index_q [0:ENTRIES-1];
  logic [SQ_INDEX_WIDTH-1:0] sq_index_q [0:ENTRIES-1];
  // A store may use an LSU port once for address generation and remain in the
  // IQ until its data source becomes ready.  This exposes the older-store
  // address to the LSQ early without making the store architecturally visible.
  logic store_address_issued_q [0:ENTRIES-1];
  logic [2:0] source_ready_now [0:ENTRIES-1];
  logic [ENTRIES-1:0] ready_now;
  logic [ENTRIES-1:0] store_data_ready_vec;
  // One-hot fan-in for the candidate payload.  Going one-hot -> binary index
  // -> ENTRIES:1 mux put an encoder AND a 6-level mux behind am_first; the
  // AND-OR form is a single OR tree over the same late signal.
  typedef struct packed {
    logic [ROB_SEQ_WIDTH-1:0]         sequence_id;
    fu_class_e                        fu;
    logic [EXEC_PORTS-1:0]            port_mask;
    logic [2:0][PHYS_TAG_WIDTH-1:0]   src_phys;
    reg_class_e                       src0_class;
    reg_class_e                       src1_class;
    reg_class_e                       src2_class;
    logic                             destination_valid;
    reg_class_e                       destination_class;
    logic [PHYS_TAG_WIDTH-1:0]        destination_phys;
    logic [XLEN-1:0]                  pc;
    logic [31:0]                      instruction;
    inst_len_e                        inst_len;
    prediction_meta_t                 prediction;
    logic [XLEN-1:0]                  immediate;
    logic [OP_WIDTH-1:0]              operation;
    logic                             use_pc;
    logic                             use_immediate;
    logic                             word_operation;
    logic [2:0]                       mem_size;
    logic                             mem_unsigned;
    logic [2:0]                       rounding_mode;
    logic                             checkpoint_valid;
    logic [CHECKPOINT_ID_WIDTH-1:0]   checkpoint_id;
    logic [LQ_INDEX_WIDTH-1:0]        lq_index;
    logic [SQ_INDEX_WIDTH-1:0]        sq_index;
    logic                             store_address_valid;
  } cand_payload_t;
  localparam int unsigned CAND_W = $bits(cand_payload_t);
  cand_payload_t entry_payload [0:ENTRIES-1];
  logic [CAND_W-1:0] sel_payload [0:SELECT_WIDTH-1];
  cand_payload_t sel_pl [0:SELECT_WIDTH-1];
  logic [FU_ONEHOT_WIDTH-1:0] entry_fu_onehot [0:ENTRIES-1];
  logic [SELECT_WIDTH-1:0][FU_ONEHOT_WIDTH-1:0] sel_fu_onehot;
  logic [SELECT_WIDTH-1:0] sel_store_data_ready;
  logic [SELECT_WIDTH-1:0][ENTRIES-1:0] am_hot;
  // Explicit balanced payload reduction. A procedural "acc |= entry" loop
  // elaborates into an ENTRIES-long OR chain before mapping; do not rely on
  // a particular synthesis engine to rebalance this late wake/select cone.
  // Bundle data/class/store-ready so all selects have the same depth. This
  // is purely combinational: no extra stage, state, issue policy or latency.
  localparam int unsigned PAYLOAD_LEAVES = 1 << $clog2(ENTRIES);
  localparam int unsigned SELECT_BUNDLE_W = CAND_W + FU_ONEHOT_WIDTH + 1;
  logic [SELECT_BUNDLE_W-1:0] payload_tree
    [0:SELECT_WIDTH-1][1:2*PAYLOAD_LEAVES-1] /* verilator split_var */;
  // PROTOTYPE: age-ordering matrix.  age_matrix_q[i][j]=1 means entry j is
  // older than entry i.  Oldest/second-oldest become 1-bit AND/NOR reductions,
  // removing every ROB-sequence comparator from the select network.
  logic [ENTRIES-1:0][ENTRIES-1:0] age_matrix_q;
  logic [ENTRIES-1:0] valid_vec;
  logic [ENTRIES-1:0] am_first, am_second;
  logic [SELECT_WIDTH-1:0] am_found;
  logic [SELECT_WIDTH-1:0][INDEX_WIDTH-1:0] am_index;
  // Saturating {any, ge2} reduction over (age_matrix_q[e] & ready_now).
  // oldest  == that set is empty,  second-oldest == it holds exactly one.
  // Deriving both from ONE tree removes the am_first -> am_ready2 -> am_second
  // dependency, which used to put two ENTRIES-wide reductions in series.
  localparam int unsigned AGE_LEVELS = $clog2(ENTRIES);
  localparam int unsigned AGE_LEAVES = 1 << AGE_LEVELS;
  logic [AGE_LEAVES-1:0] age_any [0:ENTRIES-1][0:AGE_LEVELS] /* verilator split_var */;
  logic [AGE_LEAVES-1:0] age_ge2 [0:ENTRIES-1][0:AGE_LEVELS] /* verilator split_var */;
  localparam int unsigned CNT_LEVELS = $clog2(ENTRIES);
  localparam int unsigned CNT_LEAVES = 1 << CNT_LEVELS;
  logic [COUNT_WIDTH-1:0] cnt_tree [0:CNT_LEVELS][0:CNT_LEAVES-1];
  logic [ENTRIES-1:0] available_slots;
  logic [ENTRIES-1:0] alloc_first_hot, alloc_second_hot;
  logic [1:0][ENTRIES-1:0] allocation_hot;
  logic [2*CNT_LEAVES-1:1] alloc_any, alloc_ge2;
  logic [2*CNT_LEAVES-1:1] alloc_prefix_none, alloc_prefix_one;
  logic [1:0] allocation_found;
  logic [SELECT_WIDTH-1:0] candidate_final_phase;
  logic [2:0] requested_dispatch_count;
  logic dispatch_fire;
  select_node_t select_tree [0:SELECT_TREE_LEVELS]
                                [0:SELECT_TREE_LEAVES-1][0:1];

  function automatic logic sequence_before(
    input logic [ROB_SEQ_WIDTH-1:0] lhs,
    input logic [ROB_SEQ_WIDTH-1:0] rhs
  );
    logic signed [ROB_SEQ_WIDTH-1:0] difference;
    difference = $signed(lhs - rhs);
    return difference < 0;
  endfunction

  function automatic logic sequence_after(
    input logic [ROB_SEQ_WIDTH-1:0] lhs,
    input logic [ROB_SEQ_WIDTH-1:0] rhs
  );
    logic signed [ROB_SEQ_WIDTH-1:0] difference;
    difference = $signed(lhs - rhs);
    return difference > 0;
  endfunction

  function automatic logic select_before(
    input select_node_t lhs,
    input select_node_t rhs
  );
    if (!lhs.valid)
      return 1'b0;
    if (!rhs.valid)
      return 1'b1;
    if (lhs.sequence_id == rhs.sequence_id)
      return lhs.index < rhs.index;
    return sequence_before(lhs.sequence_id, rhs.sequence_id);
  endfunction

  function automatic select_node_t select_older(
    input select_node_t lhs,
    input select_node_t rhs
  );
    return select_before(lhs, rhs) ? lhs : rhs;
  endfunction

  function automatic logic tag_wakes(
    input reg_class_e source_class,
    input logic [PHYS_TAG_WIDTH-1:0] tag
  );
    logic wake;
    wake = 1'b0;
    for (int unsigned port = 0; port < WRITEBACK_PORTS; port++)
      wake |= writeback_valid_i[port] &&
              (writeback_class_i[port] == source_class) &&
              (writeback_phys_i[port] == tag);
    return wake;
  endfunction

  always_comb begin
    for (int unsigned entry = 0; entry < ENTRIES; entry++) begin
      for (int unsigned source = 0; source < 3; source++) begin
        source_ready_now[entry][source] = !src_used_q[entry][source];
        case (source)
          0: source_ready_now[entry][source] |=
               src_ready_q[entry][source] ||
               tag_wakes(src0_class_q[entry], src_phys_q[entry][source]);
          1: source_ready_now[entry][source] |=
               src_ready_q[entry][source] ||
               tag_wakes(src1_class_q[entry], src_phys_q[entry][source]);
          default: source_ready_now[entry][source] |=
               src_ready_q[entry][source] ||
               tag_wakes(src2_class_q[entry], src_phys_q[entry][source]);
        endcase
      end
      if (fu_q[entry] == FU_STORE)
        ready_now[entry] = valid_q[entry] &&
          (store_address_issued_q[entry] ? source_ready_now[entry][1] :
                                          source_ready_now[entry][0]);
      else
        ready_now[entry] = valid_q[entry] && (&source_ready_now[entry]);
    end
  end


  // Saturating {any, ge2} reduction over (age_matrix_q[e] & ready_now).
  //   oldest        == that set is empty
  //   second-oldest == it holds exactly one element
  // Both fall out of ONE tree, so am_second no longer waits on am_first.
  // Written as a generate: a procedural triple loop unrolls to 21k iterations
  // and exceeds slang's default --unroll-limit.
  generate
    for (genvar age_e = 0; age_e < int'(ENTRIES); age_e++) begin : g_age
      assign age_any[age_e][0] = AGE_LEAVES'(age_matrix_q[age_e] & ready_now);
      assign age_ge2[age_e][0] = '0;
      for (genvar age_l = 0; age_l < int'(AGE_LEVELS); age_l++) begin : g_lvl
        for (genvar age_n = 0; age_n < int'(AGE_LEAVES >> (age_l + 1));
             age_n++) begin : g_node
          assign age_any[age_e][age_l+1][age_n] =
            age_any[age_e][age_l][2*age_n] | age_any[age_e][age_l][2*age_n+1];
          assign age_ge2[age_e][age_l+1][age_n] =
            age_ge2[age_e][age_l][2*age_n] | age_ge2[age_e][age_l][2*age_n+1] |
            (age_any[age_e][age_l][2*age_n] & age_any[age_e][age_l][2*age_n+1]);
        end
      end
      assign am_first[age_e]  = ready_now[age_e] & ~age_any[age_e][AGE_LEVELS][0];
      if (!COMPATIBLE_PAIR_SELECT) begin : g_plain_second
        assign am_second[age_e] = ready_now[age_e] & age_any[age_e][AGE_LEVELS][0]
                                  & ~age_ge2[age_e][AGE_LEVELS][0];
      end
    end
  endgenerate

  if (COMPATIBLE_PAIR_SELECT) begin : g_compatible_pair
    logic [EXEC_PORTS-1:0] first_ports;
    logic first_single_port;
    logic [EXEC_PORTS-1:0][ENTRIES-1:0] alternative_ready, alternative_oldest;
    always_comb begin
      first_ports = '0;
      for (int entry = 0; entry < ENTRIES; entry++)
        first_ports |= port_mask_q[entry] & {EXEC_PORTS{am_first[entry]}};
      first_single_port = (first_ports != '0) &&
                           ((first_ports & (first_ports - EXEC_PORTS'(1))) == '0);
    end
    for (genvar port = 0; port < EXEC_PORTS; port++) begin : g_port
      for (genvar entry = 0; entry < ENTRIES; entry++) begin : g_entry
        assign alternative_ready[port][entry] = ready_now[entry] &&
          (|(port_mask_q[entry] & ~(EXEC_PORTS'(1) << port)));
        assign alternative_oldest[port][entry] = alternative_ready[port][entry] &&
          !(|(age_matrix_q[entry] & alternative_ready[port]));
      end
    end
    for (genvar entry = 0; entry < ENTRIES; entry++) begin : g_second
      logic [EXEC_PORTS-1:0] chosen;
      for (genvar port = 0; port < EXEC_PORTS; port++) begin : g_choose
        assign chosen[port] = first_ports[port] & alternative_oldest[port][entry];
      end
      assign am_second[entry] = first_single_port ? (|chosen) :
        (ready_now[entry] & age_any[entry][AGE_LEVELS][0] &
         ~age_ge2[entry][AGE_LEVELS][0]);
    end
  end

  // Age-matrix oldest-two selection.  Both winners come out of a single
  // saturating count tree instead of two chained NOR reductions.
  always_comb begin
    for (int unsigned entry = 0; entry < ENTRIES; entry++)
      valid_vec[entry] = valid_q[entry];

    // One-hot to binary is an OR reduction per bit.  Written as a sequential
    // last-wins loop it lowered to an ENTRIES-deep priority chain.
    am_found[0] = |am_first;
    am_index[0] = '0;
    for (int unsigned bit_index = 0; bit_index < INDEX_WIDTH; bit_index++)
      for (int unsigned entry = 0; entry < ENTRIES; entry++)
        if (entry[bit_index])
          am_index[0][bit_index] = am_index[0][bit_index] | am_first[entry];
    if (SELECT_WIDTH > 1) begin
      am_found[1] = |am_second;
      am_index[1] = '0;
      for (int unsigned bit_index = 0; bit_index < INDEX_WIDTH; bit_index++)
        for (int unsigned entry = 0; entry < ENTRIES; entry++)
          if (entry[bit_index])
            am_index[1][bit_index] = am_index[1][bit_index] | am_second[entry];
    end
  end

  // Pack every per-entry field once, then select with a one-hot AND-OR.
  always_comb begin
    for (int unsigned entry = 0; entry < ENTRIES; entry++) begin
      entry_payload[entry].sequence_id       = sequence_q[entry];
      entry_payload[entry].fu                = fu_q[entry];
      entry_fu_onehot[entry] = FU_ONEHOT_WIDTH'(1) << fu_q[entry];
      entry_payload[entry].port_mask         = port_mask_q[entry];
      entry_payload[entry].src_phys          = src_phys_q[entry];
      entry_payload[entry].src0_class        = src0_class_q[entry];
      entry_payload[entry].src1_class        = src1_class_q[entry];
      entry_payload[entry].src2_class        = src2_class_q[entry];
      entry_payload[entry].destination_valid = destination_valid_q[entry];
      entry_payload[entry].destination_class = destination_class_q[entry];
      entry_payload[entry].destination_phys  = destination_phys_q[entry];
      entry_payload[entry].pc                = pc_q[entry];
      entry_payload[entry].instruction       = instruction_q[entry];
      entry_payload[entry].inst_len          = inst_len_q[entry];
      entry_payload[entry].prediction        = prediction_q[entry];
      entry_payload[entry].immediate         = immediate_q[entry];
      entry_payload[entry].operation         = operation_q[entry];
      entry_payload[entry].use_pc            = use_pc_q[entry];
      entry_payload[entry].use_immediate     = use_immediate_q[entry];
      entry_payload[entry].word_operation    = word_operation_q[entry];
      entry_payload[entry].mem_size          = mem_size_q[entry];
      entry_payload[entry].mem_unsigned      = mem_unsigned_q[entry];
      entry_payload[entry].rounding_mode     = rounding_mode_q[entry];
      entry_payload[entry].checkpoint_valid  = checkpoint_valid_q[entry];
      entry_payload[entry].checkpoint_id     = checkpoint_id_q[entry];
      entry_payload[entry].lq_index          = lq_index_q[entry];
      entry_payload[entry].sq_index          = sq_index_q[entry];
      entry_payload[entry].store_address_valid =
        (fu_q[entry] == FU_STORE) && !store_address_issued_q[entry];
      store_data_ready_vec[entry] = source_ready_now[entry][1];
    end
    am_hot[0] = am_first;
    if (SELECT_WIDTH > 1)
      am_hot[1] = am_second;
  end

  for (genvar slot = 0; slot < SELECT_WIDTH; slot++) begin : g_payload_select
    for (genvar leaf = 0; leaf < PAYLOAD_LEAVES; leaf++) begin : g_leaf
      if (leaf < ENTRIES) begin : g_present
        assign payload_tree[slot][PAYLOAD_LEAVES+leaf] =
          {SELECT_BUNDLE_W{am_hot[slot][leaf]}} &
          {CAND_W'(entry_payload[leaf]), entry_fu_onehot[leaf],
           store_data_ready_vec[leaf]};
      end else begin : g_padding
        assign payload_tree[slot][PAYLOAD_LEAVES+leaf] = '0;
      end
    end
    for (genvar node = 1; node < PAYLOAD_LEAVES; node++) begin : g_node
      assign payload_tree[slot][node] = payload_tree[slot][2*node] |
                                        payload_tree[slot][2*node+1];
    end
    assign {sel_payload[slot], sel_fu_onehot[slot],
            sel_store_data_ready[slot]} = payload_tree[slot][1];
    assign sel_pl[slot] = cand_payload_t'(sel_payload[slot]);
  end

  always_comb begin
    candidate_valid_o             = '0;
    candidate_index_o             = '0;
    candidate_sequence_o          = '0;
    candidate_fu_o                = '0;
    candidate_fu_onehot_o         = '0;
    candidate_port_mask_o         = '0;
    candidate_src_phys_o          = '0;
    candidate_src_class_o         = '0;
    candidate_destination_valid_o = '0;
    candidate_destination_class_o = '0;
    candidate_destination_phys_o  = '0;
    candidate_pc_o                = '0;
    candidate_instruction_o       = '0;
    candidate_inst_len_o          = '0;
    candidate_prediction_o        = '0;
    candidate_immediate_o         = '0;
    candidate_operation_o         = '0;
    candidate_use_pc_o            = '0;
    candidate_use_immediate_o     = '0;
    candidate_word_operation_o    = '0;
    candidate_mem_size_o          = '0;
    candidate_mem_unsigned_o      = '0;
    candidate_rounding_mode_o     = '0;
    candidate_checkpoint_valid_o  = '0;
    candidate_checkpoint_id_o     = '0;
    candidate_lq_index_o          = '0;
    candidate_sq_index_o          = '0;
    candidate_store_address_valid_o = '0;
    candidate_store_data_valid_o  = '0;
    candidate_final_phase         = '0;
    // Only the valid is suppressed during a flush.  The payload is
    // don't-care while invalid; gating it too put the recovery flush in
    // front of the candidate's PRF read address and operand path.
    begin
      for (int unsigned slot = 0; slot < SELECT_WIDTH; slot++) begin
        if (am_found[slot]) begin
          candidate_index_o[slot]        = am_index[slot];
          candidate_valid_o[slot]        = !flush_all_i && !flush_younger_i;
          candidate_sequence_o[slot]     = sel_pl[slot].sequence_id;
          candidate_fu_o[slot]           = sel_pl[slot].fu;
          candidate_fu_onehot_o[slot]    = sel_fu_onehot[slot];
          candidate_port_mask_o[slot]    = sel_pl[slot].port_mask;
          candidate_src_phys_o[slot]     = sel_pl[slot].src_phys;
          candidate_src_class_o[slot][0] = sel_pl[slot].src0_class;
          candidate_src_class_o[slot][1] = sel_pl[slot].src1_class;
          candidate_src_class_o[slot][2] = sel_pl[slot].src2_class;
          candidate_destination_valid_o[slot] = sel_pl[slot].destination_valid;
          candidate_destination_class_o[slot] = sel_pl[slot].destination_class;
          candidate_destination_phys_o[slot]  = sel_pl[slot].destination_phys;
          candidate_pc_o[slot]           = sel_pl[slot].pc;
          candidate_instruction_o[slot]  = sel_pl[slot].instruction;
          candidate_inst_len_o[slot]     = sel_pl[slot].inst_len;
          candidate_prediction_o[slot]   = sel_pl[slot].prediction;
          candidate_immediate_o[slot]    = sel_pl[slot].immediate;
          candidate_operation_o[slot]    = sel_pl[slot].operation;
          candidate_use_pc_o[slot]       = sel_pl[slot].use_pc;
          candidate_use_immediate_o[slot] = sel_pl[slot].use_immediate;
          candidate_word_operation_o[slot] = sel_pl[slot].word_operation;
          candidate_mem_size_o[slot]     = sel_pl[slot].mem_size;
          candidate_mem_unsigned_o[slot] = sel_pl[slot].mem_unsigned;
          candidate_rounding_mode_o[slot] = sel_pl[slot].rounding_mode;
          candidate_checkpoint_valid_o[slot] = sel_pl[slot].checkpoint_valid;
          candidate_checkpoint_id_o[slot] = sel_pl[slot].checkpoint_id;
          candidate_lq_index_o[slot]     = sel_pl[slot].lq_index;
          candidate_sq_index_o[slot]     = sel_pl[slot].sq_index;
          candidate_store_address_valid_o[slot] = sel_pl[slot].store_address_valid;
          // store data readiness and final phase are 1-bit reductions over the
          // same one-hot vector instead of another ENTRIES:1 mux on a late
          // signal.
          candidate_store_data_valid_o[slot] =
            (sel_pl[slot].fu == FU_STORE) && sel_store_data_ready[slot];
          candidate_final_phase[slot] =
            (sel_pl[slot].fu != FU_STORE) || sel_store_data_ready[slot];
        end
      end
    end
  end

  // Lowest two free slots, independent of dispatch handshake. Upward
  // saturating counts and downward prefix counts avoid two serial priority
  // scans. Keep the winner one-hot through age-matrix row/column updates;
  // binary indices are only an interface/payload-write representation.
  for (genvar leaf = 0; leaf < CNT_LEAVES; leaf++) begin : g_alloc_leaf
    if (leaf < ENTRIES) begin : g_present
      assign available_slots[leaf] = !valid_q[leaf];
      assign alloc_any[CNT_LEAVES+leaf] = available_slots[leaf];
      assign alloc_first_hot[leaf] = available_slots[leaf] &&
                                    alloc_prefix_none[CNT_LEAVES+leaf];
      assign alloc_second_hot[leaf] = available_slots[leaf] &&
                                     alloc_prefix_one[CNT_LEAVES+leaf];
    end else begin : g_padding
      assign alloc_any[CNT_LEAVES+leaf] = 1'b0;
    end
    assign alloc_ge2[CNT_LEAVES+leaf] = 1'b0;
  end
  for (genvar node = 1; node < CNT_LEAVES; node++) begin : g_alloc_node
    assign alloc_any[node] = alloc_any[node*2] || alloc_any[node*2+1];
    assign alloc_ge2[node] = alloc_ge2[node*2] || alloc_ge2[node*2+1] ||
                            (alloc_any[node*2] && alloc_any[node*2+1]);
    assign alloc_prefix_none[node*2] = alloc_prefix_none[node];
    assign alloc_prefix_one[node*2] = alloc_prefix_one[node];
    assign alloc_prefix_none[node*2+1] = alloc_prefix_none[node] &&
                                        !alloc_any[node*2];
    assign alloc_prefix_one[node*2+1] =
      (alloc_prefix_one[node] && !alloc_any[node*2]) ||
      (alloc_prefix_none[node] && alloc_any[node*2] && !alloc_ge2[node*2]);
  end
  assign alloc_prefix_none[1] = 1'b1;
  assign alloc_prefix_one[1] = 1'b0;

  always_comb begin

    // Do not recycle an entry accepted for issue until the following cycle.
    // Same-cycle recycling connected execution-result backpressure through
    // WB arbitration, issue selection and the 56-entry allocation scan all
    // the way to every IQ payload D input.  Using only registered valid state
    // makes dispatch allocation independent of candidate_accept_i.  A full IQ
    // may therefore pause dispatch for one cycle while accepted entries are
    // released; normal non-full operation and issue throughput are unchanged.
    allocation_hot[0] = alloc_first_hot & {ENTRIES{dispatch_valid_i[0]}};
    allocation_hot[1] = (dispatch_valid_i[0] ? alloc_second_hot : alloc_first_hot) &
                         {ENTRIES{dispatch_valid_i[1]}};
    allocation_found[0] = !dispatch_valid_i[0] || alloc_any[1];
    allocation_found[1] = !dispatch_valid_i[1] ||
                         (dispatch_valid_i[0] ? alloc_ge2[1] : alloc_any[1]);
    dispatch_index_o      = '0;
    for (int unsigned lane = 0; lane < 2; lane++) begin
      for (int unsigned bit_index = 0; bit_index < INDEX_WIDTH; bit_index++)
        for (int unsigned entry = 0; entry < ENTRIES; entry++)
          if (entry[bit_index])
            dispatch_index_o[lane][bit_index] |= allocation_hot[lane][entry];
    end

    requested_dispatch_count = {2'b0, dispatch_valid_i[0]} +
                               {2'b0, dispatch_valid_i[1]};
    dispatch_ready_o = (!dispatch_valid_i[1] || dispatch_valid_i[0]) &&
                       (&allocation_found) &&
                       !flush_all_i && !flush_younger_i;
    dispatch_fire = dispatch_ready_o && (requested_dispatch_count != 0);
  end

  always_ff @(posedge clk_i) begin
    if (!rst_ni || flush_all_i) begin
      for (int unsigned entry = 0; entry < ENTRIES; entry++) begin
        valid_q[entry] <= 1'b0;
        sequence_q[entry] <= '0;
        fu_q[entry] <= FU_NONE;
        port_mask_q[entry] <= '0;
        src_used_q[entry] <= '0;
        src0_class_q[entry] <= REG_NONE;
        src1_class_q[entry] <= REG_NONE;
        src2_class_q[entry] <= REG_NONE;
        src_phys_q[entry] <= '0;
        src_ready_q[entry] <= '0;
        destination_valid_q[entry] <= 1'b0;
        destination_class_q[entry] <= REG_NONE;
        destination_phys_q[entry] <= '0;
        pc_q[entry] <= '0;
        instruction_q[entry] <= '0;
        inst_len_q[entry] <= INST_LEN_NONE;
        prediction_q[entry] <= '0;
        immediate_q[entry] <= '0;
        operation_q[entry] <= '0;
        use_pc_q[entry] <= 1'b0;
        use_immediate_q[entry] <= 1'b0;
        word_operation_q[entry] <= 1'b0;
        mem_size_q[entry] <= '0;
        mem_unsigned_q[entry] <= 1'b0;
        rounding_mode_q[entry] <= '0;
        checkpoint_valid_q[entry] <= 1'b0;
        checkpoint_id_q[entry] <= '0;
        lq_index_q[entry] <= '0;
        sq_index_q[entry] <= '0;
        store_address_issued_q[entry] <= 1'b0;
      end
    end else if (flush_younger_i) begin
      for (int unsigned entry = 0; entry < ENTRIES; entry++) begin
        if (valid_q[entry] && sequence_after(sequence_q[entry], flush_sequence_i))
          valid_q[entry] <= 1'b0;
        else if (valid_q[entry]) begin
          // Results from older instructions may write back in the same cycle
          // as a younger-branch recovery.  Preserve those wakeups for IQ
          // entries that survive the recovery boundary.
          for (int unsigned source = 0; source < 3; source++) begin
            if (src_used_q[entry][source]) begin
              case (source)
                0: if (tag_wakes(src0_class_q[entry], src_phys_q[entry][source]))
                     src_ready_q[entry][source] <= 1'b1;
                1: if (tag_wakes(src1_class_q[entry], src_phys_q[entry][source]))
                     src_ready_q[entry][source] <= 1'b1;
                default:
                  if (tag_wakes(src2_class_q[entry], src_phys_q[entry][source]))
                    src_ready_q[entry][source] <= 1'b1;
              endcase
            end
          end
        end
      end
    end else begin
      for (int unsigned entry = 0; entry < ENTRIES; entry++) begin
        if (valid_q[entry]) begin
          for (int unsigned source = 0; source < 3; source++) begin
            if (src_used_q[entry][source]) begin
              case (source)
                0: if (tag_wakes(src0_class_q[entry], src_phys_q[entry][source]))
                     src_ready_q[entry][source] <= 1'b1;
                1: if (tag_wakes(src1_class_q[entry], src_phys_q[entry][source]))
                     src_ready_q[entry][source] <= 1'b1;
                default:
                  if (tag_wakes(src2_class_q[entry], src_phys_q[entry][source]))
                    src_ready_q[entry][source] <= 1'b1;
              endcase
            end
          end
        end
      end

      for (int unsigned slot = 0; slot < SELECT_WIDTH; slot++) begin
        if (candidate_valid_o[slot] && candidate_accept_i[slot]) begin
          if (candidate_final_phase[slot])
            valid_q[candidate_index_o[slot]] <= 1'b0;
          else
            store_address_issued_q[candidate_index_o[slot]] <= 1'b1;
        end
      end

      if (dispatch_fire) begin
        for (int unsigned lane = 0; lane < 2; lane++) begin
          if (dispatch_valid_i[lane]) begin
            valid_q[dispatch_index_o[lane]] <= 1'b1;
            sequence_q[dispatch_index_o[lane]] <= dispatch_sequence_i[lane];
            fu_q[dispatch_index_o[lane]] <= dispatch_fu_i[lane];
            port_mask_q[dispatch_index_o[lane]] <= dispatch_port_mask_i[lane];
            src_used_q[dispatch_index_o[lane]] <= dispatch_src_used_i[lane];
            src0_class_q[dispatch_index_o[lane]] <= dispatch_src_class_i[lane][0];
            src1_class_q[dispatch_index_o[lane]] <= dispatch_src_class_i[lane][1];
            src2_class_q[dispatch_index_o[lane]] <= dispatch_src_class_i[lane][2];
            src_phys_q[dispatch_index_o[lane]] <= dispatch_src_phys_i[lane];
            for (int unsigned source = 0; source < 3; source++) begin
              src_ready_q[dispatch_index_o[lane]][source] <=
                !dispatch_src_used_i[lane][source] ||
                dispatch_src_ready_i[lane][source] ||
                ((source == 0) ?
                 tag_wakes(dispatch_src_class_i[lane][0],
                           dispatch_src_phys_i[lane][source]) :
                 ((source == 1) ?
                  tag_wakes(dispatch_src_class_i[lane][1],
                            dispatch_src_phys_i[lane][source]) :
                  tag_wakes(dispatch_src_class_i[lane][2],
                            dispatch_src_phys_i[lane][source])));
            end
            destination_valid_q[dispatch_index_o[lane]] <=
              dispatch_destination_valid_i[lane];
            destination_class_q[dispatch_index_o[lane]] <=
              dispatch_destination_class_i[lane];
            destination_phys_q[dispatch_index_o[lane]] <=
              dispatch_destination_phys_i[lane];
            pc_q[dispatch_index_o[lane]] <= dispatch_pc_i[lane];
            instruction_q[dispatch_index_o[lane]] <= dispatch_instruction_i[lane];
            inst_len_q[dispatch_index_o[lane]] <= dispatch_inst_len_i[lane];
            prediction_q[dispatch_index_o[lane]] <= dispatch_prediction_i[lane];
            immediate_q[dispatch_index_o[lane]] <= dispatch_immediate_i[lane];
            operation_q[dispatch_index_o[lane]] <= dispatch_operation_i[lane];
            use_pc_q[dispatch_index_o[lane]] <= dispatch_use_pc_i[lane];
            use_immediate_q[dispatch_index_o[lane]] <=
              dispatch_use_immediate_i[lane];
            word_operation_q[dispatch_index_o[lane]] <=
              dispatch_word_operation_i[lane];
            mem_size_q[dispatch_index_o[lane]] <= dispatch_mem_size_i[lane];
            mem_unsigned_q[dispatch_index_o[lane]] <=
              dispatch_mem_unsigned_i[lane];
            rounding_mode_q[dispatch_index_o[lane]] <=
              dispatch_rounding_mode_i[lane];
            checkpoint_valid_q[dispatch_index_o[lane]] <=
              dispatch_checkpoint_valid_i[lane];
            checkpoint_id_q[dispatch_index_o[lane]] <=
              dispatch_checkpoint_id_i[lane];
            lq_index_q[dispatch_index_o[lane]] <= dispatch_lq_index_i[lane];
            sq_index_q[dispatch_index_o[lane]] <= dispatch_sq_index_i[lane];
            store_address_issued_q[dispatch_index_o[lane]] <= 1'b0;
          end
        end
      end
    end
  end

  always_comb begin
    // PROTOTYPE: balanced popcount tree.  The previous sequential increment
    // over ENTRIES synthesized as a 56-deep carry chain feeding count_o/full_o.
    for (int unsigned level = 0; level <= CNT_LEVELS; level++)
      for (int unsigned node = 0; node < CNT_LEAVES; node++)
        cnt_tree[level][node] = '0;
    for (int unsigned leaf = 0; leaf < CNT_LEAVES; leaf++)
      cnt_tree[0][leaf] = (leaf < ENTRIES) ? COUNT_WIDTH'(valid_q[leaf]) :
                                             COUNT_WIDTH'(0);
    for (int unsigned level = 1; level <= CNT_LEVELS; level++)
      for (int unsigned node = 0; node < CNT_LEAVES; node++)
        if (node < (CNT_LEAVES >> level))
          cnt_tree[level][node] = cnt_tree[level-1][2*node] +
                                  cnt_tree[level-1][2*node+1];
    count_o = cnt_tree[CNT_LEVELS][0];
    // empty/full do not need the sum at all.
    empty_o = 1'b1;
    full_o  = 1'b1;
    for (int unsigned entry = 0; entry < ENTRIES; entry++) begin
      if (valid_q[entry]) empty_o = 1'b0;
      else                full_o  = 1'b0;
    end
  end

`ifndef SYNTHESIS
  property p_lane1_dispatch_requires_lane0;
    @(posedge clk_i) disable iff (!rst_ni)
      dispatch_valid_i[1] |-> dispatch_valid_i[0];
  endproperty
  assert property (p_lane1_dispatch_requires_lane0);

  for (genvar slot = 0; slot < SELECT_WIDTH; slot++) begin : g_accept_assert
    property p_predecoded_class_matches_payload;
      @(posedge clk_i) disable iff (!rst_ni)
        candidate_valid_o[slot] |->
          candidate_fu_onehot_o[slot] ==
            (FU_ONEHOT_WIDTH'(1) << candidate_fu_o[slot]);
    endproperty
    assert property (p_predecoded_class_matches_payload);
    property p_accept_requires_candidate;
      @(posedge clk_i) disable iff (!rst_ni)
        candidate_accept_i[slot] |-> candidate_valid_o[slot];
    endproperty
    assert property (p_accept_requires_candidate);

    property p_partial_store_accept_is_address_only;
      @(posedge clk_i) disable iff (!rst_ni)
        candidate_accept_i[slot] &&
        (candidate_fu_o[slot] == FU_STORE) &&
        !candidate_store_data_valid_o[slot]
        |-> candidate_store_address_valid_o[slot];
    endproperty
    assert property (p_partial_store_accept_is_address_only);
  end

  if (SELECT_WIDTH > 1) begin : g_distinct_candidate_assert
    property p_candidate_indices_distinct;
      @(posedge clk_i) disable iff (!rst_ni)
        candidate_valid_o[0] && candidate_valid_o[1]
        |-> candidate_index_o[0] != candidate_index_o[1];
    endproperty
    assert property (p_candidate_indices_distinct);
  end

  property p_count_in_range;
    @(posedge clk_i) disable iff (!rst_ni)
      count_o <= ENTRIES;
  endproperty
  assert property (p_count_in_range);
`endif

  initial begin : p_parameter_checks
    if ((XLEN != 32) && (XLEN != 64))
      $fatal(1, "Issue queue XLEN must be 32 or 64");
    if ((ENTRIES < 2) || (SELECT_WIDTH < 1) || (SELECT_WIDTH > ENTRIES))
      $fatal(1, "Issue queue entries/select width combination is invalid");
    if (ROB_SEQ_WIDTH < 2)
      $fatal(1, "Issue queue requires a wrap-aware ROB sequence");
    if ((WRITEBACK_PORTS == 0) || (EXEC_PORTS == 0) ||
        (CHECKPOINT_ID_WIDTH == 0))
      $fatal(1, "Issue queue wakeup and execution port counts must be nonzero");
  end

  // PROTOTYPE matrix maintenance.  A newly allocated entry records every
  // currently valid entry (and, for lane1, lane0's entry) as older, and its own
  // column is cleared in every row.
  always_ff @(posedge clk_i) begin
    if (!rst_ni || flush_all_i) begin
      age_matrix_q <= '0;
    end else if (dispatch_fire) begin
      logic [ENTRIES-1:0][ENTRIES-1:0] am_next;
      logic [ENTRIES-1:0] onehot0, onehot1;

      am_next = age_matrix_q;
      onehot0 = allocation_hot[0];
      onehot1 = allocation_hot[1];

      for (int unsigned row = 0; row < ENTRIES; row++)
        am_next[row] = am_next[row] & ~onehot0 & ~onehot1;
      for (int unsigned row = 0; row < ENTRIES; row++) begin
        if (onehot0[row])
          am_next[row] = valid_vec & ~onehot0 & ~onehot1;
        if (onehot1[row])
          am_next[row] = (valid_vec | onehot0) & ~onehot1;
      end

      age_matrix_q <= am_next;
    end
  end

endmodule
