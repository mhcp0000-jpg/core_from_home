module rv_iq_equiv_case #(parameter ENTRIES=56)(output logic done);
  import rv_ooo_pkg::*;

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
  reg_class_e [1:0][2:0] dispatch_src_class;
  logic [1:0][2:0][TAG_WIDTH-1:0] dispatch_src_phys;
  logic [1:0][2:0] dispatch_src_ready;
  logic [1:0] dispatch_destination_valid;
  reg_class_e [1:0] dispatch_destination_class;
  logic [1:0][TAG_WIDTH-1:0] dispatch_destination_phys;
  logic [1:0][31:0] dispatch_pc;
  logic [1:0][31:0] dispatch_instruction;
  inst_len_e [1:0] dispatch_inst_len;
  prediction_meta_t [1:0] dispatch_prediction;
  logic [1:0][31:0] dispatch_immediate;
  logic [1:0][15:0] dispatch_operation;
  logic [1:0] dispatch_use_pc;
  logic [1:0] dispatch_use_immediate;
  logic [1:0] dispatch_word_operation;
  logic [1:0][2:0] dispatch_mem_size;
  logic [1:0] dispatch_mem_unsigned;
  logic [1:0][2:0] dispatch_rounding_mode;
  logic [1:0] dispatch_checkpoint_valid;
  logic [1:0][2:0] dispatch_checkpoint_id;
  logic [1:0][4:0] dispatch_lq_index;
  logic [1:0][3:0] dispatch_sq_index;
  logic [1:0] writeback_valid;
  reg_class_e [1:0] writeback_class;
  logic [1:0][TAG_WIDTH-1:0] writeback_phys;

  logic [1:0] candidate_valid;
  logic [1:0] candidate_accept;
  logic [1:0][INDEX_WIDTH-1:0] candidate_index;
  logic [1:0][ROB_SEQ_WIDTH-1:0] candidate_sequence;
  fu_class_e [1:0] candidate_fu;
  logic [1:0][(1 << $bits(fu_class_e))-1:0] candidate_fu_onehot;
  logic [1:0][4:0] candidate_port_mask;
  logic [1:0][2:0][TAG_WIDTH-1:0] candidate_src_phys;
  reg_class_e [1:0][2:0] candidate_src_class;
  logic [1:0] candidate_destination_valid;
  reg_class_e [1:0] candidate_destination_class;
  logic [1:0][TAG_WIDTH-1:0] candidate_destination_phys;
  logic [1:0][31:0] candidate_pc;
  logic [1:0][31:0] candidate_instruction;
  inst_len_e [1:0] candidate_inst_len;
  prediction_meta_t [1:0] candidate_prediction;
  logic [1:0][31:0] candidate_immediate;
  logic [1:0][15:0] candidate_operation;
  logic [1:0] candidate_use_pc;
  logic [1:0] candidate_use_immediate;
  logic [1:0] candidate_word_operation;
  logic [1:0][2:0] candidate_mem_size;
  logic [1:0] candidate_mem_unsigned;
  logic [1:0][2:0] candidate_rounding_mode;
  logic [1:0] candidate_checkpoint_valid;
  logic [1:0][2:0] candidate_checkpoint_id;
  logic [1:0][4:0] candidate_lq_index;
  logic [1:0][3:0] candidate_sq_index;
  logic [1:0] candidate_store_address_valid;
  logic [1:0] candidate_store_data_valid;
  logic flush_all;
  logic flush_younger;
  logic [ROB_SEQ_WIDTH-1:0] flush_sequence;
  logic [COUNT_WIDTH-1:0] count;
  logic empty;
  logic full;

  always #5 clk = ~clk;

  logic dispatch_ready_ref;
  logic [1:0][INDEX_WIDTH-1:0] dispatch_index_ref;
  logic [1:0] candidate_valid_ref;
  logic [1:0][INDEX_WIDTH-1:0] candidate_index_ref;
  logic [1:0][ROB_SEQ_WIDTH-1:0] candidate_sequence_ref;
  fu_class_e [1:0] candidate_fu_ref;
  logic [1:0][4:0] candidate_port_mask_ref;
  logic [1:0][2:0][TAG_WIDTH-1:0] candidate_src_phys_ref;
  reg_class_e [1:0][2:0] candidate_src_class_ref;
  logic [1:0] candidate_destination_valid_ref;
  reg_class_e [1:0] candidate_destination_class_ref;
  logic [1:0][TAG_WIDTH-1:0] candidate_destination_phys_ref;
  logic [1:0][31:0] candidate_pc_ref;
  logic [1:0][31:0] candidate_instruction_ref;
  inst_len_e [1:0] candidate_inst_len_ref;
  prediction_meta_t [1:0] candidate_prediction_ref;
  logic [1:0][31:0] candidate_immediate_ref;
  logic [1:0][15:0] candidate_operation_ref;
  logic [1:0] candidate_use_pc_ref;
  logic [1:0] candidate_use_immediate_ref;
  logic [1:0] candidate_word_operation_ref;
  logic [1:0][2:0] candidate_mem_size_ref;
  logic [1:0] candidate_mem_unsigned_ref;
  logic [1:0][2:0] candidate_rounding_mode_ref;
  logic [1:0] candidate_checkpoint_valid_ref;
  logic [1:0][2:0] candidate_checkpoint_id_ref;
  logic [1:0][4:0] candidate_lq_index_ref;
  logic [1:0][3:0] candidate_sq_index_ref;
  logic [1:0] candidate_store_address_valid_ref;
  logic [1:0] candidate_store_data_valid_ref;
  logic [COUNT_WIDTH-1:0] count_ref;
  logic empty_ref;
  logic full_ref;
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
    .dispatch_src_class_i      (dispatch_src_class),
    .dispatch_src_phys_i       (dispatch_src_phys),
    .dispatch_src_ready_i      (dispatch_src_ready),
    .dispatch_destination_valid_i(dispatch_destination_valid),
    .dispatch_destination_class_i(dispatch_destination_class),
    .dispatch_destination_phys_i(dispatch_destination_phys),
    .dispatch_pc_i             (dispatch_pc),
    .dispatch_instruction_i    (dispatch_instruction),
    .dispatch_inst_len_i       (dispatch_inst_len),
    .dispatch_prediction_i     (dispatch_prediction),
    .dispatch_immediate_i      (dispatch_immediate),
    .dispatch_operation_i      (dispatch_operation),
    .dispatch_use_pc_i         (dispatch_use_pc),
    .dispatch_use_immediate_i  (dispatch_use_immediate),
    .dispatch_word_operation_i (dispatch_word_operation),
    .dispatch_mem_size_i       (dispatch_mem_size),
    .dispatch_mem_unsigned_i   (dispatch_mem_unsigned),
    .dispatch_rounding_mode_i  (dispatch_rounding_mode),
    .dispatch_checkpoint_valid_i(dispatch_checkpoint_valid),
    .dispatch_checkpoint_id_i  (dispatch_checkpoint_id),
    .dispatch_lq_index_i       (dispatch_lq_index),
    .dispatch_sq_index_i       (dispatch_sq_index),
    .writeback_valid_i         (writeback_valid),
    .writeback_class_i         (writeback_class),
    .writeback_phys_i          (writeback_phys),
    .candidate_valid_o         (candidate_valid),
    .candidate_accept_i        (candidate_accept),
    .candidate_index_o         (candidate_index),
    .candidate_sequence_o      (candidate_sequence),
    .candidate_fu_o            (candidate_fu),
    .candidate_fu_onehot_o     (candidate_fu_onehot),
    .candidate_port_mask_o     (candidate_port_mask),
    .candidate_src_phys_o      (candidate_src_phys),
    .candidate_src_class_o     (candidate_src_class),
    .candidate_destination_valid_o(candidate_destination_valid),
    .candidate_destination_class_o(candidate_destination_class),
    .candidate_destination_phys_o(candidate_destination_phys),
    .candidate_pc_o            (candidate_pc),
    .candidate_instruction_o   (candidate_instruction),
    .candidate_inst_len_o      (candidate_inst_len),
    .candidate_prediction_o    (candidate_prediction),
    .candidate_immediate_o     (candidate_immediate),
    .candidate_operation_o     (candidate_operation),
    .candidate_use_pc_o        (candidate_use_pc),
    .candidate_use_immediate_o (candidate_use_immediate),
    .candidate_word_operation_o(candidate_word_operation),
    .candidate_mem_size_o      (candidate_mem_size),
    .candidate_mem_unsigned_o  (candidate_mem_unsigned),
    .candidate_rounding_mode_o (candidate_rounding_mode),
    .candidate_checkpoint_valid_o(candidate_checkpoint_valid),
    .candidate_checkpoint_id_o (candidate_checkpoint_id),
    .candidate_lq_index_o      (candidate_lq_index),
    .candidate_sq_index_o      (candidate_sq_index),
    .candidate_store_address_valid_o(candidate_store_address_valid),
    .candidate_store_data_valid_o(candidate_store_data_valid),
    .flush_all_i               (flush_all),
    .flush_younger_i           (flush_younger),
    .flush_sequence_i          (flush_sequence),
    .count_o                   (count),
    .empty_o                   (empty),
    .full_o                    (full)
  );
  rv_issue_queue_timing_ref #(
    .ENTRIES         (ENTRIES),
    .PHYS_TAG_WIDTH  (TAG_WIDTH),
    .WRITEBACK_PORTS (2)
  ) u_ref (
    .clk_i                     (clk),
    .rst_ni                    (rst_n),
    .dispatch_valid_i          (dispatch_valid),
    .dispatch_ready_o          (dispatch_ready_ref),
    .dispatch_index_o          (dispatch_index_ref),
    .dispatch_sequence_i       (dispatch_sequence),
    .dispatch_fu_i             (dispatch_fu),
    .dispatch_port_mask_i      (dispatch_port_mask),
    .dispatch_src_used_i       (dispatch_src_used),
    .dispatch_src_class_i      (dispatch_src_class),
    .dispatch_src_phys_i       (dispatch_src_phys),
    .dispatch_src_ready_i      (dispatch_src_ready),
    .dispatch_destination_valid_i(dispatch_destination_valid),
    .dispatch_destination_class_i(dispatch_destination_class),
    .dispatch_destination_phys_i(dispatch_destination_phys),
    .dispatch_pc_i             (dispatch_pc),
    .dispatch_instruction_i    (dispatch_instruction),
    .dispatch_inst_len_i       (dispatch_inst_len),
    .dispatch_prediction_i     (dispatch_prediction),
    .dispatch_immediate_i      (dispatch_immediate),
    .dispatch_operation_i      (dispatch_operation),
    .dispatch_use_pc_i         (dispatch_use_pc),
    .dispatch_use_immediate_i  (dispatch_use_immediate),
    .dispatch_word_operation_i (dispatch_word_operation),
    .dispatch_mem_size_i       (dispatch_mem_size),
    .dispatch_mem_unsigned_i   (dispatch_mem_unsigned),
    .dispatch_rounding_mode_i  (dispatch_rounding_mode),
    .dispatch_checkpoint_valid_i(dispatch_checkpoint_valid),
    .dispatch_checkpoint_id_i  (dispatch_checkpoint_id),
    .dispatch_lq_index_i       (dispatch_lq_index),
    .dispatch_sq_index_i       (dispatch_sq_index),
    .writeback_valid_i         (writeback_valid),
    .writeback_class_i         (writeback_class),
    .writeback_phys_i          (writeback_phys),
    .candidate_valid_o         (candidate_valid_ref),
    .candidate_accept_i        (candidate_accept),
    .candidate_index_o         (candidate_index_ref),
    .candidate_sequence_o      (candidate_sequence_ref),
    .candidate_fu_o            (candidate_fu_ref),
    .candidate_port_mask_o     (candidate_port_mask_ref),
    .candidate_src_phys_o      (candidate_src_phys_ref),
    .candidate_src_class_o     (candidate_src_class_ref),
    .candidate_destination_valid_o(candidate_destination_valid_ref),
    .candidate_destination_class_o(candidate_destination_class_ref),
    .candidate_destination_phys_o(candidate_destination_phys_ref),
    .candidate_pc_o            (candidate_pc_ref),
    .candidate_instruction_o   (candidate_instruction_ref),
    .candidate_inst_len_o      (candidate_inst_len_ref),
    .candidate_prediction_o    (candidate_prediction_ref),
    .candidate_immediate_o     (candidate_immediate_ref),
    .candidate_operation_o     (candidate_operation_ref),
    .candidate_use_pc_o        (candidate_use_pc_ref),
    .candidate_use_immediate_o (candidate_use_immediate_ref),
    .candidate_word_operation_o(candidate_word_operation_ref),
    .candidate_mem_size_o      (candidate_mem_size_ref),
    .candidate_mem_unsigned_o  (candidate_mem_unsigned_ref),
    .candidate_rounding_mode_o (candidate_rounding_mode_ref),
    .candidate_checkpoint_valid_o(candidate_checkpoint_valid_ref),
    .candidate_checkpoint_id_o (candidate_checkpoint_id_ref),
    .candidate_lq_index_o      (candidate_lq_index_ref),
    .candidate_sq_index_o      (candidate_sq_index_ref),
    .candidate_store_address_valid_o(candidate_store_address_valid_ref),
    .candidate_store_data_valid_o(candidate_store_data_valid_ref),
    .flush_all_i               (flush_all),
    .flush_younger_i           (flush_younger),
    .flush_sequence_i          (flush_sequence),
    .count_o                   (count_ref),
    .empty_o                   (empty_ref),
    .full_o                    (full_ref)
  );

  task automatic clear_inputs;
    dispatch_valid             = '0;
    dispatch_sequence          = '0;
    dispatch_fu                = '0;
    dispatch_port_mask         = '1;
    dispatch_src_used          = '0;
    dispatch_src_class         = '0;
    dispatch_src_phys          = '0;
    dispatch_src_ready         = '0;
    dispatch_destination_valid = '0;
    dispatch_destination_class = '0;
    dispatch_destination_phys  = '0;
    dispatch_pc                = '0;
    dispatch_instruction       = '0;
    for (int unsigned lane = 0; lane < 2; lane++)
      dispatch_inst_len[lane] = INST_LEN_32;
    dispatch_prediction        = '0;
    dispatch_immediate         = '0;
    dispatch_operation         = '0;
    dispatch_use_pc            = '0;
    dispatch_use_immediate     = '0;
    dispatch_word_operation    = '0;
    dispatch_mem_size          = '0;
    dispatch_mem_unsigned      = '0;
    dispatch_rounding_mode     = '0;
    dispatch_checkpoint_valid  = '0;
    dispatch_checkpoint_id     = '0;
    dispatch_lq_index          = '0;
    dispatch_sq_index          = '0;
    writeback_valid            = '0;
    for (int unsigned port = 0; port < 2; port++)
      writeback_class[port] = REG_INT;
    writeback_phys             = '0;
    candidate_accept           = '0;
    flush_all                  = 1'b0;
    flush_younger              = 1'b0;
    flush_sequence             = '0;
  endtask


  initial begin
    logic [ROB_SEQ_WIDTH-1:0] next_seq;
    done=0; clk=0; rst_n=0; next_seq=0; clear_inputs();
    repeat(3) @(negedge clk); rst_n=1;
    for(int n=0;n<30000;n++) begin
      @(negedge clk); clear_inputs();
      // Drain/reset often enough to keep all live ROB ages inside half-range.
      if ((n%80)==79) begin flush_all=1; next_seq=next_seq+2; end
      else begin
        dispatch_valid = (n%80<32) ? 2'b11 : 2'($urandom_range(0,3));
        dispatch_sequence[0]=next_seq;dispatch_sequence[1]=next_seq+1'b1;
        dispatch_src_used={$urandom};dispatch_src_ready={$urandom};
        dispatch_destination_valid=$urandom;
        dispatch_pc={$urandom,$urandom};dispatch_instruction={$urandom,$urandom};
        dispatch_immediate={$urandom,$urandom};dispatch_operation={$urandom};
        dispatch_use_pc=$urandom;dispatch_use_immediate=$urandom;
        dispatch_word_operation=$urandom;dispatch_mem_size=$urandom;
        dispatch_mem_unsigned=$urandom;dispatch_rounding_mode=$urandom;
        dispatch_checkpoint_valid=$urandom;dispatch_checkpoint_id=$urandom;
        dispatch_lq_index=$urandom;dispatch_sq_index=$urandom;
        for(int lane=0;lane<2;lane++) begin
          dispatch_fu[lane]=(n%5==0)?FU_STORE:fu_class_e'($urandom_range(0,9));
          dispatch_destination_class[lane]=REG_INT;
          dispatch_destination_phys[lane]=7'($urandom_range(1,79));
          for(int src=0;src<3;src++) begin
            dispatch_src_class[lane][src]=REG_INT;
            dispatch_src_phys[lane][src]=7'($urandom_range(1,79));
          end
        end
        for(int w=0;w<4;w++) begin
          writeback_valid[w]=$urandom;
          writeback_class[w]=REG_INT;writeback_phys[w]=7'($urandom_range(1,79));
        end
        candidate_accept=(n%80<32)?'0:2'($urandom_range(0,3));
        if(n%23==22) begin flush_younger=1;flush_sequence=next_seq-4;end
      end
      #1;
      for (int slot=0; slot<2; slot++)
        if (candidate_valid[slot] && candidate_fu_onehot[slot] !==
            ((1 << $bits(fu_class_e))'(1) << candidate_fu_ref[slot]))
          $fatal(1,"IQ onehot-class equivalence ENTRIES=%0d cycle=%0d",ENTRIES,n);
      if ({dispatch_ready,dispatch_index,candidate_valid,candidate_index,candidate_sequence,candidate_fu,candidate_port_mask,candidate_src_phys,candidate_src_class,candidate_destination_valid,candidate_destination_class,candidate_destination_phys,candidate_pc,candidate_instruction,candidate_inst_len,candidate_prediction,candidate_immediate,candidate_operation,candidate_use_pc,candidate_use_immediate,candidate_word_operation,candidate_mem_size,candidate_mem_unsigned,candidate_rounding_mode,candidate_checkpoint_valid,candidate_checkpoint_id,candidate_lq_index,candidate_sq_index,candidate_store_address_valid,candidate_store_data_valid,count,empty,full} !== {dispatch_ready_ref,dispatch_index_ref,candidate_valid_ref,candidate_index_ref,candidate_sequence_ref,candidate_fu_ref,candidate_port_mask_ref,candidate_src_phys_ref,candidate_src_class_ref,candidate_destination_valid_ref,candidate_destination_class_ref,candidate_destination_phys_ref,candidate_pc_ref,candidate_instruction_ref,candidate_inst_len_ref,candidate_prediction_ref,candidate_immediate_ref,candidate_operation_ref,candidate_use_pc_ref,candidate_use_immediate_ref,candidate_word_operation_ref,candidate_mem_size_ref,candidate_mem_unsigned_ref,candidate_rounding_mode_ref,candidate_checkpoint_valid_ref,candidate_checkpoint_id_ref,candidate_lq_index_ref,candidate_sq_index_ref,candidate_store_address_valid_ref,candidate_store_data_valid_ref,count_ref,empty_ref,full_ref})
        $fatal(1,"IQ all-output equivalence ENTRIES=%0d cycle=%0d",ENTRIES,n);
      if(dispatch_ready && dispatch_valid!=0) next_seq+=dispatch_valid[1]?2:1;
    end
    $display("IQ equivalence PASS ENTRIES=%0d 30000 cycles",ENTRIES);done=1;
  end
endmodule
module rv_iq_equiv_tb;
  wire done4,done7,done56;
  rv_iq_equiv_case #(.ENTRIES(4)) c4(done4);
  rv_iq_equiv_case #(.ENTRIES(7)) c7(done7);
  rv_iq_equiv_case #(.ENTRIES(56)) c56(done56);
  initial begin wait(done4&&done7&&done56);$finish;end
endmodule
