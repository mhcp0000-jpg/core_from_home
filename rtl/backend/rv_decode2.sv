module rv_decode2 #(
  parameter int unsigned XLEN      = 32,
  parameter bit          HAS_C     = 1'b1,
  parameter bit          HAS_F     = 1'b1,
  parameter bit          HAS_SMODE = 1'b0
) (
  input  logic [1:0]                         in_valid_i,
  output logic [1:0]                         in_ready_o,
  input  logic [1:0][XLEN-1:0]               in_pc_i,
  input  logic [1:0][31:0]                   in_instruction_i,
  input  rv_ooo_pkg::inst_len_e [1:0]        in_inst_len_i,
  input  rv_ooo_pkg::prediction_meta_t [1:0] in_prediction_i,
  input  logic [1:0]                         in_fetch_fault_i,

  output logic [1:0]                         uop_valid_o,
  input  logic [1:0]                         uop_ready_i,
  output logic [1:0][XLEN-1:0]               uop_pc_o,
  output logic [1:0][31:0]                   uop_raw_instruction_o,
  output logic [1:0][31:0]                   uop_canonical_instruction_o,
  output rv_ooo_pkg::inst_len_e [1:0]        uop_inst_len_o,
  output rv_ooo_pkg::prediction_meta_t [1:0] uop_prediction_o,
  output rv_ooo_pkg::fu_class_e [1:0]        uop_fu_o,
  output logic [1:0][15:0]                   uop_operation_o,
  output logic [1:0][4:0]                    uop_exec_port_mask_o,
  output rv_ooo_pkg::reg_class_e [1:0][2:0] uop_src_class_o,
  output logic [1:0][2:0][4:0]               uop_src_arch_o,
  output logic [1:0][2:0]                    uop_src_used_o,
  output rv_ooo_pkg::reg_class_e [1:0]       uop_dst_class_o,
  output logic [1:0][4:0]                    uop_dst_arch_o,
  output logic [1:0]                         uop_writes_dst_o,
  output logic [1:0][XLEN-1:0]               uop_immediate_o,
  output logic [1:0][2:0]                    uop_mem_size_o,
  output logic [1:0]                         uop_mem_unsigned_o,
  output logic [1:0][11:0]                   uop_csr_addr_o,
  output logic [1:0][2:0]                    uop_rounding_mode_o,
  output logic [1:0][3:0]                    uop_fence_predecessor_o,
  output logic [1:0][3:0]                    uop_fence_successor_o,
  output logic [1:0]                         uop_use_pc_o,
  output logic [1:0]                         uop_use_immediate_o,
  output logic [1:0]                         uop_word_operation_o,
  output logic [1:0]                         uop_csr_immediate_o,
  output logic [1:0]                         uop_is_load_o,
  output logic [1:0]                         uop_is_store_o,
  output logic [1:0]                         uop_is_branch_o,
  output logic [1:0]                         uop_is_csr_o,
  output logic [1:0]                         uop_is_fence_o,
  output logic [1:0]                         uop_is_fence_i_o,
  output logic [1:0]                         uop_is_serializing_o,
  output logic [1:0]                         uop_exception_valid_o,
  output rv_ooo_pkg::exception_code_e [1:0] uop_exception_cause_o,
  output logic [1:0][XLEN-1:0]               uop_exception_tval_o
);

  import rv_ooo_pkg::*;

  localparam logic [4:0] PORT_INT0 = 5'b00001;
  localparam logic [4:0] PORT_INT1 = 5'b00010;
  localparam logic [4:0] PORT_MEM  = 5'b01100;
  localparam logic [4:0] PORT_FP   = 5'b10000;

  localparam logic [15:0] SYS_ECALL  = 16'h0100;
  localparam logic [15:0] SYS_EBREAK = 16'h0101;
  localparam logic [15:0] SYS_MRET   = 16'h0102;
  localparam logic [15:0] SYS_SRET   = 16'h0103;
  localparam logic [15:0] SYS_WFI    = 16'h0104;

  logic [1:0][31:0] expanded_instruction;
  logic [1:0] compressed_illegal;

  for (genvar lane = 0; lane < 2; lane++) begin : g_c_expander
    rv_c_expander #(.XLEN(XLEN)) u_c_expander (
      .compressed_i  (in_instruction_i[lane][15:0]),
      .instruction_o (expanded_instruction[lane]),
      .illegal_o     (compressed_illegal[lane])
    );
  end

  function automatic logic [XLEN-1:0] imm_i(input logic [31:0] insn);
    return {{(XLEN-12){insn[31]}}, insn[31:20]};
  endfunction

  function automatic logic [XLEN-1:0] imm_s(input logic [31:0] insn);
    return {{(XLEN-12){insn[31]}}, insn[31:25], insn[11:7]};
  endfunction

  function automatic logic [XLEN-1:0] imm_b(input logic [31:0] insn);
    return {{(XLEN-13){insn[31]}}, insn[31], insn[7], insn[30:25],
            insn[11:8], 1'b0};
  endfunction

  function automatic logic [XLEN-1:0] imm_u(input logic [31:0] insn);
    return {{(XLEN-32){insn[31]}}, insn[31:12], 12'b0};
  endfunction

  function automatic logic [XLEN-1:0] imm_j(input logic [31:0] insn);
    return {{(XLEN-21){insn[31]}}, insn[31], insn[19:12], insn[20],
            insn[30:21], 1'b0};
  endfunction

  function automatic logic valid_rounding_mode(input logic [2:0] rm);
    return (rm <= 3'b100) || (rm == 3'b111);
  endfunction

  always @(*) begin
    in_ready_o[0] = uop_ready_i[0] &&
                    (!in_valid_i[1] || uop_ready_i[1]);
    in_ready_o[1] = uop_ready_i[0] &&
                    (!in_valid_i[1] || uop_ready_i[1]) && in_valid_i[0];
    uop_valid_o[0] = in_valid_i[0];
    uop_valid_o[1] = in_valid_i[1] && in_valid_i[0];
  end

  for (genvar lane = 0; lane < 2; lane++) begin : g_decode_lane
    always @(*) begin
      logic [31:0] insn;
      logic [6:0] opcode;
      logic [6:0] funct7;
      logic [2:0] funct3;
      logic [4:0] rs1;
      logic [4:0] rs2;
      logic [4:0] rd;
      logic illegal;

      insn = (in_inst_len_i[lane] == INST_LEN_16) ?
             expanded_instruction[lane] : in_instruction_i[lane];
      opcode = insn[6:0];
      funct7 = insn[31:25];
      funct3 = insn[14:12];
      rs1 = insn[19:15];
      rs2 = insn[24:20];
      rd = insn[11:7];
      illegal = 1'b0;

      uop_pc_o[lane] = in_pc_i[lane];
      uop_raw_instruction_o[lane] = in_instruction_i[lane];
      uop_canonical_instruction_o[lane] = insn;
      uop_inst_len_o[lane] = in_inst_len_i[lane];
      uop_prediction_o[lane] = in_prediction_i[lane];
      uop_fu_o[lane] = FU_NONE;
      uop_operation_o[lane] = '0;
      uop_exec_port_mask_o[lane] = '0;
      uop_src_class_o[lane][0] = REG_NONE;
      uop_src_class_o[lane][1] = REG_NONE;
      uop_src_class_o[lane][2] = REG_NONE;
      uop_src_arch_o[lane] = '0;
      uop_src_used_o[lane] = '0;
      uop_dst_class_o[lane] = REG_NONE;
      uop_dst_arch_o[lane] = rd;
      uop_writes_dst_o[lane] = 1'b0;
      uop_immediate_o[lane] = '0;
      uop_mem_size_o[lane] = '0;
      uop_mem_unsigned_o[lane] = 1'b0;
      uop_csr_addr_o[lane] = insn[31:20];
      uop_rounding_mode_o[lane] = funct3;
      uop_fence_predecessor_o[lane] = insn[27:24];
      uop_fence_successor_o[lane] = insn[23:20];
      uop_use_pc_o[lane] = 1'b0;
      uop_use_immediate_o[lane] = 1'b0;
      uop_word_operation_o[lane] = 1'b0;
      uop_csr_immediate_o[lane] = 1'b0;
      uop_is_load_o[lane] = 1'b0;
      uop_is_store_o[lane] = 1'b0;
      uop_is_branch_o[lane] = 1'b0;
      uop_is_csr_o[lane] = 1'b0;
      uop_is_fence_o[lane] = 1'b0;
      uop_is_fence_i_o[lane] = 1'b0;
      uop_is_serializing_o[lane] = 1'b0;
      uop_exception_valid_o[lane] = 1'b0;
      uop_exception_cause_o[lane] = EXC_ILLEGAL_INSTRUCTION;
      uop_exception_tval_o[lane] = '0;

      case (opcode)
        7'b0110111: begin // LUI
          uop_fu_o[lane] = FU_INT;
          uop_operation_o[lane] = 16'(ALU_COPY_SRC1);
          uop_exec_port_mask_o[lane] = PORT_INT0 | PORT_INT1;
          uop_dst_class_o[lane] = REG_INT;
          uop_writes_dst_o[lane] = (rd != 0);
          uop_immediate_o[lane] = imm_u(insn);
          uop_use_immediate_o[lane] = 1'b1;
        end

        7'b0010111: begin // AUIPC
          uop_fu_o[lane] = FU_INT;
          uop_operation_o[lane] = 16'(ALU_ADD);
          uop_exec_port_mask_o[lane] = PORT_INT0 | PORT_INT1;
          uop_dst_class_o[lane] = REG_INT;
          uop_writes_dst_o[lane] = (rd != 0);
          uop_immediate_o[lane] = imm_u(insn);
          uop_use_pc_o[lane] = 1'b1;
          uop_use_immediate_o[lane] = 1'b1;
        end

        7'b1101111: begin // JAL
          uop_fu_o[lane] = FU_BRANCH;
          uop_operation_o[lane] = 16'(BR_JAL);
          uop_exec_port_mask_o[lane] = PORT_INT0;
          uop_dst_class_o[lane] = REG_INT;
          uop_writes_dst_o[lane] = (rd != 0);
          uop_immediate_o[lane] = imm_j(insn);
          uop_is_branch_o[lane] = 1'b1;
        end

        7'b1100111: begin // JALR
          uop_fu_o[lane] = FU_BRANCH;
          uop_operation_o[lane] = 16'(BR_JALR);
          uop_exec_port_mask_o[lane] = PORT_INT0;
          uop_src_class_o[lane][0] = REG_INT;
          uop_src_arch_o[lane][0] = rs1;
          uop_src_used_o[lane][0] = 1'b1;
          uop_dst_class_o[lane] = REG_INT;
          uop_writes_dst_o[lane] = (rd != 0);
          uop_immediate_o[lane] = imm_i(insn);
          uop_is_branch_o[lane] = 1'b1;
          illegal = (funct3 != 3'b000);
        end

        7'b1100011: begin // conditional branch
          uop_fu_o[lane] = FU_BRANCH;
          uop_exec_port_mask_o[lane] = PORT_INT0;
          uop_src_class_o[lane][0] = REG_INT;
          uop_src_class_o[lane][1] = REG_INT;
          uop_src_arch_o[lane][0] = rs1;
          uop_src_arch_o[lane][1] = rs2;
          uop_src_used_o[lane][0] = 1'b1;
          uop_src_used_o[lane][1] = 1'b1;
          uop_immediate_o[lane] = imm_b(insn);
          uop_is_branch_o[lane] = 1'b1;
          case (funct3)
            3'b000: uop_operation_o[lane] = 16'(BR_EQ);
            3'b001: uop_operation_o[lane] = 16'(BR_NE);
            3'b100: uop_operation_o[lane] = 16'(BR_LT);
            3'b101: uop_operation_o[lane] = 16'(BR_GE);
            3'b110: uop_operation_o[lane] = 16'(BR_LTU);
            3'b111: uop_operation_o[lane] = 16'(BR_GEU);
            default: illegal = 1'b1;
          endcase
        end

        7'b0000011: begin // integer loads
          uop_fu_o[lane] = FU_LOAD;
          uop_exec_port_mask_o[lane] = PORT_MEM;
          uop_src_class_o[lane][0] = REG_INT;
          uop_src_arch_o[lane][0] = rs1;
          uop_src_used_o[lane][0] = 1'b1;
          uop_dst_class_o[lane] = REG_INT;
          uop_writes_dst_o[lane] = (rd != 0);
          uop_immediate_o[lane] = imm_i(insn);
          uop_is_load_o[lane] = 1'b1;
          case (funct3)
            3'b000: begin uop_mem_size_o[lane] = 0; uop_mem_unsigned_o[lane] = 0; end
            3'b001: begin uop_mem_size_o[lane] = 1; uop_mem_unsigned_o[lane] = 0; end
            3'b010: begin uop_mem_size_o[lane] = 2; uop_mem_unsigned_o[lane] = 0; end
            3'b011: begin uop_mem_size_o[lane] = 3; uop_mem_unsigned_o[lane] = 0;
                         illegal = (XLEN != 64); end
            3'b100: begin uop_mem_size_o[lane] = 0; uop_mem_unsigned_o[lane] = 1; end
            3'b101: begin uop_mem_size_o[lane] = 1; uop_mem_unsigned_o[lane] = 1; end
            3'b110: begin uop_mem_size_o[lane] = 2; uop_mem_unsigned_o[lane] = 1;
                         illegal = (XLEN != 64); end
            default: illegal = 1'b1;
          endcase
        end

        7'b0100011: begin // integer stores
          uop_fu_o[lane] = FU_STORE;
          uop_exec_port_mask_o[lane] = PORT_MEM;
          uop_src_class_o[lane][0] = REG_INT;
          uop_src_class_o[lane][1] = REG_INT;
          uop_src_arch_o[lane][0] = rs1;
          uop_src_arch_o[lane][1] = rs2;
          uop_src_used_o[lane][0] = 1'b1;
          uop_src_used_o[lane][1] = 1'b1;
          uop_immediate_o[lane] = imm_s(insn);
          uop_is_store_o[lane] = 1'b1;
          case (funct3)
            3'b000: uop_mem_size_o[lane] = 0;
            3'b001: uop_mem_size_o[lane] = 1;
            3'b010: uop_mem_size_o[lane] = 2;
            3'b011: begin uop_mem_size_o[lane] = 3; illegal = (XLEN != 64); end
            default: illegal = 1'b1;
          endcase
        end

        7'b0010011: begin // OP-IMM
          uop_fu_o[lane] = FU_INT;
          uop_exec_port_mask_o[lane] = PORT_INT0 | PORT_INT1;
          uop_src_class_o[lane][0] = REG_INT;
          uop_src_arch_o[lane][0] = rs1;
          uop_src_used_o[lane][0] = 1'b1;
          uop_dst_class_o[lane] = REG_INT;
          uop_writes_dst_o[lane] = (rd != 0);
          uop_immediate_o[lane] = imm_i(insn);
          uop_use_immediate_o[lane] = 1'b1;
          case (funct3)
            3'b000: uop_operation_o[lane] = 16'(ALU_ADD);
            3'b010: uop_operation_o[lane] = 16'(ALU_SLT);
            3'b011: uop_operation_o[lane] = 16'(ALU_SLTU);
            3'b100: uop_operation_o[lane] = 16'(ALU_XOR);
            3'b110: uop_operation_o[lane] = 16'(ALU_OR);
            3'b111: uop_operation_o[lane] = 16'(ALU_AND);
            3'b001: begin
              uop_operation_o[lane] = 16'(ALU_SLL);
              illegal = (XLEN == 32) ? (insn[31:25] != 7'b0000000) :
                                       (insn[31:26] != 6'b000000);
            end
            3'b101: begin
              uop_operation_o[lane] = insn[30] ? 16'(ALU_SRA) : 16'(ALU_SRL);
              illegal = (XLEN == 32) ?
                        !((insn[31:25] == 7'b0000000) ||
                          (insn[31:25] == 7'b0100000)) :
                        !((insn[31:26] == 6'b000000) ||
                          (insn[31:26] == 6'b010000));
            end
            default: illegal = 1'b1;
          endcase
        end

        7'b0110011: begin // OP / M
          uop_src_class_o[lane][0] = REG_INT;
          uop_src_class_o[lane][1] = REG_INT;
          uop_src_arch_o[lane][0] = rs1;
          uop_src_arch_o[lane][1] = rs2;
          uop_src_used_o[lane][0] = 1'b1;
          uop_src_used_o[lane][1] = 1'b1;
          uop_dst_class_o[lane] = REG_INT;
          uop_writes_dst_o[lane] = (rd != 0);
          if (funct7 == 7'b0000001) begin
            if (funct3 <= 3'b011) begin
              uop_fu_o[lane] = FU_MUL;
              uop_operation_o[lane] = {14'b0, funct3[1:0]};
            end else begin
              uop_fu_o[lane] = FU_DIV;
              uop_operation_o[lane] = {14'b0, funct3[1:0]};
            end
            uop_exec_port_mask_o[lane] = PORT_INT1;
          end else begin
            uop_fu_o[lane] = FU_INT;
            uop_exec_port_mask_o[lane] = PORT_INT0 | PORT_INT1;
            case (funct3)
              3'b000: begin
                uop_operation_o[lane] = funct7[5] ? 16'(ALU_SUB) : 16'(ALU_ADD);
                illegal = !((funct7 == 7'b0000000) || (funct7 == 7'b0100000));
              end
              3'b001: begin uop_operation_o[lane] = 16'(ALU_SLL);
                            illegal = (funct7 != 0); end
              3'b010: begin uop_operation_o[lane] = 16'(ALU_SLT);
                            illegal = (funct7 != 0); end
              3'b011: begin uop_operation_o[lane] = 16'(ALU_SLTU);
                            illegal = (funct7 != 0); end
              3'b100: begin uop_operation_o[lane] = 16'(ALU_XOR);
                            illegal = (funct7 != 0); end
              3'b101: begin
                uop_operation_o[lane] = funct7[5] ? 16'(ALU_SRA) : 16'(ALU_SRL);
                illegal = !((funct7 == 0) || (funct7 == 7'b0100000));
              end
              3'b110: begin uop_operation_o[lane] = 16'(ALU_OR);
                            illegal = (funct7 != 0); end
              3'b111: begin uop_operation_o[lane] = 16'(ALU_AND);
                            illegal = (funct7 != 0); end
              default: illegal = 1'b1;
            endcase
          end
        end

        7'b0011011: begin // OP-IMM-32
          uop_fu_o[lane] = FU_INT;
          uop_exec_port_mask_o[lane] = PORT_INT0 | PORT_INT1;
          uop_src_class_o[lane][0] = REG_INT;
          uop_src_arch_o[lane][0] = rs1;
          uop_src_used_o[lane][0] = 1'b1;
          uop_dst_class_o[lane] = REG_INT;
          uop_writes_dst_o[lane] = (rd != 0);
          uop_immediate_o[lane] = imm_i(insn);
          uop_use_immediate_o[lane] = 1'b1;
          uop_word_operation_o[lane] = 1'b1;
          illegal = (XLEN != 64);
          case (funct3)
            3'b000: uop_operation_o[lane] = 16'(ALU_ADD);
            3'b001: begin uop_operation_o[lane] = 16'(ALU_SLL);
                            if (funct7 != 0) illegal = 1'b1; end
            3'b101: begin
              uop_operation_o[lane] = insn[30] ? 16'(ALU_SRA) : 16'(ALU_SRL);
              if (!((funct7 == 0) || (funct7 == 7'b0100000)))
                illegal = 1'b1;
            end
            default: illegal = 1'b1;
          endcase
        end

        7'b0111011: begin // OP-32 / M-32
          uop_src_class_o[lane][0] = REG_INT;
          uop_src_class_o[lane][1] = REG_INT;
          uop_src_arch_o[lane][0] = rs1;
          uop_src_arch_o[lane][1] = rs2;
          uop_src_used_o[lane][0] = 1'b1;
          uop_src_used_o[lane][1] = 1'b1;
          uop_dst_class_o[lane] = REG_INT;
          uop_writes_dst_o[lane] = (rd != 0);
          uop_word_operation_o[lane] = 1'b1;
          illegal = (XLEN != 64);
          if (funct7 == 7'b0000001) begin
            if (funct3 == 3'b000) begin
              uop_fu_o[lane] = FU_MUL;
              uop_operation_o[lane] = 16'(MUL_LOW);
            end else if (funct3 >= 3'b100) begin
              uop_fu_o[lane] = FU_DIV;
              uop_operation_o[lane] = {14'b0, funct3[1:0]};
            end else begin
              illegal = 1'b1;
            end
            uop_exec_port_mask_o[lane] = PORT_INT1;
          end else begin
            uop_fu_o[lane] = FU_INT;
            uop_exec_port_mask_o[lane] = PORT_INT0 | PORT_INT1;
            case (funct3)
              3'b000: begin
                uop_operation_o[lane] = funct7[5] ? 16'(ALU_SUB) : 16'(ALU_ADD);
                if (!((funct7 == 0) || (funct7 == 7'b0100000)))
                  illegal = 1'b1;
              end
              3'b001: begin uop_operation_o[lane] = 16'(ALU_SLL);
                            if (funct7 != 0) illegal = 1'b1; end
              3'b101: begin
                uop_operation_o[lane] = funct7[5] ? 16'(ALU_SRA) : 16'(ALU_SRL);
                if (!((funct7 == 0) || (funct7 == 7'b0100000)))
                  illegal = 1'b1;
              end
              default: illegal = 1'b1;
            endcase
          end
        end

        7'b0001111: begin // FENCE / FENCE.I
          uop_fu_o[lane] = FU_FENCE;
          uop_exec_port_mask_o[lane] = PORT_INT0;
          uop_is_serializing_o[lane] = 1'b1;
          if (funct3 == 3'b000) begin
            uop_is_fence_o[lane] = 1'b1;
            uop_operation_o[lane] = 16'h0200;
          end else if (funct3 == 3'b001) begin
            uop_is_fence_i_o[lane] = 1'b1;
            uop_operation_o[lane] = 16'h0201;
          end else begin
            illegal = 1'b1;
          end
        end

        7'b1110011: begin // SYSTEM / CSR
          uop_fu_o[lane] = FU_CSR;
          uop_exec_port_mask_o[lane] = PORT_INT0;
          uop_is_serializing_o[lane] = 1'b1;
          if (funct3 == 3'b000) begin
            illegal = (rs1 != 0) || (rd != 0);
            case (insn[31:20])
              12'h000: uop_operation_o[lane] = SYS_ECALL;
              12'h001: begin
                uop_operation_o[lane] = SYS_EBREAK;
                uop_exception_valid_o[lane] = 1'b1;
                uop_exception_cause_o[lane] = EXC_BREAKPOINT;
                uop_exception_tval_o[lane] = in_pc_i[lane];
              end
              12'h302: uop_operation_o[lane] = SYS_MRET;
              12'h102: begin
                uop_operation_o[lane] = SYS_SRET;
                if (!HAS_SMODE) illegal = 1'b1;
              end
              12'h105: uop_operation_o[lane] = SYS_WFI;
              default: illegal = 1'b1;
            endcase
          end else begin
            uop_is_csr_o[lane] = 1'b1;
            uop_dst_class_o[lane] = REG_INT;
            uop_writes_dst_o[lane] = (rd != 0);
            uop_csr_immediate_o[lane] = funct3[2];
            if (!funct3[2]) begin
              uop_src_class_o[lane][0] = REG_INT;
              uop_src_arch_o[lane][0] = rs1;
              uop_src_used_o[lane][0] = 1'b1;
            end else begin
              uop_immediate_o[lane] = XLEN'(rs1);
            end
            case (funct3[1:0])
              2'b01: uop_operation_o[lane] = 16'(CSR_CMD_WRITE);
              2'b10: uop_operation_o[lane] = 16'(CSR_CMD_SET);
              2'b11: uop_operation_o[lane] = 16'(CSR_CMD_CLEAR);
              default: illegal = 1'b1;
            endcase
          end
        end

        7'b0000111: begin // FLW
          uop_fu_o[lane] = FU_LOAD;
          uop_exec_port_mask_o[lane] = PORT_MEM;
          uop_src_class_o[lane][0] = REG_INT;
          uop_src_arch_o[lane][0] = rs1;
          uop_src_used_o[lane][0] = 1'b1;
          uop_dst_class_o[lane] = REG_FP;
          uop_writes_dst_o[lane] = 1'b1;
          uop_immediate_o[lane] = imm_i(insn);
          uop_mem_size_o[lane] = 2;
          uop_is_load_o[lane] = 1'b1;
          illegal = !HAS_F || (funct3 != 3'b010);
        end

        7'b0100111: begin // FSW
          uop_fu_o[lane] = FU_STORE;
          uop_exec_port_mask_o[lane] = PORT_MEM;
          uop_src_class_o[lane][0] = REG_INT;
          uop_src_class_o[lane][1] = REG_FP;
          uop_src_arch_o[lane][0] = rs1;
          uop_src_arch_o[lane][1] = rs2;
          uop_src_used_o[lane][0] = 1'b1;
          uop_src_used_o[lane][1] = 1'b1;
          uop_immediate_o[lane] = imm_s(insn);
          uop_mem_size_o[lane] = 2;
          uop_is_store_o[lane] = 1'b1;
          illegal = !HAS_F || (funct3 != 3'b010);
        end

        7'b1000011, 7'b1000111, 7'b1001011, 7'b1001111: begin // FMADD family
          uop_fu_o[lane] = FU_FP;
          uop_exec_port_mask_o[lane] = PORT_FP;
          uop_src_class_o[lane][0] = REG_FP;
          uop_src_class_o[lane][1] = REG_FP;
          uop_src_class_o[lane][2] = REG_FP;
          uop_src_arch_o[lane][0] = rs1;
          uop_src_arch_o[lane][1] = rs2;
          uop_src_arch_o[lane][2] = insn[31:27];
          uop_src_used_o[lane] = 3'b111;
          uop_dst_class_o[lane] = REG_FP;
          uop_writes_dst_o[lane] = 1'b1;
          uop_operation_o[lane] = {9'b0, opcode};
          illegal = !HAS_F || (insn[26:25] != 2'b00) ||
                    !valid_rounding_mode(funct3);
        end

        7'b1010011: begin // OP-FP, format S only
          uop_fu_o[lane] = FU_FP;
          uop_exec_port_mask_o[lane] = PORT_FP;
          uop_operation_o[lane] = {funct7, funct3, rs2, 1'b0};
          uop_src_class_o[lane][0] = REG_FP;
          uop_src_arch_o[lane][0] = rs1;
          uop_src_used_o[lane][0] = 1'b1;
          uop_dst_class_o[lane] = REG_FP;
          uop_writes_dst_o[lane] = 1'b1;
          illegal = !HAS_F;
          case (funct7)
            7'b0000000, 7'b0000100, 7'b0001000, 7'b0001100:
              begin
                uop_src_class_o[lane][1] = REG_FP;
                uop_src_arch_o[lane][1] = rs2;
                uop_src_used_o[lane][1] = 1'b1;
                if (!valid_rounding_mode(funct3)) illegal = 1'b1;
              end
            7'b0101100: begin // FSQRT.S
              if ((rs2 != 0) || !valid_rounding_mode(funct3))
                illegal = 1'b1;
            end
            7'b0010000: begin // FSGNJ*
              uop_src_class_o[lane][1] = REG_FP;
              uop_src_arch_o[lane][1] = rs2;
              uop_src_used_o[lane][1] = 1'b1;
              if (funct3 > 3'b010) illegal = 1'b1;
            end
            7'b0010100: begin // FMIN/FMAX
              uop_src_class_o[lane][1] = REG_FP;
              uop_src_arch_o[lane][1] = rs2;
              uop_src_used_o[lane][1] = 1'b1;
              if (funct3 > 3'b001) illegal = 1'b1;
            end
            7'b1010000: begin // compare
              uop_src_class_o[lane][1] = REG_FP;
              uop_src_arch_o[lane][1] = rs2;
              uop_src_used_o[lane][1] = 1'b1;
              uop_dst_class_o[lane] = REG_INT;
              if (!((funct3 == 3'b000) || (funct3 == 3'b001) ||
                    (funct3 == 3'b010))) illegal = 1'b1;
            end
            7'b1100000: begin // FCVT integer from S
              uop_dst_class_o[lane] = REG_INT;
              if ((rs2 > ((XLEN == 64) ? 3 : 1)) ||
                  !valid_rounding_mode(funct3)) illegal = 1'b1;
            end
            7'b1110000: begin // FMV.X.W / FCLASS.S
              uop_dst_class_o[lane] = REG_INT;
              if ((rs2 != 0) ||
                  !((funct3 == 3'b000) || (funct3 == 3'b001)))
                illegal = 1'b1;
            end
            7'b1101000: begin // FCVT.S from integer
              uop_src_class_o[lane][0] = REG_INT;
              uop_dst_class_o[lane] = REG_FP;
              if ((rs2 > ((XLEN == 64) ? 3 : 1)) ||
                  !valid_rounding_mode(funct3)) illegal = 1'b1;
            end
            7'b1111000: begin // FMV.W.X
              uop_src_class_o[lane][0] = REG_INT;
              if ((rs2 != 0) || (funct3 != 0)) illegal = 1'b1;
            end
            default: illegal = 1'b1;
          endcase
        end

        default: illegal = 1'b1;
      endcase

      if (in_inst_len_i[lane] == INST_LEN_16) begin
        if (!HAS_C || compressed_illegal[lane]) illegal = 1'b1;
      end else if (in_inst_len_i[lane] != INST_LEN_32) begin
        illegal = 1'b1;
      end

      if (in_fetch_fault_i[lane]) begin
        uop_exception_valid_o[lane] = 1'b1;
        uop_exception_cause_o[lane] = EXC_INST_ACCESS_FAULT;
        uop_exception_tval_o[lane] = in_pc_i[lane];
      end else if (illegal) begin
        uop_fu_o[lane] = FU_NONE;
        uop_exec_port_mask_o[lane] = '0;
        uop_writes_dst_o[lane] = 1'b0;
        uop_exception_valid_o[lane] = 1'b1;
        uop_exception_cause_o[lane] = EXC_ILLEGAL_INSTRUCTION;
        uop_exception_tval_o[lane] =
          {{(XLEN-32){1'b0}}, in_instruction_i[lane]};
      end
    end
  end

`ifndef SYNTHESIS
  always_comb begin
    assert (!uop_valid_o[1] || uop_valid_o[0]);
  end
`endif

  initial begin : p_parameter_checks
    if ((XLEN != 32) && (XLEN != 64))
      $fatal(1, "Decoder XLEN must be 32 or 64");
  end

endmodule
