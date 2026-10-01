module rv_fetch_queue_equiv_tb #(
  parameter int XLEN = 32,
  parameter int FETCH_BYTES = 16,
  parameter int QUEUE_BYTES = 64
);
  import rv_ooo_pkg::*;
  localparam int CW = $clog2(QUEUE_BYTES+1);
  logic clk=0, rst_n=0;
  always #5 clk=~clk;
  logic fill_valid, redirect_valid;
  logic [31:0] fill_addr, next_fill_addr;
  logic [XLEN-1:0] redirect_pc;
  logic [FETCH_BYTES*8-1:0] fill_data;
  logic [1:0] fill_resp, out_ready;
  logic [FETCH_BYTES/2-1:0] pmp_allow;
  logic ready, ref_ready, empty, ref_empty;
  logic [CW-1:0] count, ref_count;
  logic [1:0] valid, ref_valid, fault, ref_fault;
  logic [1:0][XLEN-1:0] pc, ref_pc;
  logic [1:0][31:0] instr, ref_instr;
  inst_len_e [1:0] len, ref_len;
  int unsigned seed=32'h5179acdf;
  function automatic int unsigned random_word();
    seed ^= seed<<13; seed ^= seed>>17; seed ^= seed<<5;
    return seed;
  endfunction
  rv_fetch_queue #(.XLEN(XLEN), .FETCH_BYTES(FETCH_BYTES), .QUEUE_BYTES(QUEUE_BYTES), .UNGATED_PAYLOAD(1'b1), .SEPARATE_NORMAL_FILL_ADDRESS(1'b1)) dut (
    .clk_i(clk), .rst_ni(rst_n), .fill_valid_i(fill_valid),
    .fill_ready_o(ready), .fill_addr_i(fill_addr), .normal_fill_addr_i(fill_addr), .normal_fill_valid_i(fill_valid), .fill_id_i(4'd0),
    .fill_epoch_i(4'd0), .fill_data_i(fill_data), .fill_resp_i(fill_resp),
    .fill_pmp_allow_i(pmp_allow), .redirect_valid_i(redirect_valid),
    .redirect_pc_i(redirect_pc), .new_epoch_i(4'd0),
    .out_valid_o(valid), .out_ready_i(out_ready), .out_pc_o(pc),
    .out_instruction_o(instr), .out_inst_len_o(len), .out_fault_o(fault),
    .empty_o(empty), .byte_count_o(count)
  );
  rv_fetch_queue_ref #(.XLEN(XLEN), .FETCH_BYTES(FETCH_BYTES), .QUEUE_BYTES(QUEUE_BYTES)) reference (
    .clk_i(clk), .rst_ni(rst_n), .fill_valid_i(fill_valid),
    .fill_ready_o(ref_ready), .fill_addr_i(fill_addr), .fill_id_i(4'd0),
    .fill_epoch_i(4'd0), .fill_data_i(fill_data), .fill_resp_i(fill_resp),
    .fill_pmp_allow_i(pmp_allow), .redirect_valid_i(redirect_valid),
    .redirect_pc_i(redirect_pc), .new_epoch_i(4'd0),
    .out_valid_o(ref_valid), .out_ready_i(out_ready), .out_pc_o(ref_pc),
    .out_instruction_o(ref_instr), .out_inst_len_o(ref_len), .out_fault_o(ref_fault),
    .empty_o(ref_empty), .byte_count_o(ref_count)
  );
  initial begin
    fill_valid=0; redirect_valid=0; fill_addr=32'h80000000;
    next_fill_addr=fill_addr; redirect_pc=0; fill_data=0;
    fill_resp=0; pmp_allow='1; out_ready=0;
    repeat(3) @(negedge clk);
    rst_n=1;
    for (int cycle=0; cycle<60000; cycle++) begin
      rst_n=(cycle%733 != 732);
      redirect_valid=(random_word()%23 == 0) && rst_n;
      redirect_pc=XLEN'(32'h80000000 | (random_word()&32'hfffe));
      fill_addr=redirect_valid ? (32'(redirect_pc)&~32'(FETCH_BYTES-1)) : next_fill_addr;
      fill_valid=(random_word()%4 != 0);
      for(int word=0; word<FETCH_BYTES/4; word++)
        fill_data[word*32 +:32]=random_word();
      fill_resp=(random_word()%19 == 0) ? 2'b10 : 2'b00;
      pmp_allow=(FETCH_BYTES/2)'(random_word());
      out_ready=2'(random_word());
      #1;
      if ({ready,empty,count,valid} !== {ref_ready,ref_empty,ref_count,ref_valid})
        $fatal(1,"Queue control mismatch cycle=%0d",cycle);
      for(int lane=0; lane<2; lane++)
        if(valid[lane] && {pc[lane],instr[lane],len[lane],fault[lane]} !==
                          {ref_pc[lane],ref_instr[lane],ref_len[lane],ref_fault[lane]})
          $fatal(1,"Queue payload mismatch cycle=%0d lane=%0d",cycle,lane);
      if(!rst_n) next_fill_addr=32'h80000000;
      else if(redirect_valid) next_fill_addr=fill_addr+(fill_valid&&ready ? FETCH_BYTES : 0);
      else if(fill_valid&&ready) next_fill_addr=fill_addr+FETCH_BYTES;
      @(negedge clk);
    end
    $display("fetch queue cycle equality PASS XLEN=%0d FETCH=%0d QUEUE=%0d cycles=60000",XLEN,FETCH_BYTES,QUEUE_BYTES);
    $finish;
  end
endmodule
