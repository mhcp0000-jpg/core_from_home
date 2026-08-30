module rv_axi_error_slave #(
  parameter int unsigned ID_WIDTH = 4
) (
  input  logic          clk_i,
  input  logic          rst_ni,
  rv_axi4_if.slave      axi_s
);

  typedef enum logic [2:0] {
    ERR_IDLE,
    ERR_WRITE_DATA,
    ERR_WRITE_RESP,
    ERR_READ_DATA
  } error_state_e;

  error_state_e state_q;
  logic [ID_WIDTH-1:0] id_q;
  logic [7:0] length_q;
  logic [7:0] beat_q;

  always_comb begin
    axi_s.aw_ready = (state_q == ERR_IDLE);
    axi_s.ar_ready = (state_q == ERR_IDLE) && !axi_s.aw_valid;
    axi_s.w_ready  = (state_q == ERR_WRITE_DATA);
    axi_s.b_id     = id_q;
    axi_s.b_resp   = rv_soc_pkg::AXI_RESP_DECERR;
    axi_s.b_valid  = (state_q == ERR_WRITE_RESP);
    axi_s.r_id     = id_q;
    axi_s.r_data   = '0;
    axi_s.r_resp   = rv_soc_pkg::AXI_RESP_DECERR;
    axi_s.r_last   = (beat_q == length_q);
    axi_s.r_valid  = (state_q == ERR_READ_DATA);
  end

  always_ff @(posedge clk_i) begin
    if (!rst_ni) begin
      state_q  <= ERR_IDLE;
      id_q     <= '0;
      length_q <= '0;
      beat_q   <= '0;
    end else begin
      case (state_q)
        ERR_IDLE: begin
          if (axi_s.aw_valid && axi_s.aw_ready) begin
            id_q     <= axi_s.aw_id;
            length_q <= axi_s.aw_len;
            beat_q   <= '0;
            state_q  <= ERR_WRITE_DATA;
          end else if (axi_s.ar_valid && axi_s.ar_ready) begin
            id_q     <= axi_s.ar_id;
            length_q <= axi_s.ar_len;
            beat_q   <= '0;
            state_q  <= ERR_READ_DATA;
          end
        end
        ERR_WRITE_DATA: begin
          if (axi_s.w_valid && axi_s.w_ready) begin
            if (axi_s.w_last || (beat_q == length_q))
              state_q <= ERR_WRITE_RESP;
            else
              beat_q <= beat_q + 1'b1;
          end
        end
        ERR_WRITE_RESP: begin
          if (axi_s.b_valid && axi_s.b_ready)
            state_q <= ERR_IDLE;
        end
        ERR_READ_DATA: begin
          if (axi_s.r_valid && axi_s.r_ready) begin
            if (beat_q == length_q)
              state_q <= ERR_IDLE;
            else
              beat_q <= beat_q + 1'b1;
          end
        end
        default: state_q <= ERR_IDLE;
      endcase
    end
  end

`ifndef SYNTHESIS
  property p_error_read_always_decerr;
    @(posedge clk_i) disable iff (!rst_ni)
      axi_s.r_valid |-> axi_s.r_resp == rv_soc_pkg::AXI_RESP_DECERR;
  endproperty
  assert property (p_error_read_always_decerr);

  property p_error_write_always_decerr;
    @(posedge clk_i) disable iff (!rst_ni)
      axi_s.b_valid |-> axi_s.b_resp == rv_soc_pkg::AXI_RESP_DECERR;
  endproperty
  assert property (p_error_write_always_decerr);
`endif

endmodule
