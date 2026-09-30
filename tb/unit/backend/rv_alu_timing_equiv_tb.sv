module rv_alu_equiv_case #(parameter XLEN=32) (output logic done);
import rv_ooo_pkg::*;
logic [XLEN-1:0] a,b; int_alu_op_e op;logic word_op;
wire [XLEN-1:0] value,new_value;
rv_int_alu #(.XLEN(XLEN)) dut(a,b,op,word_op,new_value);
rv_int_alu_timing_ref #(.XLEN(XLEN)) ref_dut(a,b,op,word_op,value);
initial begin
done=0;
for(int n=0;n<150000;n++) begin
a={$urandom,$urandom};b={$urandom,$urandom};word_op=$urandom_range(0,1);
case(n%13)
0:op=ALU_ADD;1:op=ALU_SUB;2:op=ALU_SLT;3:op=ALU_SLTU;
4:op=ALU_XOR;5:op=ALU_OR;6:op=ALU_AND;7:op=ALU_SLL;
8:op=ALU_SRL;9:op=ALU_SRA;10:op=ALU_COPY_SRC0;11:op=ALU_COPY_SRC1;12:op=ALU_ADD;
endcase
case((n/13)%9)
0:begin a=0;b=0;end
1:begin a='1;b=1;end
2:begin a=0;b='1;end
3:begin a={1'b1,{(XLEN-1){1'b0}}};b=1;end
4:begin a=1;b=XLEN'(XLEN-1);end
default:begin end
endcase
#1;
if(value!==new_value)$fatal(1,"ALU XLEN=%0d n=%0d op=%0d a=%h b=%h ref=%h got=%h",XLEN,n,op,a,b,value,new_value);
end
$display("ALU equivalence PASS XLEN=%0d 150000 vectors",XLEN);done=1;
end
endmodule
module rv_alu_equiv_tb;
wire done32,done64;
rv_alu_equiv_case #(.XLEN(32)) c32(done32);
rv_alu_equiv_case #(.XLEN(64)) c64(done64);
initial begin wait(done32&&done64);$finish;end
endmodule
