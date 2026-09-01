module rv_commit_trace_logger #(
  parameter int unsigned XLEN = 32
) (
  input logic                         clk_i,
  input logic                         rst_ni,
  input logic [1:0]                   trace_valid_i,
  input logic [1:0][XLEN-1:0]         trace_pc_i,
  input logic [1:0][31:0]             trace_instr_i,
  input logic [1:0][4:0]              trace_rd_i,
  input logic [1:0]                   trace_rd_write_i,
  input logic [1:0]                   trace_rd_fp_i,
  input logic [1:0][XLEN-1:0]         trace_rd_wdata_i,
  input logic [1:0]                   trace_trap_i,
  input logic [1:0][5:0]              trace_cause_i,
  input logic [1:0][XLEN-1:0]         trace_tval_i
);

  integer trace_fd;
  string trace_path;
  longint unsigned retire_order_q;
  longint unsigned cycle_q;

  initial begin
    trace_fd = 0;
    if ($value$plusargs("trace_file=%s", trace_path)) begin
      trace_fd = $fopen(trace_path, "w");
      if (trace_fd == 0)
        $fatal(1, "Unable to open commit trace file: %s", trace_path);
      $fdisplay(trace_fd,
        "order,cycle,lane,pc,instruction,rd_write,rd_fp,rd,wdata,trap,cause,tval");
    end
  end

  always_ff @(posedge clk_i) begin
    if (!rst_ni) begin
      retire_order_q <= 0;
      cycle_q <= 0;
    end else begin
      for (int unsigned lane = 0; lane < 2; lane++) begin
        if (trace_valid_i[lane] && (trace_fd != 0)) begin
          $fdisplay(trace_fd,
            "%0d,%0t,%0d,%x,%08x,%0d,%0d,%0d,%x,%0d,%0d,%x",
            retire_order_q + ((lane == 1) && trace_valid_i[0]), cycle_q, lane,
            trace_pc_i[lane], trace_instr_i[lane],
            trace_rd_write_i[lane], trace_rd_fp_i[lane], trace_rd_i[lane],
            trace_rd_wdata_i[lane], trace_trap_i[lane],
            trace_cause_i[lane], trace_tval_i[lane]);
        end
      end
      retire_order_q <= retire_order_q +
                        $unsigned(trace_valid_i[0]) +
                        $unsigned(trace_valid_i[1]);
      cycle_q <= cycle_q + 1'b1;
    end
  end

  final begin
    if (trace_fd != 0)
      $fclose(trace_fd);
  end

endmodule
