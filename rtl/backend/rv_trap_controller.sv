module rv_trap_controller #(
  parameter int unsigned XLEN = 32,
  parameter logic [XLEN-1:0] RESET_VECTOR = 'h0000_1000
) (
  input  logic                         clk_i,
  input  logic                         rst_ni,

  input  logic                         rob_trap_valid_i,
  input  logic [XLEN-1:0]              rob_trap_pc_i,
  input  rv_ooo_pkg::exception_code_e  rob_trap_cause_i,
  input  logic [XLEN-1:0]              rob_trap_tval_i,
  input  logic                         rob_empty_i,

  input  logic                         interrupt_pending_i,
  input  logic [5:0]                   interrupt_cause_i,

  output logic                         csr_trap_valid_o,
  input  logic                         csr_trap_ready_i,
  output logic [XLEN-1:0]              csr_trap_pc_o,
  output logic [5:0]                   csr_trap_cause_o,
  output logic [XLEN-1:0]              csr_trap_tval_o,
  output logic                         csr_trap_is_interrupt_o,
  output logic [XLEN-1:0]              csr_trap_next_pc_o,
  input  logic [XLEN-1:0]              csr_trap_vector_i,

  input  logic [1:0]                   retire_fire_i,
  input  logic [1:0][XLEN-1:0]         retire_next_pc_i,
  input  logic                         retire_is_mret_i,
  input  logic                         retire_is_wfi_i,
  input  logic                         retire_is_fence_i_i,
  input  logic [XLEN-1:0]              mret_pc_i,
  input  logic                         wfi_wake_i,

  output logic                         architectural_redirect_valid_o,
  output logic [XLEN-1:0]              architectural_redirect_pc_o,
  output logic                         redirect_pending_o,
  output logic [XLEN-1:0]              architectural_next_pc_o,
  output logic                         wfi_sleep_o
);

  logic redirect_pending_q;
  logic [XLEN-1:0] redirect_target_q;
  logic [XLEN-1:0] architectural_next_pc_q;
  logic wfi_sleep_q;

  // A synchronous exception is selected before an interrupt. Interrupts are
  // sampled only when the ROB is empty, so mepc always names an architectural
  // instruction boundary. A pending post-commit redirect has higher priority.
  always_comb begin
    csr_trap_valid_o        = 1'b0;
    csr_trap_is_interrupt_o = 1'b0;
    csr_trap_pc_o           = rob_trap_pc_i;
    csr_trap_tval_o         = rob_trap_tval_i;
    csr_trap_cause_o        = 6'(rob_trap_cause_i);
    csr_trap_next_pc_o      = architectural_next_pc_q;

    if (!redirect_pending_q && rob_trap_valid_i) begin
      csr_trap_valid_o = 1'b1;
    end else if (!redirect_pending_q && rob_empty_i &&
                 interrupt_pending_i) begin
      csr_trap_valid_o        = 1'b1;
      csr_trap_is_interrupt_o = 1'b1;
      csr_trap_pc_o           = architectural_next_pc_q;
      csr_trap_tval_o         = '0;
      csr_trap_cause_o        = interrupt_cause_i;
    end
  end

  assign architectural_redirect_valid_o = redirect_pending_q ||
                                             csr_trap_valid_o;
  assign architectural_redirect_pc_o = redirect_pending_q ?
                                           redirect_target_q :
                                           csr_trap_vector_i;
  assign redirect_pending_o       = redirect_pending_q;
  assign architectural_next_pc_o  = architectural_next_pc_q;
  assign wfi_sleep_o              = wfi_sleep_q;

  always_ff @(posedge clk_i) begin
    if (!rst_ni) begin
      redirect_pending_q      <= 1'b0;
      redirect_target_q       <= RESET_VECTOR;
      architectural_next_pc_q <= RESET_VECTOR;
      wfi_sleep_q             <= 1'b0;
    end else begin
      if (redirect_pending_q)
        redirect_pending_q <= 1'b0;

      if (retire_fire_i[0] && retire_is_mret_i) begin
        redirect_pending_q <= 1'b1;
        redirect_target_q  <= mret_pc_i;
      end else if (retire_fire_i[0] &&
                   (retire_is_fence_i_i || retire_is_wfi_i)) begin
        redirect_pending_q <= 1'b1;
        redirect_target_q  <= retire_next_pc_i[0];
      end

      if (retire_fire_i[1])
        architectural_next_pc_q <= retire_next_pc_i[1];
      else if (retire_fire_i[0])
        architectural_next_pc_q <= retire_next_pc_i[0];

      if (csr_trap_valid_o && csr_trap_ready_i)
        architectural_next_pc_q <= csr_trap_vector_i;

      if (retire_fire_i[0] && retire_is_wfi_i)
        wfi_sleep_q <= 1'b1;
      if ((wfi_sleep_q && wfi_wake_i) ||
          (csr_trap_valid_o && csr_trap_ready_i))
        wfi_sleep_q <= 1'b0;
    end
  end

`ifndef SYNTHESIS
  property p_interrupt_only_at_boundary;
    @(posedge clk_i) disable iff (!rst_ni)
      csr_trap_valid_o && csr_trap_is_interrupt_o |-> rob_empty_i;
  endproperty
  assert property (p_interrupt_only_at_boundary);

  property p_sync_exception_priority;
    @(posedge clk_i) disable iff (!rst_ni)
      rob_trap_valid_i && !redirect_pending_q |->
        csr_trap_valid_o && !csr_trap_is_interrupt_o;
  endproperty
  assert property (p_sync_exception_priority);

  property p_pending_redirect_blocks_trap;
    @(posedge clk_i) disable iff (!rst_ni)
      redirect_pending_q |-> !csr_trap_valid_o;
  endproperty
  assert property (p_pending_redirect_blocks_trap);

  property p_interrupt_payload_is_precise;
    @(posedge clk_i) disable iff (!rst_ni)
      csr_trap_valid_o && csr_trap_is_interrupt_o |->
        !rob_trap_valid_i &&
        (csr_trap_pc_o == architectural_next_pc_q) &&
        (csr_trap_next_pc_o == architectural_next_pc_q) &&
        (csr_trap_tval_o == '0);
  endproperty
  assert property (p_interrupt_payload_is_precise);

  property p_exception_payload_is_preserved;
    @(posedge clk_i) disable iff (!rst_ni)
      rob_trap_valid_i && !redirect_pending_q |->
        (csr_trap_pc_o == rob_trap_pc_i) &&
        (csr_trap_cause_o == 6'(rob_trap_cause_i)) &&
        (csr_trap_tval_o == rob_trap_tval_i);
  endproperty
  assert property (p_exception_payload_is_preserved);

  property p_trap_redirects_to_csr_vector;
    @(posedge clk_i) disable iff (!rst_ni)
      csr_trap_valid_o |->
        architectural_redirect_valid_o &&
        (architectural_redirect_pc_o == csr_trap_vector_i);
  endproperty
  assert property (p_trap_redirects_to_csr_vector);
`endif

endmodule
