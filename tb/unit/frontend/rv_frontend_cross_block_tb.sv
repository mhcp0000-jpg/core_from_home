module rv_frontend_cross_block_tb #(
  parameter int unsigned XLEN = 32,
  parameter int unsigned PADDR_WIDTH = XLEN
);
  import rv_ooo_pkg::*;
  localparam logic [XLEN-1:0] BASE = (XLEN == 64) ?
    XLEN'(64'hffff_ffff_8000_0000) : XLEN'(32'h8000_0000);
  logic clk = 0, rst_n = 0;
  always #5 clk = ~clk;
  logic redirect;
  logic [XLEN-1:0] redirect_pc;
  logic [1:0] fetch_valid, fetch_ready, fetch_fault;
  logic [1:0][XLEN-1:0] fetch_pc;
  logic [1:0][31:0] fetch_instruction;
  inst_len_e [1:0] fetch_length;
  prediction_meta_t [1:0] fetch_prediction;
  logic request_valid, request_ready, response_valid, response_ready;
  logic [PADDR_WIDTH-1:0] request_address, response_address;
  logic [3:0] request_id, request_epoch, response_id, response_epoch;
  logic [127:0] response_data;
  logic [7:0] pmp_valid;
  logic [7:0][PADDR_WIDTH-1:0] pmp_address;
  logic [XLEN-1:0] expected_pc;
  int loops, instructions, ticks;

  // Seven C.NOPs followed by a 32-bit JAL x0,-14 at offset14. Its high
  // halfword is in the next block. Repeating it exercises FTB reuse,
  // sequential next-block join and both dual-output parcel coordinates.
  function automatic logic [127:0] memory_block(input logic [PADDR_WIDTH-1:0] address);
    logic [127:0] value;
    for (int parcel = 0; parcel < 8; parcel++) value[parcel*16 +: 16] = 16'h0001;
    if (address == PADDR_WIDTH'(BASE)) value[127:112] = 16'hf06f;
    else if (address == PADDR_WIDTH'(BASE + XLEN'(16))) value[15:0] = 16'hff3f;
    return value;
  endfunction
  assign response_data = memory_block(response_address);

  rv_frontend #(.XLEN(XLEN), .PADDR_WIDTH(PADDR_WIDTH), .RESET_VECTOR(BASE)) u_dut (
    .clk_i(clk), .rst_ni(rst_n), .redirect_valid_i(redirect), .redirect_pc_i(redirect_pc),
    .predictor_resolve_valid_i(1'b0), .predictor_resolve_pc_i('0),
    .predictor_resolve_instruction_i('0), .predictor_resolve_inst_len_i(INST_LEN_NONE),
    .predictor_resolve_taken_i(1'b0), .predictor_resolve_target_i('0),
    .predictor_resolve_mispredict_i(1'b0), .predictor_resolve_prediction_i('0),
    .predictor_commit_valid_i('0), .predictor_commit_pc_i('0),
    .predictor_commit_instruction_i('0),
    .predictor_commit_inst_len_i({INST_LEN_NONE, INST_LEN_NONE}),
    .predictor_commit_taken_i('0),
    .fetch_valid_o(fetch_valid), .fetch_ready_i(fetch_ready), .fetch_pc_o(fetch_pc),
    .fetch_instr_o(fetch_instruction), .fetch_inst_len_o(fetch_length),
    .fetch_prediction_o(fetch_prediction), .fetch_fault_o(fetch_fault),
    .imem_req_valid_o(request_valid), .imem_req_ready_i(request_ready),
    .imem_req_addr_o(request_address), .imem_req_id_o(request_id),
    .imem_req_epoch_o(request_epoch), .pmp_check_valid_o(pmp_valid),
    .pmp_check_address_o(pmp_address), .pmp_check_allow_i(8'hff),
    .imem_rsp_valid_i(response_valid), .imem_rsp_ready_o(response_ready),
    .imem_rsp_id_i(response_id), .imem_rsp_epoch_i(response_epoch),
    .imem_rsp_data_i(response_data), .imem_rsp_resp_i(2'b00)
  );

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      response_valid <= 0;
      response_address <= '0;
      response_id <= 0;
      response_epoch <= 0;
    end else if (!response_valid || response_ready) begin
      response_valid <= request_valid && request_ready;
      if (request_valid && request_ready) begin
        response_address <= request_address;
        response_id <= request_id;
        response_epoch <= request_epoch;
      end
    end
  end

  always @(posedge clk) begin
    if (rst_n && !redirect) begin
      for (int lane = 0; lane < 2; lane++) begin
        if (fetch_valid[lane] && fetch_ready[lane]) begin
          if (fetch_pc[lane] !== expected_pc || fetch_fault[lane])
            $fatal(1, "Front predecode PC/fault mismatch expected=%h got=%h fault=%b",
                   expected_pc, fetch_pc[lane], fetch_fault[lane]);
          if (expected_pc == BASE + XLEN'(14)) begin
            if (fetch_instruction[lane] !== 32'hff3ff06f ||
                fetch_length[lane] != INST_LEN_32 ||
                !fetch_prediction[lane].taken ||
                fetch_prediction[lane].target[XLEN-1:0] != BASE)
              $fatal(1, "Cross-block JAL decode/target mismatch");
            expected_pc = BASE;
            loops++;
          end else begin
            if (fetch_instruction[lane] !== 32'h00000001 || fetch_length[lane] != INST_LEN_16)
              $fatal(1, "C.NOP decode mismatch at %h", expected_pc);
            expected_pc += XLEN'(2);
          end
          instructions++;
        end
      end
    end
  end

  initial begin
    redirect = 0; redirect_pc = BASE; fetch_ready = 0; request_ready = 0;
    expected_pc = BASE; loops = 0; instructions = 0; ticks = 0;
    repeat (3) @(negedge clk);
    rst_n = 1;
    for (int cycle = 0; cycle < 1000 && loops < 12; cycle++) begin
      @(negedge clk);
      ticks++;
      fetch_ready = (cycle % 4 == 0) ? 2'b00 : 2'b11;
      request_ready = cycle % 3 != 0;
      // A cold architectural redirect directly to the cross-block instruction
      // discards cached metadata and leaves only the last first-block parcel.
      redirect = cycle == 45;
      redirect_pc = BASE + XLEN'(14);
      if (redirect) expected_pc = redirect_pc;
    end
    @(negedge clk);
    if (loops < 12) $fatal(1, "Frontend cross-block loop timed out");
    $display("frontend XLEN=%0d PADDR=%0d cross-block/cache/redirect/stall PASS instructions=%0d cycles=%0d",
             XLEN, PADDR_WIDTH, instructions, ticks);
    $finish;
  end
endmodule
