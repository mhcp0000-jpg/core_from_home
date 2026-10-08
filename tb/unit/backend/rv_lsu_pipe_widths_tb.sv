// Exact one-/two-entry queue model with independent native arithmetic.
// Includes invalid sizes, split store phases, signed offsets, address wrap,
// XLEN64/PADDR32 truncation, backpressure, selective flush and repeated reset.
module rv_lsu_pipe_width_case #(parameter int XLEN=32, DEPTH=2)(output logic done);
  import rv_ooo_pkg::*;
  logic clk=0, rst_n=0;
  always #5 clk=~clk;
  logic iv, ir, uv, ur, fl, fa;
  logic [7:0] seq, boundary, useq;
  logic ld, st, av, dv, lvalid, svalid;
  logic [4:0] li, uli;
  logic [3:0] si, usi;
  logic [XLEN-1:0] base, imm, data, tval;
  logic [2:0] size;
  logic [31:0] addr;
  typedef struct packed {
    logic [7:0] seq;
    logic ld,st,lv,sv;
    logic [4:0] li;
    logic [3:0] si;
    logic [31:0] addr;
    logic [2:0] size;
    logic [7:0] mask;
    logic [63:0] data;
    logic av,dv,exc;
    exception_code_e cause;
    logic [XLEN-1:0] tval;
  } entry_t;
  entry_t actual, model[$];
  rv_lsu_pipe #(.XLEN(XLEN),.PADDR_WIDTH(32),.MEM_DATA_WIDTH(64),
    .ROB_SEQ_WIDTH(8),.LQ_INDEX_WIDTH(5),.SQ_INDEX_WIDTH(4),.DEPTH(DEPTH)) dut(
    .clk_i(clk),.rst_ni(rst_n),.issue_valid_i(iv),.issue_ready_o(ir),
    .issue_rob_sequence_i(seq),.issue_is_load_i(ld),.issue_is_store_i(st),
    .issue_address_valid_i(av),.issue_store_data_valid_i(dv),
    .issue_lq_valid_i(lvalid),.issue_lq_index_i(li),
    .issue_sq_valid_i(svalid),.issue_sq_index_i(si),
    .base_i(base),.immediate_i(imm),.store_data_i(data),.memory_size_i(size),
    .flush_valid_i(fl),.flush_all_i(fa),.flush_sequence_i(boundary),
    .update_valid_o(uv),.update_ready_i(ur),
    .update_rob_sequence_o(actual.seq),.update_is_load_o(actual.ld),
    .update_is_store_o(actual.st),.update_lq_valid_o(actual.lv),
    .update_lq_index_o(actual.li),.update_sq_valid_o(actual.sv),
    .update_sq_index_o(actual.si),.update_address_o(actual.addr),
    .update_memory_size_o(actual.size),.update_byte_mask_o(actual.mask),
    .update_store_data_o(actual.data),.update_address_valid_o(actual.av),
    .update_store_data_valid_o(actual.dv),.update_exception_valid_o(actual.exc),
    .update_exception_cause_o(actual.cause),.update_exception_tval_o(actual.tval));
  function automatic logic younger(input logic [7:0] a,b);
    logic [7:0] distance;
    distance=a-b;
    return distance!=0 && !distance[7];
  endfunction
  function automatic entry_t incoming();
    entry_t e;
    logic [XLEN-1:0] ea, align;
    int offset, bytes;
    ea=base+imm; offset=int'(ea[2:0]); bytes=1<<size;
    align=XLEN'(bytes-1);
    e='0;
    e.seq=seq;e.ld=ld;e.st=st;e.lv=lvalid;e.sv=svalid;
    e.li=li;e.si=si;e.addr=32'(ea);e.size=size;
    for(int b=0;b<8;b++) e.mask[b]=(b>=offset && b<offset+bytes);
    e.data=64'(data)<<(offset*8);e.av=av;e.dv=st && dv;
    e.exc=bytes>8 || size>3 || ((ea & align)!=0);
    e.cause=st ? EXC_STORE_ADDR_MISALIGNED : EXC_LOAD_ADDR_MISALIGNED;
    e.tval=ea;
    return e;
  endfunction
  task automatic check();
    if(uv !== (model.size()!=0)) $fatal(1,"LSU valid X%0d D%0d",XLEN,DEPTH);
    if(uv && actual !== model[0]) $fatal(1,"LSU payload X%0d D%0d actual=%h expected=%h",XLEN,DEPTH,actual,model[0]);
    if(ir !== ((!fl) && ((model.size()<DEPTH) || (DEPTH==1 && ur))))
      $fatal(1,"LSU ready X%0d D%0d",XLEN,DEPTH);
  endtask
  int pushed=0,popped=0,flushed=0,reset_count=0;
  initial begin
    done=0;iv=0;ur=0;fl=0;fa=0;seq=0;boundary=0;
    ld=0;st=0;av=0;dv=0;lvalid=0;svalid=0;li=0;si=0;
    base=0;imm=0;data=0;size=0;
    repeat(3) @(negedge clk);
    for(int cycle=0;cycle<100000;cycle++) begin
      @(negedge clk);
      rst_n=(cycle%4096)!=0;
      seq=8'(pushed); // Drive only at negedge; never race DUT sampling.
      iv=($urandom_range(0,2)!=0);ur=($urandom_range(0,2)!=0);
      fl=($urandom_range(0,23)==0);fa=($urandom_range(0,4)==0);
      boundary=seq-8'($urandom_range(0,10));
      ld=1'($urandom());st=!ld;
      av=ld || 1'($urandom());dv=1'($urandom());
      lvalid=ld;svalid=st;li=5'($urandom());si=4'($urandom());
      base=XLEN'({$urandom(),$urandom()});imm=XLEN'({$urandom(),$urandom()});
      data=XLEN'({$urandom(),$urandom()});size=3'($urandom());
      // Deterministic carry, sign-extension and wrap corner vectors.
      case(cycle%64)
        0: begin base='1;imm=1;size=2;end
        1: begin base=XLEN'(32'h7fff_ffff);imm=1;end
        2: begin base=XLEN'(32'h8000_0000);imm='1;end
        3: begin base=XLEN'(32'hffff_fff8);imm=8;size=3;end
        default: begin end
      endcase
      #1;
      if(rst_n) check();
      @(posedge clk);
      if(!rst_n) begin model.delete();reset_count++;end
      else begin
        automatic logic push,pop;
        push=iv && ir;pop=uv && ur && (DEPTH==1 || !fl);
        if(pop) begin void'(model.pop_front());popped++;end
        if(fl) begin
          automatic entry_t survivors[$];
          foreach(model[i]) if(!fa && !younger(model[i].seq,boundary)) survivors.push_back(model[i]);
          model=survivors;flushed++;
        end
        if(push) begin model.push_back(incoming());pushed++;end
      end
      #1;check();
    end
    $display("PASS LSU X%0d D%0d cycles100000 push%0d pop%0d flush%0d reset%0d",XLEN,DEPTH,pushed,popped,flushed,reset_count);
    done=1;
  end
endmodule
module rv_lsu_pipe_widths_tb;
  wire [3:0] done;
  rv_lsu_pipe_width_case #(.XLEN(32),.DEPTH(1)) a(done[0]);
  rv_lsu_pipe_width_case #(.XLEN(32),.DEPTH(2)) b(done[1]);
  rv_lsu_pipe_width_case #(.XLEN(64),.DEPTH(1)) c(done[2]);
  rv_lsu_pipe_width_case #(.XLEN(64),.DEPTH(2)) d(done[3]);
  initial begin wait(&done);$finish;end
endmodule
