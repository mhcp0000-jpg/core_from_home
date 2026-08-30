module rv_sram_1r1w #(
  parameter int unsigned DATA_WIDTH = 64,
  parameter int unsigned DEPTH      = 8192,
  parameter string INIT_FILE        = "",
  localparam int unsigned ADDR_WIDTH = $clog2(DEPTH)
) (
  input  logic                        clk_i,
  input  logic                        rst_ni,
  input  logic                        read_en_i,
  input  logic [ADDR_WIDTH-1:0]       read_addr_i,
  output logic                        read_valid_o,
  output logic [DATA_WIDTH-1:0]       read_data_o,
  input  logic                        write_en_i,
  input  logic [ADDR_WIDTH-1:0]       write_addr_i,
  input  logic [DATA_WIDTH-1:0]       write_data_i,
  input  logic [DATA_WIDTH/8-1:0]     write_strb_i
);

  logic [DATA_WIDTH-1:0] mem [0:DEPTH-1];

  function automatic logic [DATA_WIDTH-1:0] apply_write_strobe(
    input logic [DATA_WIDTH-1:0] old_data,
    input logic [DATA_WIDTH-1:0] new_data,
    input logic [DATA_WIDTH/8-1:0] write_strobe
  );
    logic [DATA_WIDTH-1:0] merged_data;
    merged_data = old_data;
    for (int unsigned byte_index = 0;
         byte_index < DATA_WIDTH/8; byte_index++) begin
      if (write_strobe[byte_index])
        merged_data[byte_index*8 +: 8] = new_data[byte_index*8 +: 8];
    end
    return merged_data;
  endfunction

  initial begin : p_optional_memory_init
    if (INIT_FILE != "")
      $readmemh(INIT_FILE, mem);
  end

  always_ff @(posedge clk_i) begin
    if (!rst_ni) begin
      read_valid_o <= 1'b0;
      read_data_o  <= '0;
    end else begin
      read_valid_o <= read_en_i;
      if (read_en_i) begin
        if (write_en_i && (read_addr_i == write_addr_i))
          read_data_o <= apply_write_strobe(mem[read_addr_i], write_data_i,
                                            write_strb_i);
        else
          read_data_o <= mem[read_addr_i];
      end

      if (write_en_i)
        mem[write_addr_i] <= apply_write_strobe(mem[write_addr_i],
                                                write_data_i, write_strb_i);
    end
  end

  initial begin : p_parameter_checks
    if ((DATA_WIDTH == 0) || ((DATA_WIDTH % 8) != 0))
      $fatal(1, "DATA_WIDTH must contain whole bytes");
    if (DEPTH < 2)
      $fatal(1, "DEPTH must be at least two words");
  end

endmodule
