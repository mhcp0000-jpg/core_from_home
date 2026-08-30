module rv_bootrom_local #(
  parameter logic [31:0] BASE_ADDR = rv_soc_pkg::BOOTROM_BASE_ADDR,
  parameter int unsigned SIZE_KB   = rv_soc_pkg::BOOTROM_SIZE_KB,
  parameter string INIT_FILE       = "",
  localparam int unsigned DEPTH    = (SIZE_KB * 1024) / 8,
  localparam int unsigned INDEX_WIDTH = $clog2(DEPTH)
) (
  input  logic               clk_i,
  input  logic               rst_ni,
  rv_local_mem_if.target     bus
);

  import rv_soc_pkg::*;

  logic [63:0] memory [0:DEPTH-1];
  logic rsp_valid_q;
  logic [5:0] rsp_id_q;
  logic [63:0] rsp_data_q;
  axi_resp_e rsp_code_q;
  logic request_fire;
  logic [31:0] offset;

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

  assign bus.req_ready  = !rsp_valid_q || bus.rsp_ready;
  assign request_fire   = bus.req_valid && bus.req_ready;
  assign offset         = bus.req_addr - BASE_ADDR;
  assign bus.rsp_valid  = rsp_valid_q;
  assign bus.rsp_id     = rsp_id_q;
  assign bus.rsp_rdata  = rsp_data_q;
  assign bus.rsp_resp   = rsp_code_q;
  assign bus.rsp_replay = MEM_REPLAY_NONE;

  initial begin : p_memory_init
    if (INIT_FILE != "")
      $readmemh(INIT_FILE, memory);
  end

  always_ff @(posedge clk_i) begin
    if (!rst_ni) begin
      rsp_valid_q <= 1'b0;
      rsp_id_q    <= '0;
      rsp_data_q  <= '0;
      rsp_code_q  <= AXI_RESP_OKAY;
    end else begin
      if (rsp_valid_q && bus.rsp_ready)
        rsp_valid_q <= 1'b0;

      if (request_fire) begin
        rsp_valid_q <= 1'b1;
        rsp_id_q    <= bus.req_id;
        rsp_data_q  <= '0;
        rsp_code_q  <= AXI_RESP_OKAY;
        if (bus.req_write ||
            !addr_in_region(bus.req_addr, BASE_ADDR,
                            size_kb_to_bytes(SIZE_KB)) ||
            !access_is_aligned(bus.req_addr, bus.req_size)) begin
          rsp_code_q <= AXI_RESP_SLVERR;
        end else begin
          rsp_data_q <= memory[offset[INDEX_WIDTH+2:3]];
        end
      end
    end
  end

  initial begin : p_parameter_checks
    if ((SIZE_KB == 0) || (((SIZE_KB * 1024) % 8) != 0))
      $fatal(1, "Boot ROM size must contain whole 64-bit words");
    if ((DEPTH < 2) || ((DEPTH & (DEPTH-1)) != 0))
      $fatal(1, "Boot ROM depth must be a power of two");
  end

endmodule

module rv_bootrom #(
  parameter logic [31:0] BASE_ADDR = rv_soc_pkg::BOOTROM_BASE_ADDR,
  parameter int unsigned SIZE_KB   = rv_soc_pkg::BOOTROM_SIZE_KB,
  parameter int unsigned AXI_ID_WIDTH = 4,
  parameter string INIT_FILE       = ""
) (
  input  logic               clk_i,
  input  logic               rst_ni,
  rv_axi4_if.slave           axi_s
);

  rv_local_mem_if bootrom_bus (
    .clk_i,
    .rst_ni
  );

  rv_axi_to_local_bridge #(
    .AXI_ID_WIDTH     (AXI_ID_WIDTH),
    .LOCAL_ID_WIDTH   (6),
    .TARGET_BASE_ADDR (BASE_ADDR),
    .TARGET_SIZE_KB   (SIZE_KB),
    .TARGET_IS_DEVICE (1'b0),
    .MAX_BURST_BEATS  (16)
  ) u_axi_bridge (
    .clk_i,
    .rst_ni,
    .axi_s,
    .local_bus (bootrom_bus)
  );

  rv_bootrom_local #(
    .BASE_ADDR (BASE_ADDR),
    .SIZE_KB   (SIZE_KB),
    .INIT_FILE (INIT_FILE)
  ) u_rom (
    .clk_i,
    .rst_ni,
    .bus (bootrom_bus)
  );

endmodule
