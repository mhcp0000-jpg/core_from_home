module rv_fetch_queue_tb;
  import rv_ooo_pkg::*;

  logic clk;
  logic rst_n;
  logic fill_valid;
  logic fill_ready;
  logic [31:0] fill_addr;
  logic [127:0] fill_data;
  logic [1:0] fill_resp;
  logic [7:0] fill_pmp_allow;
  logic redirect_valid;
  logic [31:0] redirect_pc;
  logic [1:0] out_valid;
  logic [1:0] out_ready;
  logic [1:0][31:0] out_pc;
  logic [1:0][31:0] out_instruction;
  inst_len_e [1:0] out_inst_len;
  logic [1:0] out_fault;

  logic cross_fill_valid;
  logic cross_fill_ready;
  logic [31:0] cross_fill_addr;
  logic [127:0] cross_fill_data;
  logic [7:0] cross_fill_pmp_allow;
  logic [1:0] cross_out_valid;
  logic [1:0][31:0] cross_out_instruction;
  logic [1:0][31:0] cross_out_pc;
  logic [1:0] cross_out_fault;

  always #5 clk = ~clk;

  rv_fetch_queue #(.RESET_VECTOR(32'h0000_1000)) u_queue (
    .clk_i              (clk),
    .rst_ni             (rst_n),
    .fill_valid_i       (fill_valid),
    .fill_ready_o       (fill_ready),
    .fill_addr_i        (fill_addr),
    .fill_id_i          (4'd1),
    .fill_epoch_i       (4'd0),
    .fill_data_i        (fill_data),
    .fill_resp_i        (fill_resp),
    .fill_pmp_allow_i   (fill_pmp_allow),
    .redirect_valid_i   (redirect_valid),
    .redirect_pc_i      (redirect_pc),
    .new_epoch_i        (4'd1),
    .out_valid_o        (out_valid),
    .out_ready_i        (out_ready),
    .out_pc_o           (out_pc),
    .out_instruction_o  (out_instruction),
    .out_inst_len_o     (out_inst_len),
    .out_fault_o        (out_fault)
  );

  rv_fetch_queue #(.RESET_VECTOR(32'h0000_100e)) u_cross_queue (
    .clk_i              (clk),
    .rst_ni             (rst_n),
    .fill_valid_i       (cross_fill_valid),
    .fill_ready_o       (cross_fill_ready),
    .fill_addr_i        (cross_fill_addr),
    .fill_id_i          (4'd2),
    .fill_epoch_i       (4'd0),
    .fill_data_i        (cross_fill_data),
    .fill_resp_i        (2'b00),
    .fill_pmp_allow_i   (cross_fill_pmp_allow),
    .redirect_valid_i   (1'b0),
    .redirect_pc_i      (32'd0),
    .new_epoch_i        (4'd0),
    .out_valid_o        (cross_out_valid),
    .out_ready_i        (2'b00),
    .out_pc_o           (cross_out_pc),
    .out_instruction_o  (cross_out_instruction),
    .out_fault_o        (cross_out_fault)
  );

  initial begin : p_fetch_queue_test
    clk = 1'b0;
    rst_n = 1'b0;
    fill_valid = 1'b0;
    fill_addr = 32'h1000;
    fill_data = '0;
    fill_resp = 2'b00;
    fill_pmp_allow = '1;
    redirect_valid = 1'b0;
    redirect_pc = '0;
    out_ready = 2'b00;
    cross_fill_valid = 1'b0;
    cross_fill_addr = 32'h1000;
    cross_fill_data = '0;
    cross_fill_pmp_allow = '1;
    repeat (2) @(posedge clk);
    rst_n = 1'b1;

    // C.NOP, ADDI x1,x0,1, C.EBREAK in little-endian byte order.
    fill_data[15:0] = 16'h0001;
    fill_data[47:16] = 32'h0010_0093;
    fill_data[63:48] = 16'h9002;
    fill_valid = 1'b1;
    @(posedge clk);
    fill_valid = 1'b0;
    #1;
    if ((out_valid != 2'b11) || (out_inst_len[0] != INST_LEN_16) ||
        (out_inst_len[1] != INST_LEN_32) ||
        (out_instruction[0] != 32'h0000_0001) ||
        (out_instruction[1] != 32'h0010_0093) ||
        (out_pc[0] != 32'h1000) || (out_pc[1] != 32'h1002))
      $fatal(1, "Mixed C/32-bit dual extraction failed");

    out_ready = 2'b11;
    @(posedge clk);
    out_ready = 2'b00;
    #1;
    if (!out_valid[0] || (out_instruction[0] != 32'h0000_9002) ||
        (out_pc[0] != 32'h1006))
      $fatal(1, "Fetch queue consume/PC update failed");

    // A 32-bit ADDI begins at byte 14 and finishes in the next block.
    cross_fill_data = '0;
    cross_fill_data[14*8 +: 8] = 8'h93;
    cross_fill_data[15*8 +: 8] = 8'h00;
    cross_fill_valid = 1'b1;
    @(posedge clk);
    cross_fill_valid = 1'b0;
    #1;
    if (cross_out_valid[0])
      $fatal(1, "Cross-block instruction issued before all bytes arrived");

    cross_fill_addr = 32'h1010;
    cross_fill_data = '0;
    cross_fill_data[7:0] = 8'h10;
    cross_fill_data[15:8] = 8'h00;
    // The high half of this instruction belongs to parcel 0 of the second
    // block.  Denying that parcel must propagate across the block boundary.
    cross_fill_pmp_allow = 8'b1111_1110;
    cross_fill_valid = 1'b1;
    @(posedge clk);
    cross_fill_valid = 1'b0;
    #1;
    if (!cross_out_valid[0] ||
        (cross_out_instruction[0] != 32'h0010_0093) ||
        (cross_out_pc[0] != 32'h100e) || !cross_out_fault[0])
      $fatal(1, "Cross-block 32-bit assembly/fault propagation failed");

    // A target-buffer hit supplies redirect and aligned block together.  The
    // queue must discard the old path and expose the unaligned target bytes
    // immediately after this edge, without an empty replay cycle.
    redirect_pc = 32'h2002;
    fill_addr = 32'h2000;
    fill_data = '0;
    fill_data[2*8 +: 16] = 16'h0001;
    fill_data[4*8 +: 32] = 32'h0010_0093;
    fill_valid = 1'b1;
    redirect_valid = 1'b1;
    @(posedge clk);
    fill_valid = 1'b0;
    redirect_valid = 1'b0;
    #1;
    if ((out_valid != 2'b11) ||
        (out_pc[0] != 32'h2002) || (out_pc[1] != 32'h2004) ||
        (out_instruction[0] != 32'h0000_0001) ||
        (out_instruction[1] != 32'h0010_0093))
      $fatal(1, "Atomic redirect/fill did not expose target instructions");

    redirect_pc = 32'h3000;
    redirect_valid = 1'b1;
    @(posedge clk);
    redirect_valid = 1'b0;
    #1;
    if (out_valid != 0)
      $fatal(1, "Redirect did not clear fetch queue");

    // Bytes earlier in the same 16-byte transport block may be denied without
    // poisoning a legal 32-bit instruction at byte offset 12.  This is the
    // PMP TOR=0x...8fc boundary case that used to reject the whole block.
    redirect_pc = 32'h400c;
    fill_addr = 32'h4000;
    fill_data = '0;
    fill_data[12*8 +: 32] = 32'h8000_0b37;
    fill_pmp_allow = 8'b1100_0000;
    fill_valid = 1'b1;
    redirect_valid = 1'b1;
    @(posedge clk);
    fill_valid = 1'b0;
    redirect_valid = 1'b0;
    #1;
    if (!out_valid[0] || out_fault[0] ||
        (out_pc[0] != 32'h400c) ||
        (out_instruction[0] != 32'h8000_0b37))
      $fatal(1, "Denied neighboring parcels poisoned legal instruction");

    // A 32-bit instruction needs both of its own 2-byte parcels.
    fill_pmp_allow = 8'b0100_0000;
    fill_valid = 1'b1;
    redirect_valid = 1'b1;
    @(posedge clk);
    fill_valid = 1'b0;
    redirect_valid = 1'b0;
    #1;
    if (!out_valid[0] || !out_fault[0])
      $fatal(1, "Denied second parcel did not fault 32-bit instruction");

    // A compressed instruction consumes exactly one 2-byte parcel.
    redirect_pc = 32'h5002;
    fill_addr = 32'h5000;
    fill_data = '0;
    fill_data[2*8 +: 16] = 16'h0001;
    fill_pmp_allow = 8'b1111_1101;
    fill_valid = 1'b1;
    redirect_valid = 1'b1;
    @(posedge clk);
    fill_valid = 1'b0;
    redirect_valid = 1'b0;
    #1;
    if (!out_valid[0] || !out_fault[0] ||
        (out_inst_len[0] != INST_LEN_16))
      $fatal(1, "Denied compressed-instruction parcel was not faulted");

    $display("rv_fetch_queue_tb PASS");
    $finish;
  end
endmodule
