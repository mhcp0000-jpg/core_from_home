module rv_backend_int_tb;
  import rv_ooo_pkg::*;

  logic clk, rst_n;
  logic [1:0] fetch_valid, fetch_ready;
  logic [1:0][31:0] fetch_pc, fetch_instr;
  inst_len_e [1:0] fetch_len;
  prediction_meta_t [1:0] fetch_prediction;
  logic [1:0] fetch_fault;
  logic redirect_valid;
  logic [31:0] redirect_pc;
  logic [1:0] dmem_req_valid, dmem_req_ready, dmem_req_write;
  logic [1:0][5:0] dmem_req_id, dmem_rsp_id;
  logic [1:0][31:0] dmem_req_addr;
  logic [1:0][2:0] dmem_req_size, dmem_rsp_replay;
  logic [1:0][63:0] dmem_req_wdata, dmem_rsp_rdata;
  logic [1:0][7:0] dmem_req_wstrb;
  logic [1:0][1:0] dmem_req_priv, dmem_rsp_resp;
  logic [1:0][ROB_SEQ_WIDTH-1:0] dmem_req_sequence;
  logic [1:0] dmem_req_committed, dmem_req_device;
  logic [1:0] dmem_rsp_valid, dmem_rsp_ready;
  logic [1:0] trace_valid;
  logic [1:0][31:0] trace_pc, trace_instr, trace_wdata;
  logic [1:0][4:0] trace_rd;
  logic [1:0] trace_rd_write, trace_trap;

  int unsigned write_count;
  logic [4:0] write_rd [0:15];
  logic [31:0] write_data [0:15];
  logic saw_bad_x6;
  int unsigned memory_write_count;
  int unsigned memory_read_count;
  logic saw_uncommitted_write;
  logic saw_bad_forward_read;
  logic saw_dual_load_request;
  int unsigned memory_request_count;
  logic [1:0] accepted_memory_write, accepted_memory_read;
  logic irq_software;

  always #5 clk = ~clk;

  function automatic logic [63:0] memory_read_data(
    input logic [31:0] address
  );
    case (address)
      32'h8002_0000: memory_read_data = 64'hdead_beef_dead_beef;
      32'h8002_0008: memory_read_data = 64'h0000_0000_ffff_ff80;
      32'h8002_0010: memory_read_data = 64'h0000_0000_1234_5678;
      default:        memory_read_data = 64'hbad0_bad0_bad0_bad0;
    endcase
  endfunction

  rv_backend #(.XLEN(32), .PADDR_WIDTH(32), .MEM_DATA_WIDTH(64)) u_dut (
    .clk_i(clk), .rst_ni(rst_n), .fetch_valid_i(fetch_valid),
    .fetch_ready_o(fetch_ready), .fetch_pc_i(fetch_pc),
    .fetch_instr_i(fetch_instr), .fetch_inst_len_i(fetch_len),
    .fetch_prediction_i(fetch_prediction), .fetch_fault_i(fetch_fault),
    .redirect_valid_o(redirect_valid), .redirect_pc_o(redirect_pc),
    .dmem_req_valid_o(dmem_req_valid), .dmem_req_ready_i(dmem_req_ready),
    .dmem_req_id_o(dmem_req_id), .dmem_req_write_o(dmem_req_write),
    .dmem_req_addr_o(dmem_req_addr), .dmem_req_size_o(dmem_req_size),
    .dmem_req_wdata_o(dmem_req_wdata), .dmem_req_wstrb_o(dmem_req_wstrb),
    .dmem_req_priv_o(dmem_req_priv), .dmem_req_rob_seq_o(dmem_req_sequence),
    .dmem_req_committed_o(dmem_req_committed),
    .dmem_req_device_o(dmem_req_device), .dmem_rsp_valid_i(dmem_rsp_valid),
    .dmem_rsp_ready_o(dmem_rsp_ready), .dmem_rsp_id_i(dmem_rsp_id),
    .dmem_rsp_rdata_i(dmem_rsp_rdata), .dmem_rsp_resp_i(dmem_rsp_resp),
    .dmem_rsp_replay_i(dmem_rsp_replay), .irq_software_i(irq_software),
    .irq_timer_i(1'b0), .irq_external_i(1'b0), .mtime_i(64'b0),
    .debug_halt_req_i(1'b0),
    .trace_valid_o(trace_valid), .trace_pc_o(trace_pc),
    .trace_instr_o(trace_instr), .trace_rd_o(trace_rd),
    .trace_rd_write_o(trace_rd_write), .trace_rd_wdata_o(trace_wdata),
    .trace_trap_o(trace_trap)
  );

  task automatic clear_fetch;
    fetch_valid = '0;
    fetch_pc = '0;
    fetch_instr = '0;
    fetch_len[0] = INST_LEN_32;
    fetch_len[1] = INST_LEN_32;
    fetch_prediction = '0;
    fetch_fault = '0;
  endtask

  task automatic send_pair(
    input logic [31:0] pc0,
    input logic [31:0] instruction0,
    input logic second_valid,
    input logic [31:0] pc1,
    input logic [31:0] instruction1
  );
    @(negedge clk);
    fetch_valid = {second_valid, 1'b1};
    fetch_pc[0] = pc0;
    fetch_pc[1] = pc1;
    fetch_instr[0] = instruction0;
    fetch_instr[1] = instruction1;
    while (!fetch_ready[0]) @(negedge clk);
    @(posedge clk);
    @(negedge clk);
    clear_fetch();
  endtask

  always @(negedge clk) begin
    if (rst_n) begin
      for (int unsigned lane = 0; lane < 2; lane++) begin
        if (trace_valid[lane] && trace_rd_write[lane]) begin
          write_rd[write_count] = trace_rd[lane];
          write_data[write_count] = trace_wdata[lane];
          if ((trace_rd[lane] == 6) && (trace_wdata[lane] == 99))
            saw_bad_x6 = 1'b1;
          write_count = write_count + 1;
        end
      end
    end
  end

  // One-entry response slot per LSU master models the D-fabric contract.
  always_comb begin
    for (int unsigned lane = 0; lane < 2; lane++) begin
      dmem_req_ready[lane] = !dmem_rsp_valid[lane] || dmem_rsp_ready[lane];
      accepted_memory_write[lane] = dmem_req_valid[lane] &&
        dmem_req_ready[lane] && dmem_req_write[lane];
      accepted_memory_read[lane] = dmem_req_valid[lane] &&
        dmem_req_ready[lane] && !dmem_req_write[lane];
    end
  end

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      dmem_rsp_valid <= '0;
      dmem_rsp_id <= '0;
      dmem_rsp_rdata <= '0;
      dmem_rsp_resp <= '0;
      dmem_rsp_replay <= '0;
      memory_write_count <= 0;
      memory_read_count <= 0;
      saw_uncommitted_write <= 1'b0;
      saw_bad_forward_read <= 1'b0;
      saw_dual_load_request <= 1'b0;
      memory_request_count <= 0;
    end else begin
      memory_write_count <= memory_write_count +
        $unsigned($countones(accepted_memory_write));
      memory_read_count <= memory_read_count +
        $unsigned($countones(accepted_memory_read));
      for (int unsigned lane = 0; lane < 2; lane++) begin
        if (dmem_rsp_valid[lane] && dmem_rsp_ready[lane])
          dmem_rsp_valid[lane] <= 1'b0;
        if (dmem_req_valid[lane] && dmem_req_ready[lane]) begin
          dmem_rsp_valid[lane] <= 1'b1;
          dmem_rsp_id[lane] <= dmem_req_id[lane];
          dmem_rsp_rdata[lane] <= memory_read_data(dmem_req_addr[lane]);
          dmem_rsp_resp[lane] <= 2'b00;
          dmem_rsp_replay[lane] <= 3'b000;
          if (dmem_req_write[lane]) begin
            if (!dmem_req_committed[lane])
              saw_uncommitted_write <= 1'b1;
          end else begin
            if (dmem_req_addr[lane] == 32'h8002_0000)
              saw_bad_forward_read <= 1'b1;
          end
        end
      end
      if (&dmem_req_valid && !(|dmem_req_write) && (&dmem_req_ready))
        saw_dual_load_request <= 1'b1;
      if (|(dmem_req_valid & dmem_req_ready))
        memory_request_count <= memory_request_count + 1;
    end
  end

  initial begin : p_test
    clk = 1'b0;
    rst_n = 1'b0;
    clear_fetch();
    write_count = 0;
    saw_bad_x6 = 1'b0;
    irq_software = 1'b0;
    repeat (4) @(posedge clk);
    @(negedge clk);
    rst_n = 1'b1;

    // Independent producers followed by an older MUL and younger ADD.
    send_pair(32'h1000, 32'h0050_0093, 1'b1,
              32'h1004, 32'h0070_0113);
    send_pair(32'h1008, 32'h0220_81b3, 1'b1,
              32'h100c, 32'h0020_8233);

    // Taken BEQ is predicted not-taken. Its lane1 instruction must be killed.
    send_pair(32'h1010, 32'h0010_8463, 1'b1,
              32'h1014, 32'h0630_0313);
    begin
      int unsigned timeout;
      timeout = 0;
      while (!redirect_valid && (timeout < 80)) begin
        @(negedge clk);
        timeout++;
      end
      if (!redirect_valid || (redirect_pc != 32'h1018))
        $fatal(1, "Branch recovery redirect missing or wrong: %h", redirect_pc);
    end

    send_pair(32'h1018, 32'h02a0_0313, 1'b0, '0, '0);
    begin
      int unsigned timeout;
      timeout = 0;
      while ((write_count < 5) && (timeout < 120)) begin
        @(negedge clk);
        timeout++;
      end
    end

    if (write_count != 5)
      $fatal(1, "Expected five architectural writes, saw %0d", write_count);
    if ((write_rd[0] != 1) || (write_data[0] != 5) ||
        (write_rd[1] != 2) || (write_data[1] != 7) ||
        (write_rd[2] != 3) || (write_data[2] != 35) ||
        (write_rd[3] != 4) || (write_data[3] != 12) ||
        (write_rd[4] != 6) || (write_data[4] != 42))
      $fatal(1, "OoO execution/in-order commit result or order is wrong");
    if (saw_bad_x6)
      $fatal(1, "Wrong-path x6 write became architecturally visible");

    // Store and younger load issue together. The load must receive x2 through
    // SQ forwarding, while the physical write is deferred until ROB commit.
    send_pair(32'h2000, 32'h8002_00b7, 1'b1,
              32'h2004, 32'h0550_0113);
    send_pair(32'h2008, 32'h0020_a023, 1'b1,
              32'h200c, 32'h0000_a183);
    begin
      int unsigned timeout;
      timeout = 0;
      while ((write_count < 8) && (timeout < 120)) begin
        @(negedge clk);
        timeout++;
      end
    end
    if ((write_count < 8) || (write_rd[5] != 1) ||
        (write_data[5] != 32'h8002_0000) || (write_rd[6] != 2) ||
        (write_data[6] != 32'h55) || (write_rd[7] != 3) ||
        (write_data[7] != 32'h55))
      $fatal(1, "Store-to-load forwarding produced the wrong architectural result");
    repeat (6) @(negedge clk);

    // Two independent loads target opposite DTIM banks and should use both LSU
    // request ports in one cycle. LW at +8 also checks sign extension.
    send_pair(32'h2010, 32'h0080_a203, 1'b1,
              32'h2014, 32'h0100_a283);
    begin
      int unsigned timeout;
      timeout = 0;
      while ((write_count < 10) && (timeout < 160)) begin
        @(negedge clk);
        timeout++;
      end
    end
    if ((write_count != 10) || (write_rd[8] != 4) ||
        (write_data[8] != 32'hffff_ff80) || (write_rd[9] != 5) ||
        (write_data[9] != 32'h1234_5678))
      $fatal(1, "Dual LSU memory response or load formatting failed");
    if (saw_uncommitted_write)
      $fatal(1, "A store became externally visible before ROB commit");
    if (saw_bad_forward_read)
      $fatal(1, "Forwarded load incorrectly issued a stale memory read");
    if (memory_write_count != 1)
      $fatal(1, "Expected one committed store request, saw %0d",
             memory_write_count);
    if (memory_read_count != 2)
      $fatal(1, "Expected two non-forwarded load requests, saw %0d",
             memory_read_count);
    if (!saw_dual_load_request)
      $fatal(1, "Two ready loads did not use both LSU request ports");

    // Commit-time CSR execution: lane1 CSRRW depends on the lane0 LUI and
    // must return old mtvec while updating it only at architectural commit.
    send_pair(32'h3000, 32'h8000_04b7, 1'b1,
              32'h3004, 32'h3054_9073); // lui x9,0x80000; csrrw x0,mtvec,x9
    send_pair(32'h3008, 32'h3402_d3f3, 1'b1,
              32'h300c, 32'h3400_2473); // csrrwi x7,mscratch,5; csrrs x8,...
    begin
      int unsigned timeout;
      timeout = 0;
      while ((write_count < 13) && (timeout < 160)) begin
        @(negedge clk);
        timeout++;
      end
    end
    if ((write_count != 13) || (write_rd[10] != 9) ||
        (write_data[10] != 32'h8000_0000) || (write_rd[11] != 7) ||
        (write_data[11] != 0) || (write_rd[12] != 8) ||
        (write_data[12] != 5))
      $fatal(1, "Integrated CSR old-value/write ordering failed");

    // Enable MSIP locally and globally, then retire WFI. WFI first refetches
    // its next PC; asserting MSIP afterwards must vector to mtvec.
    send_pair(32'h3010, 32'h3044_5073, 1'b1,
              32'h3014, 32'h3004_5073); // csrrwi x0,mie,8; csrrwi x0,mstatus,8
    send_pair(32'h3020, 32'h1050_0073, 1'b0, '0, '0);
    begin
      int unsigned timeout;
      timeout = 0;
      while ((!redirect_valid || (redirect_pc != 32'h3024)) &&
             (timeout < 160)) begin
        @(negedge clk);
        timeout++;
      end
      if (!redirect_valid || (redirect_pc != 32'h3024))
        $fatal(1, "WFI did not serialize/refetch its next PC");
    end

    @(negedge clk);
    irq_software = 1'b1;
    // The level interrupt creates a combinational redirect before the next
    // active edge, where the frontend consumes it and the CSR file enters M.
    #1;
    if (!redirect_valid || (redirect_pc != 32'h8000_0000)) begin
      $display("MSIP diagnostic: irq=%0b pending=%0b mie=%08x mstatus=%08x mtvec=%08x rob_empty=%0b wfi_sleep=%0b redirect=%0b/%08x",
               irq_software, u_dut.csr_interrupt_pending,
               u_dut.u_csr_file.mie_q, u_dut.csr_mstatus, u_dut.csr_mtvec,
               u_dut.rob_empty, u_dut.wfi_sleep_q, redirect_valid, redirect_pc);
      $fatal(1, "Enabled MSIP did not vector through mtvec");
    end
    @(posedge clk);
    @(negedge clk);
    irq_software = 1'b0;

    // Handler MRET returns to the instruction after WFI. An ECALL at that
    // boundary then produces a precise synchronous redirect back to mtvec.
    send_pair(32'h8000_0000, 32'h3020_0073, 1'b0, '0, '0);
    begin
      int unsigned timeout;
      timeout = 0;
      while ((!redirect_valid || (redirect_pc != 32'h3024)) &&
             (timeout < 120)) begin
        @(negedge clk);
        timeout++;
      end
      if (!redirect_valid || (redirect_pc != 32'h3024))
        $fatal(1, "MRET did not return to the interrupted boundary");
    end
    send_pair(32'h3024, 32'h0000_0073, 1'b0, '0, '0);
    begin
      int unsigned timeout;
      timeout = 0;
      while ((!redirect_valid || (redirect_pc != 32'h8000_0000)) &&
             (timeout < 120)) begin
        @(negedge clk);
        timeout++;
      end
      if (!redirect_valid || (redirect_pc != 32'h8000_0000) ||
          !trace_trap[0])
        $fatal(1, "ECALL precise trap/trace is missing");
    end

    // MPRV with MPP=U makes data accesses use U privilege. With every PMP
    // entry OFF, the load must trap locally and must never reach D-memory.
    send_pair(32'h8000_0000, 32'h0002_0537, 1'b1,
              32'h8000_0004, 32'h3005_1073); // lui x10,0x20; csrw mstatus,x10
    begin
      int unsigned requests_before;
      int unsigned timeout;
      requests_before = memory_request_count;
      send_pair(32'h8000_0008, 32'h0000_2583, 1'b0, '0, '0); // lw x11,0(x0)
      timeout = 0;
      while ((!redirect_valid || (redirect_pc != 32'h8000_0000)) &&
             (timeout < 120)) begin
        @(negedge clk);
        timeout++;
      end
      if (!redirect_valid || !trace_trap[0])
        $fatal(1, "PMP-denied load did not create a precise trap");
      if (memory_request_count != requests_before)
        $fatal(1, "PMP-denied load escaped to D-memory");
    end

    send_pair(32'h8000_0000, 32'h0002_0537, 1'b1,
              32'h8000_0004, 32'h3005_1073);
    begin
      int unsigned requests_before;
      int unsigned timeout;
      requests_before = memory_request_count;
      send_pair(32'h8000_0008, 32'h0000_2023, 1'b0, '0, '0); // sw x0,0(x0)
      timeout = 0;
      while ((!redirect_valid || (redirect_pc != 32'h8000_0000)) &&
             (timeout < 120)) begin
        @(negedge clk);
        timeout++;
      end
      if (!redirect_valid || !trace_trap[0])
        $fatal(1, "PMP-denied store did not create a precise trap");
      if (memory_request_count != requests_before)
        $fatal(1, "PMP-denied store escaped to D-memory");
    end

    $display("rv_backend_int_tb PASS");
    $finish;
  end
endmodule
