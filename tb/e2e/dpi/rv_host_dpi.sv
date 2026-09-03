module rv_host_dpi #(
  parameter int unsigned XLEN = 32,
  parameter int unsigned ADDR_WIDTH = 32,
  parameter int unsigned DATA_WIDTH = 64,
  parameter int unsigned ID_WIDTH = 4,
  parameter logic [ADDR_WIDTH-1:0] BOOTROM_BASE_ADDR = 'h0000_1000,
  parameter int unsigned BOOTROM_SIZE_BYTES = 4096,
  parameter logic [ADDR_WIDTH-1:0] ITIM_BASE_ADDR = 'h8000_0000,
  parameter int unsigned ITIM_SIZE_BYTES = 128*1024,
  parameter logic [ADDR_WIDTH-1:0] DTIM_BASE_ADDR = 'h8002_0000,
  parameter int unsigned DTIM_SIZE_BYTES = 128*1024,
  parameter logic [ADDR_WIDTH-1:0] CLINT_BASE_ADDR = 'h0020_0000,
  parameter logic [ADDR_WIDTH-1:0] PLIC_BASE_ADDR = 'h0c00_0000,
  parameter logic [ADDR_WIDTH-1:0] HOSTIF_BASE_ADDR = 'h1000_0000,
  parameter logic [ADDR_WIDTH-1:0] CLINT_MSIP_OFFSET = 'h0,
  parameter logic [ADDR_WIDTH-1:0] HOSTIF_BOOT_ENTRY_OFFSET = 'h0,
  parameter logic [ADDR_WIDTH-1:0] HOSTIF_BOOT_FLAGS_OFFSET = 'h4,
  parameter bit HTIF_ENABLE = 1'b0,
  parameter logic [ADDR_WIDTH-1:0] TOHOST_ADDR = 'h8002_0000,
  parameter logic [ADDR_WIDTH-1:0] FROMHOST_ADDR = 'h8002_0008,
  parameter int unsigned HTIF_POLL_CYCLES = 32,
  parameter int unsigned HTIF_SETTLE_CYCLES = 8,
  parameter int unsigned HTIF_MAX_PRINT_BYTES = 1_048_576
) (
  input  logic                         clk_i,
  input  logic                         rst_ni,
  input  logic                         soc_ready_i,
  input  logic                         boot_wait_i,
  rv_axi4_if.master                    host_axi_m,
  input  logic                         host_event_valid_i,
  output logic                         host_event_ready_o,
  input  logic [1:0]                   host_event_kind_i,
  input  logic [31:0]                  host_event_data_i,
  output logic                         load_done_o,
  output logic                         load_failed_o,
  output logic                         htif_exit_valid_o,
  output logic [31:0]                  htif_exit_code_o
);

  localparam int unsigned DATA_BYTES = DATA_WIDTH/8;
  localparam int unsigned AXI_SIZE = $clog2(DATA_BYTES);
  localparam int unsigned MAX_BURST_BEATS = 16;

  import "DPI-C" function void host_config(
    input int xlen, input int axi_data_width, input int axi_id_width,
    input longint unsigned bootrom_base, input longint unsigned bootrom_size,
    input longint unsigned itim_base, input longint unsigned itim_size,
    input longint unsigned dtim_base, input longint unsigned dtim_size,
    input longint unsigned clint_base, input longint unsigned plic_base,
    input longint unsigned hostif_base);
  import "DPI-C" function int host_open_elf(input string path);
  import "DPI-C" function longint unsigned host_elf_entry();
  import "DPI-C" function int host_segment_count();
  import "DPI-C" function longint unsigned host_segment_paddr(input int index);
  import "DPI-C" function longint unsigned host_segment_filesz(input int index);
  import "DPI-C" function longint unsigned host_segment_memsz(input int index);
  import "DPI-C" function int host_segment_byte(
    input int index, input longint unsigned offset);
  import "DPI-C" function string host_last_error();
  import "DPI-C" function int host_poll_rx();
  import "DPI-C" function void host_event(input int kind, input int data);
  import "DPI-C" function void host_finish(input int code);

  logic [DATA_WIDTH-1:0] burst_data [0:MAX_BURST_BEATS-1];
  logic [DATA_BYTES-1:0] burst_strobe [0:MAX_BURST_BEATS-1];
  logic [ID_WIDTH-1:0] next_id_q;

  function automatic logic address_in_region(
    input longint unsigned address,
    input longint unsigned size,
    input longint unsigned base,
    input longint unsigned region_size
  );
    return (address >= base) && (size <= region_size) &&
           ((address-base) <= (region_size-size));
  endfunction

  task automatic axi_write_burst(
    input logic [ADDR_WIDTH-1:0] address,
    input int unsigned beat_count,
    input logic [2:0] transfer_size
  );
    logic address_done;
    host_axi_m.aw_id = next_id_q;
    host_axi_m.aw_addr = address;
    host_axi_m.aw_len = beat_count-1;
    host_axi_m.aw_size = transfer_size;
    host_axi_m.aw_burst = 2'b01;
    host_axi_m.aw_prot = 3'b001;
    host_axi_m.aw_cache = 4'b0011;
    host_axi_m.aw_qos = '0;
    host_axi_m.aw_valid = 1'b1;
    address_done = 1'b0;
    while (!address_done) begin
      @(posedge clk_i);
      if (host_axi_m.aw_valid && host_axi_m.aw_ready)
        address_done = 1'b1;
      @(negedge clk_i);
      if (address_done) host_axi_m.aw_valid = 1'b0;
    end
    for (int unsigned beat = 0; beat < beat_count; beat++) begin
      host_axi_m.w_data = burst_data[beat];
      host_axi_m.w_strb = burst_strobe[beat];
      host_axi_m.w_last = beat == (beat_count-1);
      host_axi_m.w_valid = 1'b1;
      do @(posedge clk_i); while (!host_axi_m.w_ready);
      @(negedge clk_i);
      host_axi_m.w_valid = 1'b0;
    end
    while (!host_axi_m.b_valid) @(posedge clk_i);
    if ((host_axi_m.b_id != next_id_q) || (host_axi_m.b_resp != 2'b00)) begin
      load_failed_o = 1'b1;
      $error("Host AXI ELF write failed addr=%h id=%h resp=%h",
             address, host_axi_m.b_id, host_axi_m.b_resp);
    end
    @(negedge clk_i);
    next_id_q = next_id_q + 1'b1;
  endtask

  task automatic write_register32(
    input logic [ADDR_WIDTH-1:0] address,
    input logic [31:0] value
  );
    int unsigned lane_offset;
    lane_offset = address[$clog2(DATA_BYTES)-1:0];
    burst_data[0] = '0;
    burst_strobe[0] = '0;
    burst_data[0][lane_offset*8 +: 32] = value;
    burst_strobe[0][lane_offset +: 4] = 4'hf;
    // AXI narrow transfers retain the addressed byte offset while WSTRB
    // identifies the active lanes of the 64-bit data bus.
    axi_write_burst(address, 1, 3'd2);
  endtask

  task automatic write_register64(
    input logic [ADDR_WIDTH-1:0] address,
    input logic [63:0] value
  );
    burst_data[0] = DATA_WIDTH'(value);
    burst_strobe[0] = '1;
    axi_write_burst(address, 1, 3'd3);
  endtask

  task automatic axi_read64(
    input  logic [ADDR_WIDTH-1:0] address,
    output logic [63:0] value
  );
    logic address_done;
    value = '0;
    host_axi_m.ar_id = next_id_q;
    host_axi_m.ar_addr = address;
    host_axi_m.ar_len = 0;
    host_axi_m.ar_size = 3'd3;
    host_axi_m.ar_burst = 2'b01;
    host_axi_m.ar_prot = 3'b001;
    host_axi_m.ar_cache = 4'b0011;
    host_axi_m.ar_qos = '0;
    host_axi_m.ar_valid = 1'b1;
    address_done = 1'b0;
    while (!address_done) begin
      @(posedge clk_i);
      if (host_axi_m.ar_valid && host_axi_m.ar_ready)
        address_done = 1'b1;
      @(negedge clk_i);
      if (address_done) host_axi_m.ar_valid = 1'b0;
    end
    while (!host_axi_m.r_valid) @(posedge clk_i);
    if ((host_axi_m.r_id != next_id_q) ||
        (host_axi_m.r_resp != 2'b00) || !host_axi_m.r_last) begin
      load_failed_o = 1'b1;
      $error("Host AXI HTIF read failed addr=%h id=%h resp=%h last=%b",
             address, host_axi_m.r_id, host_axi_m.r_resp,
             host_axi_m.r_last);
    end else begin
      value = host_axi_m.r_data[63:0];
    end
    @(negedge clk_i);
    next_id_q = next_id_q + 1'b1;
  endtask

  task automatic htif_print_memory(
    input logic [ADDR_WIDTH-1:0] address,
    input longint unsigned requested_bytes,
    input logic stop_at_nul,
    output longint unsigned printed_bytes
  );
    logic [63:0] beat;
    logic [ADDR_WIDTH-1:0] beat_address;
    int unsigned first_lane;
    logic done;
    printed_bytes = 0;
    done = 1'b0;
    while (!done && (printed_bytes < requested_bytes) &&
           (printed_bytes < HTIF_MAX_PRINT_BYTES)) begin
      beat_address = (address + ADDR_WIDTH'(printed_bytes)) &
                     ~ADDR_WIDTH'(DATA_BYTES-1);
      first_lane = (address + ADDR_WIDTH'(printed_bytes)) & (DATA_BYTES-1);
      axi_read64(beat_address, beat);
      if (load_failed_o) begin
        done = 1'b1;
      end else begin
        for (int unsigned lane = first_lane;
             lane < DATA_BYTES && !done &&
             printed_bytes < requested_bytes &&
             printed_bytes < HTIF_MAX_PRINT_BYTES; lane++) begin
          if (stop_at_nul && (beat[lane*8 +: 8] == 8'h00)) begin
            done = 1'b1;
          end else begin
            host_event(2, int'(beat[lane*8 +: 8]));
            printed_bytes++;
          end
        end
      end
    end
  endtask

  task automatic htif_read_memory64(
    input  logic [ADDR_WIDTH-1:0] address,
    output logic [63:0] value
  );
    logic [ADDR_WIDTH-1:0] aligned_address;
    logic [63:0] low_beat;
    logic [63:0] high_beat;
    int unsigned byte_offset;
    aligned_address = address & ~ADDR_WIDTH'(DATA_BYTES-1);
    byte_offset = address & (DATA_BYTES-1);
    axi_read64(aligned_address, low_beat);
    if ((byte_offset == 0) || load_failed_o) begin
      value = low_beat;
    end else begin
      axi_read64(aligned_address + ADDR_WIDTH'(DATA_BYTES), high_beat);
      value = (low_beat >> (byte_offset*8)) |
              (high_beat << ((DATA_BYTES-byte_offset)*8));
    end
  endtask

  task automatic htif_write_response(input logic [63:0] response);
    logic [63:0] current_fromhost;
    current_fromhost = '1;
    while ((current_fromhost != 0) && !load_failed_o) begin
      axi_read64(FROMHOST_ADDR, current_fromhost);
      if (current_fromhost != 0)
        repeat (HTIF_POLL_CYCLES) @(posedge clk_i);
    end
    if (!load_failed_o)
      write_register64(FROMHOST_ADDR, response);
  endtask

  task automatic htif_finish(input logic [31:0] code);
    htif_exit_code_o = code;
    htif_exit_valid_o = 1'b1;
    host_finish(int'(code));
  endtask

  task automatic htif_proxy_syscall(
    input logic [ADDR_WIDTH-1:0] request_address
  );
    logic [63:0] syscall_number;
    logic [63:0] arg0;
    logic [63:0] arg1;
    logic [63:0] arg2;
    longint unsigned printed_bytes;
    htif_read_memory64(request_address + ADDR_WIDTH'(0), syscall_number);
    if (load_failed_o) begin
      htif_finish(32'hffff_fffe);
    end else begin
      case (syscall_number)
        64: begin // Linux/RISC-V write(fd, buffer, length)
          htif_read_memory64(request_address + ADDR_WIDTH'(8), arg0);
          htif_read_memory64(request_address + ADDR_WIDTH'(16), arg1);
          htif_read_memory64(request_address + ADDR_WIDTH'(24), arg2);
          if ((arg0 == 1) || (arg0 == 2)) begin
            htif_print_memory(ADDR_WIDTH'(arg1), arg2, 1'b0, printed_bytes);
            write_register64(request_address, 64'(printed_bytes));
          end else begin
            write_register64(request_address, 64'hffff_ffff_ffff_ffff);
          end
          htif_write_response(64'd1);
        end
        93, 94: begin // exit / exit_group
          htif_read_memory64(request_address + ADDR_WIDTH'(8), arg0);
          write_register64(request_address, 64'd0);
          htif_finish(arg0[31:0]);
        end
        default: begin
          // A small bare-metal environment often places a NUL-terminated
          // string address directly in TOHOST instead of a syscall block.
          htif_print_memory(request_address, HTIF_MAX_PRINT_BYTES,
                            1'b1, printed_bytes);
          htif_write_response(64'd1);
        end
      endcase
    end
  endtask

  task automatic htif_handle_request(input logic [63:0] request);
    logic [7:0] device;
    logic [7:0] command;
    logic [47:0] payload;
    device = request[63:56];
    command = request[55:48];
    payload = request[47:0];

    // The producer owns TOHOST until the host consumes it. Clear it before
    // publishing FROMHOST so the next request cannot be mistaken for this one.
    write_register64(TOHOST_ADDR, 64'd0);
    if (load_failed_o) begin
      htif_finish(32'hffff_fffe);
    end else if ((device == 0) && (command == 0) && (request == 64'd1)) begin
      htif_finish(32'd0);
    end else if ((device == 0) && (command == 0) && request[0] &&
                 !address_in_region(ADDR_WIDTH'(payload), 1,
                                    ITIM_BASE_ADDR, ITIM_SIZE_BYTES) &&
                 !address_in_region(ADDR_WIDTH'(payload), 1,
                                    DTIM_BASE_ADDR, DTIM_SIZE_BYTES)) begin
      // riscv-tests convention: 1=PASS, odd values encode a non-zero failure.
      htif_finish(request[32:1]);
    end else if ((device == 1) && (command == 1)) begin
      // Standard HTIF console putchar packet.
      host_event(2, int'(payload[7:0]));
      htif_write_response({device, command, 47'd0, 1'b1});
    end else if ((device == 0) && (command == 0)) begin
      // Proxy syscall packet. On RV32 the low 32 bits are the request address.
      htif_proxy_syscall(ADDR_WIDTH'(payload));
    end else begin
      $display("Unsupported HTIF request device=%0d command=%0d payload=%h",
               device, command, payload);
      htif_finish(32'hffff_fffd);
    end
  endtask

  task automatic htif_server_loop;
    logic [63:0] request;
    logic [63:0] stable_request;
    forever begin
      repeat (HTIF_POLL_CYCLES) @(posedge clk_i);
      axi_read64(TOHOST_ADDR, request);
      if (load_failed_o)
        htif_finish(32'hffff_fffe);
      else if (request != 0) begin
        // RV32 can publish a 64-bit HTIF word with two stores. Re-read after a
        // short settling interval so a low-word-first console packet is not
        // misread as an odd riscv-tests completion code.
        repeat (HTIF_SETTLE_CYCLES) @(posedge clk_i);
        axi_read64(TOHOST_ADDR, stable_request);
        if ((stable_request == request) && (stable_request != 0))
          htif_handle_request(stable_request);
      end
      if (htif_exit_valid_o)
        return;
    end
  endtask

  task automatic load_segment(input int segment_index);
    longint unsigned segment_address, file_size, memory_size;
    longint unsigned first_beat, final_address, current_beat;
    int unsigned beat_count;
    segment_address = host_segment_paddr(segment_index);
    file_size = host_segment_filesz(segment_index);
    memory_size = host_segment_memsz(segment_index);
    if (!(address_in_region(segment_address, memory_size,
                            ITIM_BASE_ADDR, ITIM_SIZE_BYTES) ||
          address_in_region(segment_address, memory_size,
                            DTIM_BASE_ADDR, DTIM_SIZE_BYTES))) begin
      load_failed_o = 1'b1;
      $error("ELF PT_LOAD segment %0d lies outside ITIM/DTIM", segment_index);
      return;
    end
    first_beat = segment_address & ~(longint'(DATA_BYTES-1));
    final_address = segment_address + memory_size;
    current_beat = first_beat;
    while (current_beat < final_address) begin
      beat_count = 0;
      while ((beat_count < MAX_BURST_BEATS) &&
             ((current_beat + beat_count*DATA_BYTES) < final_address)) begin
        longint unsigned beat_address;
        beat_address = current_beat + beat_count*DATA_BYTES;
        burst_data[beat_count] = '0;
        burst_strobe[beat_count] = '0;
        for (int unsigned byte_lane = 0; byte_lane < DATA_BYTES; byte_lane++) begin
          longint unsigned byte_address, segment_offset;
          byte_address = beat_address + byte_lane;
          if ((byte_address >= segment_address) &&
              (byte_address < final_address)) begin
            segment_offset = byte_address - segment_address;
            burst_strobe[beat_count][byte_lane] = 1'b1;
            if (segment_offset < file_size)
              burst_data[beat_count][byte_lane*8 +: 8] =
                8'(host_segment_byte(segment_index, segment_offset));
          end
        end
        beat_count++;
      end
      axi_write_burst(ADDR_WIDTH'(current_beat), beat_count, AXI_SIZE[2:0]);
      if (load_failed_o) return;
      current_beat += beat_count*DATA_BYTES;
    end
  endtask

  assign host_event_ready_o = 1'b1;

  always_ff @(posedge clk_i) begin
    if (rst_ni && host_event_valid_i && host_event_ready_o) begin
      host_event(int'(host_event_kind_i), int'(host_event_data_i));
      if (host_event_kind_i == 2'd1)
        host_finish(int'(host_event_data_i));
    end
  end

  initial begin : p_dpi_host
    string elf_path;
    int segment_count;
    host_axi_m.aw_id = '0;
    host_axi_m.aw_addr = '0;
    host_axi_m.aw_len = '0;
    host_axi_m.aw_size = AXI_SIZE;
    host_axi_m.aw_burst = 2'b01;
    host_axi_m.aw_prot = 3'b001;
    host_axi_m.aw_cache = 4'b0011;
    host_axi_m.aw_qos = '0;
    host_axi_m.aw_valid = 1'b0;
    host_axi_m.w_data = '0;
    host_axi_m.w_strb = '0;
    host_axi_m.w_last = 1'b0;
    host_axi_m.w_valid = 1'b0;
    host_axi_m.b_ready = 1'b1;
    host_axi_m.ar_id = '0;
    host_axi_m.ar_addr = '0;
    host_axi_m.ar_len = '0;
    host_axi_m.ar_size = AXI_SIZE;
    host_axi_m.ar_burst = 2'b01;
    host_axi_m.ar_prot = 3'b001;
    host_axi_m.ar_cache = 4'b0011;
    host_axi_m.ar_qos = '0;
    host_axi_m.ar_valid = 1'b0;
    host_axi_m.r_ready = 1'b1;
    load_done_o = 1'b0;
    load_failed_o = 1'b0;
    htif_exit_valid_o = 1'b0;
    htif_exit_code_o = '0;
    next_id_q = '0;

    wait (rst_ni && soc_ready_i && boot_wait_i);
    host_config(XLEN, DATA_WIDTH, ID_WIDTH,
      BOOTROM_BASE_ADDR, BOOTROM_SIZE_BYTES,
      ITIM_BASE_ADDR, ITIM_SIZE_BYTES, DTIM_BASE_ADDR, DTIM_SIZE_BYTES,
      CLINT_BASE_ADDR, PLIC_BASE_ADDR, HOSTIF_BASE_ADDR);
    if (!$value$plusargs("elf=%s", elf_path)) begin
      load_failed_o = 1'b1;
      $error("DPI Host requires +elf=<path>");
    end else if (!host_open_elf(elf_path)) begin
      load_failed_o = 1'b1;
      $error("ELF parser failed: %s", host_last_error());
    end

    if (!load_failed_o) begin
      segment_count = host_segment_count();
      for (int segment = 0; segment < segment_count; segment++) begin
        load_segment(segment);
        if (load_failed_o) break;
      end
    end

    if (!load_failed_o) begin
      write_register32(HOSTIF_BASE_ADDR + HOSTIF_BOOT_ENTRY_OFFSET,
                       32'(host_elf_entry()));
      write_register32(HOSTIF_BASE_ADDR + HOSTIF_BOOT_FLAGS_OFFSET, 32'h1);
      // MSIP is deliberately the final write: every PT_LOAD B response and
      // both HostIF mailbox writes have completed before the core wakes.
      write_register32(CLINT_BASE_ADDR + CLINT_MSIP_OFFSET, 32'h1);
      load_done_o = !load_failed_o;
      if (HTIF_ENABLE && !load_failed_o)
        htif_server_loop();
    end
  end

  initial begin
    if ((DATA_WIDTH < 32) || ((DATA_WIDTH % 8) != 0) ||
        ((DATA_BYTES & (DATA_BYTES-1)) != 0))
      $fatal(1, "Host AXI data width must be a power-of-two number of bytes");
    if (HTIF_ENABLE && (DATA_WIDTH != 64))
      $fatal(1, "HTIF DPI mode currently requires a 64-bit Host AXI data bus");
    if (HTIF_ENABLE &&
        (!address_in_region(TOHOST_ADDR, 8, DTIM_BASE_ADDR, DTIM_SIZE_BYTES) ||
         !address_in_region(FROMHOST_ADDR, 8, DTIM_BASE_ADDR, DTIM_SIZE_BYTES)))
      $fatal(1, "TOHOST/FROMHOST must be aligned 64-bit words inside DTIM");
    if (HTIF_ENABLE && ((TOHOST_ADDR[2:0] != 0) ||
                        (FROMHOST_ADDR[2:0] != 0) ||
                        (TOHOST_ADDR == FROMHOST_ADDR)))
      $fatal(1, "TOHOST/FROMHOST must be distinct and 8-byte aligned");
  end
endmodule
