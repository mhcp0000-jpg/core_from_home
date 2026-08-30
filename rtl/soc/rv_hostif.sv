module rv_hostif_local #(
  parameter logic [31:0] BASE_ADDR = rv_soc_pkg::HOSTIF_BASE_ADDR,
  parameter int unsigned SIZE_KB   = rv_soc_pkg::HOSTIF_SIZE_KB,
  parameter logic [31:0] HOST_ID_VALUE = 32'h5256_4f4f
) (
  input  logic                    clk_i,
  input  logic                    rst_ni,
  rv_local_mem_if.target          bus,
  output logic [31:0]             boot_entry_o,
  output logic [31:0]             boot_flags_o,
  output logic                    event_valid_o,
  input  logic                    event_ready_i,
  output rv_soc_pkg::host_event_e event_kind_o,
  output logic [31:0]             event_data_o
);

  import rv_soc_pkg::*;

  logic [31:0] boot_entry_q;
  logic [31:0] boot_flags_q;
  logic [31:0] tohost_q;
  logic [31:0] fromhost_q;
  logic [31:0] exit_code_q;
  logic [31:0] console_tx_q;
  logic [31:0] console_rx_q;
  logic event_valid_q;
  host_event_e event_kind_q;
  logic [31:0] event_data_q;

  logic rsp_valid_q;
  logic [5:0] rsp_id_q;
  logic [63:0] rsp_data_q;
  axi_resp_e rsp_code_q;
  logic request_fire;
  logic [11:0] request_offset;
  logic [31:0] selected_word;
  logic [31:0] merged_word;

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

  assign bus.req_ready  = (!rsp_valid_q || bus.rsp_ready) &&
                          (!event_valid_q || event_ready_i);
  assign request_fire   = bus.req_valid && bus.req_ready;
  assign request_offset = bus.req_addr[11:0] - BASE_ADDR[11:0];
  assign bus.rsp_valid  = rsp_valid_q;
  assign bus.rsp_id     = rsp_id_q;
  assign bus.rsp_rdata  = rsp_data_q;
  assign bus.rsp_resp   = rsp_code_q;
  assign bus.rsp_replay = MEM_REPLAY_NONE;
  assign boot_entry_o   = boot_entry_q;
  assign boot_flags_o   = boot_flags_q;
  assign event_valid_o  = event_valid_q;
  assign event_kind_o   = event_kind_q;
  assign event_data_o   = event_data_q;

  always_comb begin
    selected_word = '0;
    case (request_offset)
      HOSTIF_ID_OFFSET:          selected_word = HOST_ID_VALUE;
      HOSTIF_BOOT_ENTRY_OFF:     selected_word = boot_entry_q;
      HOSTIF_BOOT_FLAGS_OFF:     selected_word = boot_flags_q;
      HOSTIF_TOHOST_OFF:         selected_word = tohost_q;
      HOSTIF_FROMHOST_OFF:       selected_word = fromhost_q;
      HOSTIF_EXIT_CODE_OFF:      selected_word = exit_code_q;
      HOSTIF_CONSOLE_TX_OFF:     selected_word = console_tx_q;
      HOSTIF_CONSOLE_RX_OFF:     selected_word = console_rx_q;
      HOSTIF_STATUS_OFF:         selected_word = {29'b0,
                                                   boot_flags_q[0],
                                                   event_valid_q,
                                                   1'b1};
      default:                   selected_word = '0;
    endcase
    merged_word = merge_bus_word(selected_word, bus.req_wdata,
                                 bus.req_wstrb, bus.req_addr[2]);
  end

  always_ff @(posedge clk_i) begin
    if (!rst_ni) begin
      boot_entry_q   <= '0;
      boot_flags_q   <= '0;
      tohost_q       <= '0;
      fromhost_q     <= '0;
      exit_code_q    <= '0;
      console_tx_q   <= '0;
      console_rx_q   <= '0;
      event_valid_q  <= 1'b0;
      event_kind_q   <= HOST_EVENT_RESERVED;
      event_data_q   <= '0;
      rsp_valid_q    <= 1'b0;
      rsp_id_q       <= '0;
      rsp_data_q     <= '0;
      rsp_code_q     <= AXI_RESP_OKAY;
    end else begin
      if (rsp_valid_q && bus.rsp_ready)
        rsp_valid_q <= 1'b0;
      if (event_valid_q && event_ready_i)
        event_valid_q <= 1'b0;

      if (request_fire) begin
        rsp_valid_q <= 1'b1;
        rsp_id_q    <= bus.req_id;
        rsp_data_q  <= place_bus_word(selected_word, bus.req_addr[2]);
        rsp_code_q  <= AXI_RESP_OKAY;

        if ((bus.req_size != 3'd2) ||
            !addr_in_region(bus.req_addr, BASE_ADDR,
                            size_kb_to_bytes(SIZE_KB))) begin
          rsp_code_q <= AXI_RESP_SLVERR;
        end else begin
          case (request_offset)
            HOSTIF_ID_OFFSET, HOSTIF_STATUS_OFF: begin
              if (bus.req_write)
                rsp_code_q <= AXI_RESP_SLVERR;
            end
            HOSTIF_BOOT_ENTRY_OFF: begin
              if (bus.req_write)
                boot_entry_q <= merged_word;
            end
            HOSTIF_BOOT_FLAGS_OFF: begin
              if (bus.req_write)
                boot_flags_q <= merged_word;
            end
            HOSTIF_TOHOST_OFF: begin
              if (bus.req_write) begin
                tohost_q      <= merged_word;
                event_valid_q <= 1'b1;
                event_kind_q  <= HOST_EVENT_TOHOST;
                event_data_q  <= merged_word;
              end
            end
            HOSTIF_FROMHOST_OFF: begin
              if (bus.req_write)
                fromhost_q <= merged_word;
            end
            HOSTIF_EXIT_CODE_OFF: begin
              if (bus.req_write) begin
                exit_code_q   <= merged_word;
                event_valid_q <= 1'b1;
                event_kind_q  <= HOST_EVENT_EXIT;
                event_data_q  <= merged_word;
              end
            end
            HOSTIF_CONSOLE_TX_OFF: begin
              if (bus.req_write) begin
                console_tx_q  <= merged_word;
                event_valid_q <= 1'b1;
                event_kind_q  <= HOST_EVENT_CONSOLE_TX;
                event_data_q  <= merged_word;
              end
            end
            HOSTIF_CONSOLE_RX_OFF: begin
              if (bus.req_write)
                console_rx_q <= merged_word;
            end
            default: rsp_code_q <= AXI_RESP_SLVERR;
          endcase
        end
      end
    end
  end

`ifndef SYNTHESIS
  property p_event_stable_when_stalled;
    @(posedge clk_i) disable iff (!rst_ni)
      event_valid_o && !event_ready_i |=> event_valid_o &&
      $stable({event_kind_o, event_data_o});
  endproperty
  assert property (p_event_stable_when_stalled);
`endif

  initial begin : p_parameter_checks
    if (SIZE_KB < 1)
      $fatal(1, "HostIF aperture must be at least 1 KiB");
  end

endmodule

module rv_hostif #(
  parameter logic [31:0] BASE_ADDR = rv_soc_pkg::HOSTIF_BASE_ADDR,
  parameter int unsigned SIZE_KB   = rv_soc_pkg::HOSTIF_SIZE_KB,
  parameter int unsigned AXI_ID_WIDTH = 4,
  parameter logic [31:0] HOST_ID_VALUE = 32'h5256_4f4f
) (
  input  logic                    clk_i,
  input  logic                    rst_ni,
  rv_axi4_if.slave                axi_s,
  output logic [31:0]             boot_entry_o,
  output logic [31:0]             boot_flags_o,
  output logic                    event_valid_o,
  input  logic                    event_ready_i,
  output rv_soc_pkg::host_event_e event_kind_o,
  output logic [31:0]             event_data_o
);

  rv_local_mem_if hostif_bus (
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
    .local_bus (hostif_bus)
  );

  rv_hostif_local #(
    .BASE_ADDR    (BASE_ADDR),
    .SIZE_KB      (SIZE_KB),
    .HOST_ID_VALUE(HOST_ID_VALUE)
  ) u_registers (
    .clk_i,
    .rst_ni,
    .bus          (hostif_bus),
    .boot_entry_o,
    .boot_flags_o,
    .event_valid_o,
    .event_ready_i,
    .event_kind_o,
    .event_data_o
  );

endmodule
