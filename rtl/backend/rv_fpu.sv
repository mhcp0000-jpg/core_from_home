module rv_fpu #(
  parameter int unsigned XLEN = 32,
  parameter int unsigned ROB_SEQ_WIDTH = rv_ooo_pkg::ROB_SEQ_WIDTH,
  parameter int unsigned PHYS_TAG_WIDTH = 7,
  parameter int unsigned LATENCY = 3
) (
  input  logic                                      clk_i,
  input  logic                                      rst_ni,
  input  logic                                      request_valid_i,
  output logic                                      request_ready_o,
  input  logic [31:0]                               instruction_i,
  input  logic [XLEN-1:0]                           operand_a_i,
  input  logic [XLEN-1:0]                           operand_b_i,
  input  logic [XLEN-1:0]                           operand_c_i,
  input  logic [2:0]                                rounding_mode_i,
  input  logic [2:0]                                frm_i,
  input  logic [ROB_SEQ_WIDTH-1:0]                  sequence_i,
  input  logic                                      destination_valid_i,
  input  rv_ooo_pkg::reg_class_e                    destination_class_i,
  input  logic [PHYS_TAG_WIDTH-1:0]                 destination_phys_i,

  input  logic                                      flush_valid_i,
  input  logic                                      flush_all_i,
  input  logic [ROB_SEQ_WIDTH-1:0]                  flush_sequence_i,

  output logic                                      result_valid_o,
  input  logic                                      result_ready_i,
  output logic [ROB_SEQ_WIDTH-1:0]                  result_sequence_o,
  output logic                                      result_destination_valid_o,
  output rv_ooo_pkg::reg_class_e                    result_destination_class_o,
  output logic [PHYS_TAG_WIDTH-1:0]                 result_destination_phys_o,
  output logic [XLEN-1:0]                           result_data_o,
  output logic [4:0]                                result_fflags_o,
  output logic                                      result_exception_valid_o,
  output rv_ooo_pkg::exception_code_e               result_exception_cause_o,
  output logic [XLEN-1:0]                           result_exception_tval_o
);

  import rv_ooo_pkg::*;

  localparam int unsigned PIPE_STAGES = (LATENCY < 1) ? 1 : LATENCY;
  localparam logic [4:0] FFLAG_NX = 5'b00001;
  localparam logic [4:0] FFLAG_UF = 5'b00010;
  localparam logic [4:0] FFLAG_OF = 5'b00100;
  localparam logic [4:0] FFLAG_DZ = 5'b01000;
  localparam logic [4:0] FFLAG_NV = 5'b10000;
  localparam logic [31:0] CANONICAL_NAN = 32'h7fc0_0000;

  typedef struct packed {
    logic [XLEN-1:0] data;
    logic [4:0]      flags;
  } fp_calc_t;

  typedef struct packed {
    logic [ROB_SEQ_WIDTH-1:0]  sequence_id;
    logic                      destination_valid;
    reg_class_e                destination_class;
    logic [PHYS_TAG_WIDTH-1:0] destination_phys;
    logic [XLEN-1:0]           data;
    logic [4:0]                flags;
    logic                      exception_valid;
    exception_code_e           exception_cause;
    logic [XLEN-1:0]           exception_tval;
  } pipe_payload_t;

  logic [PIPE_STAGES-1:0] valid_q;
  pipe_payload_t [PIPE_STAGES-1:0] payload_q;
  pipe_payload_t result_payload;
  logic [PIPE_STAGES-1:0] stage_ready;
  fp_calc_t request_calc;
  logic [2:0] effective_rm;
  logic request_illegal_rm;

  function automatic logic sequence_after(
    input logic [ROB_SEQ_WIDTH-1:0] lhs,
    input logic [ROB_SEQ_WIDTH-1:0] rhs
  );
    logic signed [ROB_SEQ_WIDTH-1:0] delta;
    delta = $signed(lhs - rhs);
    return delta > 0;
  endfunction

  function automatic logic killed_by_flush(
    input logic [ROB_SEQ_WIDTH-1:0] sequence_id
  );
    return flush_valid_i &&
      (flush_all_i || sequence_after(sequence_id, flush_sequence_i));
  endfunction

  function automatic logic fp_is_nan(input logic [31:0] value);
    return (&value[30:23]) && (|value[22:0]);
  endfunction

  function automatic logic fp_is_snan(input logic [31:0] value);
    return fp_is_nan(value) && !value[22];
  endfunction

  function automatic logic fp_is_inf(input logic [31:0] value);
    return (&value[30:23]) && !(|value[22:0]);
  endfunction

  function automatic logic fp_is_zero(input logic [31:0] value);
    return !(|value[30:0]);
  endfunction

  function automatic logic [23:0] fp_mantissa(input logic [31:0] value);
    if (value[30:23] == 0)
      return {1'b0, value[22:0]};
    return {1'b1, value[22:0]};
  endfunction

  function automatic integer fp_lsb_exponent(input logic [31:0] value);
    if (value[30:23] == 0)
      return -149;
    return $signed({1'b0, value[30:23]}) - 150;
  endfunction

  function automatic logic round_up(
    input logic sign,
    input logic [2:0] rm,
    input logic retained_lsb,
    input logic guard_bit,
    input logic sticky_bit
  );
    logic inexact;
    inexact = guard_bit || sticky_bit;
    case (rm)
      3'b000: return guard_bit && (sticky_bit || retained_lsb); // RNE
      3'b001: return 1'b0;                                     // RTZ
      3'b010: return sign && inexact;                           // RDN
      3'b011: return !sign && inexact;                          // RUP
      3'b100: return guard_bit;                                 // RMM
      default: return 1'b0;
    endcase
  endfunction

  function automatic logic [127:0] right_shift_sticky(
    input logic [127:0] value,
    input integer shift_amount
  );
    logic [127:0] shifted;
    logic sticky;
    shifted = '0;
    sticky = 1'b0;
    if (shift_amount <= 0) begin
      if (-shift_amount < 128)
        shifted = value << (-shift_amount);
    end else if (shift_amount >= 128) begin
      shifted[0] = |value;
    end else begin
      shifted = value >> shift_amount;
      for (integer bit_index = 0; bit_index < 128; bit_index++)
        if (bit_index < shift_amount)
          sticky |= value[bit_index];
      shifted[0] |= sticky;
    end
    return shifted;
  endfunction

  function automatic fp_calc_t pack_finite(
    input logic sign,
    input logic [127:0] magnitude,
    input integer lsb_exponent,
    input logic [2:0] rm,
    input logic extra_sticky
  );
    fp_calc_t result;
    logic [127:0] retained;
    logic [24:0] rounded;
    logic guard_bit, sticky_bit, increment, inexact;
    logic [7:0] exponent_field;
    integer highest_bit, unbiased_exponent, shift_amount;

    result = '0;
    if (magnitude == 0) begin
      result.data[31] = sign;
      return result;
    end

    highest_bit = -1;
    for (integer bit_index = 127; bit_index >= 0; bit_index--)
      if ((highest_bit < 0) && magnitude[bit_index])
        highest_bit = bit_index;
    unbiased_exponent = highest_bit + lsb_exponent;

    if (unbiased_exponent > 127) begin
      result.flags = FFLAG_OF | FFLAG_NX;
      if ((rm == 3'b001) || (rm == 3'b010 && !sign) ||
          (rm == 3'b011 && sign))
        result.data[31:0] = {sign, 8'hfe, 23'h7f_ffff};
      else
        result.data[31:0] = {sign, 8'hff, 23'h0};
      return result;
    end

    if (unbiased_exponent >= -126) begin
      shift_amount = highest_bit - 23;
      retained = '0;
      guard_bit = 1'b0;
      sticky_bit = extra_sticky;
      if (shift_amount > 0) begin
        retained = magnitude >> shift_amount;
        guard_bit = magnitude[shift_amount-1];
        for (integer bit_index = 0; bit_index < 128; bit_index++)
          if (bit_index < (shift_amount-1))
            sticky_bit |= magnitude[bit_index];
      end else begin
        retained = magnitude << (-shift_amount);
      end
      inexact = guard_bit || sticky_bit;
      increment = round_up(sign, rm, retained[0], guard_bit, sticky_bit);
      rounded = {1'b0, retained[23:0]} + increment;
      if (rounded[24]) begin
        rounded = rounded >> 1;
        unbiased_exponent = unbiased_exponent + 1;
      end
      if (unbiased_exponent > 127) begin
        result.flags = FFLAG_OF | FFLAG_NX;
        if ((rm == 3'b001) || (rm == 3'b010 && !sign) ||
            (rm == 3'b011 && sign))
          result.data[31:0] = {sign, 8'hfe, 23'h7f_ffff};
        else
          result.data[31:0] = {sign, 8'hff, 23'h0};
      end else begin
        exponent_field = 8'(unbiased_exponent + 127);
        result.data[31:0] = {sign, exponent_field, rounded[22:0]};
        if (inexact)
          result.flags |= FFLAG_NX;
      end
    end else begin
      // A subnormal fraction is an integer measured in units of 2^-149.
      shift_amount = -(lsb_exponent + 149);
      retained = '0;
      guard_bit = 1'b0;
      sticky_bit = extra_sticky;
      if (shift_amount > 0) begin
        if (shift_amount < 128) begin
          retained = magnitude >> shift_amount;
          guard_bit = magnitude[shift_amount-1];
          for (integer bit_index = 0; bit_index < 128; bit_index++)
            if (bit_index < (shift_amount-1))
              sticky_bit |= magnitude[bit_index];
        end else begin
          sticky_bit |= |magnitude;
        end
      end else if (-shift_amount < 128) begin
        retained = magnitude << (-shift_amount);
      end
      inexact = guard_bit || sticky_bit;
      increment = round_up(sign, rm, retained[0], guard_bit, sticky_bit);
      rounded = {1'b0, retained[23:0]} + increment;
      if (rounded[23]) begin
        result.data[31:0] = {sign, 8'h01, 23'h0};
      end else begin
        result.data[31:0] = {sign, 8'h00, rounded[22:0]};
        if (inexact)
          result.flags |= FFLAG_UF;
      end
      if (inexact)
        result.flags |= FFLAG_NX;
    end
    return result;
  endfunction

  function automatic fp_calc_t fp_add_sub(
    input logic [31:0] a,
    input logic [31:0] b,
    input logic subtract_b,
    input logic [2:0] rm
  );
    fp_calc_t result;
    logic sign_a, sign_b, sticky_a, sticky_b, result_sign;
    logic [23:0] mantissa_a, mantissa_b;
    logic [127:0] aligned_a, aligned_b, magnitude;
    logic signed [128:0] signed_a, signed_b, signed_sum;
    integer exponent_a, exponent_b, common_exponent;

    result = '0;
    sign_a = a[31];
    sign_b = b[31] ^ subtract_b;
    if (fp_is_nan(a) || fp_is_nan(b)) begin
      result.data[31:0] = CANONICAL_NAN;
      if (fp_is_snan(a) || fp_is_snan(b)) result.flags = FFLAG_NV;
      return result;
    end
    if (fp_is_inf(a) && fp_is_inf(b) && (sign_a != sign_b)) begin
      result.data[31:0] = CANONICAL_NAN;
      result.flags = FFLAG_NV;
      return result;
    end
    if (fp_is_inf(a)) begin
      result.data[31:0] = {sign_a, 8'hff, 23'h0};
      return result;
    end
    if (fp_is_inf(b)) begin
      result.data[31:0] = {sign_b, 8'hff, 23'h0};
      return result;
    end

    mantissa_a = fp_mantissa(a);
    mantissa_b = fp_mantissa(b);
    exponent_a = fp_lsb_exponent(a);
    exponent_b = fp_lsb_exponent(b);
    common_exponent = (exponent_a > exponent_b) ? exponent_a : exponent_b;
    aligned_a = right_shift_sticky({104'b0, mantissa_a} << 32,
                                   common_exponent - exponent_a);
    aligned_b = right_shift_sticky({104'b0, mantissa_b} << 32,
                                   common_exponent - exponent_b);
    sticky_a = aligned_a[0];
    sticky_b = aligned_b[0];
    signed_a = $signed({1'b0, aligned_a});
    signed_b = $signed({1'b0, aligned_b});
    if (sign_a) signed_a = -signed_a;
    if (sign_b) signed_b = -signed_b;
    signed_sum = signed_a + signed_b;
    if (signed_sum == 0) begin
      result.data[31] = (rm == 3'b010);
      return result;
    end
    result_sign = signed_sum[128];
    magnitude = result_sign ? 128'(-signed_sum) : 128'(signed_sum);
    result = pack_finite(result_sign, magnitude, common_exponent - 32,
                         rm, sticky_a || sticky_b);
    return result;
  endfunction

  function automatic fp_calc_t fp_multiply(
    input logic [31:0] a,
    input logic [31:0] b,
    input logic [2:0] rm
  );
    fp_calc_t result;
    logic sign;
    logic [47:0] product;
    integer result_exponent;
    result = '0;
    sign = a[31] ^ b[31];
    if (fp_is_nan(a) || fp_is_nan(b)) begin
      result.data[31:0] = CANONICAL_NAN;
      if (fp_is_snan(a) || fp_is_snan(b)) result.flags = FFLAG_NV;
    end else if ((fp_is_inf(a) && fp_is_zero(b)) ||
                 (fp_is_zero(a) && fp_is_inf(b))) begin
      result.data[31:0] = CANONICAL_NAN;
      result.flags = FFLAG_NV;
    end else if (fp_is_inf(a) || fp_is_inf(b)) begin
      result.data[31:0] = {sign, 8'hff, 23'h0};
    end else if (fp_is_zero(a) || fp_is_zero(b)) begin
      result.data[31:0] = {sign, 31'h0};
    end else begin
      product = fp_mantissa(a) * fp_mantissa(b);
      result_exponent = fp_lsb_exponent(a) + fp_lsb_exponent(b);
      result = pack_finite(sign, {80'b0, product}, result_exponent, rm, 1'b0);
    end
    return result;
  endfunction

  function automatic fp_calc_t fp_fused_multiply_add(
    input logic [31:0] a,
    input logic [31:0] b,
    input logic [31:0] c,
    input logic negate_product,
    input logic negate_c,
    input logic [2:0] rm
  );
    fp_calc_t result;
    logic product_sign, c_sign, result_sign, sticky_product, sticky_c;
    logic [47:0] product;
    logic [23:0] mantissa_c;
    logic [127:0] aligned_product, aligned_c, magnitude;
    logic signed [128:0] signed_product, signed_c, signed_sum;
    integer product_exponent, c_exponent, common_exponent;

    result = '0;
    product_sign = a[31] ^ b[31] ^ negate_product;
    c_sign = c[31] ^ negate_c;
    if (fp_is_nan(a) || fp_is_nan(b) || fp_is_nan(c)) begin
      result.data[31:0] = CANONICAL_NAN;
      if (fp_is_snan(a) || fp_is_snan(b) || fp_is_snan(c) ||
          ((fp_is_inf(a) && fp_is_zero(b)) ||
           (fp_is_zero(a) && fp_is_inf(b)))) result.flags = FFLAG_NV;
      return result;
    end
    if ((fp_is_inf(a) && fp_is_zero(b)) ||
        (fp_is_zero(a) && fp_is_inf(b))) begin
      result.data[31:0] = CANONICAL_NAN;
      result.flags = FFLAG_NV;
      return result;
    end
    if ((fp_is_inf(a) || fp_is_inf(b)) && fp_is_inf(c) &&
        (product_sign != c_sign)) begin
      result.data[31:0] = CANONICAL_NAN;
      result.flags = FFLAG_NV;
      return result;
    end
    if (fp_is_inf(a) || fp_is_inf(b)) begin
      result.data[31:0] = {product_sign, 8'hff, 23'h0};
      return result;
    end
    if (fp_is_inf(c)) begin
      result.data[31:0] = {c_sign, 8'hff, 23'h0};
      return result;
    end

    product = fp_mantissa(a) * fp_mantissa(b);
    mantissa_c = fp_mantissa(c);
    product_exponent = fp_lsb_exponent(a) + fp_lsb_exponent(b);
    c_exponent = fp_lsb_exponent(c);
    common_exponent = (product_exponent > c_exponent) ?
      product_exponent : c_exponent;
    aligned_product = right_shift_sticky({80'b0, product} << 32,
      common_exponent - product_exponent);
    aligned_c = right_shift_sticky({104'b0, mantissa_c} << 32,
      common_exponent - c_exponent);
    sticky_product = aligned_product[0];
    sticky_c = aligned_c[0];
    signed_product = $signed({1'b0, aligned_product});
    signed_c = $signed({1'b0, aligned_c});
    if (product_sign) signed_product = -signed_product;
    if (c_sign) signed_c = -signed_c;
    signed_sum = signed_product + signed_c;
    if (signed_sum == 0) begin
      result.data[31] = (rm == 3'b010);
      return result;
    end
    result_sign = signed_sum[128];
    magnitude = result_sign ? 128'(-signed_sum) : 128'(signed_sum);
    result = pack_finite(result_sign, magnitude, common_exponent - 32,
                         rm, sticky_product || sticky_c);
    return result;
  endfunction

  function automatic fp_calc_t fp_divide(
    input logic [31:0] a,
    input logic [31:0] b,
    input logic [2:0] rm
  );
    fp_calc_t result;
    logic sign;
    logic [127:0] numerator, quotient;
    logic [23:0] divisor;
    logic remainder_nonzero;
    integer result_exponent;
    result = '0;
    sign = a[31] ^ b[31];
    if (fp_is_nan(a) || fp_is_nan(b)) begin
      result.data[31:0] = CANONICAL_NAN;
      if (fp_is_snan(a) || fp_is_snan(b)) result.flags = FFLAG_NV;
    end else if ((fp_is_zero(a) && fp_is_zero(b)) ||
                 (fp_is_inf(a) && fp_is_inf(b))) begin
      result.data[31:0] = CANONICAL_NAN;
      result.flags = FFLAG_NV;
    end else if (fp_is_inf(a)) begin
      result.data[31:0] = {sign, 8'hff, 23'h0};
    end else if (fp_is_inf(b)) begin
      result.data[31:0] = {sign, 31'h0};
    end else if (fp_is_zero(b)) begin
      result.data[31:0] = {sign, 8'hff, 23'h0};
      result.flags = FFLAG_DZ;
    end else if (fp_is_zero(a)) begin
      result.data[31:0] = {sign, 31'h0};
    end else begin
      numerator = {104'b0, fp_mantissa(a)} << 63;
      divisor = fp_mantissa(b);
      quotient = numerator / divisor;
      remainder_nonzero = (numerator % divisor) != 0;
      result_exponent = fp_lsb_exponent(a) - fp_lsb_exponent(b) - 63;
      result = pack_finite(sign, quotient, result_exponent, rm,
                           remainder_nonzero);
    end
    return result;
  endfunction

  function automatic logic [63:0] integer_sqrt128(
    input logic [127:0] radicand
  );
    logic [129:0] remainder;
    logic [63:0] root;
    logic [65:0] trial;
    remainder = '0;
    root = '0;
    for (integer pair = 63; pair >= 0; pair--) begin
      remainder = (remainder << 2) | ((radicand >> (pair*2)) & 2'b11);
      trial = {root, 2'b01};
      if (remainder >= trial) begin
        remainder = remainder - trial;
        root = (root << 1) | 1'b1;
      end else begin
        root = root << 1;
      end
    end
    return root;
  endfunction

  function automatic fp_calc_t fp_square_root(
    input logic [31:0] a,
    input logic [2:0] rm
  );
    fp_calc_t result;
    logic [127:0] radicand;
    logic [63:0] root;
    logic remainder_nonzero;
    integer exponent_value;
    result = '0;
    if (fp_is_nan(a)) begin
      result.data[31:0] = CANONICAL_NAN;
      if (fp_is_snan(a)) result.flags = FFLAG_NV;
    end else if (a[31] && !fp_is_zero(a)) begin
      result.data[31:0] = CANONICAL_NAN;
      result.flags = FFLAG_NV;
    end else if (fp_is_inf(a) || fp_is_zero(a)) begin
      result.data[31:0] = a;
    end else begin
      exponent_value = fp_lsb_exponent(a);
      radicand = {104'b0, fp_mantissa(a)};
      if (exponent_value & 1) begin
        radicand = radicand << 1;
        exponent_value = exponent_value - 1;
      end
      radicand = radicand << 80;
      root = integer_sqrt128(radicand);
      remainder_nonzero = ({64'b0, root} * {64'b0, root}) != radicand;
      result = pack_finite(1'b0, {64'b0, root},
                           (exponent_value / 2) - 40, rm,
                           remainder_nonzero);
    end
    return result;
  endfunction

  function automatic fp_calc_t fp_min_max(
    input logic [31:0] a,
    input logic [31:0] b,
    input logic select_max
  );
    fp_calc_t result;
    logic a_less;
    result = '0;
    if (fp_is_snan(a) || fp_is_snan(b)) result.flags = FFLAG_NV;
    if (fp_is_nan(a) && fp_is_nan(b)) begin
      result.data[31:0] = CANONICAL_NAN;
    end else if (fp_is_nan(a)) begin
      result.data[31:0] = b;
    end else if (fp_is_nan(b)) begin
      result.data[31:0] = a;
    end else if (fp_is_zero(a) && fp_is_zero(b)) begin
      result.data[31:0] = select_max ? {a[31] & b[31], 31'h0} :
                                             {a[31] | b[31], 31'h0};
    end else begin
      if (a[31] != b[31])
        a_less = a[31];
      else if (a[31])
        a_less = a[30:0] > b[30:0];
      else
        a_less = a[30:0] < b[30:0];
      result.data[31:0] = select_max ? (a_less ? b : a) : (a_less ? a : b);
    end
    return result;
  endfunction

  function automatic fp_calc_t fp_compare(
    input logic [31:0] a,
    input logic [31:0] b,
    input logic [2:0] operation
  );
    fp_calc_t result;
    logic equal, less;
    result = '0;
    if (fp_is_nan(a) || fp_is_nan(b)) begin
      if ((operation != 3'b010) || fp_is_snan(a) || fp_is_snan(b))
        result.flags = FFLAG_NV;
      return result;
    end
    equal = (a == b) || (fp_is_zero(a) && fp_is_zero(b));
    if (equal)
      less = 1'b0;
    else if (a[31] != b[31])
      less = a[31];
    else if (a[31])
      less = a[30:0] > b[30:0];
    else
      less = a[30:0] < b[30:0];
    case (operation)
      3'b010: result.data = XLEN'(equal);        // FEQ.S
      3'b001: result.data = XLEN'(less);         // FLT.S
      default: result.data = XLEN'(less || equal); // FLE.S
    endcase
    return result;
  endfunction

  function automatic fp_calc_t fp_to_integer(
    input logic [31:0] a,
    input logic [1:0] integer_kind,
    input logic [2:0] rm
  );
    fp_calc_t result;
    logic destination_unsigned, sign, guard_bit, sticky_bit, increment;
    logic [127:0] magnitude, retained, rounded_magnitude;
    logic [63:0] maximum_value;
    integer destination_width, exponent_value, shift_amount;
    result = '0;
    destination_unsigned = integer_kind[0];
    destination_width = integer_kind[1] ? 64 : 32;
    sign = a[31];
    if (fp_is_nan(a) || fp_is_inf(a)) begin
      result.flags = FFLAG_NV;
      if (fp_is_nan(a) || !sign)
        magnitude = destination_unsigned ?
          ((destination_width == 64) ? {64'b0, 64'hffff_ffff_ffff_ffff} :
                                       {96'b0, 32'hffff_ffff}) :
          ((destination_width == 64) ? {65'b0, 63'h7fff_ffff_ffff_ffff} :
                                       {97'b0, 31'h7fff_ffff});
      else
        magnitude = destination_unsigned ? '0 :
          ((destination_width == 64) ? (128'b1 << 63) : (128'b1 << 31));
    end else begin
      magnitude = {104'b0, fp_mantissa(a)};
      exponent_value = fp_lsb_exponent(a);
      retained = '0;
      guard_bit = 1'b0;
      sticky_bit = 1'b0;
      if (exponent_value >= 0) begin
        if (exponent_value < 104)
          retained = magnitude << exponent_value;
        else
          retained = {128{1'b1}};
      end else begin
        shift_amount = -exponent_value;
        if (shift_amount < 128) begin
          retained = magnitude >> shift_amount;
          guard_bit = magnitude[shift_amount-1];
          for (integer bit_index = 0; bit_index < 128; bit_index++)
            if (bit_index < (shift_amount-1)) sticky_bit |= magnitude[bit_index];
        end else begin
          sticky_bit = |magnitude;
        end
      end
      increment = round_up(sign, rm, retained[0], guard_bit, sticky_bit);
      rounded_magnitude = retained + increment;
      if (guard_bit || sticky_bit) result.flags |= FFLAG_NX;
      maximum_value = destination_unsigned ?
        ((destination_width == 64) ? 64'hffff_ffff_ffff_ffff : 64'hffff_ffff) :
        ((destination_width == 64) ? 64'h7fff_ffff_ffff_ffff : 64'h7fff_ffff);
      if ((sign && destination_unsigned && (rounded_magnitude != 0)) ||
          (!sign && (rounded_magnitude > maximum_value)) ||
          (sign && !destination_unsigned &&
           (rounded_magnitude > (128'b1 << (destination_width-1))))) begin
        result.flags = FFLAG_NV;
        if (destination_unsigned)
          magnitude = sign ? '0 : {64'b0, maximum_value};
        else
          magnitude = sign ? (128'b1 << (destination_width-1)) :
                             {64'b0, maximum_value};
      end else begin
        magnitude = sign ? -rounded_magnitude : rounded_magnitude;
      end
    end
    if (destination_width == 32)
      result.data = XLEN'($signed(magnitude[31:0]));
    else
      result.data = XLEN'(magnitude[63:0]);
    return result;
  endfunction

  function automatic fp_calc_t integer_to_fp(
    input logic [XLEN-1:0] integer_value,
    input logic [1:0] integer_kind,
    input logic [2:0] rm
  );
    fp_calc_t result;
    logic source_unsigned, sign;
    logic [63:0] source_value, magnitude;
    integer source_width;
    result = '0;
    source_unsigned = integer_kind[0];
    source_width = integer_kind[1] ? 64 : 32;
    source_value = 64'(integer_value);
    if (source_width == 32)
      source_value = source_unsigned ? {32'b0, integer_value[31:0]} :
                                      64'($signed(integer_value[31:0]));
    sign = !source_unsigned && source_value[source_width-1];
    magnitude = sign ? -source_value : source_value;
    result = pack_finite(sign, {64'b0, magnitude}, 0, rm, 1'b0);
    return result;
  endfunction

  function automatic fp_calc_t execute_fp(
    input logic [31:0] instruction,
    input logic [XLEN-1:0] operand_a,
    input logic [XLEN-1:0] operand_b,
    input logic [XLEN-1:0] operand_c,
    input logic [2:0] rm
  );
    fp_calc_t result;
    logic [6:0] opcode, funct7;
    logic [2:0] funct3;
    logic [4:0] rs2;
    logic [31:0] a, b, c;
    result = '0;
    opcode = instruction[6:0];
    funct7 = instruction[31:25];
    funct3 = instruction[14:12];
    rs2 = instruction[24:20];
    a = operand_a[31:0];
    b = operand_b[31:0];
    c = operand_c[31:0];

    case (opcode)
      7'b1000011: result = fp_fused_multiply_add(a, b, c, 1'b0, 1'b0, rm);
      7'b1000111: result = fp_fused_multiply_add(a, b, c, 1'b0, 1'b1, rm);
      7'b1001011: result = fp_fused_multiply_add(a, b, c, 1'b1, 1'b0, rm);
      7'b1001111: result = fp_fused_multiply_add(a, b, c, 1'b1, 1'b1, rm);
      7'b1010011: begin
        case (funct7)
          7'b0000000: result = fp_add_sub(a, b, 1'b0, rm);
          7'b0000100: result = fp_add_sub(a, b, 1'b1, rm);
          7'b0001000: result = fp_multiply(a, b, rm);
          7'b0001100: result = fp_divide(a, b, rm);
          7'b0101100: result = fp_square_root(a, rm);
          7'b0010000: begin
            case (funct3)
              3'b000: result.data[31:0] = {b[31], a[30:0]};
              3'b001: result.data[31:0] = {~b[31], a[30:0]};
              default: result.data[31:0] = {a[31] ^ b[31], a[30:0]};
            endcase
          end
          7'b0010100: result = fp_min_max(a, b, funct3[0]);
          7'b1010000: result = fp_compare(a, b, funct3);
          7'b1100000: result = fp_to_integer(a, rs2[1:0], rm);
          7'b1110000: begin
            if (funct3 == 3'b000)
              result.data = XLEN'($signed(a));
            else begin
              result.data = '0;
              result.data[0] = fp_is_inf(a) && a[31];
              result.data[1] = !a[31] && 1'b0; // overwritten below by class map
              result.data[1] = a[31] && (a[30:23] != 0) &&
                               (a[30:23] != 8'hff);
              result.data[2] = a[31] && (a[30:23] == 0) && (|a[22:0]);
              result.data[3] = a[31] && fp_is_zero(a);
              result.data[4] = !a[31] && fp_is_zero(a);
              result.data[5] = !a[31] && (a[30:23] == 0) && (|a[22:0]);
              result.data[6] = !a[31] && (a[30:23] != 0) &&
                               (a[30:23] != 8'hff);
              result.data[7] = fp_is_inf(a) && !a[31];
              result.data[8] = fp_is_snan(a);
              result.data[9] = fp_is_nan(a) && !fp_is_snan(a);
            end
          end
          7'b1101000: result = integer_to_fp(operand_a, rs2[1:0], rm);
          7'b1111000: result.data[31:0] = operand_a[31:0];
          default: begin
            result.data[31:0] = CANONICAL_NAN;
            result.flags = FFLAG_NV;
          end
        endcase
      end
      default: begin
        result.data[31:0] = CANONICAL_NAN;
        result.flags = FFLAG_NV;
      end
    endcase
    return result;
  endfunction

  always_comb begin
    effective_rm = (rounding_mode_i == 3'b111) ? frm_i : rounding_mode_i;
    request_illegal_rm = effective_rm > 3'b100;
    request_calc = execute_fp(instruction_i, operand_a_i, operand_b_i,
                              operand_c_i, effective_rm);
  end

  // Keep the elastic-ready cone independent from the request arithmetic.
  // This prevents a false issue->request-data->ready combinational loop when
  // the FPU is connected to the global issue and writeback arbiters.
  always_comb begin
    stage_ready[PIPE_STAGES-1] = !valid_q[PIPE_STAGES-1] || result_ready_i;
    for (integer stage = PIPE_STAGES-2; stage >= 0; stage--)
      stage_ready[stage] = !valid_q[stage] || stage_ready[stage+1];
    request_ready_o = stage_ready[0];
  end

  assign result_payload = payload_q[PIPE_STAGES-1];
  assign result_valid_o = valid_q[PIPE_STAGES-1];
  assign result_sequence_o = result_payload.sequence_id;
  assign result_destination_valid_o = result_payload.destination_valid;
  assign result_destination_class_o = result_payload.destination_class;
  assign result_destination_phys_o = result_payload.destination_phys;
  assign result_data_o = result_payload.data;
  assign result_fflags_o = result_payload.flags;
  assign result_exception_valid_o = result_payload.exception_valid;
  assign result_exception_cause_o = result_payload.exception_cause;
  assign result_exception_tval_o = result_payload.exception_tval;

  always_ff @(posedge clk_i) begin
    if (!rst_ni) begin
      valid_q <= '0;
      for (integer stage = 0; stage < PIPE_STAGES; stage++)
        payload_q[stage] <= '0;
    end else if (flush_valid_i) begin
      for (integer stage = 0; stage < PIPE_STAGES; stage++)
        if (valid_q[stage] && killed_by_flush(payload_q[stage].sequence_id))
          valid_q[stage] <= 1'b0;
    end else begin
      for (integer stage = PIPE_STAGES-1; stage > 0; stage--) begin
        if (stage_ready[stage]) begin
          valid_q[stage] <= valid_q[stage-1];
          if (valid_q[stage-1])
            payload_q[stage] <= payload_q[stage-1];
        end
      end
      if (stage_ready[0]) begin
        valid_q[0] <= request_valid_i;
        if (request_valid_i) begin
          payload_q[0].sequence_id <= sequence_i;
          payload_q[0].destination_valid <= destination_valid_i;
          payload_q[0].destination_class <= destination_class_i;
          payload_q[0].destination_phys <= destination_phys_i;
          payload_q[0].data <= request_calc.data;
          payload_q[0].flags <= request_illegal_rm ? '0 : request_calc.flags;
          payload_q[0].exception_valid <= request_illegal_rm;
          payload_q[0].exception_cause <= EXC_ILLEGAL_INSTRUCTION;
          payload_q[0].exception_tval <= XLEN'(instruction_i);
        end
      end
    end
  end

`ifndef SYNTHESIS
  always_comb begin
    if (result_valid_o && !result_exception_valid_o)
      assert (result_destination_class_o != REG_NONE ||
              !result_destination_valid_o);
  end
`endif

  initial begin
    if ((XLEN != 32) && (XLEN != 64))
      $fatal(1, "FPU XLEN must be 32 or 64");
    if (LATENCY < 1)
      $fatal(1, "FPU LATENCY must be at least one cycle");
  end
endmodule
