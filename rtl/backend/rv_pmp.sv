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

  logic [7:0] entry_cfg_decoded [0:PMP_ENTRIES-1];
  logic [1:0] entry_mode_decoded [0:PMP_ENTRIES-1];
  logic [PADDR_WIDTH:0] region_low_decoded [0:PMP_ENTRIES-1];
  logic [PADDR_WIDTH:0] region_high_decoded [0:PMP_ENTRIES-1];

  // Decode each PMP entry once, independently of the number of access ports.
  // In particular, NAPOT trailing-one detection and TOR bound construction
  // are shared by IFU and both LSU checks instead of being replicated inside
  // every port/entry comparison cone.
  always_comb begin : p_predecode
    for (int unsigned entry = 0; entry < PMP_ENTRIES; entry++) begin
      logic [PMP_ADDR_WIDTH-1:0] entry_addr;
      logic [PMP_ADDR_WIDTH-1:0] previous_addr;
      logic [PMP_ADDR_WIDTH-1:0] napot_low_mask;
      logic trailing;
      int unsigned trailing_ones;

      entry_cfg_decoded[entry] = pmpcfg_i[entry*8 +: 8];
      entry_mode_decoded[entry] = entry_cfg_decoded[entry][4:3];
      region_low_decoded[entry] = '0;
      region_high_decoded[entry] = '0;
      entry_addr = pmpaddr_i[entry*PMP_ADDR_WIDTH +: PMP_ADDR_WIDTH];
      previous_addr = '0;
      if (entry != 0)
        previous_addr = pmpaddr_i[(entry-1)*PMP_ADDR_WIDTH +:
                                  PMP_ADDR_WIDTH];
      napot_low_mask = '0;
      trailing = 1'b1;
      trailing_ones = 0;

      case (entry_mode_decoded[entry])
        2'b01: begin // TOR
          if (entry != 0)
            region_low_decoded[entry] = {1'b0, previous_addr, 2'b00};
          region_high_decoded[entry] = {1'b0, entry_addr, 2'b00};
        end
        2'b10: begin // NA4
          region_low_decoded[entry] = {1'b0, entry_addr, 2'b00};
          region_high_decoded[entry] = region_low_decoded[entry] +
                                       (PADDR_WIDTH+1)'(4);
        end
        2'b11: begin // NAPOT
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
            region_low_decoded[entry] = '0;
            region_high_decoded[entry] = '0;
            region_high_decoded[entry][PADDR_WIDTH] = 1'b1;
          end else begin
            region_low_decoded[entry] = {1'b0,
              (entry_addr & ~napot_low_mask), 2'b00};
            region_high_decoded[entry] = region_low_decoded[entry];
            region_high_decoded[entry][trailing_ones + 3] = 1'b1;
          end
        end
        default: begin
        end
      endcase
    end
  end

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
        logic overlaps;
        logic full_match;
        logic permissions_ok;

        overlaps = (entry_mode_decoded[entry] != 2'b00) &&
                   (access_low < region_high_decoded[entry]) &&
                   (access_high > region_low_decoded[entry]);
        full_match = overlaps &&
                     (access_low >= region_low_decoded[entry]) &&
                     (access_high <= region_high_decoded[entry]) &&
                     access_in_range;
        permissions_ok =
          ((check_access_i[port] & ~entry_cfg_decoded[entry][2:0]) ==
           3'b000) &&
          !(entry_cfg_decoded[entry][1] && !entry_cfg_decoded[entry][0]);

        if (check_valid_i[port] && !selected && overlaps) begin
          selected = 1'b1;
          matched_o[port] = 1'b1;
          if (!full_match)
            allow_o[port] = 1'b0;
          else if ((check_privilege_i[port] == PRIV_M) &&
                   !entry_cfg_decoded[entry][7])
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
