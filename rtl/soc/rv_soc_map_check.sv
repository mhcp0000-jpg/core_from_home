module rv_soc_map_check #(
  parameter logic [31:0] BOOTROM_BASE_ADDR = rv_soc_pkg::BOOTROM_BASE_ADDR,
  parameter int unsigned BOOTROM_SIZE_KB   = rv_soc_pkg::BOOTROM_SIZE_KB,
  parameter logic [31:0] CLINT_BASE_ADDR   = rv_soc_pkg::CLINT_BASE_ADDR,
  parameter int unsigned CLINT_SIZE_KB     = rv_soc_pkg::CLINT_SIZE_KB,
  parameter logic [31:0] PLIC_BASE_ADDR    = rv_soc_pkg::PLIC_BASE_ADDR,
  parameter int unsigned PLIC_SIZE_KB      = rv_soc_pkg::PLIC_SIZE_KB,
  parameter logic [31:0] HOSTIF_BASE_ADDR  = rv_soc_pkg::HOSTIF_BASE_ADDR,
  parameter int unsigned HOSTIF_SIZE_KB    = rv_soc_pkg::HOSTIF_SIZE_KB,
  parameter logic [31:0] ITIM_BASE_ADDR    = rv_soc_pkg::ITIM_BASE_ADDR,
  parameter int unsigned ITIM_SIZE_KB      = rv_soc_pkg::ITIM_SIZE_KB,
  parameter logic [31:0] DTIM_BASE_ADDR    = rv_soc_pkg::DTIM_BASE_ADDR,
  parameter int unsigned DTIM_SIZE_KB      = rv_soc_pkg::DTIM_SIZE_KB,
  parameter logic [31:0] TOHOST_ADDR       = rv_soc_pkg::TOHOST_ADDR,
  parameter logic [31:0] FROMHOST_ADDR     = rv_soc_pkg::FROMHOST_ADDR,
  parameter logic [31:0] BOOT_MTVEC_ADDR   = rv_soc_pkg::BOOT_MTVEC_ADDR
);

  import rv_soc_pkg::*;

  localparam longint unsigned BOOT_BYTES = size_kb_to_bytes(BOOTROM_SIZE_KB);
  localparam longint unsigned CLINT_BYTES = size_kb_to_bytes(CLINT_SIZE_KB);
  localparam longint unsigned PLIC_BYTES = size_kb_to_bytes(PLIC_SIZE_KB);
  localparam longint unsigned HOST_BYTES = size_kb_to_bytes(HOSTIF_SIZE_KB);
  localparam longint unsigned ITIM_BYTES = size_kb_to_bytes(ITIM_SIZE_KB);
  localparam longint unsigned DTIM_BYTES = size_kb_to_bytes(DTIM_SIZE_KB);

  initial begin : p_soc_map_checks
    if ((BOOTROM_SIZE_KB == 0) || (CLINT_SIZE_KB == 0) ||
        (PLIC_SIZE_KB == 0) || (HOSTIF_SIZE_KB == 0) ||
        (ITIM_SIZE_KB == 0) || (DTIM_SIZE_KB == 0))
      $fatal(1, "All SoC regions must have a non-zero size");

    if ((BOOTROM_BASE_ADDR[11:0] != 0) || (CLINT_BASE_ADDR[11:0] != 0) ||
        (PLIC_BASE_ADDR[11:0] != 0) || (HOSTIF_BASE_ADDR[11:0] != 0) ||
        (ITIM_BASE_ADDR[11:0] != 0) || (DTIM_BASE_ADDR[11:0] != 0))
      $fatal(1, "All SoC region bases must be 4 KiB aligned");

    if (((ITIM_BYTES % 16) != 0) || ((DTIM_BYTES % 16) != 0))
      $fatal(1, "TIM sizes must support two 64-bit banks");

    if (!region_fits_address_width(BOOTROM_BASE_ADDR, BOOT_BYTES) ||
        !region_fits_address_width(CLINT_BASE_ADDR, CLINT_BYTES) ||
        !region_fits_address_width(PLIC_BASE_ADDR, PLIC_BYTES) ||
        !region_fits_address_width(HOSTIF_BASE_ADDR, HOST_BYTES) ||
        !region_fits_address_width(ITIM_BASE_ADDR, ITIM_BYTES) ||
        !region_fits_address_width(DTIM_BASE_ADDR, DTIM_BYTES))
      $fatal(1, "A SoC region exceeds the configured address width");

    if (!addr_in_region(BOOT_MTVEC_ADDR, ITIM_BASE_ADDR, ITIM_BYTES) ||
        (BOOT_MTVEC_ADDR[1:0] != 0))
      $fatal(1, "BOOT_MTVEC_ADDR must be aligned and inside ITIM");

    if (!addr_in_region(TOHOST_ADDR, DTIM_BASE_ADDR, DTIM_BYTES) ||
        !addr_in_region(TOHOST_ADDR + 32'd7, DTIM_BASE_ADDR, DTIM_BYTES) ||
        !addr_in_region(FROMHOST_ADDR, DTIM_BASE_ADDR, DTIM_BYTES) ||
        !addr_in_region(FROMHOST_ADDR + 32'd7, DTIM_BASE_ADDR, DTIM_BYTES) ||
        (TOHOST_ADDR[2:0] != 0) || (FROMHOST_ADDR[2:0] != 0) ||
        (TOHOST_ADDR == FROMHOST_ADDR))
      $fatal(1, "TOHOST/FROMHOST must be distinct aligned 64-bit words in DTIM");

    if (CLINT_BYTES <= CLINT_MTIME_HI_OFF)
      $fatal(1, "CLINT region is too small for the timer registers");
    if (PLIC_BYTES <= PLIC_M_CLAIM_OFF)
      $fatal(1, "PLIC region is too small for context-0 claim/complete");
    if (HOST_BYTES <= HOSTIF_STATUS_OFF)
      $fatal(1, "HostIF region is too small for the register block");

    if (regions_overlap(BOOTROM_BASE_ADDR, BOOT_BYTES, CLINT_BASE_ADDR, CLINT_BYTES) ||
        regions_overlap(BOOTROM_BASE_ADDR, BOOT_BYTES, PLIC_BASE_ADDR, PLIC_BYTES) ||
        regions_overlap(BOOTROM_BASE_ADDR, BOOT_BYTES, HOSTIF_BASE_ADDR, HOST_BYTES) ||
        regions_overlap(BOOTROM_BASE_ADDR, BOOT_BYTES, ITIM_BASE_ADDR, ITIM_BYTES) ||
        regions_overlap(BOOTROM_BASE_ADDR, BOOT_BYTES, DTIM_BASE_ADDR, DTIM_BYTES) ||
        regions_overlap(CLINT_BASE_ADDR, CLINT_BYTES, PLIC_BASE_ADDR, PLIC_BYTES) ||
        regions_overlap(CLINT_BASE_ADDR, CLINT_BYTES, HOSTIF_BASE_ADDR, HOST_BYTES) ||
        regions_overlap(CLINT_BASE_ADDR, CLINT_BYTES, ITIM_BASE_ADDR, ITIM_BYTES) ||
        regions_overlap(CLINT_BASE_ADDR, CLINT_BYTES, DTIM_BASE_ADDR, DTIM_BYTES) ||
        regions_overlap(PLIC_BASE_ADDR, PLIC_BYTES, HOSTIF_BASE_ADDR, HOST_BYTES) ||
        regions_overlap(PLIC_BASE_ADDR, PLIC_BYTES, ITIM_BASE_ADDR, ITIM_BYTES) ||
        regions_overlap(PLIC_BASE_ADDR, PLIC_BYTES, DTIM_BASE_ADDR, DTIM_BYTES) ||
        regions_overlap(HOSTIF_BASE_ADDR, HOST_BYTES, ITIM_BASE_ADDR, ITIM_BYTES) ||
        regions_overlap(HOSTIF_BASE_ADDR, HOST_BYTES, DTIM_BASE_ADDR, DTIM_BYTES) ||
        regions_overlap(ITIM_BASE_ADDR, ITIM_BYTES, DTIM_BASE_ADDR, DTIM_BYTES))
      $fatal(1, "SoC address regions overlap");
  end

endmodule
