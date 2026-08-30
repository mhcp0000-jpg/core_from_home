module rv_i_fabric #(
  parameter logic [31:0] ITIM_BASE_ADDR = rv_soc_pkg::ITIM_BASE_ADDR,
  parameter int unsigned ITIM_SIZE_KB   = rv_soc_pkg::ITIM_SIZE_KB,
  parameter int unsigned CORE_MAX_GRANTS = 8,
  localparam longint unsigned ITIM_SIZE_BYTES = ITIM_SIZE_KB * 1024,
  localparam int unsigned ITIM_BANK_ROWS = ITIM_SIZE_BYTES / 16,
  localparam int unsigned ROW_WIDTH = $clog2(ITIM_BANK_ROWS)
) (
  input  logic                   clk_i,
  input  logic                   rst_ni,

  input  logic                   if_req_valid_i,
  output logic                   if_req_ready_o,
  input  logic [31:0]            if_req_addr_i,
  input  logic [3:0]             if_req_id_i,
  input  logic [3:0]             if_req_epoch_i,
  output logic                   if_rsp_valid_o,
  input  logic                   if_rsp_ready_i,
  output logic [3:0]             if_rsp_id_o,
  output logic [3:0]             if_rsp_epoch_o,
  output logic [127:0]           if_rsp_data_o,
  output logic [1:0]             if_rsp_resp_o,

  rv_local_mem_if.target         xbar_in_bus,
  rv_local_mem_if.requester      outbound_bus
);

  import rv_soc_pkg::*;

  localparam int unsigned STREAK_WIDTH =
    (CORE_MAX_GRANTS < 2) ? 1 : $clog2(CORE_MAX_GRANTS + 1);

  typedef enum logic [2:0] {
    OUT_IDLE,
    OUT_REQ_LO,
    OUT_WAIT_LO,
    OUT_REQ_HI,
    OUT_WAIT_HI
  } outbound_state_e;

  logic [1:0] bank_read_en;
  logic [1:0][ROW_WIDTH-1:0] bank_read_row;
  logic [1:0] bank_read_valid;
  logic [1:0][63:0] bank_read_data;
  logic [1:0] bank_write_en;
  logic [1:0][ROW_WIDTH-1:0] bank_write_row;
  logic [1:0][63:0] bank_write_data;
  logic [1:0][7:0] bank_write_strb;

  logic if_busy_q;
  logic [3:0] if_id_q;
  logic [3:0] if_epoch_q;
  logic [31:0] if_addr_q;
  logic if_local_candidate;
  logic [31:0] if_itim_offset;
  logic if_local_accept;
  logic if_nonlocal_accept;
  logic if_error_accept;
  logic local_if_read_pending_q;
  logic if_error_valid_q;
  logic [STREAK_WIDTH-1:0] if_core_streak_q;

  logic if_rsp_buffer_valid_q;
  logic [3:0] if_rsp_buffer_id_q;
  logic [3:0] if_rsp_buffer_epoch_q;
  logic [127:0] if_rsp_buffer_data_q;
  axi_resp_e if_rsp_buffer_resp_q;
  logic local_if_rsp_valid;
  logic [127:0] local_if_rsp_data;

  logic xbar_busy_q;
  logic [5:0] xbar_id_q;
  logic xbar_itim_hit;
  logic [31:0] xbar_itim_offset;
  logic xbar_bad_access;
  logic xbar_request_active;
  logic xbar_read_candidate;
  logic xbar_read_accept;
  logic xbar_write_accept;
  logic xbar_error_accept;
  logic xbar_read_pending_q;
  logic xbar_write_ack_q;
  logic xbar_error_valid_q;
  logic xbar_pulse_valid;
  logic [63:0] xbar_pulse_data;
  axi_resp_e xbar_pulse_resp;
  logic xbar_rsp_buffer_valid_q;
  logic [5:0] xbar_rsp_buffer_id_q;
  logic [63:0] xbar_rsp_buffer_data_q;
  axi_resp_e xbar_rsp_buffer_resp_q;

  outbound_state_e outbound_state_q;
  logic [63:0] outbound_low_data_q;
  axi_resp_e outbound_resp_q;

  function automatic logic local_access_aligned(
    input logic [31:0] address,
    input logic [2:0] size
  );
    logic [31:0] byte_mask;
    if (size > 3)
      return 1'b0;
    byte_mask = (32'h1 << size) - 1'b1;
    return (address & byte_mask) == 0;
  endfunction

  always_comb begin
    if_local_candidate = addr_in_region(if_req_addr_i, ITIM_BASE_ADDR,
                                         size_kb_to_bytes(ITIM_SIZE_KB));
    if_itim_offset = if_req_addr_i - ITIM_BASE_ADDR;
    xbar_itim_hit = addr_in_region(xbar_in_bus.req_addr, ITIM_BASE_ADDR,
                                    size_kb_to_bytes(ITIM_SIZE_KB));
    xbar_itim_offset = xbar_in_bus.req_addr - ITIM_BASE_ADDR;
    xbar_bad_access = !xbar_itim_hit ||
                      !local_access_aligned(xbar_in_bus.req_addr,
                                            xbar_in_bus.req_size) ||
                      (xbar_in_bus.req_write &&
                       !xbar_in_bus.req_committed);
    xbar_request_active = xbar_in_bus.req_valid && !xbar_busy_q;
    xbar_read_candidate = xbar_request_active && !xbar_bad_access &&
                          !xbar_in_bus.req_write;

    if_req_ready_o   = 1'b0;
    if_local_accept  = 1'b0;
    if_nonlocal_accept = 1'b0;
    if_error_accept  = 1'b0;
    xbar_read_accept = 1'b0;
    xbar_write_accept = 1'b0;
    xbar_error_accept = 1'b0;
    xbar_in_bus.req_ready = 1'b0;

    // Inbound writes use the independent bank write port and therefore do not
    // block an IFU read. Inbound read and 128-bit IFU read compete for read ports.
    if (xbar_request_active && xbar_bad_access) begin
      xbar_in_bus.req_ready = 1'b1;
      xbar_error_accept = 1'b1;
    end else if (xbar_request_active && xbar_in_bus.req_write) begin
      xbar_in_bus.req_ready = 1'b1;
      xbar_write_accept = 1'b1;
    end

    if (!if_busy_q && if_req_valid_i) begin
      if (if_req_addr_i[3:0] != 0) begin
        if_req_ready_o  = 1'b1;
        if_error_accept = 1'b1;
      end else if (if_local_candidate) begin
        if (!(xbar_read_candidate &&
                       (if_core_streak_q >= CORE_MAX_GRANTS))) begin
          if_req_ready_o  = 1'b1;
          if_local_accept = 1'b1;
        end
      end else if (outbound_state_q == OUT_IDLE) begin
        if_req_ready_o     = 1'b1;
        if_nonlocal_accept = 1'b1;
      end
    end

    if (xbar_read_candidate && !if_local_accept) begin
      xbar_in_bus.req_ready = 1'b1;
      xbar_read_accept = 1'b1;
    end
  end

  always_comb begin
    bank_read_en    = '0;
    bank_read_row   = '0;
    bank_write_en   = '0;
    bank_write_row  = '0;
    bank_write_data = '0;
    bank_write_strb = '0;

    if (if_local_accept) begin
      bank_read_en      = 2'b11;
      bank_read_row[0]  = if_itim_offset[ROW_WIDTH+3:4];
      bank_read_row[1]  = if_itim_offset[ROW_WIDTH+3:4];
    end else if (xbar_read_accept) begin
      bank_read_en[xbar_itim_offset[3]] = 1'b1;
      bank_read_row[xbar_itim_offset[3]] =
        xbar_itim_offset[ROW_WIDTH+3:4];
    end

    if (xbar_write_accept) begin
      bank_write_en[xbar_itim_offset[3]] = 1'b1;
      bank_write_row[xbar_itim_offset[3]] =
        xbar_itim_offset[ROW_WIDTH+3:4];
      bank_write_data[xbar_itim_offset[3]] =
        xbar_in_bus.req_wdata;
      bank_write_strb[xbar_itim_offset[3]] =
        xbar_in_bus.req_wstrb;
    end
  end

  rv_tim_2bank #(
    .SIZE_KB    (ITIM_SIZE_KB),
    .DATA_WIDTH (64)
  ) u_itim (
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

  assign local_if_rsp_valid = local_if_read_pending_q &&
                              bank_read_valid[0] && bank_read_valid[1];
  assign local_if_rsp_data  = {bank_read_data[1], bank_read_data[0]};

  always_comb begin
    if_rsp_valid_o = 1'b0;
    if_rsp_id_o    = if_id_q;
    if_rsp_epoch_o = if_epoch_q;
    if_rsp_data_o  = '0;
    if_rsp_resp_o  = AXI_RESP_OKAY;

    if (if_rsp_buffer_valid_q) begin
      if_rsp_valid_o = 1'b1;
      if_rsp_id_o    = if_rsp_buffer_id_q;
      if_rsp_epoch_o = if_rsp_buffer_epoch_q;
      if_rsp_data_o  = if_rsp_buffer_data_q;
      if_rsp_resp_o  = if_rsp_buffer_resp_q;
    end else if (local_if_rsp_valid) begin
      if_rsp_valid_o = 1'b1;
      if_rsp_data_o  = local_if_rsp_data;
    end else if (if_error_valid_q) begin
      if_rsp_valid_o = 1'b1;
      if_rsp_resp_o  = AXI_RESP_SLVERR;
    end
  end

  always_comb begin
    outbound_bus.req_valid     = (outbound_state_q == OUT_REQ_LO) ||
                                 (outbound_state_q == OUT_REQ_HI);
    outbound_bus.req_id        = (outbound_state_q == OUT_REQ_HI) ?
                                 6'd1 : 6'd0;
    outbound_bus.req_addr      = if_addr_q +
                                 ((outbound_state_q == OUT_REQ_HI) ? 8 : 0);
    outbound_bus.req_write     = 1'b0;
    outbound_bus.req_size      = 3'd3;
    outbound_bus.req_wdata     = '0;
    outbound_bus.req_wstrb     = '0;
    outbound_bus.req_priv      = PRIV_M;
    outbound_bus.req_rob_seq   = '0;
    outbound_bus.req_committed = 1'b0;
    outbound_bus.req_device    = 1'b0;
    outbound_bus.rsp_ready     = (outbound_state_q == OUT_WAIT_LO) ||
                                 (outbound_state_q == OUT_WAIT_HI);
  end

  always_comb begin
    xbar_pulse_valid = xbar_error_valid_q || xbar_write_ack_q ||
                       (xbar_read_pending_q &&
                        (bank_read_valid[0] || bank_read_valid[1]));
    xbar_pulse_data = '0;
    xbar_pulse_resp = xbar_error_valid_q ? AXI_RESP_SLVERR : AXI_RESP_OKAY;
    if (xbar_read_pending_q) begin
      if (bank_read_valid[0])
        xbar_pulse_data = bank_read_data[0];
      else if (bank_read_valid[1])
        xbar_pulse_data = bank_read_data[1];
    end

    xbar_in_bus.rsp_valid  = 1'b0;
    xbar_in_bus.rsp_id     = xbar_id_q;
    xbar_in_bus.rsp_rdata  = '0;
    xbar_in_bus.rsp_resp   = AXI_RESP_OKAY;
    xbar_in_bus.rsp_replay = MEM_REPLAY_NONE;
    if (xbar_rsp_buffer_valid_q) begin
      xbar_in_bus.rsp_valid = 1'b1;
      xbar_in_bus.rsp_id    = xbar_rsp_buffer_id_q;
      xbar_in_bus.rsp_rdata = xbar_rsp_buffer_data_q;
      xbar_in_bus.rsp_resp  = xbar_rsp_buffer_resp_q;
    end else if (xbar_pulse_valid) begin
      xbar_in_bus.rsp_valid = 1'b1;
      xbar_in_bus.rsp_rdata = xbar_pulse_data;
      xbar_in_bus.rsp_resp  = xbar_pulse_resp;
    end
  end

  always_ff @(posedge clk_i) begin
    if (!rst_ni) begin
      if_busy_q                 <= 1'b0;
      if_id_q                   <= '0;
      if_epoch_q                <= '0;
      if_addr_q                 <= '0;
      local_if_read_pending_q   <= 1'b0;
      if_error_valid_q          <= 1'b0;
      if_core_streak_q          <= '0;
      if_rsp_buffer_valid_q     <= 1'b0;
      if_rsp_buffer_id_q        <= '0;
      if_rsp_buffer_epoch_q     <= '0;
      if_rsp_buffer_data_q      <= '0;
      if_rsp_buffer_resp_q      <= AXI_RESP_OKAY;
      xbar_busy_q               <= 1'b0;
      xbar_id_q                 <= '0;
      xbar_read_pending_q       <= 1'b0;
      xbar_write_ack_q          <= 1'b0;
      xbar_error_valid_q        <= 1'b0;
      xbar_rsp_buffer_valid_q   <= 1'b0;
      xbar_rsp_buffer_id_q      <= '0;
      xbar_rsp_buffer_data_q    <= '0;
      xbar_rsp_buffer_resp_q    <= AXI_RESP_OKAY;
      outbound_state_q          <= OUT_IDLE;
      outbound_low_data_q       <= '0;
      outbound_resp_q           <= AXI_RESP_OKAY;
    end else begin
      local_if_read_pending_q <= if_local_accept;
      if_error_valid_q        <= if_error_accept;
      xbar_read_pending_q     <= xbar_read_accept;
      xbar_write_ack_q        <= xbar_write_accept;
      xbar_error_valid_q      <= xbar_error_accept;

      if (if_req_valid_i && if_req_ready_o) begin
        if_busy_q  <= 1'b1;
        if_id_q    <= if_req_id_i;
        if_epoch_q <= if_req_epoch_i;
        if_addr_q  <= if_req_addr_i;
      end

      if (if_local_accept) begin
        if (xbar_read_candidate) begin
          if (if_core_streak_q < CORE_MAX_GRANTS)
            if_core_streak_q <= if_core_streak_q + 1'b1;
        end else begin
          if_core_streak_q <= '0;
        end
      end else if (xbar_read_accept) begin
        if_core_streak_q <= '0;
      end

      if ((local_if_rsp_valid || if_error_valid_q) &&
          !if_rsp_buffer_valid_q) begin
        if (if_rsp_ready_i) begin
          if_busy_q <= 1'b0;
        end else begin
          if_rsp_buffer_valid_q <= 1'b1;
          if_rsp_buffer_id_q    <= if_id_q;
          if_rsp_buffer_epoch_q <= if_epoch_q;
          if_rsp_buffer_data_q  <= local_if_rsp_valid ? local_if_rsp_data : '0;
          if_rsp_buffer_resp_q  <= local_if_rsp_valid ? AXI_RESP_OKAY :
                                                        AXI_RESP_SLVERR;
        end
      end
      if (if_rsp_buffer_valid_q && if_rsp_ready_i) begin
        if_rsp_buffer_valid_q <= 1'b0;
        if_busy_q             <= 1'b0;
      end

      if (xbar_in_bus.req_valid && xbar_in_bus.req_ready) begin
        xbar_busy_q <= 1'b1;
        xbar_id_q   <= xbar_in_bus.req_id;
      end
      if (xbar_pulse_valid && !xbar_rsp_buffer_valid_q) begin
        if (xbar_in_bus.rsp_ready) begin
          xbar_busy_q <= 1'b0;
        end else begin
          xbar_rsp_buffer_valid_q <= 1'b1;
          xbar_rsp_buffer_id_q    <= xbar_id_q;
          xbar_rsp_buffer_data_q  <= xbar_pulse_data;
          xbar_rsp_buffer_resp_q  <= xbar_pulse_resp;
        end
      end
      if (xbar_rsp_buffer_valid_q && xbar_in_bus.rsp_ready) begin
        xbar_rsp_buffer_valid_q <= 1'b0;
        xbar_busy_q             <= 1'b0;
      end

      case (outbound_state_q)
        OUT_IDLE: begin
          if (if_nonlocal_accept) begin
            outbound_state_q <= OUT_REQ_LO;
            outbound_resp_q  <= AXI_RESP_OKAY;
          end
        end
        OUT_REQ_LO: begin
          if (outbound_bus.req_valid && outbound_bus.req_ready)
            outbound_state_q <= OUT_WAIT_LO;
        end
        OUT_WAIT_LO: begin
          if (outbound_bus.rsp_valid && outbound_bus.rsp_ready) begin
            outbound_low_data_q <= outbound_bus.rsp_rdata;
            if (outbound_bus.rsp_resp != AXI_RESP_OKAY)
              outbound_resp_q <= outbound_bus.rsp_resp;
            outbound_state_q <= OUT_REQ_HI;
          end
        end
        OUT_REQ_HI: begin
          if (outbound_bus.req_valid && outbound_bus.req_ready)
            outbound_state_q <= OUT_WAIT_HI;
        end
        OUT_WAIT_HI: begin
          if (outbound_bus.rsp_valid && outbound_bus.rsp_ready) begin
            if_rsp_buffer_valid_q <= 1'b1;
            if_rsp_buffer_id_q    <= if_id_q;
            if_rsp_buffer_epoch_q <= if_epoch_q;
            if_rsp_buffer_data_q  <= {outbound_bus.rsp_rdata,
                                      outbound_low_data_q};
            if_rsp_buffer_resp_q  <= (outbound_bus.rsp_resp != AXI_RESP_OKAY) ?
                                     outbound_bus.rsp_resp : outbound_resp_q;
            outbound_state_q <= OUT_IDLE;
          end
        end
        default: outbound_state_q <= OUT_IDLE;
      endcase
    end
  end

`ifndef SYNTHESIS
  property p_outbound_never_targets_itim;
    @(posedge clk_i) disable iff (!rst_ni)
      outbound_bus.req_valid |->
      !addr_in_region(outbound_bus.req_addr, ITIM_BASE_ADDR,
                      size_kb_to_bytes(ITIM_SIZE_KB));
  endproperty
  assert property (p_outbound_never_targets_itim);

  property p_local_fetch_is_block_aligned;
    @(posedge clk_i) disable iff (!rst_ni)
      if_local_accept |-> if_req_addr_i[3:0] == 0;
  endproperty
  assert property (p_local_fetch_is_block_aligned);

  property p_local_fetch_uses_both_banks;
    @(posedge clk_i) disable iff (!rst_ni)
      if_local_accept |-> bank_read_en == 2'b11;
  endproperty
  assert property (p_local_fetch_uses_both_banks);

  property p_waiting_inbound_read_is_forced;
    @(posedge clk_i) disable iff (!rst_ni)
      xbar_read_candidate && (if_core_streak_q >= CORE_MAX_GRANTS)
      |-> xbar_read_accept && !if_local_accept;
  endproperty
  assert property (p_waiting_inbound_read_is_forced);
`endif

  initial begin : p_parameter_checks
    if ((ITIM_SIZE_KB == 0) || ((ITIM_SIZE_BYTES % 16) != 0))
      $fatal(1, "ITIM must split evenly into two 64-bit banks");
    if (CORE_MAX_GRANTS == 0)
      $fatal(1, "CORE_MAX_GRANTS must be nonzero");
  end

endmodule
