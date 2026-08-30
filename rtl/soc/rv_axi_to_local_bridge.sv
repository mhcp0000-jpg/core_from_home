module rv_axi_to_local_bridge #(
  parameter int unsigned ADDR_WIDTH       = 32,
  parameter int unsigned DATA_WIDTH       = 64,
  parameter int unsigned AXI_ID_WIDTH     = 4,
  parameter int unsigned LOCAL_ID_WIDTH   = 6,
  parameter int unsigned ROB_SEQ_WIDTH    = rv_ooo_pkg::ROB_SEQ_WIDTH,
  parameter logic [ADDR_WIDTH-1:0] TARGET_BASE_ADDR = '0,
  parameter int unsigned TARGET_SIZE_KB   = 128,
  parameter bit TARGET_IS_DEVICE          = 1'b0,
  parameter bit SECOND_TARGET_ENABLE      = 1'b0,
  parameter logic [ADDR_WIDTH-1:0] SECOND_TARGET_BASE_ADDR = '0,
  parameter int unsigned SECOND_TARGET_SIZE_KB = 1,
  parameter bit SECOND_TARGET_IS_DEVICE   = 1'b1,
  parameter int unsigned MAX_BURST_BEATS  = 16
) (
  input  logic                   clk_i,
  input  logic                   rst_ni,
  rv_axi4_if.slave               axi_s,
  rv_local_mem_if.requester      local_bus
);

  import rv_soc_pkg::*;

  typedef enum logic [3:0] {
    IN_IDLE,
    IN_WRITE_DATA,
    IN_WRITE_LOCAL_REQ,
    IN_WRITE_LOCAL_WAIT,
    IN_WRITE_RESP,
    IN_READ_LOCAL_REQ,
    IN_READ_LOCAL_WAIT,
    IN_READ_SEND
  } inbound_state_e;

  inbound_state_e state_q;
  logic [AXI_ID_WIDTH-1:0] axi_id_q;
  logic [ADDR_WIDTH-1:0] address_q;
  logic [7:0] burst_len_q;
  logic [7:0] beat_index_q;
  logic [2:0] size_q;
  logic [2:0] prot_q;
  logic transaction_valid_q;
  logic [DATA_WIDTH-1:0] write_data_q;
  logic [DATA_WIDTH/8-1:0] write_strb_q;
  logic write_last_q;
  logic write_protocol_error_q;
  axi_resp_e write_response_q;
  logic [DATA_WIDTH-1:0] read_data_q;
  axi_resp_e read_response_q;
  logic read_last_q;

  function automatic logic transfer_fits_region(
    input logic [63:0] start_address,
    input logic [63:0] transfer_end,
    input logic [ADDR_WIDTH-1:0] region_base,
    input int unsigned region_size_kb
  );
    logic [63:0] base_ext;
    logic [63:0] region_end;
    base_ext   = {{(64-ADDR_WIDTH){1'b0}}, region_base};
    region_end = base_ext + (64'(region_size_kb) * 64'd1024);
    return (start_address >= base_ext) && (transfer_end <= region_end);
  endfunction

  function automatic logic burst_is_valid(
    input logic [ADDR_WIDTH-1:0] start_address,
    input logic [7:0] length,
    input logic [2:0] size,
    input logic [1:0] burst
  );
    logic [63:0] start_ext;
    logic [63:0] transfer_end;
    logic [63:0] beat_bytes;
    logic [63:0] align_mask;
    start_ext    = {{(64-ADDR_WIDTH){1'b0}}, start_address};
    beat_bytes   = 64'd1 << size;
    align_mask   = beat_bytes - 1'b1;
    transfer_end = start_ext + beat_bytes * (64'(length) + 1'b1);
    return (size <= 3) && (burst == 2'b01) &&
           (length < MAX_BURST_BEATS) &&
           ((start_ext & align_mask) == 0) &&
           (transfer_fits_region(start_ext, transfer_end,
                                 TARGET_BASE_ADDR, TARGET_SIZE_KB) ||
            (SECOND_TARGET_ENABLE &&
             transfer_fits_region(start_ext, transfer_end,
                                  SECOND_TARGET_BASE_ADDR,
                                  SECOND_TARGET_SIZE_KB)));
  endfunction

  function automatic logic target_is_device(
    input logic [ADDR_WIDTH-1:0] address
  );
    if (SECOND_TARGET_ENABLE &&
        rv_soc_pkg::addr_in_region(address, SECOND_TARGET_BASE_ADDR,
          rv_soc_pkg::size_kb_to_bytes(SECOND_TARGET_SIZE_KB)))
      return SECOND_TARGET_IS_DEVICE;
    return TARGET_IS_DEVICE;
  endfunction

  function automatic axi_resp_e merge_response(
    input axi_resp_e accumulated,
    input axi_resp_e current
  );
    if ((accumulated == AXI_RESP_DECERR) || (current == AXI_RESP_DECERR))
      return AXI_RESP_DECERR;
    if ((accumulated == AXI_RESP_SLVERR) || (current == AXI_RESP_SLVERR))
      return AXI_RESP_SLVERR;
    return AXI_RESP_OKAY;
  endfunction

  function automatic privilege_e axi_privilege(input logic [2:0] prot);
    return prot[0] ? PRIV_M : PRIV_U;
  endfunction

  function automatic logic [ADDR_WIDTH-1:0] beat_increment(
    input logic [2:0] size
  );
    logic [ADDR_WIDTH-1:0] increment;
    increment    = '0;
    increment[0] = 1'b1;
    return increment << size;
  endfunction

  always_comb begin
    axi_s.aw_ready = (state_q == IN_IDLE);
    // If both address channels are asserted, accept AW and backpressure AR.
    axi_s.ar_ready = (state_q == IN_IDLE) && !axi_s.aw_valid;
    axi_s.w_ready  = (state_q == IN_WRITE_DATA);
    axi_s.b_id     = axi_id_q;
    axi_s.b_resp   = write_response_q;
    axi_s.b_valid  = (state_q == IN_WRITE_RESP);
    axi_s.r_id     = axi_id_q;
    axi_s.r_data   = read_data_q;
    axi_s.r_resp   = read_response_q;
    axi_s.r_last   = read_last_q;
    axi_s.r_valid  = (state_q == IN_READ_SEND);

    local_bus.req_valid     = (state_q == IN_WRITE_LOCAL_REQ) ||
                              (state_q == IN_READ_LOCAL_REQ);
    local_bus.req_id        = {{(LOCAL_ID_WIDTH-AXI_ID_WIDTH){1'b0}},
                               axi_id_q};
    local_bus.req_addr      = address_q;
    local_bus.req_write     = (state_q == IN_WRITE_LOCAL_REQ);
    local_bus.req_size      = size_q;
    local_bus.req_wdata     = write_data_q;
    local_bus.req_wstrb     = write_strb_q;
    local_bus.req_priv      = axi_privilege(prot_q);
    local_bus.req_rob_seq   = '0;
    local_bus.req_committed = (state_q == IN_WRITE_LOCAL_REQ);
    local_bus.req_device    = target_is_device(address_q);
    local_bus.rsp_ready     = (state_q == IN_WRITE_LOCAL_WAIT) ||
                              (state_q == IN_READ_LOCAL_WAIT);
  end

  always_ff @(posedge clk_i) begin
    if (!rst_ni) begin
      state_q                  <= IN_IDLE;
      axi_id_q                 <= '0;
      address_q                <= '0;
      burst_len_q              <= '0;
      beat_index_q             <= '0;
      size_q                   <= '0;
      prot_q                   <= '0;
      transaction_valid_q      <= 1'b0;
      write_data_q             <= '0;
      write_strb_q             <= '0;
      write_last_q             <= 1'b0;
      write_protocol_error_q   <= 1'b0;
      write_response_q         <= AXI_RESP_OKAY;
      read_data_q              <= '0;
      read_response_q          <= AXI_RESP_OKAY;
      read_last_q              <= 1'b0;
    end else begin
      case (state_q)
        IN_IDLE: begin
          if (axi_s.aw_valid && axi_s.aw_ready) begin
            axi_id_q            <= axi_s.aw_id;
            address_q           <= axi_s.aw_addr;
            burst_len_q         <= axi_s.aw_len;
            beat_index_q        <= '0;
            size_q              <= axi_s.aw_size;
            prot_q              <= axi_s.aw_prot;
            transaction_valid_q <= burst_is_valid(
                                     axi_s.aw_addr, axi_s.aw_len,
                                     axi_s.aw_size, axi_s.aw_burst);
            write_response_q       <= AXI_RESP_OKAY;
            write_protocol_error_q <= 1'b0;
            state_q                <= IN_WRITE_DATA;
          end else if (axi_s.ar_valid && axi_s.ar_ready) begin
            axi_id_q            <= axi_s.ar_id;
            address_q           <= axi_s.ar_addr;
            burst_len_q         <= axi_s.ar_len;
            beat_index_q        <= '0;
            size_q              <= axi_s.ar_size;
            prot_q              <= axi_s.ar_prot;
            transaction_valid_q <= burst_is_valid(
                                     axi_s.ar_addr, axi_s.ar_len,
                                     axi_s.ar_size, axi_s.ar_burst);
            if (burst_is_valid(axi_s.ar_addr, axi_s.ar_len,
                               axi_s.ar_size, axi_s.ar_burst)) begin
              state_q <= IN_READ_LOCAL_REQ;
            end else begin
              read_data_q     <= '0;
              read_response_q <= AXI_RESP_SLVERR;
              read_last_q     <= (axi_s.ar_len == 0);
              state_q         <= IN_READ_SEND;
            end
          end
        end

        IN_WRITE_DATA: begin
          if (axi_s.w_valid && axi_s.w_ready) begin
            write_data_q   <= axi_s.w_data;
            write_strb_q   <= axi_s.w_strb;
            write_last_q   <= axi_s.w_last;
            write_protocol_error_q <=
              axi_s.w_last != (beat_index_q == burst_len_q);
            if (!transaction_valid_q) begin
              write_response_q <= AXI_RESP_SLVERR;
              if (axi_s.w_last || (beat_index_q == burst_len_q)) begin
                state_q <= IN_WRITE_RESP;
              end else begin
                beat_index_q <= beat_index_q + 1'b1;
                address_q <= address_q + beat_increment(size_q);
              end
            end else begin
              state_q <= IN_WRITE_LOCAL_REQ;
            end
          end
        end

        IN_WRITE_LOCAL_REQ: begin
          if (local_bus.req_valid && local_bus.req_ready)
            state_q <= IN_WRITE_LOCAL_WAIT;
        end

        IN_WRITE_LOCAL_WAIT: begin
          if (local_bus.rsp_valid && local_bus.rsp_ready) begin
            if (write_protocol_error_q ||
                (local_bus.rsp_replay != MEM_REPLAY_NONE))
              write_response_q <= merge_response(write_response_q,
                                                  AXI_RESP_SLVERR);
            else
              write_response_q <= merge_response(
                                    write_response_q,
                                    local_bus.rsp_resp);

            if (write_last_q || (beat_index_q == burst_len_q)) begin
              state_q <= IN_WRITE_RESP;
            end else begin
              beat_index_q <= beat_index_q + 1'b1;
              address_q <= address_q + beat_increment(size_q);
              state_q <= IN_WRITE_DATA;
            end
          end
        end

        IN_WRITE_RESP: begin
          if (axi_s.b_valid && axi_s.b_ready)
            state_q <= IN_IDLE;
        end

        IN_READ_LOCAL_REQ: begin
          if (local_bus.req_valid && local_bus.req_ready)
            state_q <= IN_READ_LOCAL_WAIT;
        end

        IN_READ_LOCAL_WAIT: begin
          if (local_bus.rsp_valid && local_bus.rsp_ready) begin
            read_data_q <= local_bus.rsp_rdata;
            if (local_bus.rsp_replay != MEM_REPLAY_NONE)
              read_response_q <= AXI_RESP_SLVERR;
            else
              read_response_q <= local_bus.rsp_resp;
            read_last_q <= (beat_index_q == burst_len_q);
            state_q <= IN_READ_SEND;
          end
        end

        IN_READ_SEND: begin
          if (axi_s.r_valid && axi_s.r_ready) begin
            if (read_last_q) begin
              state_q <= IN_IDLE;
            end else begin
              beat_index_q <= beat_index_q + 1'b1;
              address_q <= address_q + beat_increment(size_q);
              if (transaction_valid_q) begin
                state_q <= IN_READ_LOCAL_REQ;
              end else begin
                read_data_q     <= '0;
                read_response_q <= AXI_RESP_SLVERR;
                read_last_q     <= ((beat_index_q + 1'b1) == burst_len_q);
              end
            end
          end
        end

        default: state_q <= IN_IDLE;
      endcase
    end
  end

`ifndef SYNTHESIS
  property p_address_channels_not_accepted_together;
    @(posedge clk_i) disable iff (!rst_ni)
      !(axi_s.aw_valid && axi_s.aw_ready && axi_s.ar_valid && axi_s.ar_ready);
  endproperty
  assert property (p_address_channels_not_accepted_together);

  property p_local_write_is_committed;
    @(posedge clk_i) disable iff (!rst_ni)
      local_bus.req_valid && local_bus.req_write
      |-> local_bus.req_committed;
  endproperty
  assert property (p_local_write_is_committed);

  property p_r_last_matches_declared_length;
    @(posedge clk_i) disable iff (!rst_ni)
      axi_s.r_valid |-> axi_s.r_last == (beat_index_q == burst_len_q);
  endproperty
  assert property (p_r_last_matches_declared_length);
`endif

  initial begin : p_parameter_checks
    if ((DATA_WIDTH != 64) || (ADDR_WIDTH != 32))
      $fatal(1, "M1 bridge baseline requires AXI32/64");
    if ((MAX_BURST_BEATS == 0) || (MAX_BURST_BEATS > 256))
      $fatal(1, "MAX_BURST_BEATS must be in 1..256");
    if (TARGET_SIZE_KB == 0)
      $fatal(1, "TARGET_SIZE_KB must be nonzero");
    if (SECOND_TARGET_ENABLE && (SECOND_TARGET_SIZE_KB == 0))
      $fatal(1, "SECOND_TARGET_SIZE_KB must be nonzero when enabled");
  end

endmodule
