module rv_pmp_equiv_tb #(parameter int unsigned PADDR_WIDTH=32);
  import rv_ooo_pkg::*;
  localparam int PMP_ENTRIES=8, CHECK_PORTS=2, ADDR_BITS=PADDR_WIDTH-2;
  logic [PMP_ENTRIES*8-1:0] cfg;
  logic [PMP_ENTRIES*ADDR_BITS-1:0] addr;
  logic [CHECK_PORTS-1:0] valid, allow_dut, allow_ref, match_dut, match_ref;
  logic [CHECK_PORTS-1:0][PADDR_WIDTH-1:0] address, fault_dut, fault_ref;
  logic [CHECK_PORTS-1:0][2:0] size, access;
  privilege_e [CHECK_PORTS-1:0] privilege;
  rv_pmp #(.PADDR_WIDTH(PADDR_WIDTH),.PMP_ENTRIES(PMP_ENTRIES),.CHECK_PORTS(CHECK_PORTS)) dut(
    .pmpcfg_i(cfg),.pmpaddr_i(addr),.check_valid_i(valid),.check_address_i(address),
    .check_size_i(size),.check_access_i(access),.check_privilege_i(privilege),
    .allow_o(allow_dut),.matched_o(match_dut),.fault_address_o(fault_dut));
  rv_pmp_reference #(.PADDR_WIDTH(PADDR_WIDTH),.PMP_ENTRIES(PMP_ENTRIES),.CHECK_PORTS(CHECK_PORTS)) ref_i(
    .pmpcfg_i(cfg),.pmpaddr_i(addr),.check_valid_i(valid),.check_address_i(address),
    .check_size_i(size),.check_access_i(access),.check_privilege_i(privilege),
    .allow_o(allow_ref),.matched_o(match_ref),.fault_address_o(fault_ref));
  initial begin
    int seed, checks, allowed, denied, matched;
    seed=32'h628ad947; void'($urandom(seed));
    checks=0; allowed=0; denied=0; matched=0;
    for (int cycle=0; cycle<100000; cycle++) begin
      for (int entry=0; entry<PMP_ENTRIES; entry++) begin
        logic [ADDR_BITS-1:0] raw_addr;
        int ones;
        raw_addr=ADDR_BITS'({$urandom,$urandom});
        ones=$urandom_range(0,ADDR_BITS);
        if (cycle%3!=0) raw_addr |= (ADDR_BITS'(1)<<ones)-1'b1;
        cfg[entry*8+:8]=8'($urandom);
        addr[entry*ADDR_BITS+:ADDR_BITS]=raw_addr;
      end
      valid=2'($urandom);
      for (int port=0; port<CHECK_PORTS; port++) begin
        size[port]=3'($urandom); access[port]=3'($urandom);
        privilege[port]=privilege_e'(2'($urandom));
        address[port]=PADDR_WIDTH'({$urandom,$urandom});
      end
      // Exercise both sides of decoded boundaries and address-space wrap,
      // rather than predominantly unrelated random addresses.
      #1;
      for (int port=0; port<CHECK_PORTS; port++) begin
        int entry;
        entry=$urandom_range(0,PMP_ENTRIES-1);
        case (cycle%4)
          0: address[port]=PADDR_WIDTH'(ref_i.region_low_decoded[entry])+
                           PADDR_WIDTH'($urandom_range(0,15));
          1: address[port]=PADDR_WIDTH'(ref_i.region_high_decoded[entry])-
                           PADDR_WIDTH'($urandom_range(0,15));
          2: address[port]='1-PADDR_WIDTH'($urandom_range(0,15));
          default: begin end
        endcase
      end
      #1;
      if ({allow_dut,match_dut,fault_dut} !== {allow_ref,match_ref,fault_ref})
        $fatal(1,"PMP mismatch PADDR=%0d cycle=%0d cfg=%h addr=%h check=%h size=%h priv=%h dut=%b/%b ref=%b/%b",
          PADDR_WIDTH,cycle,cfg,addr,address,size,privilege,allow_dut,match_dut,allow_ref,match_ref);
      for (int port=0; port<CHECK_PORTS; port++) if (valid[port]) begin
        checks++; allowed+=int'(allow_dut[port]); denied+=int'(!allow_dut[port]);
        matched+=int'(match_dut[port]);
      end
    end
    if (allowed<100 || denied<100 || matched<100) $fatal(1,"Insufficient PMP coverage");
    $display("PMP binary differential PASS PADDR=%0d vectors=100000 checks=%0d allowed=%0d denied=%0d matched=%0d",
      PADDR_WIDTH,checks,allowed,denied,matched);
    $finish;
  end
endmodule
