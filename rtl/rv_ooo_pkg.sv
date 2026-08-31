package rv_ooo_pkg;

  localparam int unsigned ARCH_INT_REGS = 32;
  localparam int unsigned ARCH_FP_REGS  = 32;
  localparam int unsigned FLEN          = 32;
  localparam int unsigned INST_BITS     = 32;
  localparam int unsigned ISSUE_WIDTH   = 2;
  localparam int unsigned COMMIT_WIDTH  = 2;
  // The active ROB window must be smaller than half of this modulo sequence
  // space so signed subtraction gives an unambiguous age comparison.
  localparam int unsigned ROB_SEQ_WIDTH = 8;

  // Baseline execution resources. These constants describe logical ports;
  // the physical PRF/SRAM implementation can still use banking or replication.
  localparam int unsigned INT_ALU_COUNT       = 2;
  localparam int unsigned BRANCH_UNIT_COUNT   = 1;
  localparam int unsigned INT_MUL_COUNT       = 1;
  localparam int unsigned INT_DIV_COUNT       = 1;
  localparam int unsigned LSU_PIPE_COUNT      = 2;
  localparam int unsigned AGU_COUNT           = 2;
  localparam int unsigned DTLB_LOOKUP_PORTS   = 2;
  localparam int unsigned DCACHE_CPU_PORTS    = 2;
  localparam int unsigned DCACHE_BANKS        = 2;
  localparam int unsigned FPU_CLUSTER_COUNT   = 1;
  localparam int unsigned FP_FMA_PIPE_COUNT   = 1;
  localparam int unsigned FP_DIVSQRT_COUNT    = 1;
  localparam int unsigned INT_PRF_READ_PORTS  = 4;
  localparam int unsigned INT_PRF_WRITE_PORTS = 2;
  localparam int unsigned FP_PRF_READ_PORTS   = 4;
  localparam int unsigned FP_PRF_WRITE_PORTS  = 2;

  typedef enum logic [2:0] {
    EXEC_PORT_INT0,
    EXEC_PORT_INT1,
    EXEC_PORT_MEM0,
    EXEC_PORT_MEM1,
    EXEC_PORT_FP
  } exec_port_e;

  typedef enum logic [2:0] {
    LSQ_STALL_NONE,
    LSQ_STALL_UNKNOWN_ADDR,
    LSQ_STALL_STORE_DATA,
    LSQ_STALL_PARTIAL_OVERLAP,
    LSQ_STALL_BANK_CONFLICT,
    LSQ_STALL_DEVICE_SERIALIZE
  } lsq_stall_reason_e;

  typedef enum logic [3:0] {
    FU_NONE,
    FU_INT,
    FU_BRANCH,
    FU_MUL,
    FU_DIV,
    FU_LOAD,
    FU_STORE,
    FU_FP,
    FU_CSR,
    FU_FENCE
  } fu_class_e;

  typedef enum logic [3:0] {
    ALU_ADD,
    ALU_SUB,
    ALU_SLT,
    ALU_SLTU,
    ALU_XOR,
    ALU_OR,
    ALU_AND,
    ALU_SLL,
    ALU_SRL,
    ALU_SRA,
    ALU_COPY_SRC0,
    ALU_COPY_SRC1
  } int_alu_op_e;

  typedef enum logic [3:0] {
    BR_NONE,
    BR_EQ,
    BR_NE,
    BR_LT,
    BR_GE,
    BR_LTU,
    BR_GEU,
    BR_JAL,
    BR_JALR
  } branch_op_e;

  typedef enum logic [1:0] {
    MUL_LOW,
    MUL_HIGH_SS,
    MUL_HIGH_SU,
    MUL_HIGH_UU
  } multiply_op_e;

  typedef enum logic [1:0] {
    DIV_SIGNED_QUOTIENT,
    DIV_UNSIGNED_QUOTIENT,
    DIV_SIGNED_REMAINDER,
    DIV_UNSIGNED_REMAINDER
  } divide_op_e;

  typedef enum logic [2:0] {
    CSR_CMD_NONE,
    CSR_CMD_WRITE,
    CSR_CMD_SET,
    CSR_CMD_CLEAR
  } csr_cmd_e;

  // Architectural privilege encoding is deliberately identical to the
  // privileged ISA CSR encoding.  PRIV_S remains reserved by the baseline
  // M/U core and becomes active when HAS_SMODE is enabled.
  typedef enum logic [1:0] {
    PRIV_U = 2'b00,
    PRIV_S = 2'b01,
    PRIV_M = 2'b11
  } privilege_e;

  typedef enum logic [2:0] {
    REG_NONE,
    REG_INT,
    REG_FP
  } reg_class_e;

  typedef enum logic [1:0] {
    INST_LEN_NONE,
    INST_LEN_16,
    INST_LEN_32
  } inst_len_e;

  typedef enum logic [5:0] {
    EXC_INST_ADDR_MISALIGNED = 6'd0,
    EXC_INST_ACCESS_FAULT    = 6'd1,
    EXC_ILLEGAL_INSTRUCTION  = 6'd2,
    EXC_BREAKPOINT           = 6'd3,
    EXC_LOAD_ADDR_MISALIGNED = 6'd4,
    EXC_LOAD_ACCESS_FAULT    = 6'd5,
    EXC_STORE_ADDR_MISALIGNED= 6'd6,
    EXC_STORE_ACCESS_FAULT   = 6'd7,
    EXC_ECALL_U              = 6'd8,
    EXC_ECALL_S              = 6'd9,
    EXC_ECALL_M              = 6'd11
  } exception_code_e;

  typedef struct packed {
    logic       valid;
    logic       taken;
    logic       is_call;
    logic       is_return;
    logic [63:0] target;
    logic [10:0] global_history;
    logic [7:0] btb_index;
    logic [3:0] ras_pointer;
    logic [4:0] ras_count;
  } prediction_meta_t;

  typedef struct packed {
    logic       valid;
    fu_class_e  fu;
    reg_class_e src0_class;
    reg_class_e src1_class;
    reg_class_e src2_class;
    reg_class_e dst_class;
    logic [4:0] src0_arch;
    logic [4:0] src1_arch;
    logic [4:0] src2_arch;
    logic [4:0] dst_arch;
    logic       writes_dst;
    logic       is_serializing;
    logic       is_illegal;
  } decode_control_t;

  function automatic logic is_supported_xlen(input int unsigned xlen);
    return (xlen == 32) || (xlen == 64);
  endfunction

  function automatic logic [63:0] sign_extend_64(
    input logic [63:0] value,
    input int unsigned source_bits
  );
    logic [63:0] source_mask;
    if (source_bits == 0)
      return '0;
    if (source_bits >= 64)
      return value;
    source_mask = (64'h1 << source_bits) - 1'b1;
    return (value & source_mask) |
           ({64{value[source_bits-1]}} & ~source_mask);
  endfunction

endpackage
