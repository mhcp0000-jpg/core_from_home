module rv_clint #(
  parameter logic [31:0] BASE_ADDR = rv_soc_pkg::CLINT_BASE_ADDR,
  parameter int unsigned SIZE_KB   = rv_soc_pkg::CLINT_SIZE_KB,
  parameter int unsigned CLOCK_HZ  = 100_000_000,
  parameter int unsigned TIMEBASE_HZ = rv_soc_pkg::TIMEBASE_HZ,
  localparam int unsigned PRESCALE_DIV = CLOCK_HZ / TIMEBASE_HZ,
  localparam int unsigned PRESCALE_WIDTH = (PRESCALE_DIV <= 1) ?
                                             1 : $clog2(PRESCALE_DIV)
) (
  input  logic             clk_i,
  input  logic             rst_ni,
  rv_local_mem_if.target   bus,
  output logic             msip_o,
  output logic             mtip_o,
  output logic [63:0]      mtime_o
);

  import rv_soc_pkg::*;

  logic                         msip_q;
  logic [63:0]                  mtime_q;
  logic [63:0]                  mtimecmp_q;
  logic [PRESCALE_WIDTH-1:0]    prescale_q;
  logic                         rsp_valid_q;
  logic [5:0]                   rsp_id_q;
  logic [63:0]                  rsp_data_q;
  axi_resp_e                    rsp_resp_q;
  logic                         request_fire;
  logic [15:0]                  request_offset;
  logic [31:0]                  selected_word;

  function automatic logic [31:0] merge_bus_word(
    input logic [31:0] old_word,
    input logic [63:0] write_data,
    input logic [7:0]  write_strobe,
    input logic        upper_lane
  );
    logic [31:0] merged_word;
    int unsigned lane;
    merged_word = old_word;
    for (int unsigned byte_index = 0; byte_index < 4; byte_index++) begin
      lane = byte_index + (upper_lane ? 4 : 0);
      if (write_strobe[lane])
        merged_word[byte_index*8 +: 8] = write_data[lane*8 +: 8];
    end
    return merged_word;
  endfunction

  function automatic logic [63:0] place_bus_word(
    input logic [31:0] word_data,
    input logic        upper_lane
  );
    return upper_lane ? {word_data, 32'b0} : {32'b0, word_data};
  endfunction

  assign bus.req_ready  = !rsp_valid_q || bus.rsp_ready;
  assign request_fire   = bus.req_valid && bus.req_ready;
  assign request_offset = bus.req_addr[15:0] - BASE_ADDR[15:0];
  assign bus.rsp_valid  = rsp_valid_q;
  assign bus.rsp_id     = rsp_id_q;
  assign bus.rsp_rdata  = rsp_data_q;
  assign bus.rsp_resp   = rsp_resp_q;
  assign bus.rsp_replay = MEM_REPLAY_NONE;
  assign msip_o         = msip_q;
  assign mtip_o         = (mtime_q >= mtimecmp_q);
  assign mtime_o        = mtime_q;

  always_comb begin
    selected_word = '0;
    case (request_offset)
      CLINT_MSIP_OFFSET:     selected_word = {31'b0, msip_q};
      CLINT_MTIMECMP_LO_OFF: selected_word = mtimecmp_q[31:0];
      CLINT_MTIMECMP_HI_OFF: selected_word = mtimecmp_q[63:32];
      CLINT_MTIME_LO_OFF:    selected_word = mtime_q[31:0];
      CLINT_MTIME_HI_OFF:    selected_word = mtime_q[63:32];
      default:               selected_word = '0;
    endcase
  end

  always_ff @(posedge clk_i) begin
    if (!rst_ni) begin
      msip_q      <= 1'b0;
      mtime_q     <= '0;
      mtimecmp_q  <= '1;
      prescale_q  <= '0;
      rsp_valid_q <= 1'b0;
      rsp_id_q    <= '0;
      rsp_data_q  <= '0;
      rsp_resp_q  <= AXI_RESP_OKAY;
    end else begin
      if (rsp_valid_q && bus.rsp_ready)
        rsp_valid_q <= 1'b0;

      if (PRESCALE_DIV <= 1) begin
        mtime_q <= mtime_q + 1'b1;
      end else if (prescale_q == PRESCALE_DIV-1) begin
        prescale_q <= '0;
        mtime_q    <= mtime_q + 1'b1;
      end else begin
        prescale_q <= prescale_q + 1'b1;
      end

      if (request_fire) begin
        rsp_valid_q <= 1'b1;
        rsp_id_q    <= bus.req_id;
        rsp_data_q  <= place_bus_word(selected_word, bus.req_addr[2]);
        rsp_resp_q  <= AXI_RESP_OKAY;

        if ((bus.req_size != 3'd2) ||
            !addr_in_region(bus.req_addr, BASE_ADDR,
                            size_kb_to_bytes(SIZE_KB))) begin
          rsp_resp_q <= AXI_RESP_SLVERR;
        end else begin
          case (request_offset)
            CLINT_MSIP_OFFSET: begin
              if (bus.req_write)
                msip_q <= merge_bus_word({31'b0, msip_q}, bus.req_wdata,
                                         bus.req_wstrb, bus.req_addr[2])[0];
            end
            CLINT_MTIMECMP_LO_OFF: begin
              if (bus.req_write)
                mtimecmp_q[31:0] <= merge_bus_word(mtimecmp_q[31:0],
                                                  bus.req_wdata,
                                                  bus.req_wstrb,
                                                  bus.req_addr[2]);
            end
            CLINT_MTIMECMP_HI_OFF: begin
              if (bus.req_write)
                mtimecmp_q[63:32] <= merge_bus_word(mtimecmp_q[63:32],
                                                   bus.req_wdata,
                                                   bus.req_wstrb,
                                                   bus.req_addr[2]);
            end
            CLINT_MTIME_LO_OFF: begin
              if (bus.req_write)
                mtime_q[31:0] <= merge_bus_word(mtime_q[31:0],
                                               bus.req_wdata,
                                               bus.req_wstrb,
                                               bus.req_addr[2]);
            end
            CLINT_MTIME_HI_OFF: begin
              if (bus.req_write)
                mtime_q[63:32] <= merge_bus_word(mtime_q[63:32],
                                                bus.req_wdata,
                                                bus.req_wstrb,
                                                bus.req_addr[2]);
            end
            default: rsp_resp_q <= AXI_RESP_SLVERR;
          endcase
        end
      end
    end
  end

  initial begin : p_parameter_checks
    if ((CLOCK_HZ == 0) || (TIMEBASE_HZ == 0) ||
        ((CLOCK_HZ % TIMEBASE_HZ) != 0))
      $fatal(1, "CLOCK_HZ must be an integer multiple of TIMEBASE_HZ");
    if (SIZE_KB < 64)
      $fatal(1, "CLINT SIZE_KB must cover the mtime register at 0xBFF8");
  end

endmodule
