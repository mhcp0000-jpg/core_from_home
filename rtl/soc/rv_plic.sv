module rv_plic_local #(
  parameter logic [31:0] BASE_ADDR = rv_soc_pkg::PLIC_BASE_ADDR,
  parameter int unsigned SIZE_KB   = rv_soc_pkg::PLIC_SIZE_KB,
  parameter int unsigned NUM_SOURCES = rv_soc_pkg::PLIC_NUM_SOURCES,
  parameter int unsigned PRIORITY_WIDTH = 3,
  parameter bit HAS_SMODE = 1'b0,
  localparam int unsigned SOURCE_ID_WIDTH = $clog2(NUM_SOURCES)
) (
  input  logic                         clk_i,
  input  logic                         rst_ni,
  rv_local_mem_if.target               bus,
  input  logic [NUM_SOURCES-1:1]       source_i,
  output logic                         meip_o,
  output logic                         seip_o
);

  import rv_soc_pkg::*;

  logic [PRIORITY_WIDTH-1:0] priority_q [NUM_SOURCES-1:1];
  logic [NUM_SOURCES-1:1] pending_q;
  logic [NUM_SOURCES-1:1] in_service_q;
  logic [NUM_SOURCES-1:1] m_enable_q;
  logic [NUM_SOURCES-1:1] s_enable_q;
  logic [PRIORITY_WIDTH-1:0] m_threshold_q;
  logic [PRIORITY_WIDTH-1:0] s_threshold_q;

  logic rsp_valid_q;
  logic [5:0] rsp_id_q;
  logic [63:0] rsp_data_q;
  axi_resp_e rsp_code_q;
  logic request_fire;
  logic [21:0] request_offset;
  logic [31:0] selected_word;
  logic [31:0] merged_word;
  logic [31:0] write_word;
  logic [31:0] pending_word;
  logic [31:0] m_enable_word;
  logic [31:0] s_enable_word;
  logic is_priority_access;
  int unsigned priority_source;
  logic [SOURCE_ID_WIDTH-1:0] m_claim_id;
  logic [SOURCE_ID_WIDTH-1:0] s_claim_id;

  function automatic logic [31:0] merge_bus_word(
    input logic [31:0] old_word,
    input logic [63:0] write_data,
    input logic [7:0] write_strobe,
    input logic upper_lane
  );
    logic [31:0] result;
    int unsigned lane;
    result = old_word;
    for (int unsigned byte_index = 0; byte_index < 4; byte_index++) begin
      lane = byte_index + (upper_lane ? 4 : 0);
      if (write_strobe[lane])
        result[byte_index*8 +: 8] = write_data[lane*8 +: 8];
    end
    return result;
  endfunction

  function automatic logic [63:0] place_bus_word(
    input logic [31:0] word_data,
    input logic upper_lane
  );
    return upper_lane ? {word_data, 32'b0} : {32'b0, word_data};
  endfunction

  function automatic logic [SOURCE_ID_WIDTH-1:0] select_source(
    input logic [NUM_SOURCES-1:1] enable,
    input logic [PRIORITY_WIDTH-1:0] threshold
  );
    logic [SOURCE_ID_WIDTH-1:0] selected;
    logic [PRIORITY_WIDTH-1:0] best_priority;
    selected      = '0;
    best_priority = threshold;
    // Ascending scan plus strict-greater comparison gives lower source ID
    // priority when two enabled sources have equal priority.
    for (int unsigned source = 1; source < NUM_SOURCES; source++) begin
      if (pending_q[source] && !in_service_q[source] && enable[source] &&
          (priority_q[source] > best_priority)) begin
        selected      = SOURCE_ID_WIDTH'(source);
        best_priority = priority_q[source];
      end
    end
    return selected;
  endfunction

  assign bus.req_ready  = !rsp_valid_q || bus.rsp_ready;
  assign request_fire   = bus.req_valid && bus.req_ready;
  assign request_offset = bus.req_addr[21:0] - BASE_ADDR[21:0];
  assign bus.rsp_valid  = rsp_valid_q;
  assign bus.rsp_id     = rsp_id_q;
  assign bus.rsp_rdata  = rsp_data_q;
  assign bus.rsp_resp   = rsp_code_q;
  assign bus.rsp_replay = MEM_REPLAY_NONE;
  assign m_claim_id     = select_source(m_enable_q, m_threshold_q);
  assign s_claim_id     = HAS_SMODE ? select_source(s_enable_q,
                                                     s_threshold_q) : '0;
  assign meip_o         = (m_claim_id != 0);
  assign seip_o         = HAS_SMODE && (s_claim_id != 0);

  always_comb begin
    pending_word  = '0;
    m_enable_word = '0;
    s_enable_word = '0;
    for (int unsigned source = 1; source < NUM_SOURCES; source++) begin
      pending_word[source]  = pending_q[source];
      m_enable_word[source] = m_enable_q[source];
      s_enable_word[source] = s_enable_q[source];
    end

    is_priority_access = (request_offset >= 22'h000004) &&
                         (request_offset <=
                          (22'h000004 * (NUM_SOURCES-1))) &&
                         (request_offset[1:0] == 0);
    priority_source = request_offset >> 2;

    selected_word = '0;
    if (is_priority_access) begin
      selected_word[PRIORITY_WIDTH-1:0] = priority_q[priority_source];
    end else begin
      case (request_offset)
        PLIC_PENDING_OFFSET:   selected_word = pending_word;
        PLIC_M_ENABLE_OFFSET:  selected_word = m_enable_word;
        PLIC_M_THRESHOLD_OFF:  selected_word[PRIORITY_WIDTH-1:0] =
                                m_threshold_q;
        PLIC_M_CLAIM_OFF:      selected_word[SOURCE_ID_WIDTH-1:0] =
                                m_claim_id;
        PLIC_S_ENABLE_OFFSET:  if (HAS_SMODE)
                                selected_word = s_enable_word;
        PLIC_S_THRESHOLD_OFF: if (HAS_SMODE)
                                selected_word[PRIORITY_WIDTH-1:0] =
                                  s_threshold_q;
        PLIC_S_CLAIM_OFF:     if (HAS_SMODE)
                                selected_word[SOURCE_ID_WIDTH-1:0] =
                                  s_claim_id;
        default: selected_word = '0;
      endcase
    end
    merged_word = merge_bus_word(selected_word, bus.req_wdata,
                                 bus.req_wstrb, bus.req_addr[2]);
    write_word = merge_bus_word('0, bus.req_wdata, bus.req_wstrb,
                                bus.req_addr[2]);
  end

  always_ff @(posedge clk_i) begin
    if (!rst_ni) begin
      pending_q      <= '0;
      in_service_q   <= '0;
      m_enable_q     <= '0;
      s_enable_q     <= '0;
      m_threshold_q  <= '0;
      s_threshold_q  <= '0;
      rsp_valid_q    <= 1'b0;
      rsp_id_q       <= '0;
      rsp_data_q     <= '0;
      rsp_code_q     <= AXI_RESP_OKAY;
      for (int unsigned source = 1; source < NUM_SOURCES; source++)
        priority_q[source] <= '0;
    end else begin
      if (rsp_valid_q && bus.rsp_ready)
        rsp_valid_q <= 1'b0;

      // Initial gateway is level-sensitive. A new request is latched only when
      // that source has neither a pending request nor an in-service claim.
      for (int unsigned source = 1; source < NUM_SOURCES; source++) begin
        if (source_i[source] && !pending_q[source] &&
            !in_service_q[source])
          pending_q[source] <= 1'b1;
      end

      if (request_fire) begin
        rsp_valid_q <= 1'b1;
        rsp_id_q    <= bus.req_id;
        rsp_data_q  <= place_bus_word(selected_word, bus.req_addr[2]);
        rsp_code_q  <= AXI_RESP_OKAY;

        if ((bus.req_size != 3'd2) ||
            !addr_in_region(bus.req_addr, BASE_ADDR,
                            size_kb_to_bytes(SIZE_KB))) begin
          rsp_code_q <= AXI_RESP_SLVERR;
        end else if (is_priority_access) begin
          if (bus.req_write)
            priority_q[priority_source] <=
              merged_word[PRIORITY_WIDTH-1:0];
        end else begin
          case (request_offset)
            22'h000000: begin
              if (bus.req_write)
                rsp_code_q <= AXI_RESP_SLVERR;
            end
            PLIC_PENDING_OFFSET: begin
              if (bus.req_write)
                rsp_code_q <= AXI_RESP_SLVERR;
            end
            PLIC_M_ENABLE_OFFSET: begin
              if (bus.req_write)
                m_enable_q <= merged_word[NUM_SOURCES-1:1];
            end
            PLIC_M_THRESHOLD_OFF: begin
              if (bus.req_write)
                m_threshold_q <= merged_word[PRIORITY_WIDTH-1:0];
            end
            PLIC_M_CLAIM_OFF: begin
              if (bus.req_write) begin
                if ((write_word[SOURCE_ID_WIDTH-1:0] != 0) &&
                    (write_word[SOURCE_ID_WIDTH-1:0] < NUM_SOURCES) &&
                    in_service_q[write_word[SOURCE_ID_WIDTH-1:0]])
                  in_service_q[write_word[SOURCE_ID_WIDTH-1:0]] <= 1'b0;
              end else if (m_claim_id != 0) begin
                pending_q[m_claim_id]    <= 1'b0;
                in_service_q[m_claim_id] <= 1'b1;
              end
            end
            PLIC_S_ENABLE_OFFSET: begin
              if (!HAS_SMODE) begin
                rsp_code_q <= AXI_RESP_SLVERR;
              end else if (bus.req_write) begin
                s_enable_q <= merged_word[NUM_SOURCES-1:1];
              end
            end
            PLIC_S_THRESHOLD_OFF: begin
              if (!HAS_SMODE) begin
                rsp_code_q <= AXI_RESP_SLVERR;
              end else if (bus.req_write) begin
                s_threshold_q <= merged_word[PRIORITY_WIDTH-1:0];
              end
            end
            PLIC_S_CLAIM_OFF: begin
              if (!HAS_SMODE) begin
                rsp_code_q <= AXI_RESP_SLVERR;
              end else if (bus.req_write) begin
                if ((write_word[SOURCE_ID_WIDTH-1:0] != 0) &&
                    (write_word[SOURCE_ID_WIDTH-1:0] < NUM_SOURCES) &&
                    in_service_q[write_word[SOURCE_ID_WIDTH-1:0]])
                  in_service_q[write_word[SOURCE_ID_WIDTH-1:0]] <= 1'b0;
              end else if (s_claim_id != 0) begin
                pending_q[s_claim_id]    <= 1'b0;
                in_service_q[s_claim_id] <= 1'b1;
              end
            end
            default: rsp_code_q <= AXI_RESP_SLVERR;
          endcase
        end
      end
    end
  end

`ifndef SYNTHESIS
  property p_source_zero_never_claimed;
    @(posedge clk_i) disable iff (!rst_ni)
      (m_claim_id != 0) || !meip_o;
  endproperty
  assert property (p_source_zero_never_claimed);

  property p_meip_has_eligible_source;
    @(posedge clk_i) disable iff (!rst_ni)
      meip_o |-> pending_q[m_claim_id] && m_enable_q[m_claim_id] &&
                 (priority_q[m_claim_id] > m_threshold_q);
  endproperty
  assert property (p_meip_has_eligible_source);
`endif

  initial begin : p_parameter_checks
    if ((NUM_SOURCES < 2) || (NUM_SOURCES > 32))
      $fatal(1, "PLIC baseline supports 2..32 source IDs including source0");
    if ((PRIORITY_WIDTH == 0) || (PRIORITY_WIDTH > 8))
      $fatal(1, "PLIC priority width must be in 1..8");
    if (SIZE_KB < 4096)
      $fatal(1, "PLIC aperture must cover context registers through 0x201004");
  end

endmodule

module rv_plic #(
  parameter logic [31:0] BASE_ADDR = rv_soc_pkg::PLIC_BASE_ADDR,
  parameter int unsigned SIZE_KB   = rv_soc_pkg::PLIC_SIZE_KB,
  parameter int unsigned NUM_SOURCES = rv_soc_pkg::PLIC_NUM_SOURCES,
  parameter int unsigned PRIORITY_WIDTH = 3,
  parameter bit HAS_SMODE = 1'b0,
  parameter int unsigned AXI_ID_WIDTH = 4
) (
  input  logic                         clk_i,
  input  logic                         rst_ni,
  rv_axi4_if.slave                     axi_s,
  input  logic [NUM_SOURCES-1:1]       source_i,
  output logic                         meip_o,
  output logic                         seip_o
);

  rv_local_mem_if plic_bus (
    .clk_i,
    .rst_ni
  );

  rv_axi_to_local_bridge #(
    .AXI_ID_WIDTH     (AXI_ID_WIDTH),
    .LOCAL_ID_WIDTH   (6),
    .TARGET_BASE_ADDR (BASE_ADDR),
    .TARGET_SIZE_KB   (SIZE_KB),
    .TARGET_IS_DEVICE (1'b1),
    .MAX_BURST_BEATS  (1)
  ) u_axi_bridge (
    .clk_i,
    .rst_ni,
    .axi_s,
    .local_bus (plic_bus)
  );

  rv_plic_local #(
    .BASE_ADDR     (BASE_ADDR),
    .SIZE_KB       (SIZE_KB),
    .NUM_SOURCES   (NUM_SOURCES),
    .PRIORITY_WIDTH(PRIORITY_WIDTH),
    .HAS_SMODE     (HAS_SMODE)
  ) u_registers (
    .clk_i,
    .rst_ni,
    .bus      (plic_bus),
    .source_i,
    .meip_o,
    .seip_o
  );

endmodule
