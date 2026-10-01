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
module rv_exec_result_buffer_depth2_tb #(parameter int unsigned XLEN=32);
  import rv_ooo_pkg::*;

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
  logic req_dst_valid, req_exception, req_mispredict;
  reg_class_e req_class;
  exception_code_e req_cause;
  logic [XLEN-1:0] req_tval, req_target;
  logic [4:0] req_fflags;
  logic res_dst_valid, res_exception, res_mispredict;
  reg_class_e res_class;
  exception_code_e res_cause;
  logic [XLEN-1:0] res_tval, res_target;
  logic [4:0] res_fflags;

  rv_exec_result_buffer #(.XLEN(XLEN), .ROB_SEQ_WIDTH(SEQW),
                          .PHYS_TAG_WIDTH(TAGW), .DEPTH(2)) dut (
    .clk_i(clk), .rst_ni(rst_n),
    .request_valid_i(req_valid), .request_ready_o(req_ready),
    .request_sequence_i(req_seq), .request_destination_valid_i(req_dst_valid),
    .request_destination_class_i(req_class), .request_destination_phys_i(req_phys),
    .request_data_i(req_data), .request_exception_valid_i(req_exception),
    .request_exception_cause_i(req_cause),
    .request_exception_tval_i(req_tval), .request_branch_mispredict_i(req_mispredict),
    .request_branch_target_i(req_target), .request_fflags_i(req_fflags),
    .flush_valid_i(flush_valid), .flush_all_i(flush_all),
    .flush_sequence_i(flush_seq),
    .result_valid_o(res_valid), .result_ready_i(res_ready),
    .result_sequence_o(res_seq), .result_destination_valid_o(res_dst_valid),
    .result_destination_class_o(res_class), .result_destination_phys_o(res_phys),
    .result_data_o(res_data), .result_exception_valid_o(res_exception),
    .result_exception_cause_o(res_cause), .result_exception_tval_o(res_tval),
    .result_branch_mispredict_o(res_mispredict), .result_branch_target_o(res_target),
    .result_fflags_o(res_fflags));

  typedef struct packed {
    logic [SEQW-1:0] seq;
    logic [XLEN-1:0] data;
    logic [TAGW-1:0] phys;
    logic dst_valid;
    reg_class_e dst_class;
    logic exception_valid;
    exception_code_e cause;
    logic [XLEN-1:0] tval;
    logic mispredict;
    logic [XLEN-1:0] target;
    logic [4:0] fflags;
  } ent_t;
  ent_t model [$];
  ent_t observed, submitted;
  always_comb begin
    observed = {res_seq,res_data,res_phys,res_dst_valid,res_class,res_exception,
                res_cause,res_tval,res_mispredict,res_target,res_fflags};
    submitted = {req_seq,req_data,req_phys,req_dst_valid,req_class,req_exception,
                 req_cause,req_tval,req_mispredict,req_target,req_fflags};
  end

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
    end else if (res_valid && (observed !== model[0])) begin
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
    req_dst_valid=0; req_class=REG_NONE; req_exception=0;
    req_cause=EXC_ILLEGAL_INSTRUCTION; req_tval=0; req_mispredict=0;
    req_target=0; req_fflags=0;
    flush_valid = 0; flush_all = 0; flush_seq = 0; res_ready = 0;
    repeat (3) @(negedge clk);
    rst_n = 1'b1;
    for (int cycle = 0; cycle < 200000; cycle++) begin
      @(negedge clk);
      // Repeated synchronous reset must drop every payload/valid entry.
      rst_n = (cycle%4096 != 4095);
      // stimulus for this cycle
      flush_valid = (($urandom(seed) % 23) == 0); seed++;
      flush_all   = flush_valid && (($urandom(seed) % 5) == 0); seed++;
      // flush boundary somewhere around the live window
      flush_seq   = base_seq - SEQW'($urandom(seed) % 6); seed++;
      req_valid   = (($urandom(seed) % 3) != 0); seed++;
      // issue order is not age order: pick a sequence near the window
      req_seq     = base_seq - SEQW'($urandom(seed) % 4); seed++;
      req_data    = XLEN'({$urandom(seed),$urandom(seed)}); seed++;
      req_phys    = TAGW'($urandom(seed)); seed++;
      req_dst_valid = 1'($urandom(seed)); seed++;
      req_class = reg_class_e'(2'($urandom(seed))); seed++;
      req_exception = 1'($urandom(seed)); seed++;
      req_cause = exception_code_e'(6'($urandom(seed))); seed++;
      req_tval = XLEN'({$urandom(seed),$urandom(seed)}); seed++;
      req_mispredict = 1'($urandom(seed)); seed++;
      req_target = XLEN'({$urandom(seed),$urandom(seed)}); seed++;
      req_fflags = 5'($urandom(seed)); seed++;
      res_ready   = (($urandom(seed) % 4) != 0); seed++;
      #1;
      check_outputs();
      // model transition at the clock edge
      @(posedge clk);
      if (!rst_n) begin
        model.delete();
      end else if (flush_valid) begin
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
          model.push_back(submitted);
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
      $fatal(1,"rv_exec_result_buffer_depth2_tb FAIL errors=%0d", errors);
    $finish;
  end
endmodule
