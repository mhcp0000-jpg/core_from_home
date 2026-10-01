// Bit-exact alignment comparison against an immutable Git reference.
module rv_fpu_align_equiv_tb #(parameter int XLEN=32);
  import rv_ooo_pkg::*;
  logic clk=0, rst_n=0;
  always #5 clk=~clk;
  logic [63:0] rng=64'h8391_a765_40dc_b21f;
  logic [XLEN+293:0] actual, expected;
  int vectors=0;
  int integer_vectors=0;
  rv_fpu #(.XLEN(XLEN),.LATENCY(5)) dut(
    .clk_i(clk),.rst_ni(rst_n),.request_valid_i(1'b0),.request_ready_o(),
    .instruction_i('0),.operand_a_i('0),.operand_b_i('0),.operand_c_i('0),
    .rounding_mode_i('0),.frm_i('0),.sequence_i('0),.destination_valid_i(1'b0),
    .destination_class_i(REG_NONE),.destination_phys_i('0),.flush_valid_i(1'b0),
    .flush_all_i(1'b0),.flush_sequence_i('0),.result_valid_o(),.result_ready_i(1'b1),
    .result_sequence_o(),.result_destination_valid_o(),.result_destination_class_o(),
    .result_destination_phys_o(),.result_data_o(),.result_fflags_o(),
    .result_exception_valid_o(),.result_exception_cause_o(),.result_exception_tval_o());
  rv_fpu_ref #(.XLEN(XLEN),.LATENCY(5)) reference(
    .clk_i(clk),.rst_ni(rst_n),.request_valid_i(1'b0),.request_ready_o(),
    .instruction_i('0),.operand_a_i('0),.operand_b_i('0),.operand_c_i('0),
    .rounding_mode_i('0),.frm_i('0),.sequence_i('0),.destination_valid_i(1'b0),
    .destination_class_i(REG_NONE),.destination_phys_i('0),.flush_valid_i(1'b0),
    .flush_all_i(1'b0),.flush_sequence_i('0),.result_valid_o(),.result_ready_i(1'b1),
    .result_sequence_o(),.result_destination_valid_o(),.result_destination_class_o(),
    .result_destination_phys_o(),.result_data_o(),.result_fflags_o(),
    .result_exception_valid_o(),.result_exception_cause_o(),.result_exception_tval_o());
  function automatic logic [31:0] random32();
    rng^=rng<<13; rng^=rng>>7; rng^=rng<<17; return rng[31:0];
  endfunction
  task automatic check(input logic [31:0] a,b,c, input logic [2:0] rm);
    logic [31:0] instruction;
    for (int subtract=0; subtract<2; subtract++) begin
      actual=dut.fp_add_sub_align(a,b,1'(subtract),rm);
      expected=reference.fp_add_sub_align(a,b,1'(subtract),rm);
      if (actual!==expected)
        $fatal(1,"add-align mismatch xlen=%0d a=%h b=%h sub=%0d rm=%0d actual=%h expected=%h",
          XLEN,a,b,subtract,rm,actual,expected);
      instruction={subtract ? 7'h04 : 7'h00,5'd2,5'd1,rm,5'd3,7'h53};
      actual=dut.finish_align_seed(dut.prepare_align_seed(instruction,a,b,c,rm));
      if (actual!==expected)
        $fatal(1,"split add-align mismatch xlen=%0d a=%h b=%h sub=%0d rm=%0d",XLEN,a,b,subtract,rm);
      vectors++;
    end
    for (int negate=0; negate<4; negate++) begin
      actual=dut.fp_fma_align(a,b,c,1'(negate>>1),1'(negate),rm);
      expected=reference.fp_fma_align(a,b,c,1'(negate>>1),1'(negate),rm);
      if (actual!==expected)
        $fatal(1,"fma-align mismatch xlen=%0d a=%h b=%h c=%h negate=%0d rm=%0d actual=%h expected=%h",
          XLEN,a,b,c,negate,rm,actual,expected);
      case (negate)
        0: instruction={5'd3,2'b00,5'd2,5'd1,rm,5'd4,7'h43};
        1: instruction={5'd3,2'b00,5'd2,5'd1,rm,5'd4,7'h47};
        2: instruction={5'd3,2'b00,5'd2,5'd1,rm,5'd4,7'h4b};
        3: instruction={5'd3,2'b00,5'd2,5'd1,rm,5'd4,7'h4f};
      endcase
      actual=dut.finish_align_seed(dut.prepare_align_seed(instruction,a,b,c,rm));
      if (actual!==expected)
        $fatal(1,"split fma-align mismatch xlen=%0d a=%h b=%h c=%h negate=%0d rm=%0d",XLEN,a,b,c,negate,rm);
      vectors++;
    end
  endtask
  task automatic check_integer(input logic [31:0] a);
    logic [XLEN+4:0] actual_integer, expected_integer;
    // Compare every helper RM encoding, including the default cases that
    // architectural illegal-RM handling filters before this helper is used.
    for (int kind=0; kind<4; kind++) for (int rm=0; rm<8; rm++) begin
      actual_integer=dut.fp_to_integer(a,2'(kind),3'(rm));
      expected_integer=reference.fp_to_integer(a,2'(kind),3'(rm));
      if(actual_integer!==expected_integer)
        $fatal(1,"fp-to-integer mismatch xlen=%0d a=%h kind=%0d rm=%0d actual=%h expected=%h",
               XLEN,a,kind,rm,actual_integer,expected_integer);
      integer_vectors++;
    end
  endtask
  initial begin
    if ($bits(dut.align_calc_q)!=XLEN+294)
      $fatal(1,"Update alignment struct dimensions in test");
    repeat(3) @(negedge clk); rst_n=1;
    // All exponent/sign combinations, every fraction-bit transition and its
    // adjacent values: tiny fractions, half ties, signed/unsigned 32/64-bit
    // limits, exact negative minima, infinities and both classes of NaN.
    for (int exponent=0; exponent<256; exponent++)
      for (int sign=0; sign<2; sign++) for (int sample=0; sample<73; sample++) begin
        logic [22:0] fraction;
        case(sample)
          0: fraction='0;
          1: fraction='1;
          2: fraction=23'h400000;
          3: fraction=23'h3fffff;
          default: fraction=(23'd1 << ((sample-4)/3)) + 23'((sample-4)%3) - 23'd1;
        endcase
        check_integer({1'(sign),8'(exponent),fraction});
      end
    // Every exponent combination for add, plus extrema on FMA's third
    // operand. Fraction/sign samples include subnormal/zero/Inf/NaN paths.
    for (int ea=0; ea<256; ea++) for (int eb=0; eb<256; eb++) begin
      logic [31:0] a,b,c;
      a={1'(ea),8'(ea),23'(random32())};
      b={1'(eb),8'(eb),23'(random32())};
      c=((ea+eb)%2==0) ? 32'h00000001 : 32'h7f7fffff;
      check(a,b,c,3'((ea+eb)%5));
    end
    for (int trial=0; trial<100000; trial++) begin
      logic [31:0] a,b,c;
      a=random32(); b=random32(); c=random32();
      check_integer(a);
      if (trial%17==0) a='0;
      if (trial%19==0) b=32'h80000000;
      check(a,b,c,3'(trial%5));
    end
    $display("FPU alignment bit-exact PASS XLEN=%0d vectors=%0d",XLEN,vectors);
    $display("FPU fp-to-integer bit-exact PASS XLEN=%0d vectors=%0d",XLEN,integer_vectors);
    $finish;
  end
endmodule
