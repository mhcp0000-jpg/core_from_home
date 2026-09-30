module rv_wb_equiv_tb;
import rv_ooo_pkg::*;
localparam XLEN=32,SOURCE_COUNT=11,PHYS_TAG_WIDTH=7,ROB_SEQ_WIDTH=8,INT_WRITE_PORTS=2,FP_WRITE_PORTS=2,ROB_COMPLETE_PORTS=4;
logic [SOURCE_COUNT-1:0] source_valid_i;
logic [SOURCE_COUNT-1:0] source_live_i;
logic [SOURCE_COUNT-1:0][ROB_SEQ_WIDTH-1:0] source_sequence_i;
logic [SOURCE_COUNT-1:0] source_destination_valid_i;
rv_ooo_pkg::reg_class_e [SOURCE_COUNT-1:0] source_destination_class_i;
logic [SOURCE_COUNT-1:0][PHYS_TAG_WIDTH-1:0] source_destination_phys_i;
logic [SOURCE_COUNT-1:0][XLEN-1:0] source_data_i;
logic [SOURCE_COUNT-1:0] source_exception_valid_i;
rv_ooo_pkg::exception_code_e [SOURCE_COUNT-1:0] source_exception_cause_i;
logic [SOURCE_COUNT-1:0][XLEN-1:0] source_exception_tval_i;
logic [SOURCE_COUNT-1:0] source_branch_mispredict_i;
logic [SOURCE_COUNT-1:0][XLEN-1:0] source_branch_target_i;
logic [SOURCE_COUNT-1:0][4:0] source_fflags_i;
logic flush_valid_i;
logic flush_all_i;
logic [ROB_SEQ_WIDTH-1:0] flush_sequence_i;
logic [SOURCE_COUNT-1:0] source_ready_o_0;
logic [SOURCE_COUNT-1:0] source_ready_o_1;
logic [INT_WRITE_PORTS-1:0] int_wb_valid_o_0;
logic [INT_WRITE_PORTS-1:0] int_wb_valid_o_1;
logic [INT_WRITE_PORTS-1:0][PHYS_TAG_WIDTH-1:0] int_wb_phys_o_0;
logic [INT_WRITE_PORTS-1:0][PHYS_TAG_WIDTH-1:0] int_wb_phys_o_1;
logic [INT_WRITE_PORTS-1:0][XLEN-1:0] int_wb_data_o_0;
logic [INT_WRITE_PORTS-1:0][XLEN-1:0] int_wb_data_o_1;
logic [FP_WRITE_PORTS-1:0] fp_wb_valid_o_0;
logic [FP_WRITE_PORTS-1:0] fp_wb_valid_o_1;
logic [FP_WRITE_PORTS-1:0][PHYS_TAG_WIDTH-1:0] fp_wb_phys_o_0;
logic [FP_WRITE_PORTS-1:0][PHYS_TAG_WIDTH-1:0] fp_wb_phys_o_1;
logic [FP_WRITE_PORTS-1:0][31:0] fp_wb_data_o_0;
logic [FP_WRITE_PORTS-1:0][31:0] fp_wb_data_o_1;
logic [ROB_COMPLETE_PORTS-1:0] wakeup_valid_o_0;
logic [ROB_COMPLETE_PORTS-1:0] wakeup_valid_o_1;
rv_ooo_pkg::reg_class_e [ROB_COMPLETE_PORTS-1:0] wakeup_class_o_0;
rv_ooo_pkg::reg_class_e [ROB_COMPLETE_PORTS-1:0] wakeup_class_o_1;
logic [ROB_COMPLETE_PORTS-1:0][PHYS_TAG_WIDTH-1:0] wakeup_phys_o_0;
logic [ROB_COMPLETE_PORTS-1:0][PHYS_TAG_WIDTH-1:0] wakeup_phys_o_1;
logic [ROB_COMPLETE_PORTS-1:0] complete_valid_o_0;
logic [ROB_COMPLETE_PORTS-1:0] complete_valid_o_1;
logic [ROB_COMPLETE_PORTS-1:0][ROB_SEQ_WIDTH-1:0] complete_sequence_o_0;
logic [ROB_COMPLETE_PORTS-1:0][ROB_SEQ_WIDTH-1:0] complete_sequence_o_1;
logic [ROB_COMPLETE_PORTS-1:0] complete_exception_valid_o_0;
logic [ROB_COMPLETE_PORTS-1:0] complete_exception_valid_o_1;
rv_ooo_pkg::exception_code_e [ROB_COMPLETE_PORTS-1:0] complete_exception_cause_o_0;
rv_ooo_pkg::exception_code_e [ROB_COMPLETE_PORTS-1:0] complete_exception_cause_o_1;
logic [ROB_COMPLETE_PORTS-1:0][XLEN-1:0] complete_exception_tval_o_0;
logic [ROB_COMPLETE_PORTS-1:0][XLEN-1:0] complete_exception_tval_o_1;
logic [ROB_COMPLETE_PORTS-1:0] complete_branch_mispredict_o_0;
logic [ROB_COMPLETE_PORTS-1:0] complete_branch_mispredict_o_1;
logic [ROB_COMPLETE_PORTS-1:0][XLEN-1:0] complete_branch_target_o_0;
logic [ROB_COMPLETE_PORTS-1:0][XLEN-1:0] complete_branch_target_o_1;
logic [ROB_COMPLETE_PORTS-1:0][4:0] complete_fflags_o_0;
logic [ROB_COMPLETE_PORTS-1:0][4:0] complete_fflags_o_1;
rv_writeback_arbiter #(.SOURCE_COUNT(SOURCE_COUNT)) u0 (
.source_valid_i(source_valid_i),
.source_live_i(source_live_i),
.source_sequence_i(source_sequence_i),
.source_destination_valid_i(source_destination_valid_i),
.source_destination_class_i(source_destination_class_i),
.source_destination_phys_i(source_destination_phys_i),
.source_data_i(source_data_i),
.source_exception_valid_i(source_exception_valid_i),
.source_exception_cause_i(source_exception_cause_i),
.source_exception_tval_i(source_exception_tval_i),
.source_branch_mispredict_i(source_branch_mispredict_i),
.source_branch_target_i(source_branch_target_i),
.source_fflags_i(source_fflags_i),
.flush_valid_i(flush_valid_i),
.flush_all_i(flush_all_i),
.flush_sequence_i(flush_sequence_i),
.source_ready_o(source_ready_o_0),
.int_wb_valid_o(int_wb_valid_o_0),
.int_wb_phys_o(int_wb_phys_o_0),
.int_wb_data_o(int_wb_data_o_0),
.fp_wb_valid_o(fp_wb_valid_o_0),
.fp_wb_phys_o(fp_wb_phys_o_0),
.fp_wb_data_o(fp_wb_data_o_0),
.wakeup_valid_o(wakeup_valid_o_0),
.wakeup_class_o(wakeup_class_o_0),
.wakeup_phys_o(wakeup_phys_o_0),
.complete_valid_o(complete_valid_o_0),
.complete_sequence_o(complete_sequence_o_0),
.complete_exception_valid_o(complete_exception_valid_o_0),
.complete_exception_cause_o(complete_exception_cause_o_0),
.complete_exception_tval_o(complete_exception_tval_o_0),
.complete_branch_mispredict_o(complete_branch_mispredict_o_0),
.complete_branch_target_o(complete_branch_target_o_0),
.complete_fflags_o(complete_fflags_o_0));
rv_writeback_arbiter_timing_ref #(.SOURCE_COUNT(SOURCE_COUNT)) u1 (
.source_valid_i(source_valid_i),
.source_live_i(source_live_i),
.source_sequence_i(source_sequence_i),
.source_destination_valid_i(source_destination_valid_i),
.source_destination_class_i(source_destination_class_i),
.source_destination_phys_i(source_destination_phys_i),
.source_data_i(source_data_i),
.source_exception_valid_i(source_exception_valid_i),
.source_exception_cause_i(source_exception_cause_i),
.source_exception_tval_i(source_exception_tval_i),
.source_branch_mispredict_i(source_branch_mispredict_i),
.source_branch_target_i(source_branch_target_i),
.source_fflags_i(source_fflags_i),
.flush_valid_i(flush_valid_i),
.flush_all_i(flush_all_i),
.flush_sequence_i(flush_sequence_i),
.source_ready_o(source_ready_o_1),
.int_wb_valid_o(int_wb_valid_o_1),
.int_wb_phys_o(int_wb_phys_o_1),
.int_wb_data_o(int_wb_data_o_1),
.fp_wb_valid_o(fp_wb_valid_o_1),
.fp_wb_phys_o(fp_wb_phys_o_1),
.fp_wb_data_o(fp_wb_data_o_1),
.wakeup_valid_o(wakeup_valid_o_1),
.wakeup_class_o(wakeup_class_o_1),
.wakeup_phys_o(wakeup_phys_o_1),
.complete_valid_o(complete_valid_o_1),
.complete_sequence_o(complete_sequence_o_1),
.complete_exception_valid_o(complete_exception_valid_o_1),
.complete_exception_cause_o(complete_exception_cause_o_1),
.complete_exception_tval_o(complete_exception_tval_o_1),
.complete_branch_mispredict_o(complete_branch_mispredict_o_1),
.complete_branch_target_o(complete_branch_target_o_1),
.complete_fflags_o(complete_fflags_o_1));
logic [7:0] base;
initial begin
source_valid_i='0;
source_live_i='0;
source_sequence_i='0;
source_destination_valid_i='0;
source_destination_class_i='0;
source_destination_phys_i='0;
source_data_i='0;
source_exception_valid_i='0;
source_exception_cause_i='0;
source_exception_tval_i='0;
source_branch_mispredict_i='0;
source_branch_target_i='0;
source_fflags_i='0;
flush_valid_i='0;
flush_all_i='0;
flush_sequence_i='0;
for(int n=0;n<30000;n++) begin
base=$urandom;
source_valid_i=$urandom;source_live_i=$urandom;
source_destination_valid_i=$urandom;source_exception_valid_i=$urandom;
source_branch_mispredict_i=$urandom;flush_valid_i=($urandom_range(0,7)==0);
flush_all_i=$urandom_range(0,1);flush_sequence_i=$urandom;
for(int s=0;s<SOURCE_COUNT;s++) begin
source_sequence_i[s]=base+8'((s+n)%SOURCE_COUNT);
source_destination_phys_i[s]=7'(s+1);source_data_i[s]=$urandom;
source_exception_tval_i[s]=$urandom;source_branch_target_i[s]=$urandom;
source_fflags_i[s]=$urandom;
case($urandom_range(0,2))
0:source_destination_class_i[s]=REG_NONE;
1:source_destination_class_i[s]=REG_INT;
2:source_destination_class_i[s]=REG_FP;
endcase
case($urandom_range(0,3))
0:source_exception_cause_i[s]=EXC_ILLEGAL_INSTRUCTION;
1:source_exception_cause_i[s]=EXC_LOAD_ACCESS_FAULT;
2:source_exception_cause_i[s]=EXC_STORE_ACCESS_FAULT;
3:source_exception_cause_i[s]=EXC_INST_ACCESS_FAULT;
endcase
end
#1;
if({source_ready_o_0,int_wb_valid_o_0,int_wb_phys_o_0,int_wb_data_o_0,fp_wb_valid_o_0,fp_wb_phys_o_0,fp_wb_data_o_0,wakeup_valid_o_0,wakeup_class_o_0,wakeup_phys_o_0,complete_valid_o_0,complete_sequence_o_0,complete_exception_valid_o_0,complete_exception_cause_o_0,complete_exception_tval_o_0,complete_branch_mispredict_o_0,complete_branch_target_o_0,complete_fflags_o_0}!=={source_ready_o_1,int_wb_valid_o_1,int_wb_phys_o_1,int_wb_data_o_1,fp_wb_valid_o_1,fp_wb_phys_o_1,fp_wb_data_o_1,wakeup_valid_o_1,wakeup_class_o_1,wakeup_phys_o_1,complete_valid_o_1,complete_sequence_o_1,complete_exception_valid_o_1,complete_exception_cause_o_1,complete_exception_tval_o_1,complete_branch_mispredict_o_1,complete_branch_target_o_1,complete_fflags_o_1})$fatal(1,"WB equivalence failed vector %0d",n);
end
$display("WB 11-source equivalence PASS 30000 vectors");$finish;
end
endmodule
