module rv_frontend #(
  parameter int unsigned XLEN          = 32,
  parameter int unsigned PADDR_WIDTH   = 32,
  parameter int unsigned FETCH_BYTES   = 16,
  parameter logic [XLEN-1:0] RESET_VECTOR = 'h8000_0000
) (
  input  logic                                  clk_i,
  input  logic                                  rst_ni,
  input  logic                                  redirect_valid_i,
  input  logic [XLEN-1:0]                       redirect_pc_i,

  output logic [1:0]                            fetch_valid_o,
  input  logic [1:0]                            fetch_ready_i,
  output logic [1:0][XLEN-1:0]                  fetch_pc_o,
  output logic [1:0][31:0]                      fetch_instr_o,
  output rv_ooo_pkg::inst_len_e [1:0]           fetch_inst_len_o,
  output rv_ooo_pkg::prediction_meta_t [1:0]    fetch_prediction_o,
  output logic [1:0]                            fetch_fault_o,

  output logic                                  imem_req_valid_o,
  input  logic                                  imem_req_ready_i,
  output logic [PADDR_WIDTH-1:0]                imem_req_addr_o,
  output logic [3:0]                            imem_req_id_o,
  output logic [3:0]                            imem_req_epoch_o,
  input  logic                                  imem_rsp_valid_i,
  output logic                                  imem_rsp_ready_o,
  input  logic [3:0]                            imem_rsp_id_i,
  input  logic [3:0]                            imem_rsp_epoch_i,
  input  logic [FETCH_BYTES*8-1:0]              imem_rsp_data_i,
  input  logic [1:0]                            imem_rsp_resp_i
);

  // M0 architecture shell. Fetch queue, branch predictor, and C aligner are
  // implemented in M1/M3. Keeping every output inactive makes the incomplete
  // state explicit and prevents accidental execution before those blocks exist.
  always_comb begin
    fetch_valid_o      = '0;
    fetch_pc_o         = '0;
    fetch_instr_o      = '0;
    fetch_inst_len_o   = '0;
    fetch_prediction_o = '0;
    fetch_fault_o      = '0;
    imem_req_valid_o   = 1'b0;
    imem_req_addr_o    = RESET_VECTOR;
    imem_req_id_o      = '0;
    imem_req_epoch_o   = '0;
    imem_rsp_ready_o   = 1'b0;
  end

  logic unused_inputs;
  always_comb begin
    unused_inputs = clk_i ^ rst_ni ^ redirect_valid_i ^ (^redirect_pc_i) ^
                    (^fetch_ready_i) ^ imem_req_ready_i ^ imem_rsp_valid_i ^
                    (^imem_rsp_id_i) ^ (^imem_rsp_epoch_i) ^
                    (^imem_rsp_data_i) ^ (^imem_rsp_resp_i);
  end

endmodule
