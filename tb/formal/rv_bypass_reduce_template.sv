module rv_bypass_reduce_miter #(
  parameter int XLEN=@XLEN@,
  parameter int PHYS_TAG_WIDTH=7,
  parameter int DIRECT_BYPASS_PORTS=@PORTS@
)(
  input logic [DIRECT_BYPASS_PORTS-1:0] direct_wake_valid,
  input rv_ooo_pkg::reg_class_e [DIRECT_BYPASS_PORTS-1:0] direct_wake_class,
  input logic [DIRECT_BYPASS_PORTS-1:0][PHYS_TAG_WIDTH-1:0] direct_wake_phys,
  input logic [DIRECT_BYPASS_PORTS-1:0][XLEN-1:0] direct_wake_data,
  input rv_ooo_pkg::reg_class_e cls,
  input logic [PHYS_TAG_WIDTH-1:0] tag,
  input logic [XLEN-1:0] int_value,
  input logic [31:0] fp_value,
  output logic unique_matches,
  output logic mismatch
);
  import rv_ooo_pkg::*;
  @REFERENCE_FUNCTION@
  @CANDIDATE_FUNCTION@
  logic [DIRECT_BYPASS_PORTS-1:0] hits;
  logic [XLEN-1:0] reference_result,candidate_result;
  for(genvar w=0;w<DIRECT_BYPASS_PORTS;w++) begin:g_hit
    assign hits[w]=direct_wake_valid[w] && cls!=REG_NONE &&
      direct_wake_class[w]==cls && direct_wake_phys[w]==tag;
  end
  assign unique_matches=($countones(hits)<=1);
  assign reference_result=reference_bypass(cls,tag,int_value,fp_value);
  assign candidate_result=candidate_bypass(cls,tag,int_value,fp_value) @ERROR_MASK@;
  assign mismatch=(reference_result!=candidate_result);
endmodule
