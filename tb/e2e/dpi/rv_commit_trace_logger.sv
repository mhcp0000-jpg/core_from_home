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
  input logic [1:0][XLEN-1:0]         trace_tval_i,
  output logic                        last_commit_valid_o,
  output logic [63:0]                 retire_order_o,
  output logic [63:0]                 cycle_o,
  output logic [63:0]                 cycles_since_commit_o,
  output logic [XLEN-1:0]             last_commit_pc_o,
  output logic [31:0]                 last_commit_instr_o
  );

  integer trace_fd;
  string trace_path;
  longint unsigned retire_order_q;
  longint unsigned cycle_q;
  longint unsigned cycles_since_commit_q;
  logic last_commit_valid_q;
  logic [XLEN-1:0] last_commit_pc_q;
  logic [31:0] last_commit_instr_q;

  assign last_commit_valid_o = last_commit_valid_q;
  assign retire_order_o = retire_order_q;
  assign cycle_o = cycle_q;
  assign cycles_since_commit_o = cycles_since_commit_q;
  assign last_commit_pc_o = last_commit_pc_q;
  assign last_commit_instr_o = last_commit_instr_q;

  initial begin
    trace_fd = 0;
    if ($value$plusargs("trace_file=%s", trace_path)) begin
      trace_fd = $fopen(trace_path, "w");
      if (trace_fd == 0)
        $fatal(1, "Unable to open commit trace file: %s", trace_path);
      $fdisplay(trace_fd,
        "order,cycle,lane,pc,instruction,rd_write,rd_fp,rd,wdata,trap,cause,tval");
      $fflush(trace_fd);
      $display("[COMMIT][%0t] trace file opened: %s", $time, trace_path);
    end
    $display("[COMMIT][%0t] live logger enabled: every retired instruction",
             $time);
  end

  always_ff @(posedge clk_i) begin
    if (!rst_ni) begin
      retire_order_q <= 0;
      cycle_q <= 0;
      cycles_since_commit_q <= 0;
      last_commit_valid_q <= 1'b0;
      last_commit_pc_q <= '0;
      last_commit_instr_q <= '0;
    end else begin
      for (int unsigned lane = 0; lane < 2; lane++) begin
        if (trace_valid_i[lane]) begin
          if (trace_fd != 0) begin
            $fdisplay(trace_fd,
              "%0d,%0d,%0d,%x,%08x,%0d,%0d,%0d,%x,%0d,%0d,%x",
              retire_order_q + ((lane == 1) && trace_valid_i[0]), cycle_q, lane,
              trace_pc_i[lane], trace_instr_i[lane],
              trace_rd_write_i[lane], trace_rd_fp_i[lane], trace_rd_i[lane],
              trace_rd_wdata_i[lane], trace_trap_i[lane],
              trace_cause_i[lane], trace_tval_i[lane]);
          end
          $display("[COMMIT][%0t] order=%0d cycle=%0d lane=%0d pc=%08h instr=%08h rd_we=%b rd_fp=%b rd=%0d wdata=%08h trap=%b cause=%0d tval=%08h",
            $time, retire_order_q + ((lane == 1) && trace_valid_i[0]),
            cycle_q, lane, trace_pc_i[lane], trace_instr_i[lane],
            trace_rd_write_i[lane], trace_rd_fp_i[lane], trace_rd_i[lane],
            trace_rd_wdata_i[lane], trace_trap_i[lane],
            trace_cause_i[lane], trace_tval_i[lane]);
        end
      end
      if (|trace_valid_i) begin
        cycles_since_commit_q <= 0;
        last_commit_valid_q <= 1'b1;
        if (trace_valid_i[1]) begin
          last_commit_pc_q <= trace_pc_i[1];
          last_commit_instr_q <= trace_instr_i[1];
        end else begin
          last_commit_pc_q <= trace_pc_i[0];
          last_commit_instr_q <= trace_instr_i[0];
        end
      end else begin
        cycles_since_commit_q <= cycles_since_commit_q + 1'b1;
      end
      retire_order_q <= retire_order_q +
                        $unsigned(trace_valid_i[0]) +
                        $unsigned(trace_valid_i[1]);
      cycle_q <= cycle_q + 1'b1;
      // If the core stops retiring, periodically flush the last CSV records so
      // the file remains useful even before the simulation reaches timeout.
      if ((trace_fd != 0) && (cycle_q[9:0] == 10'b0))
        $fflush(trace_fd);
    end
  end

  final begin
    if (trace_fd != 0)
      $fclose(trace_fd);
  end

endmodule
