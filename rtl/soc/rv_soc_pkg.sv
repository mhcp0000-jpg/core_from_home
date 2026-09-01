package rv_soc_pkg;

  // --------------------------------------------------------------------------
  // User-editable SoC defaults. rv_soc_top mirrors these as instance parameters.
  // --------------------------------------------------------------------------
  parameter int unsigned SOC_ADDR_WIDTH = 32;
  parameter int unsigned SOC_DATA_WIDTH = 64;
  parameter int unsigned AXI_LOCAL_ID_WIDTH = 4;
  parameter int unsigned AXI_XBAR_ID_WIDTH  = AXI_LOCAL_ID_WIDTH + 2;

  parameter logic [SOC_ADDR_WIDTH-1:0] BOOTROM_BASE_ADDR = 32'h0000_1000;
  parameter int unsigned               BOOTROM_SIZE_KB   = 4;

  parameter logic [SOC_ADDR_WIDTH-1:0] CLINT_BASE_ADDR   = 32'h0020_0000;
  parameter int unsigned               CLINT_SIZE_KB     = 64;

  parameter logic [SOC_ADDR_WIDTH-1:0] PLIC_BASE_ADDR    = 32'h0c00_0000;
  parameter int unsigned               PLIC_SIZE_KB      = 4096;

  parameter logic [SOC_ADDR_WIDTH-1:0] HOSTIF_BASE_ADDR  = 32'h1000_0000;
  parameter int unsigned               HOSTIF_SIZE_KB    = 4;

  parameter logic [SOC_ADDR_WIDTH-1:0] ITIM_BASE_ADDR    = 32'h8000_0000;
  parameter int unsigned               ITIM_SIZE_KB      = 128;

  parameter logic [SOC_ADDR_WIDTH-1:0] DTIM_BASE_ADDR    = 32'h8002_0000;
  parameter int unsigned               DTIM_SIZE_KB      = 128;

  parameter logic [SOC_ADDR_WIDTH-1:0] BOOT_MTVEC_ADDR   = ITIM_BASE_ADDR;
  parameter int unsigned               BOOT_VECTOR_BYTES = 256;
  parameter int unsigned               PLIC_NUM_SOURCES  = 32;
  parameter int unsigned               PMP_ENTRIES       = 8;
  parameter int unsigned               TIMEBASE_HZ       = 10_000_000;

  localparam longint unsigned BOOTROM_SIZE_BYTES = BOOTROM_SIZE_KB * 1024;
  localparam longint unsigned CLINT_SIZE_BYTES   = CLINT_SIZE_KB   * 1024;
  localparam longint unsigned PLIC_SIZE_BYTES    = PLIC_SIZE_KB    * 1024;
  localparam longint unsigned HOSTIF_SIZE_BYTES  = HOSTIF_SIZE_KB  * 1024;
  localparam longint unsigned ITIM_SIZE_BYTES    = ITIM_SIZE_KB    * 1024;
  localparam longint unsigned DTIM_SIZE_BYTES    = DTIM_SIZE_KB    * 1024;

  localparam int unsigned TIM_BANKS      = 2;
  localparam int unsigned TIM_BANK_WIDTH = 64;
  localparam int unsigned ITIM_BANK_ROWS = ITIM_SIZE_BYTES /
                                           (TIM_BANKS * (TIM_BANK_WIDTH/8));
  localparam int unsigned DTIM_BANK_ROWS = DTIM_SIZE_BYTES /
                                           (TIM_BANKS * (TIM_BANK_WIDTH/8));

  // CLINT-compatible offsets.
  localparam logic [15:0] CLINT_MSIP_OFFSET      = 16'h0000;
  localparam logic [15:0] CLINT_MTIMECMP_LO_OFF  = 16'h4000;
  localparam logic [15:0] CLINT_MTIMECMP_HI_OFF  = 16'h4004;
  localparam logic [15:0] CLINT_MTIME_LO_OFF     = 16'hbff8;
  localparam logic [15:0] CLINT_MTIME_HI_OFF     = 16'hbffc;

  // PLIC context-0 offsets.
  localparam logic [21:0] PLIC_PENDING_OFFSET    = 22'h001000;
  localparam logic [21:0] PLIC_M_ENABLE_OFFSET   = 22'h002000;
  localparam logic [21:0] PLIC_M_THRESHOLD_OFF   = 22'h200000;
  localparam logic [21:0] PLIC_M_CLAIM_OFF       = 22'h200004;
  localparam logic [21:0] PLIC_S_ENABLE_OFFSET   = 22'h002080;
  localparam logic [21:0] PLIC_S_THRESHOLD_OFF   = 22'h201000;
  localparam logic [21:0] PLIC_S_CLAIM_OFF       = 22'h201004;

  // HostIF offsets. The testbench passes these values to DPI-C at startup.
  localparam logic [11:0] HOSTIF_ID_OFFSET        = 12'h000;
  localparam logic [11:0] HOSTIF_BOOT_ENTRY_OFF   = 12'h004;
  localparam logic [11:0] HOSTIF_BOOT_FLAGS_OFF   = 12'h008;
  localparam logic [11:0] HOSTIF_TOHOST_OFF       = 12'h00c;
  localparam logic [11:0] HOSTIF_FROMHOST_OFF     = 12'h010;
  localparam logic [11:0] HOSTIF_EXIT_CODE_OFF    = 12'h014;
  localparam logic [11:0] HOSTIF_CONSOLE_TX_OFF   = 12'h018;
  localparam logic [11:0] HOSTIF_CONSOLE_RX_OFF   = 12'h01c;
  localparam logic [11:0] HOSTIF_STATUS_OFF       = 12'h020;

  typedef enum logic [1:0] {
    AXI_RESP_OKAY   = 2'b00,
    AXI_RESP_EXOKAY = 2'b01,
    AXI_RESP_SLVERR = 2'b10,
    AXI_RESP_DECERR = 2'b11
  } axi_resp_e;

  typedef enum logic [1:0] {
    PRIV_U = 2'b00,
    PRIV_S = 2'b01,
    PRIV_M = 2'b11
  } privilege_e;

  typedef enum logic [2:0] {
    MEM_REPLAY_NONE,
    MEM_REPLAY_BANK_CONFLICT,
    MEM_REPLAY_UNKNOWN_STORE,
    MEM_REPLAY_STORE_DATA,
    MEM_REPLAY_PARTIAL_OVERLAP,
    MEM_REPLAY_FLUSHED
  } mem_replay_reason_e;

  typedef enum logic [2:0] {
    SOC_TARGET_I_LOCAL  = 3'd0,
    SOC_TARGET_D_LOCAL  = 3'd1,
    SOC_TARGET_PLIC     = 3'd2,
    SOC_TARGET_HOSTIF   = 3'd3,
    SOC_TARGET_RESERVED = 3'd4,
    SOC_TARGET_ERROR    = 3'd5
  } soc_target_e;

  typedef enum logic [1:0] {
    HOST_EVENT_TOHOST,
    HOST_EVENT_EXIT,
    HOST_EVENT_CONSOLE_TX,
    HOST_EVENT_RESERVED
  } host_event_e;

  function automatic longint unsigned size_kb_to_bytes(
    input int unsigned size_kb
  );
    longint unsigned size_kb_wide;
    size_kb_wide = {32'b0, size_kb};
    return size_kb_wide * 64'd1024;
  endfunction

  function automatic logic addr_in_region(
    input logic [SOC_ADDR_WIDTH-1:0] addr,
    input logic [SOC_ADDR_WIDTH-1:0] base_addr,
    input longint unsigned size_bytes
  );
    logic [63:0] addr_ext;
    logic [63:0] base_ext;
    logic [63:0] end_exclusive;
    addr_ext      = {{(64-SOC_ADDR_WIDTH){1'b0}}, addr};
    base_ext      = {{(64-SOC_ADDR_WIDTH){1'b0}}, base_addr};
    end_exclusive = base_ext + size_bytes;
    return (addr_ext >= base_ext) && (addr_ext < end_exclusive);
  endfunction

  function automatic logic regions_overlap(
    input logic [SOC_ADDR_WIDTH-1:0] base_a,
    input longint unsigned size_a,
    input logic [SOC_ADDR_WIDTH-1:0] base_b,
    input longint unsigned size_b
  );
    logic [63:0] base_a_ext;
    logic [63:0] base_b_ext;
    logic [63:0] end_a;
    logic [63:0] end_b;
    base_a_ext = {{(64-SOC_ADDR_WIDTH){1'b0}}, base_a};
    base_b_ext = {{(64-SOC_ADDR_WIDTH){1'b0}}, base_b};
    end_a      = base_a_ext + size_a;
    end_b      = base_b_ext + size_b;
    return (base_a_ext < end_b) && (base_b_ext < end_a);
  endfunction

  function automatic logic region_fits_address_width(
    input logic [SOC_ADDR_WIDTH-1:0] base_addr,
    input longint unsigned size_bytes
  );
    logic [63:0] base_ext;
    logic [63:0] end_exclusive;
    logic [63:0] address_limit;
    base_ext       = {{(64-SOC_ADDR_WIDTH){1'b0}}, base_addr};
    end_exclusive  = base_ext + size_bytes;
    address_limit  = 64'h1 << SOC_ADDR_WIDTH;
    return (size_bytes != 0) && (end_exclusive <= address_limit);
  endfunction

endpackage
