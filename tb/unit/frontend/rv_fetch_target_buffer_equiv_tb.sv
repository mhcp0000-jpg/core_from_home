module rv_fetch_target_buffer_equiv_tb #(
  parameter int PADDR_WIDTH=32, FETCH_BYTES=16, ENTRIES=16, LOOKUP_PORTS=2,
  localparam int OFF=$clog2(FETCH_BYTES), IDX=$clog2(ENTRIES),
  localparam int SEL=(LOOKUP_PORTS>1)?$clog2(LOOKUP_PORTS):1
);
  logic clk=0, rst_n=0;
  always #5 clk=~clk;
  logic invalidate, fill_valid;
  logic [PADDR_WIDTH-1:0] fill_addr;
  logic [FETCH_BYTES*8-1:0] fill_data, data, ref_data;
  logic [FETCH_BYTES/2-1:0] fill_pmp, pmp, ref_pmp;
  logic [LOOKUP_PORTS-1:0] valid;
  logic [LOOKUP_PORTS-1:0][PADDR_WIDTH-1:0] addr;
  logic [SEL-1:0] select_port;
  logic hit, ref_hit;
  logic [ENTRIES-1:0][PADDR_WIDTH-1:0] address_pool;
  int unsigned seed=32'h5317bace;
  int comparisons=0;
  function automatic int unsigned rand_word();
    seed ^= seed<<13; seed ^= seed>>17; seed ^= seed<<5;
    return seed;
  endfunction
  rv_fetch_target_buffer #(.PADDR_WIDTH(PADDR_WIDTH), .FETCH_BYTES(FETCH_BYTES),
    .ENTRIES(ENTRIES), .LOOKUP_PORTS(LOOKUP_PORTS)) dut (
    .clk_i(clk), .rst_ni(rst_n), .invalidate_i(invalidate),
    .lookup_valid_i(valid), .lookup_addr_i(addr), .lookup_select_i(select_port),
    .lookup_hit_o(hit), .lookup_data_o(data), .lookup_pmp_allow_o(pmp),
    .fill_valid_i(fill_valid), .fill_addr_i(fill_addr), .fill_data_i(fill_data),
    .fill_pmp_allow_i(fill_pmp)
  );
  rv_fetch_target_buffer_ref #(.PADDR_WIDTH(PADDR_WIDTH), .FETCH_BYTES(FETCH_BYTES),
    .ENTRIES(ENTRIES), .LOOKUP_PORTS(LOOKUP_PORTS)) reference (
    .clk_i(clk), .rst_ni(rst_n), .invalidate_i(invalidate),
    .lookup_valid_i(valid), .lookup_addr_i(addr), .lookup_select_i(select_port),
    .lookup_hit_o(ref_hit), .lookup_data_o(ref_data), .lookup_pmp_allow_o(ref_pmp),
    .fill_valid_i(fill_valid), .fill_addr_i(fill_addr), .fill_data_i(fill_data),
    .fill_pmp_allow_i(fill_pmp)
  );
  task automatic check();
    comparisons++;
    // Raw data/PMP on misses and invalid ports are part of this comparison.
    if ({hit,data,pmp} !== {ref_hit,ref_data,ref_pmp})
      $fatal(1,"FTB public mismatch check=%0d select=%b hit=%b/%b",comparisons,select_port,hit,ref_hit);
    if(dut.valid_q !== reference.valid_q) $fatal(1,"FTB valid-state mismatch");
    for(int e=0; e<ENTRIES; e++)
      if({dut.tag_q[e],dut.data_q[e],dut.pmp_allow_q[e]} !==
         {reference.tag_q[e],reference.data_q[e],reference.pmp_allow_q[e]})
        $fatal(1,"FTB resident state mismatch e=%0d",e);
  endtask
  initial begin
    invalidate=0; fill_valid=0; fill_addr=0; fill_data=0; fill_pmp=0;
    valid=0; addr=0; select_port=0; address_pool=0;
    repeat(3) @(negedge clk);
    rst_n=1;
    for(int cycle=0; cycle<100000; cycle++) begin
      rst_n=(cycle%997 != 996);
      invalidate=(rand_word()%19==0);
      fill_valid=(rand_word()%3!=0);
      fill_addr=PADDR_WIDTH'(32'h80000000 | ((rand_word()&32'h1ff)<<OFF));
      if(PADDR_WIDTH==64) fill_addr=PADDR_WIDTH'({rand_word(),32'(fill_addr)});
      for(int w=0; w<FETCH_BYTES/4; w++) fill_data[w*32 +:32]=rand_word();
      fill_pmp=(FETCH_BYTES/2)'(rand_word());
      for(int port=0; port<LOOKUP_PORTS; port++) begin
        addr[port]=address_pool[rand_word()%ENTRIES];
        if(rand_word()%4==0) addr[port]=fill_addr;
        if(rand_word()%5==0) addr[port] ^= (PADDR_WIDTH'(1) << (OFF+IDX));
        valid[port]=1'(rand_word());
      end
      select_port=SEL'(rand_word()%LOOKUP_PORTS);
      #1; check();
      if(!rst_n) address_pool=0;
      else if(!invalidate && fill_valid) address_pool[fill_addr[OFF+IDX-1:OFF]]=fill_addr;
      @(negedge clk); check();
    end
`ifdef FTB_XCHECK
    // Icarus four-state check: unknown selectors/valids/tag and index bits,
    // without an undefined memory write. Verilator's normal run omits this.
    rst_n=1; invalidate=0; valid='1; select_port=0;
    for(int e=0; e<ENTRIES; e++) begin
      fill_valid=1; fill_addr=PADDR_WIDTH'(32'h80000000)+(PADDR_WIDTH'(e)<<OFF);
      fill_data=(FETCH_BYTES*8)'(32'h12340000+e); fill_pmp='1;
      @(negedge clk); check();
    end
    fill_valid=0;
    for(int port=0; port<LOOKUP_PORTS; port++)
      addr[port]=PADDR_WIDTH'(32'h80000000)+(PADDR_WIDTH'(port%ENTRIES)<<OFF);
    #1; check();
    select_port='x; #1; check();
    valid='0; #1; check();
    select_port=0; valid='1;
    addr[0][PADDR_WIDTH-1]=1'bx; #1; check();
    addr[0]=PADDR_WIDTH'(32'h80000000); addr[0][OFF]=1'bx; #1; check();
    valid[0]=1'b0; #1; check();
    addr[0]=PADDR_WIDTH'(32'h80000000); valid[0]=1'bx; #1; check();
    valid='1; select_port=SEL'(LOOKUP_PORTS-1); #1; check();
    if(LOOKUP_PORTS==1) begin select_port=1; #1; check(); end
    $display("FTB four-state selector/valid/tag/index probes PASS");
`endif
    $display("FTB full-output/state equivalence PASS PADDR=%0d FETCH=%0d ENTRIES=%0d PORTS=%0d compares=%0d",
             PADDR_WIDTH,FETCH_BYTES,ENTRIES,LOOKUP_PORTS,comparisons);
    $finish;
  end
endmodule
