module rv_frontend #(
  parameter int unsigned XLEN          = 32,
  parameter int unsigned PADDR_WIDTH   = 32,
  parameter int unsigned FETCH_BYTES   = 16,
  parameter logic [XLEN-1:0] RESET_VECTOR = 'h8000_0000
) (
  input  logic                                  clk_i,
  input  logic                                  rst_ni,
  input  logic                                  redirect_valid_i,
  input  logic [XLEN-1:0]                       redirect_pc_i,
  input  logic                                  predictor_resolve_valid_i,
  input  logic [XLEN-1:0]                       predictor_resolve_pc_i,
  input  logic [31:0]                           predictor_resolve_instruction_i,
  input  rv_ooo_pkg::inst_len_e                 predictor_resolve_inst_len_i,
  input  logic                                  predictor_resolve_taken_i,
  input  logic [XLEN-1:0]                       predictor_resolve_target_i,
  input  logic                                  predictor_resolve_mispredict_i,
  input  rv_ooo_pkg::prediction_meta_t          predictor_resolve_prediction_i,
  input  logic [1:0]                            predictor_commit_valid_i,
  input  logic [1:0][XLEN-1:0]                  predictor_commit_pc_i,
  input  logic [1:0][31:0]                      predictor_commit_instruction_i,
  input  rv_ooo_pkg::inst_len_e [1:0]           predictor_commit_inst_len_i,
  input  logic [1:0]                            predictor_commit_taken_i,

  output logic [1:0]                            fetch_valid_o,
  input  logic [1:0]                            fetch_ready_i,
  output logic [1:0][XLEN-1:0]                  fetch_pc_o,
  output logic [1:0][31:0]                      fetch_instr_o,
  output rv_ooo_pkg::inst_len_e [1:0]           fetch_inst_len_o,
  output rv_ooo_pkg::prediction_meta_t [1:0]    fetch_prediction_o,
  output logic [1:0]                            fetch_fault_o,

  output logic                                  imem_req_valid_o,
  input  logic                                  imem_req_ready_i,
  output logic [PADDR_WIDTH-1:0]                imem_req_addr_o,
  output logic [3:0]                            imem_req_id_o,
  output logic [3:0]                            imem_req_epoch_o,
  input  logic                                  imem_rsp_valid_i,
  output logic                                  imem_rsp_ready_o,
  input  logic [3:0]                            imem_rsp_id_i,
  input  logic [3:0]                            imem_rsp_epoch_i,
  input  logic [FETCH_BYTES*8-1:0]              imem_rsp_data_i,
  input  logic [1:0]                            imem_rsp_resp_i
);

  import rv_ooo_pkg::*;

  localparam int unsigned QUEUE_BYTES = 64;
  localparam int unsigned QUEUE_COUNT_WIDTH = $clog2(QUEUE_BYTES + 1);
  localparam int unsigned FETCH_ADDR_LSB = $clog2(FETCH_BYTES);
  localparam logic [XLEN-1:0] PC_INCREMENT_2 = 2;
  localparam logic [XLEN-1:0] PC_INCREMENT_4 = 4;
  localparam logic [PADDR_WIDTH-1:0] FETCH_BYTES_VALUE = FETCH_BYTES;

  logic [PADDR_WIDTH-1:0] reset_vector_paddr;
  logic [PADDR_WIDTH-1:0] redirect_paddr;
  logic [PADDR_WIDTH-1:0] redirect_block_addr;
  logic [PADDR_WIDTH-1:0] next_request_addr_q;
  logic [3:0] epoch_q;
  logic [3:0] next_id_q;
  logic outstanding_q;
  logic [3:0] outstanding_id_q;
  logic [3:0] outstanding_epoch_q;
  logic [PADDR_WIDTH-1:0] outstanding_addr_q;
  logic fault_stop_q;

  logic queue_fill_valid;
  logic queue_fill_ready;
  logic [1:0] queue_valid;
  logic [1:0] queue_ready;
  logic [1:0][XLEN-1:0] queue_pc;
  logic [1:0][31:0] queue_instruction;
  inst_len_e [1:0] queue_inst_len;
  logic [1:0] queue_fault;
  logic queue_empty;
  logic [QUEUE_COUNT_WIDTH-1:0] queue_byte_count;
  logic response_id_matches;
  logic response_is_current;
  logic [1:0][XLEN-1:0] sequential_pc;
  logic [1:0] prediction_taken, prediction_fire;
  logic [1:0][XLEN-1:0] prediction_target;
  prediction_meta_t [1:0] prediction_meta;
  logic predicted_redirect_fire, frontend_redirect_valid;
  logic [XLEN-1:0] predicted_redirect_pc, frontend_redirect_pc;

  if (PADDR_WIDTH >= XLEN) begin : g_pc_extend
    assign reset_vector_paddr = {{(PADDR_WIDTH-XLEN){1'b0}}, RESET_VECTOR};
    assign redirect_paddr = {{(PADDR_WIDTH-XLEN){1'b0}}, frontend_redirect_pc};
  end else begin : g_pc_truncate
    assign reset_vector_paddr = RESET_VECTOR[PADDR_WIDTH-1:0];
    assign redirect_paddr = frontend_redirect_pc[PADDR_WIDTH-1:0];
  end

  assign redirect_block_addr =
    {redirect_paddr[PADDR_WIDTH-1:FETCH_ADDR_LSB], {FETCH_ADDR_LSB{1'b0}}};
  assign response_id_matches = outstanding_q &&
                               (imem_rsp_id_i == outstanding_id_q);
  assign response_is_current = response_id_matches &&
                               (imem_rsp_epoch_i == outstanding_epoch_q) &&
                               (outstanding_epoch_q == epoch_q);

  assign imem_req_valid_o = !frontend_redirect_valid && !outstanding_q &&
                            !fault_stop_q &&
                            (queue_byte_count <= (QUEUE_BYTES-FETCH_BYTES));
  assign imem_req_addr_o = next_request_addr_q;
  assign imem_req_id_o = next_id_q;
  assign imem_req_epoch_o = epoch_q;

  assign queue_fill_valid = imem_rsp_valid_i && response_is_current &&
                            !frontend_redirect_valid;
  assign imem_rsp_ready_o = response_is_current ? queue_fill_ready : 1'b1;

  assign fetch_valid_o[0] = redirect_valid_i ? 1'b0 : queue_valid[0];
  assign fetch_valid_o[1] = redirect_valid_i ? 1'b0 :
    (queue_valid[1] && !prediction_taken[0]);
  assign fetch_pc_o = queue_pc;
  assign fetch_instr_o = queue_instruction;
  assign fetch_inst_len_o = queue_inst_len;
  assign fetch_fault_o = queue_fault;
  assign queue_ready[0] = redirect_valid_i ? 1'b0 : fetch_ready_i[0];
  assign queue_ready[1] = redirect_valid_i ? 1'b0 :
    (fetch_ready_i[1] && fetch_ready_i[0] && !prediction_taken[0]);
  assign prediction_fire[0] = fetch_valid_o[0] && fetch_ready_i[0];
  assign prediction_fire[1] = fetch_valid_o[1] && fetch_ready_i[1] &&
                              prediction_fire[0];
  assign predicted_redirect_fire =
    (prediction_fire[0] && prediction_taken[0]) ||
    (prediction_fire[1] && prediction_taken[1]);
  assign predicted_redirect_pc = prediction_taken[0] ?
    prediction_target[0] : prediction_target[1];
  assign frontend_redirect_valid = redirect_valid_i || predicted_redirect_fire;
  assign frontend_redirect_pc = redirect_valid_i ? redirect_pc_i :
                                                  predicted_redirect_pc;

  always_comb begin
    fetch_prediction_o = prediction_meta;
    sequential_pc = '0;
    for (int unsigned lane = 0; lane < 2; lane++) begin
      sequential_pc[lane] = queue_pc[lane] +
        ((queue_inst_len[lane] == INST_LEN_16) ?
         PC_INCREMENT_2 : PC_INCREMENT_4);
      if (!prediction_meta[lane].valid) begin
        fetch_prediction_o[lane].target = '0;
        fetch_prediction_o[lane].target[XLEN-1:0] = sequential_pc[lane];
      end
    end
  end

  rv_branch_predictor #(
    .XLEN(XLEN), .BTB_ENTRIES(256), .BTB_WAYS(4),
    .PHT_ENTRIES(2048), .RAS_DEPTH(16)
  ) u_branch_predictor (
    .clk_i, .rst_ni, .query_valid_i(queue_valid), .query_pc_i(queue_pc),
    .query_instruction_i(queue_instruction), .query_inst_len_i(queue_inst_len),
    .prediction_taken_o(prediction_taken),
    .prediction_target_o(prediction_target),
    .prediction_meta_o(prediction_meta), .prediction_fire_i(prediction_fire),
    .redirect_valid_i(redirect_valid_i),
    .resolve_valid_i(predictor_resolve_valid_i),
    .resolve_pc_i(predictor_resolve_pc_i),
    .resolve_instruction_i(predictor_resolve_instruction_i),
    .resolve_inst_len_i(predictor_resolve_inst_len_i),
    .resolve_taken_i(predictor_resolve_taken_i),
    .resolve_target_i(predictor_resolve_target_i),
    .resolve_mispredict_i(predictor_resolve_mispredict_i),
    .resolve_prediction_i(predictor_resolve_prediction_i),
    .commit_valid_i(predictor_commit_valid_i),
    .commit_pc_i(predictor_commit_pc_i),
    .commit_instruction_i(predictor_commit_instruction_i),
    .commit_inst_len_i(predictor_commit_inst_len_i),
    .commit_taken_i(predictor_commit_taken_i)
  );

  rv_fetch_queue #(
    .XLEN         (XLEN),
    .PADDR_WIDTH  (PADDR_WIDTH),
    .FETCH_BYTES  (FETCH_BYTES),
    .QUEUE_BYTES  (QUEUE_BYTES),
    .RESET_VECTOR (RESET_VECTOR)
  ) u_fetch_queue (
    .clk_i,
    .rst_ni,
    .fill_valid_i      (queue_fill_valid),
    .fill_ready_o      (queue_fill_ready),
    .fill_addr_i       (outstanding_addr_q),
    .fill_id_i         (imem_rsp_id_i),
    .fill_epoch_i      (imem_rsp_epoch_i),
    .fill_data_i       (imem_rsp_data_i),
    .fill_resp_i       (imem_rsp_resp_i),
    .redirect_valid_i     (frontend_redirect_valid),
    .redirect_pc_i        (frontend_redirect_pc),
    .new_epoch_i       (epoch_q + 1'b1),
    .out_valid_o       (queue_valid),
    .out_ready_i       (queue_ready),
    .out_pc_o          (queue_pc),
    .out_instruction_o (queue_instruction),
    .out_inst_len_o    (queue_inst_len),
    .out_fault_o       (queue_fault),
    .empty_o           (queue_empty),
    .byte_count_o      (queue_byte_count)
  );

  always_ff @(posedge clk_i) begin
    if (!rst_ni) begin
      next_request_addr_q <=
        {reset_vector_paddr[PADDR_WIDTH-1:FETCH_ADDR_LSB],
         {FETCH_ADDR_LSB{1'b0}}};
      epoch_q <= '0;
      next_id_q <= '0;
      outstanding_q <= 1'b0;
      outstanding_id_q <= '0;
      outstanding_epoch_q <= '0;
      outstanding_addr_q <= '0;
      fault_stop_q <= 1'b0;
    end else begin
      if (imem_req_valid_o && imem_req_ready_i) begin
        outstanding_q <= 1'b1;
        outstanding_id_q <= next_id_q;
        outstanding_epoch_q <= epoch_q;
        outstanding_addr_q <= next_request_addr_q;
        next_request_addr_q <= next_request_addr_q + FETCH_BYTES_VALUE;
        next_id_q <= next_id_q + 1'b1;
      end

      if (imem_rsp_valid_i && imem_rsp_ready_o && response_id_matches) begin
        outstanding_q <= 1'b0;
        if (response_is_current && (imem_rsp_resp_i != 2'b00))
          fault_stop_q <= 1'b1;
      end

      if (frontend_redirect_valid) begin
        epoch_q <= epoch_q + 1'b1;
        next_request_addr_q <= redirect_block_addr;
        fault_stop_q <= 1'b0;
      end
    end
  end

`ifndef SYNTHESIS
  property p_request_stable_when_stalled;
    @(posedge clk_i) disable iff (!rst_ni || frontend_redirect_valid)
      imem_req_valid_o && !imem_req_ready_i |=> imem_req_valid_o &&
      $stable({imem_req_addr_o, imem_req_id_o, imem_req_epoch_o});
  endproperty
  assert property (p_request_stable_when_stalled);

  property p_response_id_matches_outstanding;
    @(posedge clk_i) disable iff (!rst_ni)
      imem_rsp_valid_i && outstanding_q |->
      (imem_rsp_id_i == outstanding_id_q);
  endproperty
  assert property (p_response_id_matches_outstanding);
`endif

  logic unused_queue_empty;
  always_comb unused_queue_empty = queue_empty;

endmodule
