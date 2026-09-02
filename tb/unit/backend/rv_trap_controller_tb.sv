module rv_trap_controller_tb;
  import rv_ooo_pkg::*;

  logic clk, rst_n;
  logic rob_trap_valid, rob_empty;
  logic [31:0] rob_trap_pc, rob_trap_tval;
  exception_code_e rob_trap_cause;
  logic interrupt_pending;
  logic [5:0] interrupt_cause;
  logic csr_trap_valid, csr_trap_ready, csr_trap_is_interrupt;
  logic [31:0] csr_trap_pc, csr_trap_tval, csr_trap_next_pc;
  logic [5:0] csr_trap_cause;
  logic [31:0] csr_trap_vector;
  logic [1:0] retire_fire;
  logic [1:0][31:0] retire_next_pc;
  logic retire_is_mret, retire_is_wfi, retire_is_fence_i;
  logic [31:0] mret_pc;
  logic wfi_wake;
  logic redirect_valid, redirect_pending, wfi_sleep;
  logic [31:0] redirect_pc, architectural_next_pc;

  always #5 clk = ~clk;

  rv_trap_controller #(.XLEN(32), .RESET_VECTOR(32'h0000_1000)) u_dut (
    .clk_i(clk), .rst_ni(rst_n),
    .rob_trap_valid_i(rob_trap_valid), .rob_trap_pc_i(rob_trap_pc),
    .rob_trap_cause_i(rob_trap_cause), .rob_trap_tval_i(rob_trap_tval),
    .rob_empty_i(rob_empty), .interrupt_pending_i(interrupt_pending),
    .interrupt_cause_i(interrupt_cause),
    .csr_trap_valid_o(csr_trap_valid), .csr_trap_ready_i(csr_trap_ready),
    .csr_trap_pc_o(csr_trap_pc), .csr_trap_cause_o(csr_trap_cause),
    .csr_trap_tval_o(csr_trap_tval),
    .csr_trap_is_interrupt_o(csr_trap_is_interrupt),
    .csr_trap_next_pc_o(csr_trap_next_pc),
    .csr_trap_vector_i(csr_trap_vector),
    .retire_fire_i(retire_fire), .retire_next_pc_i(retire_next_pc),
    .retire_is_mret_i(retire_is_mret), .retire_is_wfi_i(retire_is_wfi),
    .retire_is_fence_i_i(retire_is_fence_i), .mret_pc_i(mret_pc),
    .wfi_wake_i(wfi_wake),
    .architectural_redirect_valid_o(redirect_valid),
    .architectural_redirect_pc_o(redirect_pc),
    .redirect_pending_o(redirect_pending),
    .architectural_next_pc_o(architectural_next_pc),
    .wfi_sleep_o(wfi_sleep)
  );

  task automatic idle_inputs;
    rob_trap_valid = 1'b0;
    rob_trap_pc = '0;
    rob_trap_cause = EXC_ILLEGAL_INSTRUCTION;
    rob_trap_tval = '0;
    rob_empty = 1'b1;
    interrupt_pending = 1'b0;
    interrupt_cause = '0;
    csr_trap_ready = 1'b1;
    csr_trap_vector = 32'h8000_0100;
    retire_fire = '0;
    retire_next_pc = '0;
    retire_is_mret = 1'b0;
    retire_is_wfi = 1'b0;
    retire_is_fence_i = 1'b0;
    mret_pc = '0;
    wfi_wake = 1'b0;
  endtask

  initial begin
    clk = 1'b0;
    rst_n = 1'b0;
    idle_inputs();
    repeat (3) @(posedge clk);
    @(negedge clk);
    rst_n = 1'b1;

    // Interrupts are precise and cannot enter while the ROB still contains
    // speculative or unretired instructions.
    interrupt_pending = 1'b1;
    interrupt_cause = 6'd7;
    rob_empty = 1'b0;
    #1;
    if (csr_trap_valid || redirect_valid)
      $fatal(1, "interrupt entered before an architectural boundary");

    // A synchronous exception at the head has priority over a simultaneously
    // pending interrupt and carries its own PC/cause/tval.
    rob_empty = 1'b1;
    rob_trap_valid = 1'b1;
    rob_trap_pc = 32'h8000_0040;
    rob_trap_cause = EXC_LOAD_ACCESS_FAULT;
    rob_trap_tval = 32'hdead_beef;
    #1;
    if (!csr_trap_valid || csr_trap_is_interrupt ||
        (csr_trap_pc != 32'h8000_0040) ||
        (csr_trap_cause != 6'(EXC_LOAD_ACCESS_FAULT)) ||
        (csr_trap_tval != 32'hdead_beef) ||
        !redirect_valid || (redirect_pc != csr_trap_vector))
      $fatal(1, "synchronous exception priority/state failed");
    @(posedge clk);
    @(negedge clk);
    rob_trap_valid = 1'b0;
    interrupt_pending = 1'b0;

    // Retire establishes the exact next-PC boundary used as interrupt mepc.
    retire_fire = 2'b01;
    retire_next_pc[0] = 32'h8000_0084;
    @(posedge clk);
    @(negedge clk);
    retire_fire = '0;
    interrupt_pending = 1'b1;
    interrupt_cause = 6'd11;
    #1;
    if (!csr_trap_valid || !csr_trap_is_interrupt ||
        (csr_trap_pc != 32'h8000_0084) ||
        (csr_trap_next_pc != 32'h8000_0084) ||
        (csr_trap_cause != 6'd11) || (csr_trap_tval != 0))
      $fatal(1, "interrupt boundary/cause state failed");
    @(posedge clk);
    @(negedge clk);
    interrupt_pending = 1'b0;

    // WFI first redirects to its sequential boundary. A wake request clears
    // sleep, while the pending post-commit redirect prevents a second trap
    // from being accepted on the same edge.
    retire_fire = 2'b01;
    retire_is_wfi = 1'b1;
    retire_next_pc[0] = 32'h8000_00c0;
    @(posedge clk);
    @(negedge clk);
    retire_fire = '0;
    retire_is_wfi = 1'b0;
    interrupt_pending = 1'b1;
    wfi_wake = 1'b1;
    #1;
    if (!wfi_sleep || !redirect_pending || !redirect_valid ||
        (redirect_pc != 32'h8000_00c0) || csr_trap_valid)
      $fatal(1, "WFI redirect/wake serialization failed");
    @(posedge clk);
    @(negedge clk);
    if (wfi_sleep)
      $fatal(1, "WFI wake did not clear sleep state");

    $display("rv_trap_controller_tb PASS");
    $finish;
  end
endmodule
