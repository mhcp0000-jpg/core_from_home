interface rv_axi4_if #(
  parameter int unsigned ADDR_WIDTH = 32,
  parameter int unsigned DATA_WIDTH = 64,
  parameter int unsigned ID_WIDTH   = 4
) (
  input logic clk_i,
  input logic rst_ni
);

  logic [ID_WIDTH-1:0]   aw_id;
  logic [ADDR_WIDTH-1:0] aw_addr;
  logic [7:0]            aw_len;
  logic [2:0]            aw_size;
  logic [1:0]            aw_burst;
  logic [2:0]            aw_prot;
  logic [3:0]            aw_cache;
  logic [3:0]            aw_qos;
  logic                  aw_valid;
  logic                  aw_ready;

  logic [DATA_WIDTH-1:0]   w_data;
  logic [DATA_WIDTH/8-1:0] w_strb;
  logic                    w_last;
  logic                    w_valid;
  logic                    w_ready;

  logic [ID_WIDTH-1:0] b_id;
  logic [1:0]          b_resp;
  logic                b_valid;
  logic                b_ready;

  logic [ID_WIDTH-1:0]   ar_id;
  logic [ADDR_WIDTH-1:0] ar_addr;
  logic [7:0]            ar_len;
  logic [2:0]            ar_size;
  logic [1:0]            ar_burst;
  logic [2:0]            ar_prot;
  logic [3:0]            ar_cache;
  logic [3:0]            ar_qos;
  logic                  ar_valid;
  logic                  ar_ready;

  logic [ID_WIDTH-1:0] r_id;
  logic [DATA_WIDTH-1:0] r_data;
  logic [1:0]             r_resp;
  logic                   r_last;
  logic                   r_valid;
  logic                   r_ready;

  modport master (
    output aw_id, aw_addr, aw_len, aw_size, aw_burst, aw_prot, aw_cache,
           aw_qos, aw_valid,
    input  aw_ready,
    output w_data, w_strb, w_last, w_valid,
    input  w_ready,
    input  b_id, b_resp, b_valid,
    output b_ready,
    output ar_id, ar_addr, ar_len, ar_size, ar_burst, ar_prot, ar_cache,
           ar_qos, ar_valid,
    input  ar_ready,
    input  r_id, r_data, r_resp, r_last, r_valid,
    output r_ready
  );

  modport slave (
    input  aw_id, aw_addr, aw_len, aw_size, aw_burst, aw_prot, aw_cache,
           aw_qos, aw_valid,
    output aw_ready,
    input  w_data, w_strb, w_last, w_valid,
    output w_ready,
    output b_id, b_resp, b_valid,
    input  b_ready,
    input  ar_id, ar_addr, ar_len, ar_size, ar_burst, ar_prot, ar_cache,
           ar_qos, ar_valid,
    output ar_ready,
    output r_id, r_data, r_resp, r_last, r_valid,
    input  r_ready
  );

`ifndef SYNTHESIS
  property p_aw_stable_when_stalled;
    @(posedge clk_i) disable iff (!rst_ni)
      aw_valid && !aw_ready |=> aw_valid &&
      $stable({aw_id, aw_addr, aw_len, aw_size, aw_burst, aw_prot,
               aw_cache, aw_qos});
  endproperty
  assert property (p_aw_stable_when_stalled);

  property p_w_stable_when_stalled;
    @(posedge clk_i) disable iff (!rst_ni)
      w_valid && !w_ready |=> w_valid && $stable({w_data, w_strb, w_last});
  endproperty
  assert property (p_w_stable_when_stalled);

  property p_ar_stable_when_stalled;
    @(posedge clk_i) disable iff (!rst_ni)
      ar_valid && !ar_ready |=> ar_valid &&
      $stable({ar_id, ar_addr, ar_len, ar_size, ar_burst, ar_prot,
               ar_cache, ar_qos});
  endproperty
  assert property (p_ar_stable_when_stalled);

  property p_b_stable_when_stalled;
    @(posedge clk_i) disable iff (!rst_ni)
      b_valid && !b_ready |=> b_valid && $stable({b_id, b_resp});
  endproperty
  assert property (p_b_stable_when_stalled);

  property p_r_stable_when_stalled;
    @(posedge clk_i) disable iff (!rst_ni)
      r_valid && !r_ready |=> r_valid &&
      $stable({r_id, r_data, r_resp, r_last});
  endproperty
  assert property (p_r_stable_when_stalled);
`endif

endinterface
