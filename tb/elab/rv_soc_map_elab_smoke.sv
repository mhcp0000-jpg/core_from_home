module rv_soc_default_map_smoke;
  rv_soc_map_check u_map_check ();
endmodule

module rv_soc_relocated_map_smoke;
  rv_soc_map_check #(
    .BOOTROM_BASE_ADDR (32'h0001_0000),
    .BOOTROM_SIZE_KB   (8),
    .CLINT_BASE_ADDR   (32'h0040_0000),
    .CLINT_SIZE_KB     (64),
    .PLIC_BASE_ADDR    (32'h0d00_0000),
    .PLIC_SIZE_KB      (4096),
    .HOSTIF_BASE_ADDR  (32'h1100_0000),
    .HOSTIF_SIZE_KB    (4),
    .ITIM_BASE_ADDR    (32'h9000_0000),
    .ITIM_SIZE_KB      (256),
    .DTIM_BASE_ADDR    (32'h9004_0000),
    .DTIM_SIZE_KB      (256),
    .BOOT_MTVEC_ADDR   (32'h9000_0000)
  ) u_map_check ();
endmodule
