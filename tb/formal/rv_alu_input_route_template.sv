// The runner inserts the CURRENT backend ALU routing/instances, not a copied
// implementation. This combinational proof is local to that boundary, not ISA
// or scheduler correctness. Invalid/flush-killed payloads are not observable.
module rv_alu_input_route_miter #(
  parameter int XLEN = @XLEN@
) (
  input logic [1:0][XLEN-1:0] cand_operand0,cand_operand1,
  input logic [1:0][XLEN-1:0] cand_pc,cand_immediate,
  input logic [1:0] cand_use_pc,cand_use_immediate,cand_word,
  input logic [1:0][15:0] cand_operation,
  input logic [1:0] port_candidate,selected_port_valid,
  input logic flush_valid,
  output logic mismatch
);
  import rv_ooo_pkg::*;
  logic [1:0][XLEN-1:0] ref_a,ref_b,ref_result;
  logic [1:0][3:0] ref_operation;
  logic [1:0] ref_word;
  always_comb begin
    ref_a='0; ref_b='0; ref_operation='0; ref_word='0;
    for(int port=0;port<2;port++) begin
      if(selected_port_valid[port] && !flush_valid) begin
        ref_a[port]=cand_use_pc[port_candidate[port]] ?
          cand_pc[port_candidate[port]] : cand_operand0[port_candidate[port]];
        ref_b[port]=cand_use_immediate[port_candidate[port]] ?
          cand_immediate[port_candidate[port]] : cand_operand1[port_candidate[port]];
        ref_operation[port]=cand_operation[port_candidate[port]][3:0];
        ref_word[port]=cand_word[port_candidate[port]];
      end
    end
  end
  for(genvar port=0;port<2;port++) begin : g_reference
    rv_int_alu #(.XLEN(XLEN)) u_reference(
      .operand_a_i(ref_a[port]),.operand_b_i(ref_b[port]),
      .operation_i(int_alu_op_e'(ref_operation[port])),
      .word_operation_i(ref_word[port]),.result_o(ref_result[port]));
  end
  @BACKEND_ALU_BLOCK@
  always_comb begin
    mismatch=1'b0;
    for(int port=0;port<2;port++)
      if(selected_port_valid[port] && !flush_valid)
        mismatch |= (alu_a[port]!=ref_a[port]) || (alu_b[port]!=ref_b[port]) ||
          (alu_operation[port]!=ref_operation[port]) ||
          (alu_word[port]!=ref_word[port]) || (alu_result[port]!=ref_result[port]);
  end
endmodule
