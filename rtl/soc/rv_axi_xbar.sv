module rv_axi_xbar #(
  parameter int unsigned LOCAL_ID_WIDTH = 4,
  parameter int unsigned XBAR_ID_WIDTH  = LOCAL_ID_WIDTH + 2,
  parameter logic [31:0] BOOTROM_BASE_ADDR = rv_soc_pkg::BOOTROM_BASE_ADDR,
  parameter int unsigned BOOTROM_SIZE_KB   = rv_soc_pkg::BOOTROM_SIZE_KB,
  parameter logic [31:0] CLINT_BASE_ADDR   = rv_soc_pkg::CLINT_BASE_ADDR,
  parameter int unsigned CLINT_SIZE_KB     = rv_soc_pkg::CLINT_SIZE_KB,
  parameter logic [31:0] PLIC_BASE_ADDR    = rv_soc_pkg::PLIC_BASE_ADDR,
  parameter int unsigned PLIC_SIZE_KB      = rv_soc_pkg::PLIC_SIZE_KB,
  parameter logic [31:0] HOSTIF_BASE_ADDR  = rv_soc_pkg::HOSTIF_BASE_ADDR,
  parameter int unsigned HOSTIF_SIZE_KB    = rv_soc_pkg::HOSTIF_SIZE_KB,
  parameter logic [31:0] ITIM_BASE_ADDR    = rv_soc_pkg::ITIM_BASE_ADDR,
  parameter int unsigned ITIM_SIZE_KB      = rv_soc_pkg::ITIM_SIZE_KB,
  parameter logic [31:0] DTIM_BASE_ADDR    = rv_soc_pkg::DTIM_BASE_ADDR,
  parameter int unsigned DTIM_SIZE_KB      = rv_soc_pkg::DTIM_SIZE_KB
) (
  input  logic       clk_i,
  input  logic       rst_ni,
  rv_axi4_if.slave   m0_s,
  rv_axi4_if.slave   m1_s,
  rv_axi4_if.slave   m2_s,
  rv_axi4_if.master  s0_m,
  rv_axi4_if.master  s1_m,
  rv_axi4_if.master  s2_m,
  rv_axi4_if.master  s3_m,
  rv_axi4_if.master  s4_m,
  rv_axi4_if.master  s5_m
);

  import rv_soc_pkg::*;

  localparam int unsigned MASTER_COUNT = 3;
  localparam int unsigned SLAVE_COUNT  = 6;

  logic [MASTER_COUNT-1:0] m_aw_valid;
  logic [MASTER_COUNT-1:0] m_aw_ready;
  logic [MASTER_COUNT-1:0][LOCAL_ID_WIDTH-1:0] m_aw_id;
  logic [MASTER_COUNT-1:0][31:0] m_aw_addr;
  logic [MASTER_COUNT-1:0][7:0] m_aw_len;
  logic [MASTER_COUNT-1:0][2:0] m_aw_size;
  logic [MASTER_COUNT-1:0][1:0] m_aw_burst;
  logic [MASTER_COUNT-1:0][2:0] m_aw_prot;
  logic [MASTER_COUNT-1:0][3:0] m_aw_cache;
  logic [MASTER_COUNT-1:0][3:0] m_aw_qos;
  logic [MASTER_COUNT-1:0] m_w_valid;
  logic [MASTER_COUNT-1:0] m_w_ready;
  logic [MASTER_COUNT-1:0][63:0] m_w_data;
  logic [MASTER_COUNT-1:0][7:0] m_w_strb;
  logic [MASTER_COUNT-1:0] m_w_last;
  logic [MASTER_COUNT-1:0] m_b_valid;
  logic [MASTER_COUNT-1:0] m_b_ready;
  logic [MASTER_COUNT-1:0][LOCAL_ID_WIDTH-1:0] m_b_id;
  logic [MASTER_COUNT-1:0][1:0] m_b_resp;
  logic [MASTER_COUNT-1:0] m_ar_valid;
  logic [MASTER_COUNT-1:0] m_ar_ready;
  logic [MASTER_COUNT-1:0][LOCAL_ID_WIDTH-1:0] m_ar_id;
  logic [MASTER_COUNT-1:0][31:0] m_ar_addr;
  logic [MASTER_COUNT-1:0][7:0] m_ar_len;
  logic [MASTER_COUNT-1:0][2:0] m_ar_size;
  logic [MASTER_COUNT-1:0][1:0] m_ar_burst;
  logic [MASTER_COUNT-1:0][2:0] m_ar_prot;
  logic [MASTER_COUNT-1:0][3:0] m_ar_cache;
  logic [MASTER_COUNT-1:0][3:0] m_ar_qos;
  logic [MASTER_COUNT-1:0] m_r_valid;
  logic [MASTER_COUNT-1:0] m_r_ready;
  logic [MASTER_COUNT-1:0][LOCAL_ID_WIDTH-1:0] m_r_id;
  logic [MASTER_COUNT-1:0][63:0] m_r_data;
  logic [MASTER_COUNT-1:0][1:0] m_r_resp;
  logic [MASTER_COUNT-1:0] m_r_last;

  logic [SLAVE_COUNT-1:0] s_aw_valid;
  logic [SLAVE_COUNT-1:0] s_aw_ready;
  logic [SLAVE_COUNT-1:0][XBAR_ID_WIDTH-1:0] s_aw_id;
  logic [SLAVE_COUNT-1:0][31:0] s_aw_addr;
  logic [SLAVE_COUNT-1:0][7:0] s_aw_len;
  logic [SLAVE_COUNT-1:0][2:0] s_aw_size;
  logic [SLAVE_COUNT-1:0][1:0] s_aw_burst;
  logic [SLAVE_COUNT-1:0][2:0] s_aw_prot;
  logic [SLAVE_COUNT-1:0][3:0] s_aw_cache;
  logic [SLAVE_COUNT-1:0][3:0] s_aw_qos;
  logic [SLAVE_COUNT-1:0] s_w_valid;
  logic [SLAVE_COUNT-1:0] s_w_ready;
  logic [SLAVE_COUNT-1:0][63:0] s_w_data;
  logic [SLAVE_COUNT-1:0][7:0] s_w_strb;
  logic [SLAVE_COUNT-1:0] s_w_last;
  logic [SLAVE_COUNT-1:0] s_b_valid;
  logic [SLAVE_COUNT-1:0] s_b_ready;
  logic [SLAVE_COUNT-1:0][XBAR_ID_WIDTH-1:0] s_b_id;
  logic [SLAVE_COUNT-1:0][1:0] s_b_resp;
  logic [SLAVE_COUNT-1:0] s_ar_valid;
  logic [SLAVE_COUNT-1:0] s_ar_ready;
  logic [SLAVE_COUNT-1:0][XBAR_ID_WIDTH-1:0] s_ar_id;
  logic [SLAVE_COUNT-1:0][31:0] s_ar_addr;
  logic [SLAVE_COUNT-1:0][7:0] s_ar_len;
  logic [SLAVE_COUNT-1:0][2:0] s_ar_size;
  logic [SLAVE_COUNT-1:0][1:0] s_ar_burst;
  logic [SLAVE_COUNT-1:0][2:0] s_ar_prot;
  logic [SLAVE_COUNT-1:0][3:0] s_ar_cache;
  logic [SLAVE_COUNT-1:0][3:0] s_ar_qos;
  logic [SLAVE_COUNT-1:0] s_r_valid;
  logic [SLAVE_COUNT-1:0] s_r_ready;
  logic [SLAVE_COUNT-1:0][XBAR_ID_WIDTH-1:0] s_r_id;
  logic [SLAVE_COUNT-1:0][63:0] s_r_data;
  logic [SLAVE_COUNT-1:0][1:0] s_r_resp;
  logic [SLAVE_COUNT-1:0] s_r_last;

  soc_target_e [MASTER_COUNT-1:0] aw_target;
  soc_target_e [MASTER_COUNT-1:0] ar_target;
  logic [SLAVE_COUNT-1:0][MASTER_COUNT-1:0] aw_candidate;
  logic [SLAVE_COUNT-1:0][MASTER_COUNT-1:0] ar_candidate;
  logic [SLAVE_COUNT-1:0] aw_grant;
  logic [SLAVE_COUNT-1:0][1:0] aw_owner;
  logic [SLAVE_COUNT-1:0] ar_grant;
  logic [SLAVE_COUNT-1:0][1:0] ar_owner;
  logic [SLAVE_COUNT-1:0][1:0] aw_rr_q;
  logic [SLAVE_COUNT-1:0][1:0] ar_rr_q;
  logic [SLAVE_COUNT-1:0] write_data_active_q;
  logic [SLAVE_COUNT-1:0][1:0] write_owner_q;
  logic [MASTER_COUNT-1:0] master_write_busy_q;
  logic [MASTER_COUNT-1:0] master_read_busy_q;
  soc_target_e [MASTER_COUNT-1:0] master_write_target_q;
  soc_target_e [MASTER_COUNT-1:0] master_read_target_q;
  logic [MASTER_COUNT-1:0] b_selected;
  logic [MASTER_COUNT-1:0] r_selected;
  logic [MASTER_COUNT-1:0] b_handshake;
  logic [MASTER_COUNT-1:0] r_last_handshake;

  function automatic soc_target_e decode_address(input logic [31:0] address);
    if (addr_in_region(address, ITIM_BASE_ADDR,
                       size_kb_to_bytes(ITIM_SIZE_KB)) ||
        addr_in_region(address, BOOTROM_BASE_ADDR,
                       size_kb_to_bytes(BOOTROM_SIZE_KB)))
      return SOC_TARGET_I_LOCAL;
    if (addr_in_region(address, DTIM_BASE_ADDR,
                       size_kb_to_bytes(DTIM_SIZE_KB)) ||
        addr_in_region(address, CLINT_BASE_ADDR,
                       size_kb_to_bytes(CLINT_SIZE_KB)))
      return SOC_TARGET_D_LOCAL;
    if (addr_in_region(address, PLIC_BASE_ADDR,
                       size_kb_to_bytes(PLIC_SIZE_KB)))
      return SOC_TARGET_PLIC;
    if (addr_in_region(address, HOSTIF_BASE_ADDR,
                       size_kb_to_bytes(HOSTIF_SIZE_KB)))
      return SOC_TARGET_HOSTIF;
    return SOC_TARGET_ERROR;
  endfunction

  function automatic soc_target_e decode_burst(
    input logic [31:0] address,
    input logic [7:0] length,
    input logic [2:0] size,
    input logic [1:0] burst
  );
    logic [63:0] last_byte;
    soc_target_e first_target;
    soc_target_e last_target;
    if ((size > 3) || (length >= 16) || (burst != 2'b01))
      return SOC_TARGET_ERROR;
    last_byte = {32'b0, address} +
                ((64'(length) + 1'b1) << size) - 1'b1;
    if (last_byte[63:32] != 0)
      return SOC_TARGET_ERROR;
    first_target = decode_address(address);
    last_target  = decode_address(last_byte[31:0]);
    if ((first_target == SOC_TARGET_ERROR) ||
        (first_target != last_target))
      return SOC_TARGET_ERROR;
    return first_target;
  endfunction

  function automatic logic [XBAR_ID_WIDTH-1:0] prefix_id(
    input logic [1:0] master,
    input logic [LOCAL_ID_WIDTH-1:0] local_id
  );
    logic [XBAR_ID_WIDTH-1:0] result;
    result = '0;
    result[LOCAL_ID_WIDTH-1:0] = local_id;
    result[LOCAL_ID_WIDTH +: 2] = master;
    return result;
  endfunction

  function automatic logic [1:0] response_owner(
    input logic [XBAR_ID_WIDTH-1:0] response_id
  );
    return response_id[LOCAL_ID_WIDTH +: 2];
  endfunction

  function automatic logic [LOCAL_ID_WIDTH-1:0] unprefix_id(
    input logic [XBAR_ID_WIDTH-1:0] response_id
  );
    return response_id[LOCAL_ID_WIDTH-1:0];
  endfunction

  function automatic logic [1:0] next_master(input logic [1:0] master);
    return (master == 2) ? 0 : master + 1'b1;
  endfunction

  // Master-side interface unpack/pack.
  always_comb begin
    m_aw_valid = {m2_s.aw_valid, m1_s.aw_valid, m0_s.aw_valid};
    m_aw_id[0] = m0_s.aw_id; m_aw_id[1] = m1_s.aw_id; m_aw_id[2] = m2_s.aw_id;
    m_aw_addr[0] = m0_s.aw_addr; m_aw_addr[1] = m1_s.aw_addr; m_aw_addr[2] = m2_s.aw_addr;
    m_aw_len[0] = m0_s.aw_len; m_aw_len[1] = m1_s.aw_len; m_aw_len[2] = m2_s.aw_len;
    m_aw_size[0] = m0_s.aw_size; m_aw_size[1] = m1_s.aw_size; m_aw_size[2] = m2_s.aw_size;
    m_aw_burst[0] = m0_s.aw_burst; m_aw_burst[1] = m1_s.aw_burst; m_aw_burst[2] = m2_s.aw_burst;
    m_aw_prot[0] = m0_s.aw_prot; m_aw_prot[1] = m1_s.aw_prot; m_aw_prot[2] = m2_s.aw_prot;
    m_aw_cache[0] = m0_s.aw_cache; m_aw_cache[1] = m1_s.aw_cache; m_aw_cache[2] = m2_s.aw_cache;
    m_aw_qos[0] = m0_s.aw_qos; m_aw_qos[1] = m1_s.aw_qos; m_aw_qos[2] = m2_s.aw_qos;
    m_w_valid = {m2_s.w_valid, m1_s.w_valid, m0_s.w_valid};
    m_w_data[0] = m0_s.w_data; m_w_data[1] = m1_s.w_data; m_w_data[2] = m2_s.w_data;
    m_w_strb[0] = m0_s.w_strb; m_w_strb[1] = m1_s.w_strb; m_w_strb[2] = m2_s.w_strb;
    m_w_last = {m2_s.w_last, m1_s.w_last, m0_s.w_last};
    m_b_ready = {m2_s.b_ready, m1_s.b_ready, m0_s.b_ready};
    m_ar_valid = {m2_s.ar_valid, m1_s.ar_valid, m0_s.ar_valid};
    m_ar_id[0] = m0_s.ar_id; m_ar_id[1] = m1_s.ar_id; m_ar_id[2] = m2_s.ar_id;
    m_ar_addr[0] = m0_s.ar_addr; m_ar_addr[1] = m1_s.ar_addr; m_ar_addr[2] = m2_s.ar_addr;
    m_ar_len[0] = m0_s.ar_len; m_ar_len[1] = m1_s.ar_len; m_ar_len[2] = m2_s.ar_len;
    m_ar_size[0] = m0_s.ar_size; m_ar_size[1] = m1_s.ar_size; m_ar_size[2] = m2_s.ar_size;
    m_ar_burst[0] = m0_s.ar_burst; m_ar_burst[1] = m1_s.ar_burst; m_ar_burst[2] = m2_s.ar_burst;
    m_ar_prot[0] = m0_s.ar_prot; m_ar_prot[1] = m1_s.ar_prot; m_ar_prot[2] = m2_s.ar_prot;
    m_ar_cache[0] = m0_s.ar_cache; m_ar_cache[1] = m1_s.ar_cache; m_ar_cache[2] = m2_s.ar_cache;
    m_ar_qos[0] = m0_s.ar_qos; m_ar_qos[1] = m1_s.ar_qos; m_ar_qos[2] = m2_s.ar_qos;
    m_r_ready = {m2_s.r_ready, m1_s.r_ready, m0_s.r_ready};

    m0_s.aw_ready = m_aw_ready[0]; m1_s.aw_ready = m_aw_ready[1]; m2_s.aw_ready = m_aw_ready[2];
    m0_s.w_ready = m_w_ready[0]; m1_s.w_ready = m_w_ready[1]; m2_s.w_ready = m_w_ready[2];
    m0_s.b_valid = m_b_valid[0]; m1_s.b_valid = m_b_valid[1]; m2_s.b_valid = m_b_valid[2];
    m0_s.b_id = m_b_id[0]; m1_s.b_id = m_b_id[1]; m2_s.b_id = m_b_id[2];
    m0_s.b_resp = m_b_resp[0]; m1_s.b_resp = m_b_resp[1]; m2_s.b_resp = m_b_resp[2];
    m0_s.ar_ready = m_ar_ready[0]; m1_s.ar_ready = m_ar_ready[1]; m2_s.ar_ready = m_ar_ready[2];
    m0_s.r_valid = m_r_valid[0]; m1_s.r_valid = m_r_valid[1]; m2_s.r_valid = m_r_valid[2];
    m0_s.r_id = m_r_id[0]; m1_s.r_id = m_r_id[1]; m2_s.r_id = m_r_id[2];
    m0_s.r_data = m_r_data[0]; m1_s.r_data = m_r_data[1]; m2_s.r_data = m_r_data[2];
    m0_s.r_resp = m_r_resp[0]; m1_s.r_resp = m_r_resp[1]; m2_s.r_resp = m_r_resp[2];
    m0_s.r_last = m_r_last[0]; m1_s.r_last = m_r_last[1]; m2_s.r_last = m_r_last[2];
  end

  // Slave-side interface pack/unpack.
  always_comb begin
    s_aw_ready = {s5_m.aw_ready, s4_m.aw_ready, s3_m.aw_ready,
                  s2_m.aw_ready, s1_m.aw_ready, s0_m.aw_ready};
    s_w_ready = {s5_m.w_ready, s4_m.w_ready, s3_m.w_ready,
                 s2_m.w_ready, s1_m.w_ready, s0_m.w_ready};
    s_b_valid = {s5_m.b_valid, s4_m.b_valid, s3_m.b_valid,
                 s2_m.b_valid, s1_m.b_valid, s0_m.b_valid};
    s_b_id[0]=s0_m.b_id; s_b_id[1]=s1_m.b_id; s_b_id[2]=s2_m.b_id;
    s_b_id[3]=s3_m.b_id; s_b_id[4]=s4_m.b_id; s_b_id[5]=s5_m.b_id;
    s_b_resp[0]=s0_m.b_resp; s_b_resp[1]=s1_m.b_resp; s_b_resp[2]=s2_m.b_resp;
    s_b_resp[3]=s3_m.b_resp; s_b_resp[4]=s4_m.b_resp; s_b_resp[5]=s5_m.b_resp;
    s_ar_ready = {s5_m.ar_ready, s4_m.ar_ready, s3_m.ar_ready,
                  s2_m.ar_ready, s1_m.ar_ready, s0_m.ar_ready};
    s_r_valid = {s5_m.r_valid, s4_m.r_valid, s3_m.r_valid,
                 s2_m.r_valid, s1_m.r_valid, s0_m.r_valid};
    s_r_id[0]=s0_m.r_id; s_r_id[1]=s1_m.r_id; s_r_id[2]=s2_m.r_id;
    s_r_id[3]=s3_m.r_id; s_r_id[4]=s4_m.r_id; s_r_id[5]=s5_m.r_id;
    s_r_data[0]=s0_m.r_data; s_r_data[1]=s1_m.r_data; s_r_data[2]=s2_m.r_data;
    s_r_data[3]=s3_m.r_data; s_r_data[4]=s4_m.r_data; s_r_data[5]=s5_m.r_data;
    s_r_resp[0]=s0_m.r_resp; s_r_resp[1]=s1_m.r_resp; s_r_resp[2]=s2_m.r_resp;
    s_r_resp[3]=s3_m.r_resp; s_r_resp[4]=s4_m.r_resp; s_r_resp[5]=s5_m.r_resp;
    s_r_last = {s5_m.r_last, s4_m.r_last, s3_m.r_last,
                s2_m.r_last, s1_m.r_last, s0_m.r_last};

    s0_m.aw_id=s_aw_id[0]; s1_m.aw_id=s_aw_id[1]; s2_m.aw_id=s_aw_id[2]; s3_m.aw_id=s_aw_id[3]; s4_m.aw_id=s_aw_id[4]; s5_m.aw_id=s_aw_id[5];
    s0_m.aw_addr=s_aw_addr[0]; s1_m.aw_addr=s_aw_addr[1]; s2_m.aw_addr=s_aw_addr[2]; s3_m.aw_addr=s_aw_addr[3]; s4_m.aw_addr=s_aw_addr[4]; s5_m.aw_addr=s_aw_addr[5];
    s0_m.aw_len=s_aw_len[0]; s1_m.aw_len=s_aw_len[1]; s2_m.aw_len=s_aw_len[2]; s3_m.aw_len=s_aw_len[3]; s4_m.aw_len=s_aw_len[4]; s5_m.aw_len=s_aw_len[5];
    s0_m.aw_size=s_aw_size[0]; s1_m.aw_size=s_aw_size[1]; s2_m.aw_size=s_aw_size[2]; s3_m.aw_size=s_aw_size[3]; s4_m.aw_size=s_aw_size[4]; s5_m.aw_size=s_aw_size[5];
    s0_m.aw_burst=s_aw_burst[0]; s1_m.aw_burst=s_aw_burst[1]; s2_m.aw_burst=s_aw_burst[2]; s3_m.aw_burst=s_aw_burst[3]; s4_m.aw_burst=s_aw_burst[4]; s5_m.aw_burst=s_aw_burst[5];
    s0_m.aw_prot=s_aw_prot[0]; s1_m.aw_prot=s_aw_prot[1]; s2_m.aw_prot=s_aw_prot[2]; s3_m.aw_prot=s_aw_prot[3]; s4_m.aw_prot=s_aw_prot[4]; s5_m.aw_prot=s_aw_prot[5];
    s0_m.aw_cache=s_aw_cache[0]; s1_m.aw_cache=s_aw_cache[1]; s2_m.aw_cache=s_aw_cache[2]; s3_m.aw_cache=s_aw_cache[3]; s4_m.aw_cache=s_aw_cache[4]; s5_m.aw_cache=s_aw_cache[5];
    s0_m.aw_qos=s_aw_qos[0]; s1_m.aw_qos=s_aw_qos[1]; s2_m.aw_qos=s_aw_qos[2]; s3_m.aw_qos=s_aw_qos[3]; s4_m.aw_qos=s_aw_qos[4]; s5_m.aw_qos=s_aw_qos[5];
    s0_m.aw_valid=s_aw_valid[0]; s1_m.aw_valid=s_aw_valid[1]; s2_m.aw_valid=s_aw_valid[2]; s3_m.aw_valid=s_aw_valid[3]; s4_m.aw_valid=s_aw_valid[4]; s5_m.aw_valid=s_aw_valid[5];
    s0_m.w_data=s_w_data[0]; s1_m.w_data=s_w_data[1]; s2_m.w_data=s_w_data[2]; s3_m.w_data=s_w_data[3]; s4_m.w_data=s_w_data[4]; s5_m.w_data=s_w_data[5];
    s0_m.w_strb=s_w_strb[0]; s1_m.w_strb=s_w_strb[1]; s2_m.w_strb=s_w_strb[2]; s3_m.w_strb=s_w_strb[3]; s4_m.w_strb=s_w_strb[4]; s5_m.w_strb=s_w_strb[5];
    s0_m.w_last=s_w_last[0]; s1_m.w_last=s_w_last[1]; s2_m.w_last=s_w_last[2]; s3_m.w_last=s_w_last[3]; s4_m.w_last=s_w_last[4]; s5_m.w_last=s_w_last[5];
    s0_m.w_valid=s_w_valid[0]; s1_m.w_valid=s_w_valid[1]; s2_m.w_valid=s_w_valid[2]; s3_m.w_valid=s_w_valid[3]; s4_m.w_valid=s_w_valid[4]; s5_m.w_valid=s_w_valid[5];
    s0_m.b_ready=s_b_ready[0]; s1_m.b_ready=s_b_ready[1]; s2_m.b_ready=s_b_ready[2]; s3_m.b_ready=s_b_ready[3]; s4_m.b_ready=s_b_ready[4]; s5_m.b_ready=s_b_ready[5];
    s0_m.ar_id=s_ar_id[0]; s1_m.ar_id=s_ar_id[1]; s2_m.ar_id=s_ar_id[2]; s3_m.ar_id=s_ar_id[3]; s4_m.ar_id=s_ar_id[4]; s5_m.ar_id=s_ar_id[5];
    s0_m.ar_addr=s_ar_addr[0]; s1_m.ar_addr=s_ar_addr[1]; s2_m.ar_addr=s_ar_addr[2]; s3_m.ar_addr=s_ar_addr[3]; s4_m.ar_addr=s_ar_addr[4]; s5_m.ar_addr=s_ar_addr[5];
    s0_m.ar_len=s_ar_len[0]; s1_m.ar_len=s_ar_len[1]; s2_m.ar_len=s_ar_len[2]; s3_m.ar_len=s_ar_len[3]; s4_m.ar_len=s_ar_len[4]; s5_m.ar_len=s_ar_len[5];
    s0_m.ar_size=s_ar_size[0]; s1_m.ar_size=s_ar_size[1]; s2_m.ar_size=s_ar_size[2]; s3_m.ar_size=s_ar_size[3]; s4_m.ar_size=s_ar_size[4]; s5_m.ar_size=s_ar_size[5];
    s0_m.ar_burst=s_ar_burst[0]; s1_m.ar_burst=s_ar_burst[1]; s2_m.ar_burst=s_ar_burst[2]; s3_m.ar_burst=s_ar_burst[3]; s4_m.ar_burst=s_ar_burst[4]; s5_m.ar_burst=s_ar_burst[5];
    s0_m.ar_prot=s_ar_prot[0]; s1_m.ar_prot=s_ar_prot[1]; s2_m.ar_prot=s_ar_prot[2]; s3_m.ar_prot=s_ar_prot[3]; s4_m.ar_prot=s_ar_prot[4]; s5_m.ar_prot=s_ar_prot[5];
    s0_m.ar_cache=s_ar_cache[0]; s1_m.ar_cache=s_ar_cache[1]; s2_m.ar_cache=s_ar_cache[2]; s3_m.ar_cache=s_ar_cache[3]; s4_m.ar_cache=s_ar_cache[4]; s5_m.ar_cache=s_ar_cache[5];
    s0_m.ar_qos=s_ar_qos[0]; s1_m.ar_qos=s_ar_qos[1]; s2_m.ar_qos=s_ar_qos[2]; s3_m.ar_qos=s_ar_qos[3]; s4_m.ar_qos=s_ar_qos[4]; s5_m.ar_qos=s_ar_qos[5];
    s0_m.ar_valid=s_ar_valid[0]; s1_m.ar_valid=s_ar_valid[1]; s2_m.ar_valid=s_ar_valid[2]; s3_m.ar_valid=s_ar_valid[3]; s4_m.ar_valid=s_ar_valid[4]; s5_m.ar_valid=s_ar_valid[5];
    s0_m.r_ready=s_r_ready[0]; s1_m.r_ready=s_r_ready[1]; s2_m.r_ready=s_r_ready[2]; s3_m.r_ready=s_r_ready[3]; s4_m.r_ready=s_r_ready[4]; s5_m.r_ready=s_r_ready[5];
  end

  always_comb begin
    for (int unsigned master = 0; master < MASTER_COUNT; master++) begin
      aw_target[master] = decode_burst(m_aw_addr[master], m_aw_len[master],
                                        m_aw_size[master], m_aw_burst[master]);
      ar_target[master] = decode_burst(m_ar_addr[master], m_ar_len[master],
                                        m_ar_size[master], m_ar_burst[master]);
    end
    for (int unsigned slave = 0; slave < SLAVE_COUNT; slave++) begin
      for (int unsigned master = 0; master < MASTER_COUNT; master++) begin
        aw_candidate[slave][master] = m_aw_valid[master] &&
          !master_write_busy_q[master] &&
          (aw_target[master] == soc_target_e'(slave));
        ar_candidate[slave][master] = m_ar_valid[master] &&
          !master_read_busy_q[master] &&
          (ar_target[master] == soc_target_e'(slave));
      end
    end
  end

  always_comb begin
    aw_grant = '0; aw_owner = '0; ar_grant = '0; ar_owner = '0;
    for (int unsigned slave = 0; slave < SLAVE_COUNT; slave++) begin
      if (!write_data_active_q[slave]) begin
        case (aw_rr_q[slave])
          0: begin
            if (aw_candidate[slave][0]) begin aw_grant[slave]=1; aw_owner[slave]=0; end
            else if (aw_candidate[slave][1]) begin aw_grant[slave]=1; aw_owner[slave]=1; end
            else if (aw_candidate[slave][2]) begin aw_grant[slave]=1; aw_owner[slave]=2; end
          end
          1: begin
            if (aw_candidate[slave][1]) begin aw_grant[slave]=1; aw_owner[slave]=1; end
            else if (aw_candidate[slave][2]) begin aw_grant[slave]=1; aw_owner[slave]=2; end
            else if (aw_candidate[slave][0]) begin aw_grant[slave]=1; aw_owner[slave]=0; end
          end
          default: begin
            if (aw_candidate[slave][2]) begin aw_grant[slave]=1; aw_owner[slave]=2; end
            else if (aw_candidate[slave][0]) begin aw_grant[slave]=1; aw_owner[slave]=0; end
            else if (aw_candidate[slave][1]) begin aw_grant[slave]=1; aw_owner[slave]=1; end
          end
        endcase
      end
      case (ar_rr_q[slave])
        0: begin
          if (ar_candidate[slave][0]) begin ar_grant[slave]=1; ar_owner[slave]=0; end
          else if (ar_candidate[slave][1]) begin ar_grant[slave]=1; ar_owner[slave]=1; end
          else if (ar_candidate[slave][2]) begin ar_grant[slave]=1; ar_owner[slave]=2; end
        end
        1: begin
          if (ar_candidate[slave][1]) begin ar_grant[slave]=1; ar_owner[slave]=1; end
          else if (ar_candidate[slave][2]) begin ar_grant[slave]=1; ar_owner[slave]=2; end
          else if (ar_candidate[slave][0]) begin ar_grant[slave]=1; ar_owner[slave]=0; end
        end
        default: begin
          if (ar_candidate[slave][2]) begin ar_grant[slave]=1; ar_owner[slave]=2; end
          else if (ar_candidate[slave][0]) begin ar_grant[slave]=1; ar_owner[slave]=0; end
          else if (ar_candidate[slave][1]) begin ar_grant[slave]=1; ar_owner[slave]=1; end
        end
      endcase
    end
  end

  always_comb begin
    m_aw_ready='0; m_w_ready='0; m_b_valid='0; m_b_id='0; m_b_resp='0;
    m_ar_ready='0; m_r_valid='0; m_r_id='0; m_r_data='0; m_r_resp='0; m_r_last='0;
    s_aw_valid='0; s_aw_id='0; s_aw_addr='0; s_aw_len='0; s_aw_size='0; s_aw_burst='0; s_aw_prot='0; s_aw_cache='0; s_aw_qos='0;
    s_w_valid='0; s_w_data='0; s_w_strb='0; s_w_last='0; s_b_ready='0;
    s_ar_valid='0; s_ar_id='0; s_ar_addr='0; s_ar_len='0; s_ar_size='0; s_ar_burst='0; s_ar_prot='0; s_ar_cache='0; s_ar_qos='0; s_r_ready='0;
    b_selected='0; r_selected='0; b_handshake='0; r_last_handshake='0;

    for (int unsigned slave = 0; slave < SLAVE_COUNT; slave++) begin
      if (aw_grant[slave]) begin
        s_aw_valid[slave] = 1'b1;
        s_aw_id[slave] = prefix_id(aw_owner[slave], m_aw_id[aw_owner[slave]]);
        s_aw_addr[slave]=m_aw_addr[aw_owner[slave]]; s_aw_len[slave]=m_aw_len[aw_owner[slave]];
        s_aw_size[slave]=m_aw_size[aw_owner[slave]]; s_aw_burst[slave]=m_aw_burst[aw_owner[slave]];
        s_aw_prot[slave]=m_aw_prot[aw_owner[slave]]; s_aw_cache[slave]=m_aw_cache[aw_owner[slave]]; s_aw_qos[slave]=m_aw_qos[aw_owner[slave]];
        m_aw_ready[aw_owner[slave]] = s_aw_ready[slave];
      end
      if (write_data_active_q[slave]) begin
        s_w_valid[slave] = m_w_valid[write_owner_q[slave]];
        s_w_data[slave]  = m_w_data[write_owner_q[slave]];
        s_w_strb[slave]  = m_w_strb[write_owner_q[slave]];
        s_w_last[slave]  = m_w_last[write_owner_q[slave]];
        m_w_ready[write_owner_q[slave]] = s_w_ready[slave];
      end
      if (ar_grant[slave]) begin
        s_ar_valid[slave] = 1'b1;
        s_ar_id[slave] = prefix_id(ar_owner[slave], m_ar_id[ar_owner[slave]]);
        s_ar_addr[slave]=m_ar_addr[ar_owner[slave]]; s_ar_len[slave]=m_ar_len[ar_owner[slave]];
        s_ar_size[slave]=m_ar_size[ar_owner[slave]]; s_ar_burst[slave]=m_ar_burst[ar_owner[slave]];
        s_ar_prot[slave]=m_ar_prot[ar_owner[slave]]; s_ar_cache[slave]=m_ar_cache[ar_owner[slave]]; s_ar_qos[slave]=m_ar_qos[ar_owner[slave]];
        m_ar_ready[ar_owner[slave]] = s_ar_ready[slave];
      end
    end

    for (int unsigned slave = 0; slave < SLAVE_COUNT; slave++) begin
      if (s_b_valid[slave]) begin
        if ((response_owner(s_b_id[slave]) < MASTER_COUNT) &&
            master_write_busy_q[response_owner(s_b_id[slave])] &&
            (master_write_target_q[response_owner(s_b_id[slave])] ==
             soc_target_e'(slave)) &&
            !b_selected[response_owner(s_b_id[slave])]) begin
          b_selected[response_owner(s_b_id[slave])] = 1'b1;
          m_b_valid[response_owner(s_b_id[slave])] = 1'b1;
          m_b_id[response_owner(s_b_id[slave])] = unprefix_id(s_b_id[slave]);
          m_b_resp[response_owner(s_b_id[slave])] = s_b_resp[slave];
          s_b_ready[slave] = m_b_ready[response_owner(s_b_id[slave])];
          b_handshake[response_owner(s_b_id[slave])] =
            s_b_ready[slave] && s_b_valid[slave];
        end else if (response_owner(s_b_id[slave]) >= MASTER_COUNT) begin
          s_b_ready[slave] = 1'b1;
        end
      end
      if (s_r_valid[slave]) begin
        if ((response_owner(s_r_id[slave]) < MASTER_COUNT) &&
            master_read_busy_q[response_owner(s_r_id[slave])] &&
            (master_read_target_q[response_owner(s_r_id[slave])] ==
             soc_target_e'(slave)) &&
            !r_selected[response_owner(s_r_id[slave])]) begin
          r_selected[response_owner(s_r_id[slave])] = 1'b1;
          m_r_valid[response_owner(s_r_id[slave])] = 1'b1;
          m_r_id[response_owner(s_r_id[slave])] = unprefix_id(s_r_id[slave]);
          m_r_data[response_owner(s_r_id[slave])] = s_r_data[slave];
          m_r_resp[response_owner(s_r_id[slave])] = s_r_resp[slave];
          m_r_last[response_owner(s_r_id[slave])] = s_r_last[slave];
          s_r_ready[slave] = m_r_ready[response_owner(s_r_id[slave])];
          r_last_handshake[response_owner(s_r_id[slave])] =
            s_r_ready[slave] && s_r_valid[slave] && s_r_last[slave];
        end else if (response_owner(s_r_id[slave]) >= MASTER_COUNT) begin
          s_r_ready[slave] = 1'b1;
        end
      end
    end
  end

  always_ff @(posedge clk_i) begin
    if (!rst_ni) begin
      aw_rr_q <= '0; ar_rr_q <= '0; write_data_active_q <= '0;
      write_owner_q <= '0; master_write_busy_q <= '0; master_read_busy_q <= '0;
      for (int unsigned master = 0; master < MASTER_COUNT; master++) begin
        master_write_target_q[master] <= SOC_TARGET_ERROR;
        master_read_target_q[master]  <= SOC_TARGET_ERROR;
      end
    end else begin
      for (int unsigned slave = 0; slave < SLAVE_COUNT; slave++) begin
        if (s_aw_valid[slave] && s_aw_ready[slave]) begin
          write_data_active_q[slave] <= 1'b1;
          write_owner_q[slave] <= aw_owner[slave];
          master_write_busy_q[aw_owner[slave]] <= 1'b1;
          master_write_target_q[aw_owner[slave]] <= soc_target_e'(slave);
          aw_rr_q[slave] <= next_master(aw_owner[slave]);
        end
        if (s_w_valid[slave] && s_w_ready[slave] && s_w_last[slave])
          write_data_active_q[slave] <= 1'b0;
        if (s_ar_valid[slave] && s_ar_ready[slave]) begin
          master_read_busy_q[ar_owner[slave]] <= 1'b1;
          master_read_target_q[ar_owner[slave]] <= soc_target_e'(slave);
          ar_rr_q[slave] <= next_master(ar_owner[slave]);
        end
      end
      for (int unsigned master = 0; master < MASTER_COUNT; master++) begin
        if (b_handshake[master])
          master_write_busy_q[master] <= 1'b0;
        if (r_last_handshake[master])
          master_read_busy_q[master] <= 1'b0;
      end
    end
  end

`ifndef SYNTHESIS
  for (genvar slave = 0; slave < SLAVE_COUNT; slave++) begin : g_xbar_assert
    property p_w_has_aw_owner;
      @(posedge clk_i) disable iff (!rst_ni)
        s_w_valid[slave] |-> write_data_active_q[slave];
    endproperty
    assert property (p_w_has_aw_owner);
  end

  for (genvar master = 0; master < MASTER_COUNT; master++) begin : g_master_assert
    property p_master_single_write;
      @(posedge clk_i) disable iff (!rst_ni)
        master_write_busy_q[master] |-> !m_aw_ready[master];
    endproperty
    assert property (p_master_single_write);

    property p_master_single_read;
      @(posedge clk_i) disable iff (!rst_ni)
        master_read_busy_q[master] |-> !m_ar_ready[master];
    endproperty
    assert property (p_master_single_read);
  end
`endif

  initial begin : p_parameter_checks
    if (XBAR_ID_WIDTH < (LOCAL_ID_WIDTH + 2))
      $fatal(1, "Xbar downstream ID must contain 2-bit master prefix");
  end

endmodule
