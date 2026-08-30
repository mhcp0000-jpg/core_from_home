module rv_phys_regfile #(
  parameter int unsigned DATA_WIDTH = 32,
  parameter int unsigned PHYS_REGS = 80,
  parameter int unsigned TAG_WIDTH = 7,
  parameter int unsigned READ_PORTS = 4,
  parameter int unsigned WRITE_PORTS = 2,
  parameter int unsigned ALLOC_PORTS = 2,
  parameter int unsigned INITIAL_MAPPED_REGS = 32,
  parameter bit ZERO_REGISTER = 1'b0,
  parameter logic [TAG_WIDTH-1:0] ZERO_TAG = '0
) (
  input  logic                                  clk_i,
  input  logic                                  rst_ni,

  input  logic [READ_PORTS-1:0][TAG_WIDTH-1:0]  read_addr_i,
  output logic [READ_PORTS-1:0][DATA_WIDTH-1:0] read_data_o,
  output logic [READ_PORTS-1:0]                 read_ready_o,

  input  logic [WRITE_PORTS-1:0]                write_valid_i,
  input  logic [WRITE_PORTS-1:0][TAG_WIDTH-1:0] write_addr_i,
  input  logic [WRITE_PORTS-1:0][DATA_WIDTH-1:0] write_data_i,

  input  logic [ALLOC_PORTS-1:0]                allocate_valid_i,
  input  logic [ALLOC_PORTS-1:0][TAG_WIDTH-1:0] allocate_addr_i,

  input  logic [TAG_WIDTH-1:0]                  probe_addr_i,
  output logic                                  probe_ready_o
);

  logic [DATA_WIDTH-1:0] data_q [0:PHYS_REGS-1];
  logic [PHYS_REGS-1:0] ready_q;

  function automatic logic tag_is_allocated_this_cycle(
    input logic [TAG_WIDTH-1:0] tag
  );
    logic allocated;
    allocated = 1'b0;
    for (int unsigned port = 0; port < ALLOC_PORTS; port++)
      allocated |= allocate_valid_i[port] && (allocate_addr_i[port] == tag);
    return allocated;
  endfunction

  always_comb begin
    for (int unsigned read_port = 0;
         read_port < READ_PORTS; read_port++) begin
      read_data_o[read_port]  = data_q[read_addr_i[read_port]];
      read_ready_o[read_port] = ready_q[read_addr_i[read_port]];

      // Higher-numbered write port wins only if the producer arbitration
      // intentionally presents duplicate tags. An assertion rejects that case
      // in the baseline, but deterministic priority avoids X propagation.
      for (int unsigned write_port = 0;
           write_port < WRITE_PORTS; write_port++) begin
        if (write_valid_i[write_port] &&
            (write_addr_i[write_port] == read_addr_i[read_port])) begin
          read_data_o[read_port]  = write_data_i[write_port];
          read_ready_o[read_port] = 1'b1;
        end
      end

      // A tag recycled by rename belongs to a new generation. Allocation wins
      // over a same-cycle stale writeback and therefore keeps it not-ready.
      if (tag_is_allocated_this_cycle(read_addr_i[read_port]))
        read_ready_o[read_port] = 1'b0;

      if (ZERO_REGISTER && (read_addr_i[read_port] == ZERO_TAG)) begin
        read_data_o[read_port]  = '0;
        read_ready_o[read_port] = 1'b1;
      end
    end

    probe_ready_o = ready_q[probe_addr_i];
    for (int unsigned write_port = 0;
         write_port < WRITE_PORTS; write_port++) begin
      if (write_valid_i[write_port] && (write_addr_i[write_port] == probe_addr_i))
        probe_ready_o = 1'b1;
    end
    if (tag_is_allocated_this_cycle(probe_addr_i))
      probe_ready_o = 1'b0;
    if (ZERO_REGISTER && (probe_addr_i == ZERO_TAG))
      probe_ready_o = 1'b1;
  end

  always_ff @(posedge clk_i) begin
    if (!rst_ni) begin
      ready_q <= '0;
      for (int unsigned tag = 0; tag < PHYS_REGS; tag++)
        data_q[tag] <= '0;
      for (int unsigned tag = 0; tag < INITIAL_MAPPED_REGS; tag++)
        ready_q[tag] <= 1'b1;
      if (ZERO_REGISTER) begin
        ready_q[ZERO_TAG] <= 1'b1;
        data_q[ZERO_TAG]  <= '0;
      end
    end else begin
      for (int unsigned write_port = 0;
           write_port < WRITE_PORTS; write_port++) begin
        if (write_valid_i[write_port] &&
            !(ZERO_REGISTER && (write_addr_i[write_port] == ZERO_TAG))) begin
          data_q[write_addr_i[write_port]]  <= write_data_i[write_port];
          ready_q[write_addr_i[write_port]] <= 1'b1;
        end
      end

      // Allocation is later in this block so it has priority over a stale
      // writeback if integration violates generation filtering.
      for (int unsigned alloc_port = 0;
           alloc_port < ALLOC_PORTS; alloc_port++) begin
        if (allocate_valid_i[alloc_port] &&
            !(ZERO_REGISTER && (allocate_addr_i[alloc_port] == ZERO_TAG)))
          ready_q[allocate_addr_i[alloc_port]] <= 1'b0;
      end

      if (ZERO_REGISTER) begin
        ready_q[ZERO_TAG] <= 1'b1;
        data_q[ZERO_TAG]  <= '0;
      end
    end
  end

`ifndef SYNTHESIS
  for (genvar lhs = 0; lhs < WRITE_PORTS; lhs++) begin : g_write_unique_lhs
    for (genvar rhs = lhs + 1; rhs < WRITE_PORTS; rhs++) begin : g_write_unique_rhs
      property p_no_duplicate_write_tag;
        @(posedge clk_i) disable iff (!rst_ni)
          write_valid_i[lhs] && write_valid_i[rhs]
          |-> write_addr_i[lhs] != write_addr_i[rhs];
      endproperty
      assert property (p_no_duplicate_write_tag);
    end
  end

  for (genvar lhs = 0; lhs < ALLOC_PORTS; lhs++) begin : g_alloc_unique_lhs
    for (genvar rhs = lhs + 1; rhs < ALLOC_PORTS; rhs++) begin : g_alloc_unique_rhs
      property p_no_duplicate_allocation_tag;
        @(posedge clk_i) disable iff (!rst_ni)
          allocate_valid_i[lhs] && allocate_valid_i[rhs]
          |-> allocate_addr_i[lhs] != allocate_addr_i[rhs];
      endproperty
      assert property (p_no_duplicate_allocation_tag);
    end
  end
`endif

  initial begin : p_parameter_checks
    if ((DATA_WIDTH == 0) || (PHYS_REGS < INITIAL_MAPPED_REGS))
      $fatal(1, "Physical register file dimensions are invalid");
    if (PHYS_REGS > (1 << TAG_WIDTH))
      $fatal(1, "TAG_WIDTH cannot represent all physical registers");
    if ((READ_PORTS == 0) || (WRITE_PORTS == 0) || (ALLOC_PORTS == 0))
      $fatal(1, "Physical register file port counts must be nonzero");
    if (ZERO_REGISTER && (ZERO_TAG >= PHYS_REGS))
      $fatal(1, "ZERO_TAG lies outside the physical register file");
  end

endmodule
