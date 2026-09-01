module rv_csr_file_tb;
  import rv_ooo_pkg::*;

  logic clk, rst_n;
  logic csr_valid, csr_execute, csr_commit, csr_rs1_zero;
  logic [11:0] csr_addr;
  csr_cmd_e csr_cmd;
  logic [31:0] csr_operand, csr_rdata;
  logic csr_ready, csr_illegal, csr_write_effect;
  logic trap_valid, trap_ready, trap_is_interrupt;
  logic [31:0] trap_pc, trap_tval, trap_next_pc, trap_vector;
  logic [5:0] trap_cause;
  logic mret_valid, mret_commit, mret_ready, mret_illegal;
  logic [31:0] mret_pc;
  logic wfi_valid, wfi_illegal, wfi_wake;
  logic irq_software, irq_timer, irq_external;
  logic [63:0] mtime;
  logic interrupt_pending;
  logic [5:0] interrupt_cause;
  logic [1:0] retire_count;
  logic fflags_accrue_valid;
  logic [4:0] fflags_accrue;
  privilege_e privilege;
  logic [31:0] mstatus, mtvec, mepc;
  logic [2:0] frm;
  logic [4:0] fflags;
  logic [7:0][7:0] pmpcfg;
  logic [7:0][29:0] pmpaddr;

  always #5 clk = ~clk;

  rv_csr_file #(
    .XLEN(32), .HAS_SMODE(1'b0), .PMP_ENTRIES(8),
    .RESET_MTVEC(32'h8000_0000), .HART_ID(32'd3)
  ) u_dut (
    .clk_i(clk), .rst_ni(rst_n),
    .csr_valid_i(csr_valid), .csr_execute_i(csr_execute),
    .csr_commit_i(csr_commit),
    .csr_addr_i(csr_addr), .csr_cmd_i(csr_cmd),
    .csr_operand_i(csr_operand), .csr_rs1_is_zero_i(csr_rs1_zero),
    .csr_ready_o(csr_ready), .csr_rdata_o(csr_rdata),
    .csr_illegal_o(csr_illegal), .csr_write_effect_o(csr_write_effect),
    .trap_valid_i(trap_valid), .trap_ready_o(trap_ready),
    .trap_pc_i(trap_pc), .trap_cause_i(trap_cause),
    .trap_tval_i(trap_tval), .trap_is_interrupt_i(trap_is_interrupt),
    .trap_next_pc_i(trap_next_pc), .trap_vector_o(trap_vector),
    .mret_valid_i(mret_valid), .mret_commit_i(mret_commit),
    .mret_ready_o(mret_ready), .mret_pc_o(mret_pc),
    .mret_illegal_o(mret_illegal), .wfi_valid_i(wfi_valid),
    .wfi_illegal_o(wfi_illegal), .wfi_wake_o(wfi_wake),
    .irq_software_i(irq_software), .irq_timer_i(irq_timer),
    .irq_external_i(irq_external), .mtime_i(mtime),
    .interrupt_pending_o(interrupt_pending),
    .interrupt_cause_o(interrupt_cause), .retire_count_i(retire_count),
    .fflags_accrue_valid_i(fflags_accrue_valid),
    .fflags_accrue_i(fflags_accrue), .flush_all_i(1'b0),
    .privilege_o(privilege),
    .mstatus_o(mstatus), .mtvec_o(mtvec), .mepc_o(mepc),
    .frm_o(frm), .fflags_o(fflags), .pmpcfg_o(pmpcfg),
    .pmpaddr_o(pmpaddr)
  );

  task automatic idle_inputs;
    csr_valid = 1'b0;
    csr_execute = 1'b0;
    csr_commit = 1'b0;
    csr_addr = '0;
    csr_cmd = CSR_CMD_NONE;
    csr_operand = '0;
    csr_rs1_zero = 1'b0;
    trap_valid = 1'b0;
    trap_pc = '0;
    trap_cause = '0;
    trap_tval = '0;
    trap_is_interrupt = 1'b0;
    trap_next_pc = '0;
    mret_valid = 1'b0;
    mret_commit = 1'b0;
    wfi_valid = 1'b0;
    irq_software = 1'b0;
    irq_timer = 1'b0;
    irq_external = 1'b0;
    mtime = 64'h0123_4567_89ab_cdef;
    retire_count = '0;
    fflags_accrue_valid = 1'b0;
    fflags_accrue = '0;
  endtask

  task automatic write_csr(input logic [11:0] address,
                           input logic [31:0] value);
    @(negedge clk);
    csr_valid = 1'b1;
    csr_execute = 1'b1;
    csr_commit = 1'b0;
    csr_addr = address;
    csr_cmd = CSR_CMD_WRITE;
    csr_operand = value;
    csr_rs1_zero = 1'b0;
    #1;
    if (csr_illegal || !csr_write_effect)
      $fatal(1, "legal CSR write rejected: %h", address);
    @(posedge clk);
    @(negedge clk);
    csr_execute = 1'b0;
    csr_commit = 1'b1;
    @(posedge clk);
    @(negedge clk);
    csr_valid = 1'b0;
    csr_commit = 1'b0;
    csr_cmd = CSR_CMD_NONE;
  endtask

  task automatic read_csr(input logic [11:0] address,
                          output logic [31:0] value,
                          output logic illegal);
    csr_valid = 1'b1;
    csr_execute = 1'b0;
    csr_commit = 1'b0;
    csr_addr = address;
    csr_cmd = CSR_CMD_SET;
    csr_operand = '0;
    csr_rs1_zero = 1'b1;
    #1;
    value = csr_rdata;
    illegal = csr_illegal;
    csr_valid = 1'b0;
    csr_execute = 1'b0;
    csr_cmd = CSR_CMD_NONE;
  endtask

  initial begin : p_test
    logic [31:0] value;
    logic illegal;
    clk = 1'b0;
    rst_n = 1'b0;
    idle_inputs();
    repeat (3) @(posedge clk);
    @(negedge clk);
    rst_n = 1'b1;
    #1;
    if ((privilege != PRIV_M) || (mtvec != 32'h8000_0000))
      $fatal(1, "CSR reset privilege/mtvec is wrong");

    // Evaluation without commit must return the old value but not mutate it.
    csr_valid = 1'b1;
    csr_execute = 1'b0;
    csr_addr = 12'h340;
    csr_cmd = CSR_CMD_WRITE;
    csr_operand = 32'hdead_beef;
    #1;
    if ((csr_rdata != 0) || !csr_write_effect)
      $fatal(1, "CSR evaluate result is wrong");
    @(posedge clk);
    @(negedge clk);
    csr_valid = 1'b0;
    csr_execute = 1'b0;
    read_csr(12'h340, value, illegal);
    if (illegal || (value != 0))
      $fatal(1, "CSR changed without commit");
    write_csr(12'h340, 32'hdead_beef);
    read_csr(12'h340, value, illegal);
    if (illegal || (value != 32'hdead_beef))
      $fatal(1, "committed mscratch write was lost");

    // Enable machine software interrupt and global interrupt.
    write_csr(12'h304, 32'h0000_0008);
    write_csr(12'h300, 32'h0000_0008);
    irq_software = 1'b1;
    #1;
    if (!interrupt_pending || !wfi_wake || (interrupt_cause != 6'd3))
      $fatal(1, "MSIP eligibility is wrong");

    // Vectored mtvec selects BASE + 4*cause for an interrupt.
    write_csr(12'h305, 32'h8000_0001);
    trap_valid = 1'b1;
    trap_is_interrupt = 1'b1;
    trap_cause = 6'd3;
    trap_next_pc = 32'h1000_0044;
    #1;
    if (trap_vector != 32'h8000_000c)
      $fatal(1, "vectored trap target is wrong");
    @(posedge clk);
    @(negedge clk);
    trap_valid = 1'b0;
    irq_software = 1'b0;
    if ((mepc != 32'h1000_0044) || mstatus[3])
      $fatal(1, "trap entry state is wrong");
    read_csr(12'h342, value, illegal);
    if (illegal || (value != 32'h8000_0003))
      $fatal(1, "interrupt mcause is wrong: %h", value);

    // Set MPIE and MPP=U, then MRET into U mode.
    write_csr(12'h300, 32'h0000_0080);
    mret_valid = 1'b1;
    mret_commit = 1'b1;
    #1;
    if (mret_illegal || (mret_pc != 32'h1000_0044))
      $fatal(1, "legal MRET evaluation failed");
    @(posedge clk);
    @(negedge clk);
    mret_valid = 1'b0;
    mret_commit = 1'b0;
    if (privilege != PRIV_U)
      $fatal(1, "MRET did not enter U mode");

    csr_valid = 1'b1;
    csr_addr = 12'h300;
    csr_cmd = CSR_CMD_SET;
    csr_rs1_zero = 1'b1;
    #1;
    if (!csr_illegal)
      $fatal(1, "U-mode machine CSR access was accepted");
    csr_valid = 1'b0;
    read_csr(12'hC00, value, illegal);
    if (!illegal)
      $fatal(1, "U-mode cycle read ignored mcounteren");

    // A U-mode synchronous trap returns to M and captures fault PC/tval.
    trap_valid = 1'b1;
    trap_pc = 32'h2000_0002;
    trap_cause = 6'd8;
    trap_tval = 32'h55aa_aa55;
    trap_is_interrupt = 1'b0;
    #1;
    if (trap_vector != 32'h8000_0000)
      $fatal(1, "exception incorrectly used vectored offset");
    @(posedge clk);
    @(negedge clk);
    trap_valid = 1'b0;
    if ((privilege != PRIV_M) || (mepc != 32'h2000_0002))
      $fatal(1, "U-mode trap entry failed");

    // Counter enable is honored after returning to U.
    write_csr(12'h306, 32'h1);
    mret_valid = 1'b1;
    mret_commit = 1'b1;
    @(posedge clk);
    @(negedge clk);
    mret_valid = 1'b0;
    mret_commit = 1'b0;
    read_csr(12'hC00, value, illegal);
    if (illegal)
      $fatal(1, "enabled U-mode cycle read was rejected");

    // User floating-point CSRs remain legal and accrue flags at commit.
    write_csr(12'h003, 32'h0000_0061); // frm=3, fflags=1
    fflags_accrue_valid = 1'b1;
    fflags_accrue = 5'b10100;
    @(posedge clk);
    @(negedge clk);
    fflags_accrue_valid = 1'b0;
    if ((frm != 3) || (fflags != 5'b10101))
      $fatal(1, "FCSR write/accrue semantics are wrong");

    $display("rv_csr_file_tb PASS");
    $finish;
  end
endmodule
