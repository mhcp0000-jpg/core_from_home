module rv_decode2_tb;
  import rv_ooo_pkg::*;

  logic [15:0] c32_in;
  logic [31:0] c32_out;
  logic c32_illegal;
  logic [15:0] c64_in;
  logic [31:0] c64_out;
  logic c64_illegal;

  logic [1:0] in_valid;
  logic [1:0] in_ready;
  logic [1:0][31:0] in_pc;
  logic [1:0][31:0] in_instruction;
  inst_len_e [1:0] in_inst_len;
  prediction_meta_t [1:0] in_prediction;
  logic [1:0] in_fetch_fault;
  logic [1:0] uop_valid;
  logic [1:0] uop_ready;
  logic [1:0][31:0] uop_canonical;
  fu_class_e [1:0] uop_fu;
  logic [1:0][15:0] uop_operation;
  logic [1:0][4:0] uop_port_mask;
  reg_class_e [1:0][2:0] uop_src_class;
  logic [1:0][2:0][4:0] uop_src_arch;
  logic [1:0][2:0] uop_src_used;
  reg_class_e [1:0] uop_dst_class;
  logic [1:0][4:0] uop_dst_arch;
  logic [1:0] uop_writes_dst;
  logic [1:0][31:0] uop_immediate;
  logic [1:0][2:0] uop_mem_size;
  logic [1:0] uop_mem_unsigned;
  logic [1:0] uop_is_load;
  logic [1:0] uop_is_store;
  logic [1:0] uop_is_branch;
  logic [1:0] uop_is_csr;
  logic [1:0] uop_is_fence_i;
  logic [1:0] uop_exception_valid;
  exception_code_e [1:0] uop_exception_cause;

  rv_c_expander #(.XLEN(32)) u_c32 (
    .compressed_i  (c32_in),
    .instruction_o (c32_out),
    .illegal_o     (c32_illegal)
  );

  rv_c_expander #(.XLEN(64)) u_c64 (
    .compressed_i  (c64_in),
    .instruction_o (c64_out),
    .illegal_o     (c64_illegal)
  );

  rv_decode2 #(.XLEN(32)) u_decode (
    .in_valid_i                    (in_valid),
    .in_ready_o                    (in_ready),
    .in_pc_i                       (in_pc),
    .in_instruction_i              (in_instruction),
    .in_inst_len_i                 (in_inst_len),
    .in_prediction_i               (in_prediction),
    .in_fetch_fault_i              (in_fetch_fault),
    .uop_valid_o                   (uop_valid),
    .uop_ready_i                   (uop_ready),
    .uop_canonical_instruction_o   (uop_canonical),
    .uop_fu_o                      (uop_fu),
    .uop_operation_o               (uop_operation),
    .uop_exec_port_mask_o          (uop_port_mask),
    .uop_src_class_o               (uop_src_class),
    .uop_src_arch_o                (uop_src_arch),
    .uop_src_used_o                (uop_src_used),
    .uop_dst_class_o               (uop_dst_class),
    .uop_dst_arch_o                (uop_dst_arch),
    .uop_writes_dst_o              (uop_writes_dst),
    .uop_immediate_o               (uop_immediate),
    .uop_mem_size_o                (uop_mem_size),
    .uop_mem_unsigned_o            (uop_mem_unsigned),
    .uop_is_load_o                 (uop_is_load),
    .uop_is_store_o                (uop_is_store),
    .uop_is_branch_o               (uop_is_branch),
    .uop_is_csr_o                  (uop_is_csr),
    .uop_is_fence_i_o              (uop_is_fence_i),
    .uop_exception_valid_o         (uop_exception_valid),
    .uop_exception_cause_o         (uop_exception_cause)
  );

  task automatic drive32(input logic [31:0] instruction);
    in_instruction[0] = instruction;
    in_instruction[1] = 32'h0000_0013;
    in_inst_len[0] = INST_LEN_32;
    in_inst_len[1] = INST_LEN_32;
    #1;
  endtask

  initial begin : p_decode_test
    c32_in = 16'h0001; // C.NOP
    c64_in = 16'h2085; // C.ADDIW x1,x1,1 on RV64
    in_valid = 2'b01;
    in_pc[0] = 32'h8000_0000;
    in_pc[1] = 32'h8000_0004;
    in_instruction = '0;
    in_inst_len[0] = INST_LEN_32;
    in_inst_len[1] = INST_LEN_32;
    in_prediction = '0;
    in_fetch_fault = '0;
    uop_ready = 2'b11;
    #1;

    if (c32_illegal || (c32_out != 32'h0000_0013))
      $fatal(1, "C.NOP expansion failed");
    if (c64_illegal || (c64_out != 32'h0010_809b))
      $fatal(1, "RV64 C.ADDIW expansion failed");

    c32_in = 16'h9002; // C.EBREAK
    #1;
    if (c32_illegal || (c32_out != 32'h0010_0073))
      $fatal(1, "C.EBREAK expansion failed");

    drive32(32'h0020_81b3); // ADD x3,x1,x2
    if ((uop_fu[0] != FU_INT) || (uop_operation[0] != 16'(ALU_ADD)) ||
        (uop_port_mask[0] != 5'b00011) ||
        (uop_src_arch[0][0] != 1) || (uop_src_arch[0][1] != 2) ||
        (uop_dst_arch[0] != 3) || !uop_writes_dst[0] ||
        uop_exception_valid[0])
      $fatal(1, "ADD decode failed");

    drive32(32'h0083_2283); // LW x5,8(x6)
    if (!uop_is_load[0] || (uop_fu[0] != FU_LOAD) ||
        (uop_mem_size[0] != 2) || (uop_immediate[0] != 8) ||
        (uop_dst_class[0] != REG_INT))
      $fatal(1, "LW decode failed");

    drive32(32'h0053_2623); // SW x5,12(x6)
    if (!uop_is_store[0] || (uop_fu[0] != FU_STORE) ||
        (uop_immediate[0] != 12) ||
        (uop_src_class[0][1] != REG_INT) || (uop_src_arch[0][1] != 5))
      $fatal(1, "SW decode failed");

    drive32(32'h0220_81b3); // MUL x3,x1,x2
    if ((uop_fu[0] != FU_MUL) || (uop_port_mask[0] != 5'b00010))
      $fatal(1, "MUL decode failed");

    drive32(32'h0000_100f); // FENCE.I
    if (!uop_is_fence_i[0] || uop_exception_valid[0])
      $fatal(1, "FENCE.I decode failed");

    drive32(32'h3001_10f3); // CSRRW x1,mstatus,x2
    if (!uop_is_csr[0] || (uop_fu[0] != FU_CSR) ||
        (uop_src_arch[0][0] != 2) || (uop_dst_arch[0] != 1))
      $fatal(1, "CSRRW decode failed");

    in_instruction[0] = 32'hffff_ffff;
    #1;
    if (!uop_exception_valid[0] ||
        (uop_exception_cause[0] != EXC_ILLEGAL_INSTRUCTION))
      $fatal(1, "Illegal instruction decode failed");

    in_valid = 2'b10;
    #1;
    if (uop_valid[1])
      $fatal(1, "Lane1 became valid without lane0");

    $display("rv_decode2_tb PASS");
    $finish;
  end
endmodule
