interface rv_local_mem_if #(
  parameter int unsigned ADDR_WIDTH    = 32,
  parameter int unsigned DATA_WIDTH    = 64,
  parameter int unsigned ID_WIDTH      = 6,
  parameter int unsigned ROB_SEQ_WIDTH = 8
) (
  input logic clk_i,
  input logic rst_ni
);

  logic                       req_valid;
  logic                       req_ready;
  logic [ID_WIDTH-1:0]        req_id;
  logic [ADDR_WIDTH-1:0]      req_addr;
  logic                       req_write;
  logic [2:0]                 req_size;
  logic [DATA_WIDTH-1:0]      req_wdata;
  logic [DATA_WIDTH/8-1:0]    req_wstrb;
  rv_soc_pkg::privilege_e     req_priv;
  logic [ROB_SEQ_WIDTH-1:0]   req_rob_seq;
  logic                       req_committed;
  logic                       req_device;

  logic                       rsp_valid;
  logic                       rsp_ready;
  logic [ID_WIDTH-1:0]        rsp_id;
  logic [DATA_WIDTH-1:0]      rsp_rdata;
  rv_soc_pkg::axi_resp_e      rsp_resp;
  rv_soc_pkg::mem_replay_reason_e rsp_replay;

  modport requester (
    output req_valid, req_id, req_addr, req_write, req_size, req_wdata,
           req_wstrb, req_priv, req_rob_seq, req_committed, req_device,
    input  req_ready,
    input  rsp_valid, rsp_id, rsp_rdata, rsp_resp, rsp_replay,
    output rsp_ready
  );

  modport target (
    input  req_valid, req_id, req_addr, req_write, req_size, req_wdata,
           req_wstrb, req_priv, req_rob_seq, req_committed, req_device,
    output req_ready,
    output rsp_valid, rsp_id, rsp_rdata, rsp_resp, rsp_replay,
    input  rsp_ready
  );

`ifndef SYNTHESIS
  property p_request_stable_when_stalled;
    @(posedge clk_i) disable iff (!rst_ni)
      req_valid && !req_ready |=> req_valid &&
      $stable({req_id, req_addr, req_write, req_size, req_wdata, req_wstrb,
               req_priv, req_rob_seq, req_committed, req_device});
  endproperty
  assert property (p_request_stable_when_stalled);

  property p_no_uncommitted_write;
    @(posedge clk_i) disable iff (!rst_ni)
      req_valid && req_write |-> req_committed;
  endproperty
  assert property (p_no_uncommitted_write);

  property p_response_stable_when_stalled;
    @(posedge clk_i) disable iff (!rst_ni)
      rsp_valid && !rsp_ready |=> rsp_valid &&
      $stable({rsp_id, rsp_rdata, rsp_resp, rsp_replay});
  endproperty
  assert property (p_response_stable_when_stalled);
`endif

endinterface
