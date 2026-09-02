module rv_d_fabric #(
  parameter logic [31:0] DTIM_BASE_ADDR  = rv_soc_pkg::DTIM_BASE_ADDR,
  parameter int unsigned DTIM_SIZE_KB    = rv_soc_pkg::DTIM_SIZE_KB,
  parameter logic [31:0] CLINT_BASE_ADDR = rv_soc_pkg::CLINT_BASE_ADDR,
  parameter int unsigned CLINT_SIZE_KB   = rv_soc_pkg::CLINT_SIZE_KB,
  parameter int unsigned CLOCK_HZ        = 100_000_000,
  parameter int unsigned TIMEBASE_HZ     = rv_soc_pkg::TIMEBASE_HZ,
  parameter int unsigned ROB_SEQ_WIDTH   = rv_ooo_pkg::ROB_SEQ_WIDTH,
  parameter int unsigned CORE_MAX_GRANTS = 8,
  localparam longint unsigned DTIM_SIZE_BYTES = DTIM_SIZE_KB * 1024,
  localparam int unsigned DTIM_BANK_ROWS = DTIM_SIZE_BYTES / 16,
  localparam int unsigned ROW_WIDTH = $clog2(DTIM_BANK_ROWS)
) (
  input  logic                   clk_i,
  input  logic                   rst_ni,
  rv_local_mem_if.target         lsu0_bus,
  rv_local_mem_if.target         lsu1_bus,
  rv_local_mem_if.target         xbar_in_bus,
  rv_local_mem_if.requester      outbound_bus,
  output logic                   msip_o,
  output logic                   mtip_o,
  output logic [63:0]            mtime_o
);

  import rv_soc_pkg::*;

  localparam int unsigned MASTER_COUNT = 3;
  localparam logic [1:0] MASTER_LSU0 = 2'd0;
  localparam logic [1:0] MASTER_LSU1 = 2'd1;
  localparam logic [1:0] MASTER_XBAR = 2'd2;
  localparam int unsigned STREAK_WIDTH =
    (CORE_MAX_GRANTS < 2) ? 1 : $clog2(CORE_MAX_GRANTS + 1);

  typedef enum logic [2:0] {
    RSP_SOURCE_NONE,
    RSP_SOURCE_BANK0,
    RSP_SOURCE_BANK1,
    RSP_SOURCE_CLINT,
    RSP_SOURCE_OUTBOUND,
    RSP_SOURCE_ERROR
  } rsp_source_e;

  logic [MASTER_COUNT-1:0] req_valid;
  logic [MASTER_COUNT-1:0] req_ready;
  logic [MASTER_COUNT-1:0][5:0] req_id;
  logic [MASTER_COUNT-1:0][31:0] req_addr;
  logic [MASTER_COUNT-1:0] req_write;
  logic [MASTER_COUNT-1:0][2:0] req_size;
  logic [MASTER_COUNT-1:0][63:0] req_wdata;
  logic [MASTER_COUNT-1:0][7:0] req_wstrb;
  privilege_e [MASTER_COUNT-1:0] req_priv;
  logic [MASTER_COUNT-1:0][ROB_SEQ_WIDTH-1:0] req_rob_seq;
  logic [MASTER_COUNT-1:0] req_committed;
  logic [MASTER_COUNT-1:0] req_device;

  logic [MASTER_COUNT-1:0] rsp_valid;
  logic [MASTER_COUNT-1:0] rsp_ready;
  logic [MASTER_COUNT-1:0][5:0] rsp_id;
  logic [MASTER_COUNT-1:0][63:0] rsp_rdata;
  axi_resp_e [MASTER_COUNT-1:0] rsp_resp;
  mem_replay_reason_e [MASTER_COUNT-1:0] rsp_replay;

  logic [MASTER_COUNT-1:0] busy_q;
  rsp_source_e [MASTER_COUNT-1:0] source_q;
  logic [MASTER_COUNT-1:0][5:0] accepted_id_q;

  logic [MASTER_COUNT-1:0] dtim_hit;
  logic [MASTER_COUNT-1:0] clint_hit;
  logic [MASTER_COUNT-1:0] bad_dtim_access;
  logic [MASTER_COUNT-1:0] forbidden_write;
  logic [MASTER_COUNT-1:0] request_active;
  logic [MASTER_COUNT-1:0] outbound_candidate;
  logic [MASTER_COUNT-1:0] clint_candidate;
  logic [MASTER_COUNT-1:0] error_candidate;
  logic [MASTER_COUNT-1:0][31:0] dtim_offset;
  logic [1:0][MASTER_COUNT-1:0] bank_read_candidate;
  logic [1:0][MASTER_COUNT-1:0] bank_write_candidate;

  logic [1:0] bank_read_en;
  logic [1:0][ROW_WIDTH-1:0] bank_read_row;
  logic [1:0] bank_read_valid;
  logic [1:0][63:0] bank_read_data;
  logic [1:0] bank_write_en;
  logic [1:0][ROW_WIDTH-1:0] bank_write_row;
  logic [1:0][63:0] bank_write_data;
  logic [1:0][7:0] bank_write_strb;
  logic [1:0][1:0] bank_read_owner;
  logic [1:0][1:0] bank_write_owner;
  logic [1:0] bank_read_grant;
  logic [1:0] bank_write_grant;
  logic [1:0][1:0] bank_read_owner_q;
  logic [1:0][1:0] bank_write_owner_q;
  logic [1:0] bank_write_ack_q;
  logic [1:0][STREAK_WIDTH-1:0] read_core_streak_q;
  logic [1:0][STREAK_WIDTH-1:0] write_core_streak_q;

  logic clint_grant;
  logic [1:0] clint_selected;
  logic [1:0] clint_owner_q;
  logic [1:0] clint_rr_q;
  logic outbound_grant;
  logic [1:0] outbound_selected;
  logic [1:0] outbound_owner_q;

  logic [MASTER_COUNT-1:0] error_accept;
  logic [MASTER_COUNT-1:0] error_valid_q;
  logic [MASTER_COUNT-1:0] pulse_valid;
  logic [MASTER_COUNT-1:0][63:0] pulse_data;
  axi_resp_e [MASTER_COUNT-1:0] pulse_resp;
  mem_replay_reason_e [MASTER_COUNT-1:0] pulse_replay;

  logic [MASTER_COUNT-1:0] rsp_buffer_valid_q;
  logic [MASTER_COUNT-1:0][5:0] rsp_buffer_id_q;
  logic [MASTER_COUNT-1:0][63:0] rsp_buffer_data_q;
  axi_resp_e [MASTER_COUNT-1:0] rsp_buffer_resp_q;
  mem_replay_reason_e [MASTER_COUNT-1:0] rsp_buffer_replay_q;
  logic [MASTER_COUNT-1:0] response_fire;
  logic [MASTER_COUNT-1:0] request_accept;

  rv_local_mem_if #(
    .ADDR_WIDTH    (32),
    .DATA_WIDTH    (64),
    .ID_WIDTH      (6),
    .ROB_SEQ_WIDTH (ROB_SEQ_WIDTH)
  ) clint_bus (
    .clk_i,
    .rst_ni
  );

  function automatic logic seq_before(
    input logic [ROB_SEQ_WIDTH-1:0] lhs,
    input logic [ROB_SEQ_WIDTH-1:0] rhs
  );
    logic signed [ROB_SEQ_WIDTH-1:0] difference;
    difference = $signed(lhs - rhs);
    return difference < 0;
  endfunction

  function automatic logic access_is_aligned(
    input logic [31:0] address,
    input logic [2:0] size
  );
    logic [31:0] byte_mask;
    if (size > 3)
      return 1'b0;
    byte_mask = (32'h1 << size) - 1'b1;
    return (address & byte_mask) == 0;
  endfunction

  // Convert the three interface instances into arrays for common arbitration.
  always_comb begin
    req_valid[0]     = lsu0_bus.req_valid;
    req_id[0]        = lsu0_bus.req_id;
    req_addr[0]      = lsu0_bus.req_addr;
    req_write[0]     = lsu0_bus.req_write;
    req_size[0]      = lsu0_bus.req_size;
    req_wdata[0]     = lsu0_bus.req_wdata;
    req_wstrb[0]     = lsu0_bus.req_wstrb;
    req_priv[0]      = lsu0_bus.req_priv;
    req_rob_seq[0]   = lsu0_bus.req_rob_seq;
    req_committed[0] = lsu0_bus.req_committed;
    req_device[0]    = lsu0_bus.req_device;
    rsp_ready[0]     = lsu0_bus.rsp_ready;

    req_valid[1]     = lsu1_bus.req_valid;
    req_id[1]        = lsu1_bus.req_id;
    req_addr[1]      = lsu1_bus.req_addr;
    req_write[1]     = lsu1_bus.req_write;
    req_size[1]      = lsu1_bus.req_size;
    req_wdata[1]     = lsu1_bus.req_wdata;
    req_wstrb[1]     = lsu1_bus.req_wstrb;
    req_priv[1]      = lsu1_bus.req_priv;
    req_rob_seq[1]   = lsu1_bus.req_rob_seq;
    req_committed[1] = lsu1_bus.req_committed;
    req_device[1]    = lsu1_bus.req_device;
    rsp_ready[1]     = lsu1_bus.rsp_ready;

    req_valid[2]     = xbar_in_bus.req_valid;
    req_id[2]        = xbar_in_bus.req_id;
    req_addr[2]      = xbar_in_bus.req_addr;
    req_write[2]     = xbar_in_bus.req_write;
    req_size[2]      = xbar_in_bus.req_size;
    req_wdata[2]     = xbar_in_bus.req_wdata;
    req_wstrb[2]     = xbar_in_bus.req_wstrb;
    req_priv[2]      = xbar_in_bus.req_priv;
    req_rob_seq[2]   = xbar_in_bus.req_rob_seq;
    req_committed[2] = xbar_in_bus.req_committed;
    req_device[2]    = xbar_in_bus.req_device;
    rsp_ready[2]     = xbar_in_bus.rsp_ready;
  end

  assign response_fire = rsp_valid & rsp_ready;
  assign request_accept = req_valid & req_ready;

  always_comb begin
    lsu0_bus.req_ready   = req_ready[0];
    lsu0_bus.rsp_valid   = rsp_valid[0];
    lsu0_bus.rsp_id      = rsp_id[0];
    lsu0_bus.rsp_rdata   = rsp_rdata[0];
    lsu0_bus.rsp_resp    = rsp_resp[0];
    lsu0_bus.rsp_replay  = rsp_replay[0];

    lsu1_bus.req_ready   = req_ready[1];
    lsu1_bus.rsp_valid   = rsp_valid[1];
    lsu1_bus.rsp_id      = rsp_id[1];
    lsu1_bus.rsp_rdata   = rsp_rdata[1];
    lsu1_bus.rsp_resp    = rsp_resp[1];
    lsu1_bus.rsp_replay  = rsp_replay[1];

    xbar_in_bus.req_ready  = req_ready[2];
    xbar_in_bus.rsp_valid  = rsp_valid[2];
    xbar_in_bus.rsp_id     = rsp_id[2];
    xbar_in_bus.rsp_rdata  = rsp_rdata[2];
    xbar_in_bus.rsp_resp   = rsp_resp[2];
    xbar_in_bus.rsp_replay = rsp_replay[2];
  end

  // Decode and form bank/CLINT/outbound/error candidates. Xbar inbound is
  // never allowed to loop back to the outbound port.
  always_comb begin
    for (int unsigned master = 0; master < MASTER_COUNT; master++) begin
      // A consumed response releases the requester's single outstanding slot
      // combinationally.  This permits a response/next-request handoff on the
      // same edge without increasing the number of in-flight transactions.
      // The old response continues to use accepted_id_q/source_q while the new
      // request metadata is installed only at the edge.
      request_active[master] = req_valid[master] &&
                               (!busy_q[master] || response_fire[master]);
      dtim_hit[master] = addr_in_region(req_addr[master], DTIM_BASE_ADDR,
                                        size_kb_to_bytes(DTIM_SIZE_KB));
      dtim_offset[master] = req_addr[master] - DTIM_BASE_ADDR;
      clint_hit[master] = addr_in_region(req_addr[master], CLINT_BASE_ADDR,
                                         size_kb_to_bytes(CLINT_SIZE_KB));
      bad_dtim_access[master] = dtim_hit[master] &&
                                !access_is_aligned(req_addr[master],
                                                   req_size[master]);
      forbidden_write[master] = req_write[master] &&
                                 !req_committed[master];
      outbound_candidate[master] = 1'b0;
      clint_candidate[master]    = 1'b0;
      error_candidate[master]    = 1'b0;
      for (int unsigned bank = 0; bank < 2; bank++) begin
        bank_read_candidate[bank][master]  = 1'b0;
        bank_write_candidate[bank][master] = 1'b0;
      end

      if (request_active[master]) begin
        if (forbidden_write[master] || bad_dtim_access[master]) begin
          error_candidate[master] = 1'b1;
        end else if (dtim_hit[master]) begin
          if (req_write[master])
            bank_write_candidate[dtim_offset[master][3]]
                                [master] = 1'b1;
          else
            bank_read_candidate[dtim_offset[master][3]]
                               [master] = 1'b1;
        end else if (clint_hit[master]) begin
          clint_candidate[master] = 1'b1;
        end else if (master != MASTER_XBAR) begin
          outbound_candidate[master] = 1'b1;
        end else begin
          error_candidate[master] = 1'b1;
        end
      end
    end
  end

  // DTIM arbitration. LSU0/1 use modulo sequence age; an inbound requester
  // waiting behind core traffic is forced after CORE_MAX_GRANTS grants.
  always_comb begin
    bank_read_grant  = '0;
    bank_write_grant = '0;
    bank_read_owner  = '0;
    bank_write_owner = '0;

    for (int unsigned bank = 0; bank < 2; bank++) begin
      if (bank_read_candidate[bank][2] &&
          (read_core_streak_q[bank] >= CORE_MAX_GRANTS)) begin
        bank_read_grant[bank] = 1'b1;
        bank_read_owner[bank] = MASTER_XBAR;
      end else if (bank_read_candidate[bank][0] &&
                   bank_read_candidate[bank][1]) begin
        bank_read_grant[bank] = 1'b1;
        bank_read_owner[bank] = seq_before(req_rob_seq[0], req_rob_seq[1]) ?
                                MASTER_LSU0 : MASTER_LSU1;
      end else if (bank_read_candidate[bank][0]) begin
        bank_read_grant[bank] = 1'b1;
        bank_read_owner[bank] = MASTER_LSU0;
      end else if (bank_read_candidate[bank][1]) begin
        bank_read_grant[bank] = 1'b1;
        bank_read_owner[bank] = MASTER_LSU1;
      end else if (bank_read_candidate[bank][2]) begin
        bank_read_grant[bank] = 1'b1;
        bank_read_owner[bank] = MASTER_XBAR;
      end

      if (bank_write_candidate[bank][2] &&
          (write_core_streak_q[bank] >= CORE_MAX_GRANTS)) begin
        bank_write_grant[bank] = 1'b1;
        bank_write_owner[bank] = MASTER_XBAR;
      end else if (bank_write_candidate[bank][0] &&
                   bank_write_candidate[bank][1]) begin
        bank_write_grant[bank] = 1'b1;
        bank_write_owner[bank] = seq_before(req_rob_seq[0], req_rob_seq[1]) ?
                                 MASTER_LSU0 : MASTER_LSU1;
      end else if (bank_write_candidate[bank][0]) begin
        bank_write_grant[bank] = 1'b1;
        bank_write_owner[bank] = MASTER_LSU0;
      end else if (bank_write_candidate[bank][1]) begin
        bank_write_grant[bank] = 1'b1;
        bank_write_owner[bank] = MASTER_LSU1;
      end else if (bank_write_candidate[bank][2]) begin
        bank_write_grant[bank] = 1'b1;
        bank_write_owner[bank] = MASTER_XBAR;
      end
    end
  end

  // Single-request CLINT and outbound selection.
  always_comb begin
    clint_grant    = 1'b0;
    clint_selected = MASTER_LSU0;
    case (clint_rr_q)
      2'd0: begin
        if (clint_candidate[0]) begin clint_grant = 1'b1; clint_selected = 0; end
        else if (clint_candidate[1]) begin clint_grant = 1'b1; clint_selected = 1; end
        else if (clint_candidate[2]) begin clint_grant = 1'b1; clint_selected = 2; end
      end
      2'd1: begin
        if (clint_candidate[1]) begin clint_grant = 1'b1; clint_selected = 1; end
        else if (clint_candidate[2]) begin clint_grant = 1'b1; clint_selected = 2; end
        else if (clint_candidate[0]) begin clint_grant = 1'b1; clint_selected = 0; end
      end
      default: begin
        if (clint_candidate[2]) begin clint_grant = 1'b1; clint_selected = 2; end
        else if (clint_candidate[0]) begin clint_grant = 1'b1; clint_selected = 0; end
        else if (clint_candidate[1]) begin clint_grant = 1'b1; clint_selected = 1; end
      end
    endcase

    outbound_grant    = 1'b0;
    outbound_selected = MASTER_LSU0;
    if (outbound_candidate[0] && outbound_candidate[1]) begin
      outbound_grant = 1'b1;
      outbound_selected = seq_before(req_rob_seq[0], req_rob_seq[1]) ?
                          MASTER_LSU0 : MASTER_LSU1;
    end else if (outbound_candidate[0]) begin
      outbound_grant = 1'b1;
      outbound_selected = MASTER_LSU0;
    end else if (outbound_candidate[1]) begin
      outbound_grant = 1'b1;
      outbound_selected = MASTER_LSU1;
    end
  end

  // Drive target requests and requester ready. SRAM write acknowledgements and
  // error responses are generated one cycle after acceptance.
  always_comb begin
    req_ready       = '0;
    bank_read_en    = bank_read_grant;
    bank_write_en   = bank_write_grant;
    bank_read_row   = '0;
    bank_write_row  = '0;
    bank_write_data = '0;
    bank_write_strb = '0;
    error_accept    = '0;

    for (int unsigned bank = 0; bank < 2; bank++) begin
      if (bank_read_grant[bank]) begin
        bank_read_row[bank] =
          dtim_offset[bank_read_owner[bank]][ROW_WIDTH+3:4];
        req_ready[bank_read_owner[bank]] = 1'b1;
      end
      if (bank_write_grant[bank]) begin
        bank_write_row[bank] =
          dtim_offset[bank_write_owner[bank]][ROW_WIDTH+3:4];
        bank_write_data[bank] = req_wdata[bank_write_owner[bank]];
        bank_write_strb[bank] = req_wstrb[bank_write_owner[bank]];
        req_ready[bank_write_owner[bank]] = 1'b1;
      end
    end

    clint_bus.req_valid     = clint_grant;
    clint_bus.req_id        = req_id[clint_selected];
    clint_bus.req_addr      = req_addr[clint_selected];
    clint_bus.req_write     = req_write[clint_selected];
    clint_bus.req_size      = req_size[clint_selected];
    clint_bus.req_wdata     = req_wdata[clint_selected];
    clint_bus.req_wstrb     = req_wstrb[clint_selected];
    clint_bus.req_priv      = req_priv[clint_selected];
    clint_bus.req_rob_seq   = req_rob_seq[clint_selected];
    clint_bus.req_committed = req_committed[clint_selected];
    clint_bus.req_device    = 1'b1;
    if (clint_grant)
      req_ready[clint_selected] = clint_bus.req_ready;

    outbound_bus.req_valid     = outbound_grant;
    outbound_bus.req_id        = req_id[outbound_selected];
    outbound_bus.req_addr      = req_addr[outbound_selected];
    outbound_bus.req_write     = req_write[outbound_selected];
    outbound_bus.req_size      = req_size[outbound_selected];
    outbound_bus.req_wdata     = req_wdata[outbound_selected];
    outbound_bus.req_wstrb     = req_wstrb[outbound_selected];
    outbound_bus.req_priv      = req_priv[outbound_selected];
    outbound_bus.req_rob_seq   = req_rob_seq[outbound_selected];
    outbound_bus.req_committed = req_committed[outbound_selected];
    outbound_bus.req_device    = req_device[outbound_selected];
    if (outbound_grant)
      req_ready[outbound_selected] = outbound_bus.req_ready;

    for (int unsigned master = 0; master < MASTER_COUNT; master++) begin
      if (error_candidate[master]) begin
        req_ready[master]    = 1'b1;
        error_accept[master] = req_valid[master];
      end
    end
  end

  rv_tim_2bank #(
    .SIZE_KB    (DTIM_SIZE_KB),
    .DATA_WIDTH (64)
  ) u_dtim (
    .clk_i,
    .rst_ni,
    .read_en_i     (bank_read_en),
    .read_row_i    (bank_read_row),
    .read_valid_o  (bank_read_valid),
    .read_data_o   (bank_read_data),
    .write_en_i    (bank_write_en),
    .write_row_i   (bank_write_row),
    .write_data_i  (bank_write_data),
    .write_strb_i  (bank_write_strb)
  );

  rv_clint #(
    .BASE_ADDR   (CLINT_BASE_ADDR),
    .SIZE_KB     (CLINT_SIZE_KB),
    .CLOCK_HZ    (CLOCK_HZ),
    .TIMEBASE_HZ (TIMEBASE_HZ)
  ) u_clint (
    .clk_i,
    .rst_ni,
    .bus     (clint_bus),
    .msip_o,
    .mtip_o,
    .mtime_o
  );

  // Pulse responses from synchronous SRAM reads, write acknowledgements, and
  // locally rejected requests. A one-entry skid buffer per requester preserves
  // the response if that requester deasserts ready on the pulse cycle.
  always_comb begin
    pulse_valid  = error_valid_q;
    pulse_data   = '0;
    pulse_resp   = '{default: AXI_RESP_SLVERR};
    pulse_replay = '{default: MEM_REPLAY_NONE};

    for (int unsigned bank = 0; bank < 2; bank++) begin
      if (bank_read_valid[bank]) begin
        pulse_valid[bank_read_owner_q[bank]] = 1'b1;
        pulse_data[bank_read_owner_q[bank]]  = bank_read_data[bank];
        pulse_resp[bank_read_owner_q[bank]]  = AXI_RESP_OKAY;
      end
      if (bank_write_ack_q[bank]) begin
        pulse_valid[bank_write_owner_q[bank]] = 1'b1;
        pulse_data[bank_write_owner_q[bank]]  = '0;
        pulse_resp[bank_write_owner_q[bank]]  = AXI_RESP_OKAY;
      end
    end
  end

  always_comb begin
    rsp_valid  = '0;
    rsp_id     = accepted_id_q;
    rsp_rdata  = '0;
    rsp_resp   = '{default: AXI_RESP_OKAY};
    rsp_replay = '{default: MEM_REPLAY_NONE};
    clint_bus.rsp_ready   = 1'b0;
    outbound_bus.rsp_ready = 1'b0;

    for (int unsigned master = 0; master < MASTER_COUNT; master++) begin
      if (rsp_buffer_valid_q[master]) begin
        rsp_valid[master]  = 1'b1;
        rsp_id[master]     = rsp_buffer_id_q[master];
        rsp_rdata[master]  = rsp_buffer_data_q[master];
        rsp_resp[master]   = rsp_buffer_resp_q[master];
        rsp_replay[master] = rsp_buffer_replay_q[master];
      end else if (pulse_valid[master]) begin
        rsp_valid[master]  = 1'b1;
        rsp_id[master]     = accepted_id_q[master];
        rsp_rdata[master]  = pulse_data[master];
        rsp_resp[master]   = pulse_resp[master];
        rsp_replay[master] = pulse_replay[master];
      end else if ((source_q[master] == RSP_SOURCE_CLINT) &&
                   (clint_owner_q == master)) begin
        rsp_valid[master]  = clint_bus.rsp_valid;
        rsp_id[master]     = clint_bus.rsp_id;
        rsp_rdata[master]  = clint_bus.rsp_rdata;
        rsp_resp[master]   = clint_bus.rsp_resp;
        rsp_replay[master] = clint_bus.rsp_replay;
        clint_bus.rsp_ready = rsp_ready[master];
      end else if ((source_q[master] == RSP_SOURCE_OUTBOUND) &&
                   (outbound_owner_q == master)) begin
        rsp_valid[master]  = outbound_bus.rsp_valid;
        rsp_id[master]     = outbound_bus.rsp_id;
        rsp_rdata[master]  = outbound_bus.rsp_rdata;
        rsp_resp[master]   = outbound_bus.rsp_resp;
        rsp_replay[master] = outbound_bus.rsp_replay;
        outbound_bus.rsp_ready = rsp_ready[master];
      end
    end
  end

  always_ff @(posedge clk_i) begin
    if (!rst_ni) begin
      busy_q               <= '0;
      source_q             <= '{default: RSP_SOURCE_NONE};
      accepted_id_q        <= '0;
      bank_read_owner_q    <= '0;
      bank_write_owner_q   <= '0;
      bank_write_ack_q     <= '0;
      read_core_streak_q   <= '0;
      write_core_streak_q  <= '0;
      clint_owner_q        <= '0;
      clint_rr_q           <= '0;
      outbound_owner_q     <= '0;
      error_valid_q        <= '0;
      rsp_buffer_valid_q   <= '0;
      rsp_buffer_id_q      <= '0;
      rsp_buffer_data_q    <= '0;
      rsp_buffer_resp_q    <= '{default: AXI_RESP_OKAY};
      rsp_buffer_replay_q  <= '{default: MEM_REPLAY_NONE};
    end else begin
      bank_write_ack_q <= '0;
      error_valid_q    <= '0;

      for (int unsigned bank = 0; bank < 2; bank++) begin
        if (bank_read_en[bank]) begin
          bank_read_owner_q[bank] <= bank_read_owner[bank];
          if (bank_read_candidate[bank][2] &&
              (bank_read_owner[bank] != MASTER_XBAR)) begin
            if (read_core_streak_q[bank] < CORE_MAX_GRANTS)
              read_core_streak_q[bank] <= read_core_streak_q[bank] + 1'b1;
          end else begin
            read_core_streak_q[bank] <= '0;
          end
        end
        if (bank_write_en[bank]) begin
          bank_write_owner_q[bank] <= bank_write_owner[bank];
          bank_write_ack_q[bank]   <= 1'b1;
          if (bank_write_candidate[bank][2] &&
              (bank_write_owner[bank] != MASTER_XBAR)) begin
            if (write_core_streak_q[bank] < CORE_MAX_GRANTS)
              write_core_streak_q[bank] <= write_core_streak_q[bank] + 1'b1;
          end else begin
            write_core_streak_q[bank] <= '0;
          end
        end
      end

      if (clint_grant && clint_bus.req_ready) begin
        clint_owner_q <= clint_selected;
        clint_rr_q    <= (clint_selected == 2) ? 0 : clint_selected + 1'b1;
      end
      if (outbound_grant && outbound_bus.req_ready)
        outbound_owner_q <= outbound_selected;

      for (int unsigned master = 0; master < MASTER_COUNT; master++) begin
        if (pulse_valid[master] && !rsp_buffer_valid_q[master]) begin
          if (rsp_ready[master]) begin
            busy_q[master]   <= 1'b0;
            source_q[master] <= RSP_SOURCE_NONE;
          end else begin
            rsp_buffer_valid_q[master]  <= 1'b1;
            rsp_buffer_id_q[master]     <= accepted_id_q[master];
            rsp_buffer_data_q[master]   <= pulse_data[master];
            rsp_buffer_resp_q[master]   <= pulse_resp[master];
            rsp_buffer_replay_q[master] <= pulse_replay[master];
          end
        end

        if (rsp_buffer_valid_q[master] && rsp_ready[master]) begin
          rsp_buffer_valid_q[master] <= 1'b0;
          busy_q[master]             <= 1'b0;
          source_q[master]           <= RSP_SOURCE_NONE;
        end

        if ((source_q[master] == RSP_SOURCE_CLINT) &&
            clint_bus.rsp_valid && clint_bus.rsp_ready) begin
          busy_q[master]   <= 1'b0;
          source_q[master] <= RSP_SOURCE_NONE;
        end
        if ((source_q[master] == RSP_SOURCE_OUTBOUND) &&
            outbound_bus.rsp_valid && outbound_bus.rsp_ready) begin
          busy_q[master]   <= 1'b0;
          source_q[master] <= RSP_SOURCE_NONE;
        end

        // Install a newly accepted request after response retirement so a
        // same-cycle handoff leaves the requester busy with the new request,
        // rather than letting the old response's clear win the NBA ordering.
        if (request_accept[master]) begin
          busy_q[master]        <= 1'b1;
          accepted_id_q[master] <= req_id[master];
          if (error_accept[master]) begin
            source_q[master]      <= RSP_SOURCE_ERROR;
            error_valid_q[master] <= 1'b1;
          end else if (dtim_hit[master]) begin
            source_q[master] <= dtim_offset[master][3] ?
                                RSP_SOURCE_BANK1 : RSP_SOURCE_BANK0;
          end else if (clint_hit[master]) begin
            source_q[master] <= RSP_SOURCE_CLINT;
          end else begin
            source_q[master] <= RSP_SOURCE_OUTBOUND;
          end
        end
      end
    end
  end

`ifndef SYNTHESIS
  for (genvar master = 0; master < MASTER_COUNT; master++) begin : g_write_assert
    property p_no_uncommitted_write_accept;
      @(posedge clk_i) disable iff (!rst_ni)
        req_valid[master] && req_ready[master] && req_write[master]
        |-> req_committed[master];
    endproperty
    assert property (p_no_uncommitted_write_accept);

    property p_busy_accept_requires_response_handoff;
      @(posedge clk_i) disable iff (!rst_ni)
        busy_q[master] && request_accept[master]
        |-> response_fire[master];
    endproperty
    assert property (p_busy_accept_requires_response_handoff);

    property p_handoff_retains_new_request_busy;
      @(posedge clk_i) disable iff (!rst_ni)
        response_fire[master] && request_accept[master]
        |=> busy_q[master];
    endproperty
    assert property (p_handoff_retains_new_request_busy);
  end

  property p_xbar_inbound_never_loops_outbound;
    @(posedge clk_i) disable iff (!rst_ni)
      xbar_in_bus.req_valid && xbar_in_bus.req_ready
      |-> !outbound_candidate[2];
  endproperty
  assert property (p_xbar_inbound_never_loops_outbound);

  property p_bank0_read_has_selected_candidate;
    @(posedge clk_i) disable iff (!rst_ni)
      bank_read_en[0] |-> bank_read_candidate[0][bank_read_owner[0]];
  endproperty
  assert property (p_bank0_read_has_selected_candidate);

  property p_bank1_read_has_selected_candidate;
    @(posedge clk_i) disable iff (!rst_ni)
      bank_read_en[1] |-> bank_read_candidate[1][bank_read_owner[1]];
  endproperty
  assert property (p_bank1_read_has_selected_candidate);

  for (genvar bank = 0; bank < 2; bank++) begin : g_fairness_assert
    property p_waiting_inbound_read_is_forced;
      @(posedge clk_i) disable iff (!rst_ni)
        bank_read_candidate[bank][2] &&
        (read_core_streak_q[bank] >= CORE_MAX_GRANTS)
        |-> bank_read_en[bank] &&
            (bank_read_owner[bank] == MASTER_XBAR);
    endproperty
    assert property (p_waiting_inbound_read_is_forced);

    property p_waiting_inbound_write_is_forced;
      @(posedge clk_i) disable iff (!rst_ni)
        bank_write_candidate[bank][2] &&
        (write_core_streak_q[bank] >= CORE_MAX_GRANTS)
        |-> bank_write_en[bank] &&
            (bank_write_owner[bank] == MASTER_XBAR);
    endproperty
    assert property (p_waiting_inbound_write_is_forced);
  end

  property p_different_bank_reads_can_progress_together;
    @(posedge clk_i) disable iff (!rst_ni)
      bank_read_candidate[0][0] && bank_read_candidate[1][1]
      |-> bank_read_en[0] && bank_read_en[1];
  endproperty
  assert property (p_different_bank_reads_can_progress_together);
`endif

  initial begin : p_parameter_checks
    if ((DTIM_SIZE_KB == 0) || ((DTIM_SIZE_BYTES % 16) != 0))
      $fatal(1, "DTIM must split evenly into two 64-bit banks");
    if (ROB_SEQ_WIDTH < 2)
      $fatal(1, "ROB sequence width is too small for modulo age comparison");
    if (CORE_MAX_GRANTS == 0)
      $fatal(1, "CORE_MAX_GRANTS must be nonzero");
  end

endmodule
