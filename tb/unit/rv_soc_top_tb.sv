module rv_soc_top_tb;
  import rv_soc_pkg::*;

  logic clk;
  logic rst_n;
  logic [PLIC_NUM_SOURCES-1:1] external_irq;
  logic soc_ready;
  logic [31:0] host_boot_entry;
  logic [31:0] host_boot_flags;
  logic host_event_valid;
  host_event_e host_event_kind;
  logic [31:0] host_event_data;
  logic [1:0] trace_valid;
  logic [1:0][31:0] trace_pc;
  logic [1:0][31:0] trace_instr;

  logic aw_valid;
  logic [3:0] aw_id;
  logic [31:0] aw_addr;
  logic [7:0] aw_len;
  logic [2:0] aw_size;
  logic [63:0] w_data;
  logic [7:0] w_strb;
  logic w_last;
  logic w_valid;
  logic ar_valid;
  logic [3:0] ar_id;
  logic [31:0] ar_addr;
  logic [7:0] ar_len;
  logic [2:0] ar_size;

  rv_axi4_if #(
    .ID_WIDTH (AXI_LOCAL_ID_WIDTH)
  ) host_axi (.clk_i(clk), .rst_ni(rst_n));

  always #5 clk = ~clk;

  always_comb begin
    host_axi.aw_id    = aw_id;
    host_axi.aw_addr  = aw_addr;
    host_axi.aw_len   = aw_len;
    host_axi.aw_size  = aw_size;
    host_axi.aw_burst = 2'b01;
    host_axi.aw_prot  = 3'b001;
    host_axi.aw_cache = 4'b0011;
    host_axi.aw_qos   = '0;
    host_axi.aw_valid = aw_valid;
    host_axi.w_data   = w_data;
    host_axi.w_strb   = w_strb;
    host_axi.w_last   = w_last;
    host_axi.w_valid  = w_valid;
    host_axi.b_ready  = 1'b1;
    host_axi.ar_id    = ar_id;
    host_axi.ar_addr  = ar_addr;
    host_axi.ar_len   = ar_len;
    host_axi.ar_size  = ar_size;
    host_axi.ar_burst = 2'b01;
    host_axi.ar_prot  = 3'b001;
    host_axi.ar_cache = 4'b0011;
    host_axi.ar_qos   = '0;
    host_axi.ar_valid = ar_valid;
    host_axi.r_ready  = 1'b1;
  end

  rv_soc_top #(
    .BOOTROM_INIT_FILE ("tb/data/bootrom_test.hex")
  ) u_dut (
    .clk_i                (clk),
    .rst_ni               (rst_n),
    .external_irq_i     (external_irq),
    .host_axi_s         (host_axi),
    .soc_ready_o        (soc_ready),
    .host_boot_entry_o  (host_boot_entry),
    .host_boot_flags_o  (host_boot_flags),
    .host_event_valid_o (host_event_valid),
    .host_event_ready_i (1'b1),
    .host_event_kind_o  (host_event_kind),
    .host_event_data_o  (host_event_data),
    .trace_valid_o      (trace_valid),
    .trace_pc_o         (trace_pc),
    .trace_instr_o      (trace_instr)
  );

  task automatic axi_write(
    input logic [3:0] id,
    input logic [31:0] address,
    input logic [2:0] size,
    input logic [63:0] data,
    input logic [7:0] strobe,
    output logic [1:0] response
  );
    logic aw_done;
    logic w_done;
    aw_done = 1'b0;
    w_done  = 1'b0;
    @(negedge clk);
    aw_id    = id;
    aw_addr  = address;
    aw_len   = 0;
    aw_size  = size;
    aw_valid = 1'b1;
    w_data   = data;
    w_strb   = strobe;
    w_last   = 1'b1;
    w_valid  = 1'b1;
    while (!aw_done || !w_done) begin
      @(posedge clk);
      if (aw_valid && host_axi.aw_ready)
        aw_done = 1'b1;
      if (w_valid && host_axi.w_ready)
        w_done = 1'b1;
      @(negedge clk);
      if (aw_done)
        aw_valid = 1'b0;
      if (w_done)
        w_valid = 1'b0;
    end
    while (!host_axi.b_valid)
      @(negedge clk);
    response = host_axi.b_resp;
    if (host_axi.b_id != id)
      $fatal(1, "SoC write response ID mismatch");
    @(posedge clk);
  endtask

  task automatic axi_read(
    input logic [3:0] id,
    input logic [31:0] address,
    input logic [2:0] size,
    output logic [63:0] data,
    output logic [1:0] response
  );
    @(negedge clk);
    ar_id    = id;
    ar_addr  = address;
    ar_len   = 0;
    ar_size  = size;
    ar_valid = 1'b1;
    do @(posedge clk); while (!host_axi.ar_ready);
    @(negedge clk);
    ar_valid = 1'b0;
    while (!host_axi.r_valid)
      @(negedge clk);
    data     = host_axi.r_data;
    response = host_axi.r_resp;
    if ((host_axi.r_id != id) || !host_axi.r_last)
      $fatal(1, "SoC read response metadata mismatch");
    @(posedge clk);
  endtask

  logic [63:0] read_data;
  logic [1:0] response;

  initial begin : p_soc_host_path_test
    clk          = 1'b0;
    rst_n        = 1'b0;
    external_irq = '0;
    aw_valid     = 1'b0;
    aw_id        = '0;
    aw_addr      = '0;
    aw_len       = '0;
    aw_size      = 3'd3;
    w_data       = '0;
    w_strb       = '0;
    w_last       = 1'b1;
    w_valid      = 1'b0;
    ar_valid     = 1'b0;
    ar_id        = '0;
    ar_addr      = '0;
    ar_len       = '0;
    ar_size      = 3'd3;

    repeat (3) @(posedge clk);
    @(negedge clk);
    rst_n = 1'b1;
    wait (soc_ready);

    axi_read(4'h1, BOOTROM_BASE_ADDR, 3'd3, read_data, response);
    if ((response != AXI_RESP_OKAY) ||
        (read_data != 64'h0123_4567_89ab_cdef))
      $fatal(1, "Host-to-BootROM path failed");

    axi_write(4'h2, ITIM_BASE_ADDR + 32'h20, 3'd3,
              64'h1111_2222_3333_4444, 8'hff, response);
    if (response != AXI_RESP_OKAY)
      $fatal(1, "Host-to-ITIM write failed");
    axi_read(4'h3, ITIM_BASE_ADDR + 32'h20, 3'd3, read_data, response);
    if ((response != AXI_RESP_OKAY) ||
        (read_data != 64'h1111_2222_3333_4444))
      $fatal(1, "Host-to-ITIM readback failed");

    axi_write(4'h4, DTIM_BASE_ADDR + 32'h28, 3'd3,
              64'haaaa_5555_dead_beef, 8'hff, response);
    axi_read(4'h5, DTIM_BASE_ADDR + 32'h28, 3'd3, read_data, response);
    if ((response != AXI_RESP_OKAY) ||
        (read_data != 64'haaaa_5555_dead_beef))
      $fatal(1, "Host-to-DTIM readback failed");

    axi_write(4'h6, CLINT_BASE_ADDR + CLINT_MSIP_OFFSET, 3'd2,
              64'h0000_0000_0000_0001, 8'h0f, response);
    axi_read(4'h7, CLINT_BASE_ADDR + CLINT_MSIP_OFFSET, 3'd2,
             read_data, response);
    if ((response != AXI_RESP_OKAY) || !read_data[0])
      $fatal(1, "Host-to-CLINT MSIP path failed");

    axi_write(4'h8, HOSTIF_BASE_ADDR + HOSTIF_BOOT_ENTRY_OFF, 3'd2,
              64'h8000_0100_0000_0000, 8'hf0, response);
    if ((response != AXI_RESP_OKAY) ||
        (host_boot_entry != 32'h8000_0100))
      $fatal(1, "Host-to-HostIF BOOT_ENTRY path failed");

    axi_read(4'h9, 32'hde00_0000, 3'd3, read_data, response);
    if (response != AXI_RESP_DECERR)
      $fatal(1, "Unmapped access did not return DECERR");

    $display("rv_soc_top_tb PASS");
    $finish;
  end
endmodule
