module rv_multiplier_equiv_case #(parameter XLEN=32) (output logic done);
import rv_ooo_pkg::*;
logic clk=0; always #5 clk=~clk;
logic rst_n=0,req,word_op,dst_valid,flush,flush_all,ready;
logic [XLEN-1:0] a,b;
multiply_op_e op;
logic [7:0] seq,flush_seq;
logic [6:0] tag;
logic [1:0] req_ready,valid,out_dst_valid;
logic [1:0][XLEN-1:0] data;
logic [1:0][7:0] out_seq;
logic [1:0][6:0] out_tag;
rv_multiplier #(.XLEN(XLEN)) u0 (
    .clk_i(clk),
    .rst_ni(rst_n),
    .request_valid_i(req),
    .request_ready_o(req_ready[0]),
    .operand_a_i(a),
    .operand_b_i(b),
    .operation_i(op),
    .word_operation_i(word_op),
    .sequence_i(seq),
    .destination_valid_i(dst_valid),
    .destination_phys_i(tag),
    .flush_valid_i(flush),
    .flush_all_i(flush_all),
    .flush_sequence_i(flush_seq),
    .result_valid_o(valid[0]),
    .result_ready_i(ready),
    .result_o(data[0]),
    .result_sequence_o(out_seq[0]),
    .result_destination_valid_o(out_dst_valid[0]),
    .result_destination_phys_o(out_tag[0]));
rv_multiplier_timing_ref #(.XLEN(XLEN)) u1 (
    .clk_i(clk),
    .rst_ni(rst_n),
    .request_valid_i(req),
    .request_ready_o(req_ready[1]),
    .operand_a_i(a),
    .operand_b_i(b),
    .operation_i(op),
    .word_operation_i(word_op),
    .sequence_i(seq),
    .destination_valid_i(dst_valid),
    .destination_phys_i(tag),
    .flush_valid_i(flush),
    .flush_all_i(flush_all),
    .flush_sequence_i(flush_seq),
    .result_valid_o(valid[1]),
    .result_ready_i(ready),
    .result_o(data[1]),
    .result_sequence_o(out_seq[1]),
    .result_destination_valid_o(out_dst_valid[1]),
    .result_destination_phys_o(out_tag[1]));

initial begin
done=0; req=0; a=0;b=0;op=MUL_LOW;word_op=0;
dst_valid=1;flush=0;flush_all=0;ready=0;seq=0;flush_seq=0;tag=0;
repeat(3) @(negedge clk);
rst_n=1;
for(int n=0;n<150000;n++) begin
  @(negedge clk);
  req=$urandom_range(0,1);ready=($urandom_range(0,3)!=0);
  a={$urandom,$urandom}; b={$urandom,$urandom};
  case(n%13)
    0:begin a=0;b='1;end
    1:begin a={1'b1,{(XLEN-1){1'b0}}};b='1;end
    2:begin a='1;b='1;end
    3:begin a={1'b0,{(XLEN-1){1'b1}}};b={1'b0,{(XLEN-1){1'b1}}};end
    default:begin end
  endcase
  word_op=$urandom_range(0,1);
  case($urandom_range(0,3))
    0:op=MUL_LOW;1:op=MUL_HIGH_SS;2:op=MUL_HIGH_SU;3:op=MUL_HIGH_UU;
  endcase
  seq=$urandom;tag=$urandom;dst_valid=$urandom_range(0,1);
  flush=($urandom_range(0,31)==0);flush_all=$urandom_range(0,1);flush_seq=$urandom;
  #1;
  if({req_ready[0],valid[0],data[0],out_seq[0],out_tag[0],out_dst_valid[0]} !==
     {req_ready[1],valid[1],data[1],out_seq[1],out_tag[1],out_dst_valid[1]})
    $fatal(1,"MUL equivalence XLEN=%0d cycle=%0d",XLEN,n);
end
$display("MUL equivalence PASS XLEN=%0d 150000 cycles",XLEN);
done=1;
end
endmodule
module rv_multiplier_equiv_tb;
wire done32,done64;
rv_multiplier_equiv_case #(.XLEN(32)) c32(done32);
rv_multiplier_equiv_case #(.XLEN(64)) c64(done64);
initial begin wait(done32&&done64); $finish; end
endmodule
