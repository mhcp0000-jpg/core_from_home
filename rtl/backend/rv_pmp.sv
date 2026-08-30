module rv_pmp #(
  parameter int unsigned PADDR_WIDTH = 32,
  parameter int unsigned PMP_ENTRIES = 8,
  parameter int unsigned CHECK_PORTS = 3,
  localparam int unsigned PMP_ADDR_WIDTH = PADDR_WIDTH - 2
) (
  input  logic [PMP_ENTRIES*8-1:0]                   pmpcfg_i,
  input  logic [PMP_ENTRIES*PMP_ADDR_WIDTH-1:0]      pmpaddr_i,
  input  logic [CHECK_PORTS-1:0]                      check_valid_i,
  input  logic [CHECK_PORTS-1:0][PADDR_WIDTH-1:0]     check_address_i,
  input  logic [CHECK_PORTS-1:0][2:0]                 check_size_i,
  // Bit 0/1/2 request read/write/execute permission respectively.
  input  logic [CHECK_PORTS-1:0][2:0]                 check_access_i,
  input  rv_ooo_pkg::privilege_e [CHECK_PORTS-1:0]    check_privilege_i,
  output logic [CHECK_PORTS-1:0]                      allow_o,
  output logic [CHECK_PORTS-1:0]                      matched_o,
  output logic [CHECK_PORTS-1:0][PADDR_WIDTH-1:0]     fault_address_o
);
  import rv_ooo_pkg::*;

  // PMP regions and accesses use an exclusive upper bound with one extra bit
  // so a region ending exactly at 2**PADDR_WIDTH is representable.
  always_comb begin : p_lookup
    allow_o = '0;
    matched_o = '0;
    fault_address_o = check_address_i;

    for (int unsigned port = 0; port < CHECK_PORTS; port++) begin
      logic selected;
      logic [PADDR_WIDTH:0] access_low;
      logic [PADDR_WIDTH:0] access_high;
      logic [PADDR_WIDTH:0] access_bytes;
      logic [PADDR_WIDTH:0] address_space_end;
      logic access_in_range;

      selected = 1'b0;
      access_low = {1'b0, check_address_i[port]};
      access_bytes = '0;
      if (check_size_i[port] <= PADDR_WIDTH)
        access_bytes[check_size_i[port]] = 1'b1;
      access_high = access_low + access_bytes;
      address_space_end = '0;
      address_space_end[PADDR_WIDTH] = 1'b1;
      access_in_range = (access_bytes != 0) &&
                        (access_high <= address_space_end);

      // No matching entry permits M-mode accesses, but S/U accesses require
      // a matching entry. An access that wraps the physical address space is
      // always rejected.
      allow_o[port] = (check_privilege_i[port] == PRIV_M) &&
                      access_in_range;

      for (int unsigned entry = 0; entry < PMP_ENTRIES; entry++) begin
        logic [1:0] address_mode;
        logic [7:0] entry_cfg;
        logic [PMP_ADDR_WIDTH-1:0] entry_addr;
        logic [PMP_ADDR_WIDTH-1:0] previous_addr;
        logic [PADDR_WIDTH:0] region_low;
        logic [PADDR_WIDTH:0] region_high;
        logic [PMP_ADDR_WIDTH-1:0] napot_low_mask;
        logic trailing;
        int unsigned trailing_ones;
        logic overlaps;
        logic full_match;
        logic permissions_ok;

        entry_cfg = pmpcfg_i[entry*8 +: 8];
        entry_addr = pmpaddr_i[entry*PMP_ADDR_WIDTH +: PMP_ADDR_WIDTH];
        previous_addr = '0;
        if (entry != 0)
          previous_addr = pmpaddr_i[(entry-1)*PMP_ADDR_WIDTH +:
                                    PMP_ADDR_WIDTH];
        address_mode = entry_cfg[4:3];
        region_low = '0;
        region_high = '0;
        napot_low_mask = '0;
        trailing = 1'b1;
        trailing_ones = 0;

        if (address_mode == 2'b01) begin // TOR
          if (entry != 0)
            region_low = {1'b0, previous_addr, 2'b00};
          region_high = {1'b0, entry_addr, 2'b00};
        end else if (address_mode == 2'b10) begin // NA4
          region_low = {1'b0, entry_addr, 2'b00};
          region_high = region_low + (PADDR_WIDTH+1)'(4);
        end else if (address_mode == 2'b11) begin // NAPOT
          for (int unsigned bit_index = 0;
               bit_index < PMP_ADDR_WIDTH; bit_index++) begin
            if (trailing && entry_addr[bit_index]) begin
              napot_low_mask[bit_index] = 1'b1;
              trailing_ones++;
            end else begin
              trailing = 1'b0;
            end
          end
          if ((trailing_ones + 3) >= PADDR_WIDTH) begin
            region_low = '0;
            region_high = '0;
            region_high[PADDR_WIDTH] = 1'b1;
          end else begin
            region_low = {1'b0,
              (entry_addr & ~napot_low_mask), 2'b00};
            region_high = region_low;
            region_high[trailing_ones + 3] = 1'b1;
          end
        end

        overlaps = (address_mode != 2'b00) &&
                   (access_low < region_high) &&
                   (access_high > region_low);
        full_match = overlaps && (access_low >= region_low) &&
                     (access_high <= region_high) &&
                     access_in_range;
        permissions_ok =
          ((check_access_i[port] & ~entry_cfg[2:0]) == 3'b000) &&
          !(entry_cfg[1] && !entry_cfg[0]);

        if (check_valid_i[port] && !selected && overlaps) begin
          selected = 1'b1;
          matched_o[port] = 1'b1;
          if (!full_match)
            allow_o[port] = 1'b0;
          else if ((check_privilege_i[port] == PRIV_M) &&
                   !entry_cfg[7])
            allow_o[port] = 1'b1;
          else
            allow_o[port] = permissions_ok;
        end
      end

      if (!check_valid_i[port]) begin
        allow_o[port] = 1'b1;
        matched_o[port] = 1'b0;
      end
    end
  end

  initial begin : p_parameter_checks
    if (PADDR_WIDTH < 4)
      $fatal(1, "PMP requires at least a 4-bit physical address");
    if ((PMP_ENTRIES == 0) || (CHECK_PORTS == 0))
      $fatal(1, "PMP entry and check-port counts must be non-zero");
  end
endmodule
