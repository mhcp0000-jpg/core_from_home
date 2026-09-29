// Randomized reference-model check for rv_exec_result_buffer DEPTH=2.
//
// Model: an insertion-ordered queue of at most two entries.
//   * request accepted  <=> request_valid && request_ready
//   * request_ready     == (occupancy < 2) && !flush_valid   (registered only)
//   * head popped       <=> result_valid && result_ready && !flush_valid
//   * flush cycle       : no push/pop; every entry younger than the boundary
//                         (or all, on flush_all) is removed, order preserved
// The DUT output must always equal the model head, and a stalled head must
// stay stable.
module rv_exec_result_buffer_depth2_tb;
  import rv_ooo_pkg::*;

  localparam int unsigned XLEN = 32;
  localparam int unsigned SEQW = 8;
  localparam int unsigned TAGW = 7;

  logic clk = 1'b0, rst_n = 1'b0;
  always #5 clk = ~clk;

  logic req_valid, req_ready;
  logic [SEQW-1:0] req_seq;
  logic [XLEN-1:0] req_data;
  logic [TAGW-1:0] req_phys;
  logic flush_valid, flush_all;
  logic [SEQW-1:0] flush_seq;
  logic res_valid, res_ready;
  logic [SEQW-1:0] res_seq;
  logic [XLEN-1:0] res_data;
  logic [TAGW-1:0] res_phys;

  rv_exec_result_buffer #(.XLEN(XLEN), .ROB_SEQ_WIDTH(SEQW),
                          .PHYS_TAG_WIDTH(TAGW), .DEPTH(2)) dut (
    .clk_i(clk), .rst_ni(rst_n),
    .request_valid_i(req_valid), .request_ready_o(req_ready),
    .request_sequence_i(req_seq), .request_destination_valid_i(1'b1),
    .request_destination_class_i(REG_INT), .request_destination_phys_i(req_phys),
    .request_data_i(req_data), .request_exception_valid_i(1'b0),
    .request_exception_cause_i(EXC_ILLEGAL_INSTRUCTION),
    .request_exception_tval_i('0), .request_branch_mispredict_i(1'b0),
    .request_branch_target_i('0), .request_fflags_i('0),
    .flush_valid_i(flush_valid), .flush_all_i(flush_all),
    .flush_sequence_i(flush_seq),
    .result_valid_o(res_valid), .result_ready_i(res_ready),
    .result_sequence_o(res_seq), .result_destination_valid_o(),
    .result_destination_class_o(), .result_destination_phys_o(res_phys),
    .result_data_o(res_data), .result_exception_valid_o(),
    .result_exception_cause_o(), .result_exception_tval_o(),
    .result_branch_mispredict_o(), .result_branch_target_o(),
    .result_fflags_o());

  typedef struct packed {
    logic [SEQW-1:0] seq;
    logic [XLEN-1:0] data;
    logic [TAGW-1:0] phys;
  } ent_t;
  ent_t model [$];

  function automatic logic younger(input logic [SEQW-1:0] c, input logic [SEQW-1:0] b);
    logic [SEQW-1:0] d;
    d = c - b;
    return (d != 0) && !d[SEQW-1];
  endfunction

  int unsigned seed = 32'h1234_5678;
  int unsigned errors = 0, pushes = 0, pops = 0, flushes = 0;
  logic [SEQW-1:0] base_seq = 8'd10;

  task automatic check_outputs();
    if (res_valid !== (model.size() != 0)) begin
      errors++;
      $display("VALID mismatch dut=%0b model=%0d", res_valid, model.size());
    end else if (res_valid && ({res_seq, res_data, res_phys} !==
                               {model[0].seq, model[0].data, model[0].phys})) begin
      errors++;
      $display("HEAD mismatch dut seq=%0d data=%08h model seq=%0d data=%08h",
               res_seq, res_data, model[0].seq, model[0].data);
    end
    if (req_ready !== ((model.size() < 2) && !flush_valid)) begin
      errors++;
      $display("READY mismatch dut=%0b occ=%0d flush=%0b", req_ready,
               model.size(), flush_valid);
    end
  endtask

  initial begin
    req_valid = 0; req_seq = 0; req_data = 0; req_phys = 0;
    flush_valid = 0; flush_all = 0; flush_seq = 0; res_ready = 0;
    repeat (3) @(negedge clk);
    rst_n = 1'b1;
    for (int cycle = 0; cycle < 200000; cycle++) begin
      @(negedge clk);
      // stimulus for this cycle
      flush_valid = (($urandom(seed) % 23) == 0); seed++;
      flush_all   = flush_valid && (($urandom(seed) % 5) == 0); seed++;
      // flush boundary somewhere around the live window
      flush_seq   = base_seq - SEQW'($urandom(seed) % 6); seed++;
      req_valid   = (($urandom(seed) % 3) != 0); seed++;
      // issue order is not age order: pick a sequence near the window
      req_seq     = base_seq - SEQW'($urandom(seed) % 4); seed++;
      req_data    = $urandom(seed); seed++;
      req_phys    = TAGW'($urandom(seed)); seed++;
      res_ready   = (($urandom(seed) % 4) != 0); seed++;
      #1;
      check_outputs();
      // model transition at the clock edge
      @(posedge clk);
      if (flush_valid) begin
        automatic ent_t keep [$];
        keep.delete();
        flushes++;
        foreach (model[i])
          if (!(flush_all || younger(model[i].seq, flush_seq)))
            keep.push_back(model[i]);
        model = keep;
      end else begin
        automatic logic do_pop, do_push;
        do_pop  = (model.size() != 0) && res_ready;
        do_push = req_valid && (model.size() < 2);
        if (do_pop) begin
          void'(model.pop_front());
          pops++;
        end
        if (do_push) begin
          automatic ent_t e;
          e.seq = req_seq; e.data = req_data; e.phys = req_phys;
          model.push_back(e);
          pushes++;
          base_seq = base_seq + 1;
        end
      end
      if (errors > 10) break;
    end
    if (errors == 0)
      $display("rv_exec_result_buffer_depth2_tb PASS pushes=%0d pops=%0d flushes=%0d",
               pushes, pops, flushes);
    else
      $display("rv_exec_result_buffer_depth2_tb FAIL errors=%0d", errors);
    $finish;
  end
endmodule
