module rv_local_to_axi_bridge #(
  parameter int unsigned ADDR_WIDTH       = 32,
  parameter int unsigned DATA_WIDTH       = 64,
  parameter int unsigned LOCAL_ID_WIDTH   = 6,
  parameter int unsigned AXI_ID_WIDTH     = 4,
  parameter int unsigned ROB_SEQ_WIDTH    = rv_ooo_pkg::ROB_SEQ_WIDTH,
  parameter bit          IS_INSTRUCTION   = 1'b0
) (
  input  logic                   clk_i,
  input  logic                   rst_ni,
  rv_local_mem_if.target         local_bus,
  rv_axi4_if.master              axi_m
);

  import rv_soc_pkg::*;

  typedef enum logic [2:0] {
    BR_IDLE,
    BR_WRITE_SEND,
    BR_WRITE_RESP,
    BR_READ_ADDR,
    BR_READ_DATA,
    BR_LOCAL_RESP
  } bridge_state_e;

  bridge_state_e state_q;
  logic [LOCAL_ID_WIDTH-1:0] local_id_q;
  logic [ADDR_WIDTH-1:0] address_q;
  logic [2:0] size_q;
  logic [DATA_WIDTH-1:0] write_data_q;
  logic [DATA_WIDTH/8-1:0] write_strb_q;
  privilege_e privilege_q;
  logic device_q;
  logic committed_q;
  logic aw_sent_q;
  logic w_sent_q;
  logic aw_fire;
  logic w_fire;
  logic [AXI_ID_WIDTH-1:0] axi_id_q;
  logic [DATA_WIDTH-1:0] response_data_q;
  axi_resp_e response_code_q;

  function automatic logic request_is_aligned(
    input logic [ADDR_WIDTH-1:0] request_address,
    input logic [2:0] request_size
  );
    logic [ADDR_WIDTH-1:0] byte_mask;
    if (request_size > 3)
      return 1'b0;
    byte_mask = ({{(ADDR_WIDTH-1){1'b0}}, 1'b1} << request_size) - 1;
    return (request_address & byte_mask) == 0;
  endfunction

  assign local_bus.req_ready  = (state_q == BR_IDLE);
  assign local_bus.rsp_valid  = (state_q == BR_LOCAL_RESP);
  assign local_bus.rsp_id     = local_id_q;
  assign local_bus.rsp_rdata  = response_data_q;
  assign local_bus.rsp_resp   = response_code_q;
  assign local_bus.rsp_replay = MEM_REPLAY_NONE;

  assign aw_fire = axi_m.aw_valid && axi_m.aw_ready;
  assign w_fire  = axi_m.w_valid && axi_m.w_ready;

  always_comb begin
    axi_m.aw_id    = axi_id_q;
    axi_m.aw_addr  = address_q;
    axi_m.aw_len   = 8'd0;
    axi_m.aw_size  = size_q;
    axi_m.aw_burst = 2'b01;
    axi_m.aw_prot  = {IS_INSTRUCTION, 1'b0,
                      (privilege_q != PRIV_U)};
    axi_m.aw_cache = device_q ? 4'b0000 : 4'b0011;
    axi_m.aw_qos   = '0;
    axi_m.aw_valid = (state_q == BR_WRITE_SEND) && !aw_sent_q;

    axi_m.w_data   = write_data_q;
    axi_m.w_strb   = write_strb_q;
    axi_m.w_last   = 1'b1;
    axi_m.w_valid  = (state_q == BR_WRITE_SEND) && !w_sent_q;
    axi_m.b_ready  = (state_q == BR_WRITE_RESP);

    axi_m.ar_id    = axi_id_q;
    axi_m.ar_addr  = address_q;
    axi_m.ar_len   = 8'd0;
    axi_m.ar_size  = size_q;
    axi_m.ar_burst = 2'b01;
    axi_m.ar_prot  = {IS_INSTRUCTION, 1'b0,
                      (privilege_q != PRIV_U)};
    axi_m.ar_cache = device_q ? 4'b0000 : 4'b0011;
    axi_m.ar_qos   = '0;
    axi_m.ar_valid = (state_q == BR_READ_ADDR);
    axi_m.r_ready  = (state_q == BR_READ_DATA);
  end

  always_ff @(posedge clk_i) begin
    if (!rst_ni) begin
      state_q         <= BR_IDLE;
      local_id_q      <= '0;
      address_q       <= '0;
      size_q          <= '0;
      write_data_q    <= '0;
      write_strb_q    <= '0;
      privilege_q     <= PRIV_M;
      device_q        <= 1'b0;
      committed_q     <= 1'b0;
      aw_sent_q       <= 1'b0;
      w_sent_q        <= 1'b0;
      axi_id_q        <= '0;
      response_data_q <= '0;
      response_code_q <= AXI_RESP_OKAY;
    end else begin
      case (state_q)
        BR_IDLE: begin
          if (local_bus.req_valid && local_bus.req_ready) begin
            local_id_q   <= local_bus.req_id;
            address_q    <= local_bus.req_addr;
            size_q       <= local_bus.req_size;
            write_data_q <= local_bus.req_wdata;
            write_strb_q <= local_bus.req_wstrb;
            privilege_q  <= local_bus.req_priv;
            device_q     <= local_bus.req_device;
            committed_q  <= local_bus.req_committed;
            axi_id_q     <= AXI_ID_WIDTH'(local_bus.req_id);
            aw_sent_q    <= 1'b0;
            w_sent_q     <= 1'b0;
            if (!request_is_aligned(local_bus.req_addr,
                                    local_bus.req_size)) begin
              response_data_q <= '0;
              response_code_q <= AXI_RESP_SLVERR;
              state_q         <= BR_LOCAL_RESP;
            end else if (local_bus.req_write) begin
              state_q <= BR_WRITE_SEND;
            end else begin
              state_q <= BR_READ_ADDR;
            end
          end
        end

        BR_WRITE_SEND: begin
          if (aw_fire)
            aw_sent_q <= 1'b1;
          if (w_fire)
            w_sent_q <= 1'b1;
          if ((aw_sent_q || aw_fire) && (w_sent_q || w_fire))
            state_q <= BR_WRITE_RESP;
        end

        BR_WRITE_RESP: begin
          if (axi_m.b_valid && axi_m.b_ready) begin
            response_data_q <= '0;
            response_code_q <= (axi_m.b_id == axi_id_q) ?
                               axi_resp_e'(axi_m.b_resp) : AXI_RESP_SLVERR;
            state_q <= BR_LOCAL_RESP;
          end
        end

        BR_READ_ADDR: begin
          if (axi_m.ar_valid && axi_m.ar_ready)
            state_q <= BR_READ_DATA;
        end

        BR_READ_DATA: begin
          if (axi_m.r_valid && axi_m.r_ready) begin
            response_data_q <= axi_m.r_data;
            if ((axi_m.r_id != axi_id_q) || !axi_m.r_last)
              response_code_q <= AXI_RESP_SLVERR;
            else
              response_code_q <= axi_resp_e'(axi_m.r_resp);
            state_q <= BR_LOCAL_RESP;
          end
        end

        BR_LOCAL_RESP: begin
          if (local_bus.rsp_valid && local_bus.rsp_ready)
            state_q <= BR_IDLE;
        end

        default: state_q <= BR_IDLE;
      endcase
    end
  end

`ifndef SYNTHESIS
  property p_single_beat_write;
    @(posedge clk_i) disable iff (!rst_ni)
      axi_m.w_valid |-> axi_m.w_last;
  endproperty
  assert property (p_single_beat_write);

  property p_no_axi_write_for_uncommitted_store;
    @(posedge clk_i) disable iff (!rst_ni)
      (axi_m.aw_valid || axi_m.w_valid) |-> committed_q;
  endproperty
  assert property (p_no_axi_write_for_uncommitted_store);
`endif

  initial begin : p_parameter_checks
    if ((DATA_WIDTH != 64) || (ADDR_WIDTH != 32))
      $fatal(1, "M1 bridge baseline requires AXI32/64");
    if ((AXI_ID_WIDTH == 0) || (LOCAL_ID_WIDTH == 0))
      $fatal(1, "Bridge ID widths must be nonzero");
  end

endmodule
