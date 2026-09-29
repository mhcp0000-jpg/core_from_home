// Randomized reference-model check for rv_lsu_pipe DEPTH=2.
//
// Model: an issue-ordered queue of at most two update entries.
//   * issue accepted  <=> issue_valid && issue_ready
//   * issue_ready     == (occupancy < 2) && !flush_valid   (registered only)
//   * head popped     <=> update_valid && update_ready && !flush_valid
//   * flush cycle     : no push/pop; entries younger than the boundary (or
//                       all, on flush_all) are removed, order preserved
// The address/mask/data generation is shared with DEPTH=1 (rv_lsu_pipe_tb);
// this bench checks ordering, occupancy, flush and head stability.
module rv_lsu_pipe_depth2_tb;
  import rv_ooo_pkg::*;

  localparam int unsigned SEQW = 8;

  logic clk = 1'b0, rst_n = 1'b0;
  always #5 clk = ~clk;

  logic issue_valid, issue_ready, is_load, is_store;
  logic [SEQW-1:0] issue_seq;
  logic [31:0] base, imm, sdata;
  logic [2:0] size;
  logic [4:0] lq_index;
  logic [3:0] sq_index;
  logic flush_valid, flush_all;
  logic [SEQW-1:0] flush_seq;
  logic upd_valid, upd_ready;
  logic [SEQW-1:0] upd_seq;
  logic [31:0] upd_addr;
  logic [2:0] upd_size;
  logic upd_is_load, upd_is_store;
  logic [4:0] upd_lq_index;
  logic [3:0] upd_sq_index;

  rv_lsu_pipe #(.XLEN(32), .PADDR_WIDTH(32), .MEM_DATA_WIDTH(64),
                .ROB_SEQ_WIDTH(SEQW), .LQ_INDEX_WIDTH(5),
                .SQ_INDEX_WIDTH(4), .DEPTH(2)) dut (
    .clk_i(clk), .rst_ni(rst_n),
    .issue_valid_i(issue_valid), .issue_ready_o(issue_ready),
    .issue_rob_sequence_i(issue_seq), .issue_is_load_i(is_load),
    .issue_is_store_i(is_store), .issue_address_valid_i(1'b1),
    .issue_store_data_valid_i(is_store), .issue_lq_valid_i(is_load),
    .issue_lq_index_i(lq_index), .issue_sq_valid_i(is_store),
    .issue_sq_index_i(sq_index), .base_i(base), .immediate_i(imm),
    .store_data_i(sdata), .memory_size_i(size),
    .flush_valid_i(flush_valid), .flush_all_i(flush_all),
    .flush_sequence_i(flush_seq),
    .update_valid_o(upd_valid), .update_ready_i(upd_ready),
    .update_rob_sequence_o(upd_seq), .update_is_load_o(upd_is_load),
    .update_is_store_o(upd_is_store), .update_lq_valid_o(),
    .update_lq_index_o(upd_lq_index), .update_sq_valid_o(),
    .update_sq_index_o(upd_sq_index), .update_address_o(upd_addr),
    .update_memory_size_o(upd_size), .update_byte_mask_o(),
    .update_store_data_o(), .update_address_valid_o(),
    .update_store_data_valid_o(), .update_exception_valid_o(),
    .update_exception_cause_o(), .update_exception_tval_o());

  typedef struct packed {
    logic [SEQW-1:0] seq;
    logic [31:0] addr;
    logic [2:0] size;
    logic is_load, is_store;
    logic [4:0] lq_index;
    logic [3:0] sq_index;
  } ent_t;
  ent_t model [$];

  function automatic logic younger(input logic [SEQW-1:0] c, input logic [SEQW-1:0] b);
    logic [SEQW-1:0] d;
    d = c - b;
    return (d != 0) && !d[SEQW-1];
  endfunction

  int unsigned seed = 32'h0bad_5eed;
  int unsigned errors = 0, pushes = 0, pops = 0, flushes = 0, full_cycles = 0;
  logic [SEQW-1:0] base_seq = 8'd20;

  task automatic check_outputs();
    if (upd_valid !== (model.size() != 0)) begin
      errors++;
      $display("VALID mismatch dut=%0b model=%0d", upd_valid, model.size());
    end else if (upd_valid &&
                 ({upd_seq, upd_addr, upd_size, upd_is_load, upd_is_store,
                   upd_lq_index, upd_sq_index} !==
                  {model[0].seq, model[0].addr, model[0].size,
                   model[0].is_load, model[0].is_store, model[0].lq_index,
                   model[0].sq_index})) begin
      errors++;
      $display("HEAD mismatch dut seq=%0d addr=%08h model seq=%0d addr=%08h",
               upd_seq, upd_addr, model[0].seq, model[0].addr);
    end
    if (issue_ready !== ((model.size() < 2) && !flush_valid)) begin
      errors++;
      $display("READY mismatch dut=%0b occ=%0d flush=%0b", issue_ready,
               model.size(), flush_valid);
    end
  endtask

  initial begin
    issue_valid = 0; issue_seq = 0; is_load = 0; is_store = 0; base = 0;
    imm = 0; sdata = 0; size = 0; lq_index = 0; sq_index = 0;
    flush_valid = 0; flush_all = 0; flush_seq = 0; upd_ready = 0;
    repeat (3) @(negedge clk);
    rst_n = 1'b1;
    for (int cycle = 0; cycle < 200000; cycle++) begin
      @(negedge clk);
      flush_valid = (($urandom(seed) % 29) == 0); seed++;
      flush_all   = flush_valid && (($urandom(seed) % 5) == 0); seed++;
      flush_seq   = base_seq - SEQW'($urandom(seed) % 6); seed++;
      issue_valid = (($urandom(seed) % 3) != 0); seed++;
      issue_seq   = base_seq - SEQW'($urandom(seed) % 4); seed++;
      is_load     = 1'($urandom(seed) % 2); seed++;
      is_store    = !is_load;
      base        = $urandom(seed); seed++;
      imm         = $urandom(seed) % 4096; seed++;
      sdata       = $urandom(seed); seed++;
      size        = 3'($urandom(seed) % 3); seed++;
      lq_index    = 5'($urandom(seed)); seed++;
      sq_index    = 4'($urandom(seed)); seed++;
      upd_ready   = (($urandom(seed) % 3) != 0); seed++;
      #1;
      check_outputs();
      if (model.size() == 2) full_cycles++;
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
        do_pop  = (model.size() != 0) && upd_ready;
        do_push = issue_valid && (model.size() < 2);
        if (do_pop) begin
          void'(model.pop_front());
          pops++;
        end
        if (do_push) begin
          automatic ent_t e;
          e.seq = issue_seq; e.addr = base + imm; e.size = size;
          e.is_load = is_load; e.is_store = is_store;
          e.lq_index = lq_index; e.sq_index = sq_index;
          model.push_back(e);
          pushes++;
          base_seq = base_seq + 1;
        end
      end
      if (errors > 10) break;
    end
    if (errors == 0)
      $display("rv_lsu_pipe_depth2_tb PASS pushes=%0d pops=%0d flushes=%0d full=%0d",
               pushes, pops, flushes, full_cycles);
    else
      $display("rv_lsu_pipe_depth2_tb FAIL errors=%0d", errors);
    $finish;
  end
endmodule
