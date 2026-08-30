module rv_tim_2bank #(
  parameter int unsigned SIZE_KB    = 128,
  parameter int unsigned DATA_WIDTH = 64,
  parameter string INIT_FILE_BANK0  = "",
  parameter string INIT_FILE_BANK1  = "",
  localparam longint unsigned SIZE_BYTES = SIZE_KB * 1024,
  localparam int unsigned BANK_ROWS = SIZE_BYTES / (2 * (DATA_WIDTH/8)),
  localparam int unsigned ROW_WIDTH = $clog2(BANK_ROWS)
) (
  input  logic                              clk_i,
  input  logic                              rst_ni,
  input  logic [1:0]                        read_en_i,
  input  logic [1:0][ROW_WIDTH-1:0]         read_row_i,
  output logic [1:0]                        read_valid_o,
  output logic [1:0][DATA_WIDTH-1:0]        read_data_o,
  input  logic [1:0]                        write_en_i,
  input  logic [1:0][ROW_WIDTH-1:0]         write_row_i,
  input  logic [1:0][DATA_WIDTH-1:0]        write_data_i,
  input  logic [1:0][DATA_WIDTH/8-1:0]      write_strb_i
);

  rv_sram_1r1w #(
    .DATA_WIDTH (DATA_WIDTH),
    .DEPTH      (BANK_ROWS),
    .INIT_FILE  (INIT_FILE_BANK0)
  ) u_bank0 (
    .clk_i,
    .rst_ni,
    .read_en_i    (read_en_i[0]),
    .read_addr_i  (read_row_i[0]),
    .read_valid_o (read_valid_o[0]),
    .read_data_o  (read_data_o[0]),
    .write_en_i   (write_en_i[0]),
    .write_addr_i (write_row_i[0]),
    .write_data_i (write_data_i[0]),
    .write_strb_i (write_strb_i[0])
  );

  rv_sram_1r1w #(
    .DATA_WIDTH (DATA_WIDTH),
    .DEPTH      (BANK_ROWS),
    .INIT_FILE  (INIT_FILE_BANK1)
  ) u_bank1 (
    .clk_i,
    .rst_ni,
    .read_en_i    (read_en_i[1]),
    .read_addr_i  (read_row_i[1]),
    .read_valid_o (read_valid_o[1]),
    .read_data_o  (read_data_o[1]),
    .write_en_i   (write_en_i[1]),
    .write_addr_i (write_row_i[1]),
    .write_data_i (write_data_i[1]),
    .write_strb_i (write_strb_i[1])
  );

  initial begin : p_parameter_checks
    if ((SIZE_KB == 0) || (DATA_WIDTH != 64))
      $fatal(1, "TIM baseline requires nonzero SIZE_KB and 64-bit banks");
    if ((SIZE_BYTES % (2 * (DATA_WIDTH/8))) != 0)
      $fatal(1, "TIM size must divide evenly across two banks");
    if ((BANK_ROWS < 2) || ((BANK_ROWS & (BANK_ROWS-1)) != 0))
      $fatal(1, "TIM bank rows must be a power of two for offset slicing");
  end

endmodule
