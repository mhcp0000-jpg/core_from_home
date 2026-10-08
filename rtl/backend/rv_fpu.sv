module rv_fpu #(
  parameter int unsigned XLEN = 32,
  parameter int unsigned ROB_SEQ_WIDTH = rv_ooo_pkg::ROB_SEQ_WIDTH,
  parameter int unsigned PHYS_TAG_WIDTH = 7,
  parameter int unsigned LATENCY = 4
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

  // LATENCY>=3 uses an explicit arithmetic/pre-normalization stage.  The
  // default LATENCY=4 also separates leading-bit normalization/barrel shift
  // from rounding/packing. Backend latency comes from Top/PKG (default 6);
  // clock sign-off still needs whole-core STA with the target library.
  // LATENCY 1/2 keeps the compact unsplit datapath.
  // float32 exact FMA/add 에 실제로 필요한 누산 폭.  product 48-bit +
  // ALIGN_SH 만큼의 하위 여유 + carry.  128-bit 은 과했다.
  localparam int unsigned MAGW     = 80;
  localparam int unsigned ALIGN_SH = 32;
  // radix-2 FDIV 가 만드는 몫의 소수 bit 수.  피연산자 mantissa 를 나누기
  // 전에 정규화하므로 A/B in (0.5, 2) 가 보장되고, 24-bit significand +
  // guard 에 sticky(div_remainder != 0) 를 더하면 충분하다.  정규화 이전에는
  // subnormal(선행 0 최대 23개) 때문에 52 가 필요했다.
  localparam int unsigned DIV_FRAC = 28;
  localparam int unsigned DIV_NUMW = 25 + DIV_FRAC;
  // radix-2 FSQRT.  피연산자 mantissa 를 정규화하면 m in [2^23, 2^24) 이므로
  // 근은 29-bit 면 24-bit significand + guard 를 담고도 남는다.  정규화
  // 이전에는 subnormal 을 덮으려고 128-bit radicand / 64 회 반복을 썼다.
  localparam int unsigned SQRT_ITERS = 29;
  localparam int unsigned SQRT_RADW  = 2 * SQRT_ITERS;
  localparam int unsigned SQRT_ROOTW = SQRT_ITERS;
  localparam int unsigned SQRT_REMW  = SQRT_RADW + 2;
  // 지수 산술 폭.  fp_lsb_exponent 는 [-149, 104], FMA product 지수는
  // [-298, 208], ALIGN_SH 보정까지 합쳐도 |e| < 400 이다.  이것을 32-bit
  // integer 로 계산하면 정렬/정규화 경로마다 1,080 ps 짜리 캐리 체인이
  // 직렬로 붙는다.  16-bit signed 로 80배 여유가 있다.
  localparam int unsigned EXPW = 16;
  localparam logic signed [EXPW-1:0] MAGW_S = EXPW'(MAGW);
  localparam bit SPLIT_PREPACK = LATENCY >= 3;
  localparam bit SPLIT_NORMALIZE = LATENCY >= 4;
  // LATENCY>=5 additionally separates the multiply/alignment network from the
  // wide signed accumulate.  That accumulate was the longest single datapath
  // in the fast pipe.
  localparam bit SPLIT_ALIGN = LATENCY >= 5;
  // LATENCY6 splits product/exponent preparation from sticky barrel shifts.
  // Additional latency above six is elastic result transport, not arithmetic.
  localparam bit SPLIT_ALIGN_SHIFT = LATENCY >= 6;
  localparam int unsigned PIPE_STAGES = SPLIT_ALIGN_SHIFT ? LATENCY - 4 :
                                        (SPLIT_ALIGN ? LATENCY - 3 :
                                         (SPLIT_NORMALIZE ? LATENCY - 2 :
                                          (SPLIT_PREPACK ? LATENCY - 1 :
                                           ((LATENCY < 1) ? 1 : LATENCY))));
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
    logic                needs_pack;
    fp_calc_t             direct;
    logic                sign;
    logic [MAGW-1:0]         magnitude;
    logic signed [EXPW-1:0] lsb_exponent;
    logic [2:0]          rounding_mode;
    logic                extra_sticky;
  } fp_precalc_t;

  typedef struct packed {
    logic                 sum_pending;
    fp_precalc_t          pre;
    logic [MAGW-1:0]         mag_x;
    logic [MAGW-1:0]         mag_y;
    logic                 neg_x;
    logic                 neg_y;
    logic signed [EXPW-1:0] common_exponent;
    logic                 sticky;
    logic [2:0]           rm;
    logic                 zx_zero;
    logic                 zx_sign;
    logic                 zy_zero;
    logic                 zy_sign;
  } fp_align_t;
  typedef struct packed {
    fp_align_t align;
    logic signed [EXPW-1:0] shift_x;
    logic signed [EXPW-1:0] shift_y;
    logic product_pending;
    logic product_precalc;
  } fp_align_seed_t;

  typedef struct packed {
    logic                direct_valid;
    fp_calc_t             direct;
    logic                sign;
    logic [23:0]         retained;
    logic                guard_bit;
    logic                sticky_bit;
    logic signed [EXPW-1:0] unbiased_exponent;
    logic [2:0]          rounding_mode;
    logic                subnormal;
  } fp_normalized_t;

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
  logic pre_valid_q;
  logic [ROB_SEQ_WIDTH-1:0] pre_sequence_q;
  logic pre_destination_valid_q;
  reg_class_e pre_destination_class_q;
  logic [PHYS_TAG_WIDTH-1:0] pre_destination_phys_q;
  logic pre_exception_valid_q;
  exception_code_e pre_exception_cause_q;
  logic [XLEN-1:0] pre_exception_tval_q;
  fp_precalc_t pre_calc_q;
  logic align_valid_q;
  logic [ROB_SEQ_WIDTH-1:0] align_sequence_q;
  logic align_destination_valid_q;
  reg_class_e align_destination_class_q;
  logic [PHYS_TAG_WIDTH-1:0] align_destination_phys_q;
  logic align_exception_valid_q;
  exception_code_e align_exception_cause_q;
  logic [XLEN-1:0] align_exception_tval_q;
  fp_align_t align_calc_q;
  logic seed_valid_q;
  pipe_payload_t seed_metadata_q;
  fp_align_seed_t seed_calc_q, request_seed;
  fp_align_t seed_aligned;
  logic seed_ready;
  logic norm_valid_q;
  logic [ROB_SEQ_WIDTH-1:0] norm_sequence_q;
  logic norm_destination_valid_q;
  reg_class_e norm_destination_class_q;
  logic [PHYS_TAG_WIDTH-1:0] norm_destination_phys_q;
  logic norm_exception_valid_q;
  exception_code_e norm_exception_cause_q;
  logic [XLEN-1:0] norm_exception_tval_q;
  fp_normalized_t norm_calc_q;
  pipe_payload_t result_payload;
  logic [PIPE_STAGES-1:0] stage_ready;
  logic pre_ready;
  logic align_ready;
  fp_align_t request_align;
  fp_precalc_t align_pre_calc;
  logic norm_ready;
  fp_precalc_t request_precalc;
  fp_normalized_t pre_norm_calc;
  fp_calc_t request_final_calc;
  fp_calc_t pre_final_calc;
  fp_calc_t norm_final_calc;
  logic [2:0] effective_rm;
  logic request_illegal_rm;

  typedef enum logic [2:0] {
    SLOW_IDLE,
    SLOW_DIVIDE,
    SLOW_DIV_PACK,
    SLOW_SQRT,
    SLOW_SQRT_PACK
  } slow_state_e;

  slow_state_e slow_state_q;
  pipe_payload_t slow_payload_q;
  logic slow_result_valid_q;
  logic request_is_divide, request_is_sqrt, request_is_slow;
  logic request_accept, fast_request_accept, slow_request_accept;
  logic fast_pipe_empty;
  fp_calc_t slow_special_calc;
  logic slow_special_case;

  logic div_sign_q;
  logic [2:0] div_rm_q;
  logic signed [EXPW-1:0] div_exponent_q;
  logic [23:0] div_divisor_q;
  logic [DIV_NUMW-1:0] div_numerator_q;
  logic [24:0] div_remainder_q;
  logic [DIV_NUMW-1:0] div_quotient_q;
  logic [6:0] div_count_q;
  logic [24:0] div_shifted_remainder;
  logic [24:0] div_next_remainder;
  logic [DIV_NUMW-1:0] div_next_quotient;
  logic div_quotient_bit;
  logic [4:0] div_lz_a, div_lz_b;
  logic [23:0] div_norm_a, div_norm_b;

  logic [2:0] sqrt_rm_q;
  logic signed [EXPW-1:0] sqrt_exponent_q;
  logic [SQRT_RADW-1:0] sqrt_radicand_q;
  logic [SQRT_REMW-1:0] sqrt_remainder_q;
  logic [SQRT_ROOTW-1:0] sqrt_root_q;
  logic [6:0] sqrt_count_q;
  logic [SQRT_REMW-1:0] sqrt_shifted_remainder;
  logic [SQRT_REMW-1:0] sqrt_trial;
  logic [SQRT_REMW-1:0] sqrt_next_remainder;
  logic [SQRT_ROOTW-1:0] sqrt_next_root;
  logic sqrt_root_bit;
  logic [4:0] sqrt_lz;
  logic [23:0] sqrt_norm_m;
  logic signed [EXPW-1:0] sqrt_lsb;
  fp_calc_t div_pack_calc;
  fp_calc_t sqrt_pack_calc;

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

  // IEEE-754 exact-zero sign rule.  Two zero addends with the same effective
  // sign preserve that sign.  Opposite-sign zeros, or exact cancellation of
  // non-zero magnitudes, produce -0 only for roundTowardNegative (RDN).
  function automatic logic exact_sum_zero_sign(
    input logic lhs_is_zero,
    input logic lhs_sign,
    input logic rhs_is_zero,
    input logic rhs_sign,
    input logic [2:0] rm
  );
    if (lhs_is_zero && rhs_is_zero && (lhs_sign == rhs_sign))
      return lhs_sign;
    return rm == 3'b010;
  endfunction

  function automatic logic [23:0] fp_mantissa(input logic [31:0] value);
    if (value[30:23] == 0)
      return {1'b0, value[22:0]};
    return {1'b1, value[22:0]};
  endfunction

  function automatic logic signed [EXPW-1:0] fp_lsb_exponent_n(
    input logic [31:0] value
  );
    if (value[30:23] == 0)
      return -signed'(EXPW'(149));
    return signed'(EXPW'({1'b0, value[30:23]})) - signed'(EXPW'(150));
  endfunction

  function automatic integer fp_lsb_exponent(input logic [31:0] value);
    if (value[30:23] == 0)
      return -149;
    return $signed({1'b0, value[30:23]}) - 150;
  endfunction

  // 24-bit mantissa 의 선행 0 개수.  subnormal 피연산자를 FDIV 앞에서
  // 정규화하는 데 쓴다.  mantissa 가 0 인 경우는 slow_special_case 가
  // 먼저 걸러내므로 여기 도달하지 않는다.
  function automatic logic [4:0] mantissa_lz(input logic [23:0] mantissa);
    logic [4:0] lz;
    logic       found;
    lz = 5'd0;
    found = 1'b0;
    for (integer bit_index = 23; bit_index >= 0; bit_index--) begin
      if (!found && mantissa[bit_index]) begin
        lz = 5'(23 - bit_index);
        found = 1'b1;
      end
    end
    return lz;
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

  function automatic logic [MAGW-1:0] right_shift_sticky(
    input logic [MAGW-1:0] value,
    input logic signed [EXPW-1:0] shift_amount
  );
    logic [MAGW-1:0] shifted;
    logic [6:0] shift_unsigned;
    logic [6:0] shift_minus1;
    logic sticky;
    shifted = '0;
    shift_unsigned = 7'd0;
    shift_minus1 = 7'd0;
    sticky = 1'b0;
    // 시프트량은 이 분기 안에서 0 < s < MAGW 가 보장되므로 7-bit 로 좁힌다.
    // 32-bit 비교를 MAGW 번 돌리던 sticky mask 가 7-bit 비교로 바뀐다.
    if (shift_amount <= '0) begin
      if (-shift_amount < MAGW_S) begin
        shift_unsigned = 7'(-shift_amount);
        shifted = value << shift_unsigned;
      end
    end else if (shift_amount >= MAGW_S) begin
      shifted[0] = |value;
    end else begin
      shift_unsigned = 7'(shift_amount);
      shifted = value >> shift_unsigned;
      for (integer bit_index = 0; bit_index < int'(MAGW); bit_index++)
        if (7'(bit_index) < shift_unsigned)
          sticky |= value[bit_index];
      shifted[0] |= sticky;
    end
    return shifted;
  endfunction

  function automatic fp_calc_t pack_finite(
    input logic sign,
    input logic [MAGW-1:0] magnitude,
    input logic signed [EXPW-1:0] lsb_exponent,
    input logic [2:0] rm,
    input logic extra_sticky
  );
    fp_calc_t result;
    logic [MAGW-1:0] retained;
    logic [24:0] rounded;
    logic guard_bit, sticky_bit, increment, inexact;
    logic [7:0] exponent_field;
    logic [6:0] highest_bit;
    logic [6:0] shift_unsigned;
    logic [6:0] shift_minus1;
    // normalize_fp_pre 와 같은 이유로 지수 산술을 16-bit 로 좁히고, LZC 결과에
    // 의존하지 않는 항은 모두 앞으로 뺀다.  원래는 LZC 뒤에 32-bit 캐리
    // 체인이 다섯 개까지 직렬로 이어졌다.
    logic signed [EXPW-1:0] lsb_exp;
    logic signed [EXPW-1:0] overflow_threshold;
    logic signed [EXPW-1:0] subnormal_threshold;
    logic signed [EXPW-1:0] subnormal_shift;
    logic signed [EXPW-1:0] biased_base;
    logic signed [EXPW-1:0] highest_signed;
    logic signed [EXPW-1:0] shift_amount;
    logic signed [EXPW-1:0] exponent_no_carry;
    logic signed [EXPW-1:0] exponent_with_carry;
    logic is_overflow;
    logic is_normal_range;
    logic overflow_after_round;
    logic carry_out;

    result = '0;
    if (magnitude == 0) begin
      result.data[31] = sign;
      return result;
    end

    lsb_exp             = lsb_exponent;
    overflow_threshold  =  signed'(EXPW'(127)) - lsb_exp;
    subnormal_threshold = -signed'(EXPW'(126)) - lsb_exp;
    subnormal_shift     = -(lsb_exp + signed'(EXPW'(149)));
    biased_base         =  lsb_exp + signed'(EXPW'(127));

    highest_bit = highest_magnitude_bit(magnitude);
    highest_signed  = signed'(EXPW'({9'b0, highest_bit}));
    is_overflow     = highest_signed >  overflow_threshold;
    is_normal_range = highest_signed >= subnormal_threshold;
    // Both post-rounding exponent candidates are built before the rounding
    // carry is known, so the carry only selects instead of starting a new add.
    exponent_no_carry   = highest_signed + biased_base;
    exponent_with_carry = highest_signed + biased_base + signed'(EXPW'(1));

    if (is_overflow) begin
      result.flags = FFLAG_OF | FFLAG_NX;
      if ((rm == 3'b001) || (rm == 3'b010 && !sign) ||
          (rm == 3'b011 && sign))
        result.data[31:0] = {sign, 8'hfe, 23'h7f_ffff};
      else
        result.data[31:0] = {sign, 8'hff, 23'h0};
      return result;
    end

    if (is_normal_range) begin
      shift_amount = highest_signed - signed'(EXPW'(23));
      retained = '0;
      guard_bit = 1'b0;
      sticky_bit = extra_sticky;
      if (shift_amount > 0) begin
        shift_unsigned = 7'(shift_amount);
        shift_minus1 = shift_unsigned - 7'd1;
        retained = magnitude >> shift_unsigned;
        guard_bit = magnitude[shift_minus1];
        for (integer bit_index = 0; bit_index < int'(MAGW); bit_index++)
          if (7'(bit_index) < shift_minus1)
            sticky_bit |= magnitude[bit_index];
      end else begin
        shift_unsigned = 7'(-shift_amount);
        retained = magnitude << shift_unsigned;
      end
      inexact = guard_bit || sticky_bit;
      increment = round_up(sign, rm, retained[0], guard_bit, sticky_bit);
      rounded = {1'b0, retained[23:0]} + increment;
      carry_out = rounded[24];
      if (carry_out)
        rounded = rounded >> 1;
      // (hb + carry) + lsb > 127  <=>  hb + carry > overflow_threshold
      overflow_after_round = carry_out ? (highest_signed >= overflow_threshold)
                                       : (highest_signed >  overflow_threshold);
      if (overflow_after_round) begin
        result.flags = FFLAG_OF | FFLAG_NX;
        if ((rm == 3'b001) || (rm == 3'b010 && !sign) ||
            (rm == 3'b011 && sign))
          result.data[31:0] = {sign, 8'hfe, 23'h7f_ffff};
        else
          result.data[31:0] = {sign, 8'hff, 23'h0};
      end else begin
        exponent_field = 8'(carry_out ? exponent_with_carry : exponent_no_carry);
        result.data[31:0] = {sign, exponent_field, rounded[22:0]};
        if (inexact)
          result.flags |= FFLAG_NX;
      end
    end else begin
      // A subnormal fraction is an integer measured in units of 2^-149.
      shift_amount = subnormal_shift;
      retained = '0;
      guard_bit = 1'b0;
      sticky_bit = extra_sticky;
      if (shift_amount > 0) begin
        if (shift_amount < MAGW_S) begin
          shift_unsigned = 7'(shift_amount);
          shift_minus1 = shift_unsigned - 7'd1;
          retained = magnitude >> shift_unsigned;
          guard_bit = magnitude[shift_minus1];
          for (integer bit_index = 0; bit_index < int'(MAGW); bit_index++)
            if (7'(bit_index) < shift_minus1)
              sticky_bit |= magnitude[bit_index];
        end else begin
          sticky_bit |= |magnitude;
        end
      end else if (-shift_amount < MAGW_S) begin
        shift_unsigned = 7'(-shift_amount);
        retained = magnitude << shift_unsigned;
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

  // Highest-set-bit priority is explicit and balanced: each tree node picks
  // its higher-index child iff that subtree contains a one. Invalid padding
  // covers MAGW=80 without reading outside the magnitude. No new state/stage.
  function automatic logic [6:0] highest_magnitude_bit(
    input logic [MAGW-1:0] magnitude
  );
    localparam int LEAVES = 1 << $clog2(MAGW);
    logic [7:0] nodes [1:2*LEAVES-1];
    for (int bit_index = 0; bit_index < LEAVES; bit_index++) begin
      if (bit_index < MAGW)
        nodes[LEAVES+bit_index] = {magnitude[bit_index], 7'(bit_index)};
      else nodes[LEAVES+bit_index] = '0;
    end
    for (int node = LEAVES-1; node > 0; node--) begin
      nodes[node][7] = nodes[node*2][7] | nodes[node*2+1][7];
      nodes[node][6:0] = nodes[node*2+1][7] ? nodes[node*2+1][6:0] : nodes[node*2][6:0];
    end
    return nodes[1][7] ? nodes[1][6:0] : 7'd0;
  endfunction

  // Stage 1 of the timing-oriented packer: leading-one detection, exponent
  // classification and the 80-bit alignment/sticky shift. The registered
  // output leaves a 25-bit round/add and final field assembly for stage 2.
  function automatic fp_normalized_t normalize_fp_pre(
    input fp_precalc_t pre
  );
    fp_normalized_t norm;
    fp_calc_t direct;
    logic [MAGW-1:0] magnitude;
    logic [MAGW-1:0] retained_wide;
    logic sticky;
    logic [6:0] highest_bit;
    logic [6:0] shift_unsigned;
    logic [6:0] shift_minus1;
    // lsb_exponent 의 실제 범위는 대략 [-362, +208] 이라 16-bit signed 로
    // 충분하다.  32-bit integer 로 계산하면 LZC 뒤에 32-bit 캐리 체인이
    // 세 개 직렬로 붙어 이 스테이지의 대부분을 차지한다.
    logic signed [EXPW-1:0] lsb_exp;
    logic signed [EXPW-1:0] overflow_threshold;
    logic signed [EXPW-1:0] subnormal_threshold;
    logic signed [EXPW-1:0] subnormal_shift;
    logic signed [EXPW-1:0] highest_signed;
    logic signed [EXPW-1:0] unbiased_exponent;
    logic signed [EXPW-1:0] shift_amount;
    logic is_overflow;
    logic is_normal_range;

    norm = '0;
    magnitude = pre.magnitude;
    if (!pre.needs_pack) begin
      norm.direct_valid = 1'b1;
      norm.direct = pre.direct;
      return norm;
    end

    if (magnitude == 0) begin
      norm.direct_valid = 1'b1;
      norm.direct.data[31] = pre.sign;
      return norm;
    end

    // These depend on lsb_exponent only, so they resolve concurrently with the
    // leading-one search rather than chaining behind it.
    lsb_exp             = pre.lsb_exponent;
    overflow_threshold  =  signed'(EXPW'(127)) - lsb_exp;
    subnormal_threshold = -signed'(EXPW'(126)) - lsb_exp;
    subnormal_shift     = -(lsb_exp + signed'(EXPW'(149)));

    highest_bit = highest_magnitude_bit(magnitude);
    highest_signed = signed'(EXPW'({9'b0, highest_bit}));

    // hb + lsb > 127  <=>  hb >  127 - lsb
    // hb + lsb >= -126 <=> hb >= -126 - lsb
    is_overflow       = highest_signed >  overflow_threshold;
    is_normal_range   = highest_signed >= subnormal_threshold;
    unbiased_exponent = highest_signed + lsb_exp;

    if (is_overflow) begin
      direct = '0;
      direct.flags = FFLAG_OF | FFLAG_NX;
      if ((pre.rounding_mode == 3'b001) ||
          (pre.rounding_mode == 3'b010 && !pre.sign) ||
          (pre.rounding_mode == 3'b011 && pre.sign))
        direct.data[31:0] = {pre.sign, 8'hfe, 23'h7f_ffff};
      else
        direct.data[31:0] = {pre.sign, 8'hff, 23'h0};
      norm.direct_valid = 1'b1;
      norm.direct = direct;
      return norm;
    end

    norm.sign = pre.sign;
    norm.unbiased_exponent = unbiased_exponent;
    norm.rounding_mode = pre.rounding_mode;
    retained_wide = '0;
    norm.guard_bit = 1'b0;
    sticky = pre.extra_sticky;
    norm.subnormal = ~is_normal_range;
    shift_amount = is_normal_range ? (highest_signed - signed'(EXPW'(23))) : subnormal_shift;

    if (shift_amount > 0) begin
      if (shift_amount < MAGW_S) begin
        shift_unsigned = 7'(shift_amount);
        shift_minus1 = shift_unsigned - 7'd1;
        retained_wide = magnitude >> shift_unsigned;
        norm.guard_bit = magnitude[shift_minus1];
        for (integer bit_index = 0; bit_index < int'(MAGW); bit_index++)
          if (7'(bit_index) < shift_minus1)
            sticky |= magnitude[bit_index];
      end else begin
        sticky |= |magnitude;
      end
    end else if (-shift_amount < MAGW_S) begin
      shift_unsigned = 7'(-shift_amount);
      retained_wide = magnitude << shift_unsigned;
    end

    norm.retained = retained_wide[23:0];
    norm.sticky_bit = sticky;
    return norm;
  endfunction

  function automatic fp_calc_t finalize_fp_normalized(
    input fp_normalized_t norm
  );
    fp_calc_t result;
    logic [24:0] rounded;
    logic increment;
    logic inexact;
    logic [7:0] exponent_field;
    logic signed [EXPW-1:0] unbiased_exponent;
    logic signed [EXPW-1:0] exponent_no_carry;
    logic signed [EXPW-1:0] exponent_with_carry;
    logic carry_out;

    if (norm.direct_valid)
      return norm.direct;

    result = '0;
    inexact = norm.guard_bit || norm.sticky_bit;
    increment = round_up(norm.sign, norm.rounding_mode, norm.retained[0],
                         norm.guard_bit, norm.sticky_bit);
    rounded = {1'b0, norm.retained} + increment;
    unbiased_exponent = norm.unbiased_exponent;
    // 반올림 캐리가 새 가산을 시작하지 않도록 두 후보를 미리 만들어 둔다.
    exponent_no_carry   = unbiased_exponent + signed'(EXPW'(127));
    exponent_with_carry = unbiased_exponent + signed'(EXPW'(128));
    carry_out = 1'b0;

    if (!norm.subnormal) begin
      carry_out = rounded[24];
      if (carry_out)
        rounded = rounded >> 1;
      if (carry_out ? (unbiased_exponent >= signed'(EXPW'(127)))
                    : (unbiased_exponent >  signed'(EXPW'(127)))) begin
        result.flags = FFLAG_OF | FFLAG_NX;
        if ((norm.rounding_mode == 3'b001) ||
            (norm.rounding_mode == 3'b010 && !norm.sign) ||
            (norm.rounding_mode == 3'b011 && norm.sign))
          result.data[31:0] = {norm.sign, 8'hfe, 23'h7f_ffff};
        else
          result.data[31:0] = {norm.sign, 8'hff, 23'h0};
      end else begin
        exponent_field = 8'(carry_out ? exponent_with_carry : exponent_no_carry);
        result.data[31:0] = {norm.sign, exponent_field, rounded[22:0]};
        if (inexact)
          result.flags |= FFLAG_NX;
      end
    end else begin
      if (rounded[23])
        result.data[31:0] = {norm.sign, 8'h01, 23'h0};
      else begin
        result.data[31:0] = {norm.sign, 8'h00, rounded[22:0]};
        if (inexact)
          result.flags |= FFLAG_UF;
      end
      if (inexact)
        result.flags |= FFLAG_NX;
    end
    return result;
  endfunction

  function automatic fp_precalc_t fp_add_sub_pre(
    input logic [31:0] a,
    input logic [31:0] b,
    input logic subtract_b,
    input logic [2:0] rm
  );
    fp_precalc_t pre;
    fp_calc_t result;
    logic sign_a, sign_b, sticky_a, sticky_b, result_sign;
    logic [23:0] mantissa_a, mantissa_b;
    logic [MAGW-1:0] aligned_a, aligned_b, magnitude;
    logic signed [MAGW:0] signed_a, signed_b, signed_sum;
    logic signed [EXPW-1:0] exponent_a, exponent_b, common_exponent;

    pre = '0;
    pre.rounding_mode = rm;
    result = '0;
    sign_a = a[31];
    sign_b = b[31] ^ subtract_b;
    if (fp_is_nan(a) || fp_is_nan(b)) begin
      result.data[31:0] = CANONICAL_NAN;
      if (fp_is_snan(a) || fp_is_snan(b)) result.flags = FFLAG_NV;
      pre.direct = result;
      return pre;
    end
    if (fp_is_inf(a) && fp_is_inf(b) && (sign_a != sign_b)) begin
      result.data[31:0] = CANONICAL_NAN;
      result.flags = FFLAG_NV;
      pre.direct = result;
      return pre;
    end
    if (fp_is_inf(a)) begin
      result.data[31:0] = {sign_a, 8'hff, 23'h0};
      pre.direct = result;
      return pre;
    end
    if (fp_is_inf(b)) begin
      result.data[31:0] = {sign_b, 8'hff, 23'h0};
      pre.direct = result;
      return pre;
    end

    mantissa_a = fp_mantissa(a);
    mantissa_b = fp_mantissa(b);
    exponent_a = fp_lsb_exponent_n(a);
    exponent_b = fp_lsb_exponent_n(b);
    common_exponent = (exponent_a > exponent_b) ? exponent_a : exponent_b;
    aligned_a = right_shift_sticky({{(MAGW-24){1'b0}}, mantissa_a} << ALIGN_SH,
                                   common_exponent - exponent_a);
    aligned_b = right_shift_sticky({{(MAGW-24){1'b0}}, mantissa_b} << ALIGN_SH,
                                   common_exponent - exponent_b);
    sticky_a = aligned_a[0];
    sticky_b = aligned_b[0];
    signed_a = $signed({1'b0, aligned_a});
    signed_b = $signed({1'b0, aligned_b});
    if (sign_a) signed_a = -signed_a;
    if (sign_b) signed_b = -signed_b;
    signed_sum = signed_a + signed_b;
    if (signed_sum == 0) begin
      result.data[31] = exact_sum_zero_sign(fp_is_zero(a), sign_a,
                                            fp_is_zero(b), sign_b, rm);
      pre.direct = result;
      return pre;
    end
    result_sign = signed_sum[MAGW];
    magnitude = result_sign ? MAGW'(-signed_sum) : MAGW'(signed_sum);
    pre.needs_pack = 1'b1;
    pre.sign = result_sign;
    pre.magnitude = magnitude;
    pre.lsb_exponent = common_exponent - signed'(EXPW'(ALIGN_SH));
    pre.extra_sticky = sticky_a || sticky_b;
    return pre;
  endfunction

  function automatic fp_align_t fp_add_sub_align(
    input logic [31:0] a,
    input logic [31:0] b,
    input logic subtract_b,
    input logic [2:0] rm
  );
    fp_precalc_t pre;
    fp_align_t al;
    fp_calc_t result;
    logic sign_a, sign_b, sticky_a, sticky_b, result_sign;
    logic [23:0] mantissa_a, mantissa_b;
    logic [MAGW-1:0] aligned_a, aligned_b, magnitude;
    logic signed [MAGW:0] signed_a, signed_b, signed_sum;
    logic signed [EXPW-1:0] exponent_a, exponent_b, common_exponent;

    pre = '0;
    al = '0;
    pre.rounding_mode = rm;
    result = '0;
    sign_a = a[31];
    sign_b = b[31] ^ subtract_b;
    if (fp_is_nan(a) || fp_is_nan(b)) begin
      result.data[31:0] = CANONICAL_NAN;
      if (fp_is_snan(a) || fp_is_snan(b)) result.flags = FFLAG_NV;
      pre.direct = result;
      al.pre = pre;
      return al;
    end
    if (fp_is_inf(a) && fp_is_inf(b) && (sign_a != sign_b)) begin
      result.data[31:0] = CANONICAL_NAN;
      result.flags = FFLAG_NV;
      pre.direct = result;
      al.pre = pre;
      return al;
    end
    if (fp_is_inf(a)) begin
      result.data[31:0] = {sign_a, 8'hff, 23'h0};
      pre.direct = result;
      al.pre = pre;
      return al;
    end
    if (fp_is_inf(b)) begin
      result.data[31:0] = {sign_b, 8'hff, 23'h0};
      pre.direct = result;
      al.pre = pre;
      return al;
    end

    mantissa_a = fp_mantissa(a);
    mantissa_b = fp_mantissa(b);
    exponent_a = fp_lsb_exponent_n(a);
    exponent_b = fp_lsb_exponent_n(b);
    common_exponent = (exponent_a > exponent_b) ? exponent_a : exponent_b;
    aligned_a = right_shift_sticky({{(MAGW-24){1'b0}}, mantissa_a} << ALIGN_SH,
                                   common_exponent - exponent_a);
    aligned_b = right_shift_sticky({{(MAGW-24){1'b0}}, mantissa_b} << ALIGN_SH,
                                   common_exponent - exponent_b);
    sticky_a = aligned_a[0];
    sticky_b = aligned_b[0];
    al.sum_pending     = 1'b1;
    al.mag_x           = aligned_a;
    al.mag_y           = aligned_b;
    al.neg_x           = sign_a;
    al.neg_y           = sign_b;
    al.common_exponent = common_exponent;
    al.sticky          = sticky_a || sticky_b;
    al.rm              = rm;
    al.zx_zero         = fp_is_zero(a);
    al.zx_sign         = sign_a;
    al.zy_zero         = fp_is_zero(b);
    al.zy_sign         = sign_b;
    al.pre             = pre;
    return al;
  endfunction

  function automatic fp_precalc_t fp_multiply_pre(
    input logic [31:0] a,
    input logic [31:0] b,
    input logic [2:0] rm
  );
    fp_precalc_t pre;
    fp_calc_t result;
    logic sign;
    logic [47:0] product;
    logic signed [EXPW-1:0] result_exponent;
    pre = '0;
    pre.rounding_mode = rm;
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
      result_exponent = fp_lsb_exponent_n(a) + fp_lsb_exponent_n(b);
      pre.needs_pack = 1'b1;
      pre.sign = sign;
      pre.magnitude = {{(MAGW-48){1'b0}}, product};
      pre.lsb_exponent = result_exponent;
    end
    pre.direct = result;
    return pre;
  endfunction

  function automatic fp_precalc_t fp_fused_multiply_add_pre(
    input logic [31:0] a,
    input logic [31:0] b,
    input logic [31:0] c,
    input logic negate_product,
    input logic negate_c,
    input logic [2:0] rm
  );
    fp_precalc_t pre;
    fp_calc_t result;
    logic product_sign, c_sign, result_sign, sticky_product, sticky_c;
    logic [47:0] product;
    logic [23:0] mantissa_c;
    logic [MAGW-1:0] aligned_product, aligned_c, magnitude;
    logic signed [MAGW:0] signed_product, signed_c, signed_sum;
    logic signed [EXPW-1:0] product_exponent, c_exponent, common_exponent;

    pre = '0;
    pre.rounding_mode = rm;
    result = '0;
    product_sign = a[31] ^ b[31] ^ negate_product;
    c_sign = c[31] ^ negate_c;
    if (fp_is_nan(a) || fp_is_nan(b) || fp_is_nan(c)) begin
      result.data[31:0] = CANONICAL_NAN;
      if (fp_is_snan(a) || fp_is_snan(b) || fp_is_snan(c) ||
          ((fp_is_inf(a) && fp_is_zero(b)) ||
           (fp_is_zero(a) && fp_is_inf(b)))) result.flags = FFLAG_NV;
      pre.direct = result;
      return pre;
    end
    if ((fp_is_inf(a) && fp_is_zero(b)) ||
        (fp_is_zero(a) && fp_is_inf(b))) begin
      result.data[31:0] = CANONICAL_NAN;
      result.flags = FFLAG_NV;
      pre.direct = result;
      return pre;
    end
    if ((fp_is_inf(a) || fp_is_inf(b)) && fp_is_inf(c) &&
        (product_sign != c_sign)) begin
      result.data[31:0] = CANONICAL_NAN;
      result.flags = FFLAG_NV;
      pre.direct = result;
      return pre;
    end
    if (fp_is_inf(a) || fp_is_inf(b)) begin
      result.data[31:0] = {product_sign, 8'hff, 23'h0};
      pre.direct = result;
      return pre;
    end
    if (fp_is_inf(c)) begin
      result.data[31:0] = {c_sign, 8'hff, 23'h0};
      pre.direct = result;
      return pre;
    end
    // A finite zero product contributes no magnitude.  Do not feed its
    // synthetic fp_lsb_exponent into the alignment network: for a large
    // non-zero multiplicand times zero that exponent can otherwise discard
    // most or all of a small addend.  The addend is exact in this case.
    if (fp_is_zero(a) || fp_is_zero(b)) begin
      if (!fp_is_zero(c)) begin
        result.data[31:0] = {c_sign, c[30:0]};
      end else begin
        result.data[31:0] = '0;
        result.data[31] = exact_sum_zero_sign(1'b1, product_sign,
                                              1'b1, c_sign, rm);
      end
      pre.direct = result;
      return pre;
    end

    product = fp_mantissa(a) * fp_mantissa(b);
    mantissa_c = fp_mantissa(c);
    product_exponent = fp_lsb_exponent_n(a) + fp_lsb_exponent_n(b);
    c_exponent = fp_lsb_exponent_n(c);
    common_exponent = (product_exponent > c_exponent) ?
      product_exponent : c_exponent;
    aligned_product = right_shift_sticky({{(MAGW-48){1'b0}}, product} << ALIGN_SH,
      common_exponent - product_exponent);
    aligned_c = right_shift_sticky({{(MAGW-24){1'b0}}, mantissa_c} << ALIGN_SH,
      common_exponent - c_exponent);
    sticky_product = aligned_product[0];
    sticky_c = aligned_c[0];
    signed_product = $signed({1'b0, aligned_product});
    signed_c = $signed({1'b0, aligned_c});
    if (product_sign) signed_product = -signed_product;
    if (c_sign) signed_c = -signed_c;
    signed_sum = signed_product + signed_c;
    if (signed_sum == 0) begin
      result.data[31] = exact_sum_zero_sign(fp_is_zero(a) || fp_is_zero(b),
                                           product_sign, fp_is_zero(c), c_sign,
                                           rm);
      pre.direct = result;
      return pre;
    end
    result_sign = signed_sum[MAGW];
    magnitude = result_sign ? MAGW'(-signed_sum) : MAGW'(signed_sum);
    pre.needs_pack = 1'b1;
    pre.sign = result_sign;
    pre.magnitude = magnitude;
    pre.lsb_exponent = common_exponent - signed'(EXPW'(ALIGN_SH));
    pre.extra_sticky = sticky_product || sticky_c;
    return pre;
  endfunction

  function automatic fp_align_t fp_fma_align(
    input logic [31:0] a,
    input logic [31:0] b,
    input logic [31:0] c,
    input logic negate_product,
    input logic negate_c,
    input logic [2:0] rm
  );
    fp_precalc_t pre;
    fp_align_t al;
    fp_calc_t result;
    logic product_sign, c_sign, result_sign, sticky_product, sticky_c;
    logic [47:0] product;
    logic [23:0] mantissa_c;
    logic [MAGW-1:0] aligned_product, aligned_c, magnitude;
    logic signed [MAGW:0] signed_product, signed_c, signed_sum;
    logic signed [EXPW-1:0] product_exponent, c_exponent, common_exponent;

    pre = '0;
    al = '0;
    pre.rounding_mode = rm;
    result = '0;
    product_sign = a[31] ^ b[31] ^ negate_product;
    c_sign = c[31] ^ negate_c;
    if (fp_is_nan(a) || fp_is_nan(b) || fp_is_nan(c)) begin
      result.data[31:0] = CANONICAL_NAN;
      if (fp_is_snan(a) || fp_is_snan(b) || fp_is_snan(c) ||
          ((fp_is_inf(a) && fp_is_zero(b)) ||
           (fp_is_zero(a) && fp_is_inf(b)))) result.flags = FFLAG_NV;
      pre.direct = result;
      al.pre = pre;
      return al;
    end
    if ((fp_is_inf(a) && fp_is_zero(b)) ||
        (fp_is_zero(a) && fp_is_inf(b))) begin
      result.data[31:0] = CANONICAL_NAN;
      result.flags = FFLAG_NV;
      pre.direct = result;
      al.pre = pre;
      return al;
    end
    if ((fp_is_inf(a) || fp_is_inf(b)) && fp_is_inf(c) &&
        (product_sign != c_sign)) begin
      result.data[31:0] = CANONICAL_NAN;
      result.flags = FFLAG_NV;
      pre.direct = result;
      al.pre = pre;
      return al;
    end
    if (fp_is_inf(a) || fp_is_inf(b)) begin
      result.data[31:0] = {product_sign, 8'hff, 23'h0};
      pre.direct = result;
      al.pre = pre;
      return al;
    end
    if (fp_is_inf(c)) begin
      result.data[31:0] = {c_sign, 8'hff, 23'h0};
      pre.direct = result;
      al.pre = pre;
      return al;
    end
    // A finite zero product contributes no magnitude.  Do not feed its
    // synthetic fp_lsb_exponent into the alignment network: for a large
    // non-zero multiplicand times zero that exponent can otherwise discard
    // most or all of a small addend.  The addend is exact in this case.
    if (fp_is_zero(a) || fp_is_zero(b)) begin
      if (!fp_is_zero(c)) begin
        result.data[31:0] = {c_sign, c[30:0]};
      end else begin
        result.data[31:0] = '0;
        result.data[31] = exact_sum_zero_sign(1'b1, product_sign,
                                              1'b1, c_sign, rm);
      end
      pre.direct = result;
      al.pre = pre;
      return al;
    end

    product = fp_mantissa(a) * fp_mantissa(b);
    mantissa_c = fp_mantissa(c);
    product_exponent = fp_lsb_exponent_n(a) + fp_lsb_exponent_n(b);
    c_exponent = fp_lsb_exponent_n(c);
    common_exponent = (product_exponent > c_exponent) ?
      product_exponent : c_exponent;
    aligned_product = right_shift_sticky({{(MAGW-48){1'b0}}, product} << ALIGN_SH,
      common_exponent - product_exponent);
    aligned_c = right_shift_sticky({{(MAGW-24){1'b0}}, mantissa_c} << ALIGN_SH,
      common_exponent - c_exponent);
    sticky_product = aligned_product[0];
    sticky_c = aligned_c[0];
    al.sum_pending     = 1'b1;
    al.mag_x           = aligned_product;
    al.mag_y           = aligned_c;
    al.neg_x           = product_sign;
    al.neg_y           = c_sign;
    al.common_exponent = common_exponent;
    al.sticky          = sticky_product || sticky_c;
    al.rm              = rm;
    al.zx_zero         = fp_is_zero(a) || fp_is_zero(b);
    al.zx_sign         = product_sign;
    al.zy_zero         = fp_is_zero(c);
    al.zy_sign         = c_sign;
    al.pre             = pre;
    return al;
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
    // FP32 has only 24 significant bits. Detect large positive exponents
    // before the shifter; they always saturate the 32/64-bit destination.
    logic [63:0] magnitude, retained, rounded_magnitude;
    logic [63:0] maximum_value;
    logic [24:0] fractional_rounded;
    logic too_large;
    integer destination_width, exponent_value, shift_amount;
    result = '0;
    destination_unsigned = integer_kind[0];
    destination_width = integer_kind[1] ? 64 : 32;
    sign = a[31];
    if (fp_is_nan(a) || fp_is_inf(a)) begin
      result.flags = FFLAG_NV;
      if (fp_is_nan(a) || !sign)
        magnitude = destination_unsigned ?
          ((destination_width == 64) ? 64'hffff_ffff_ffff_ffff :
                                       {32'b0, 32'hffff_ffff}) :
          ((destination_width == 64) ? {1'b0, 63'h7fff_ffff_ffff_ffff} :
                                       {33'b0, 31'h7fff_ffff});
      else
        magnitude = destination_unsigned ? '0 :
          ((destination_width == 64) ? (64'b1 << 63) : (64'b1 << 31));
    end else begin
      magnitude = {40'b0, fp_mantissa(a)};
      exponent_value = fp_lsb_exponent(a);
      retained = '0;
      guard_bit = 1'b0;
      sticky_bit = 1'b0;
      too_large = 1'b0;
      if (exponent_value >= 0) begin
        // In this branch the FP operand is normal, so bit23 is always one.
        // exp>=width-23 implies an integer magnitude >=2**width.
        too_large = exponent_value >= (destination_width-23);
        if (!too_large)
          retained = magnitude << exponent_value;
      end else begin
        shift_amount = -exponent_value;
        if (shift_amount <= 24) begin
          retained = magnitude >> shift_amount;
          guard_bit = magnitude[shift_amount-1];
          for (integer bit_index = 0; bit_index < 24; bit_index++)
            if (bit_index < (shift_amount-1)) sticky_bit |= magnitude[bit_index];
        end else begin
          sticky_bit = |magnitude;
        end
      end
      increment = round_up(sign, rm, retained[0], guard_bit, sticky_bit);
      // A nonnegative exponent is already an exact integer, increment=0.
      // Fractional values can round at most a 24-bit retained significand.
      fractional_rounded = {1'b0,retained[23:0]} + 25'(increment);
      rounded_magnitude = (exponent_value >= 0) ? retained :
                            {39'b0,fractional_rounded};
      if (guard_bit || sticky_bit) result.flags |= FFLAG_NX;
      maximum_value = destination_unsigned ?
        ((destination_width == 64) ? 64'hffff_ffff_ffff_ffff : 64'hffff_ffff) :
        ((destination_width == 64) ? 64'h7fff_ffff_ffff_ffff : 64'h7fff_ffff);
      if (too_large || (sign && destination_unsigned && (rounded_magnitude != 0)) ||
          (!sign && (rounded_magnitude > maximum_value)) ||
          (sign && !destination_unsigned &&
           (rounded_magnitude > (64'b1 << (destination_width-1))))) begin
        result.flags = FFLAG_NV;
        if (destination_unsigned)
          magnitude = sign ? '0 : maximum_value;
        else
          magnitude = sign ? (64'b1 << (destination_width-1)) : maximum_value;
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

  function automatic fp_precalc_t integer_to_fp_pre(
    input logic [XLEN-1:0] integer_value,
    input logic [1:0] integer_kind,
    input logic [2:0] rm
  );
    fp_precalc_t pre;
    logic source_unsigned, sign;
    logic [63:0] source_value, magnitude;
    integer source_width;
    pre = '0;
    pre.needs_pack = 1'b1;
    pre.rounding_mode = rm;
    source_unsigned = integer_kind[0];
    source_width = integer_kind[1] ? 64 : 32;
    source_value = 64'(integer_value);
    if (source_width == 32)
      source_value = source_unsigned ? {32'b0, integer_value[31:0]} :
                                      64'($signed(integer_value[31:0]));
    sign = !source_unsigned && source_value[source_width-1];
    magnitude = sign ? -source_value : source_value;
    pre.sign = sign;
    pre.magnitude = {{(MAGW-64){1'b0}}, magnitude};
    pre.lsb_exponent = '0;
    return pre;
  endfunction

  function automatic fp_precalc_t execute_fp_pre(
    input logic [31:0] instruction,
    input logic [XLEN-1:0] operand_a,
    input logic [XLEN-1:0] operand_b,
    input logic [XLEN-1:0] operand_c,
    input logic [2:0] rm
  );
    fp_precalc_t pre;
    fp_calc_t result;
    logic use_precalc;
    logic [6:0] opcode, funct7;
    logic [2:0] funct3;
    logic [4:0] rs2;
    logic [31:0] a, b, c;
    pre = '0;
    pre.rounding_mode = rm;
    result = '0;
    use_precalc = 1'b0;
    opcode = instruction[6:0];
    funct7 = instruction[31:25];
    funct3 = instruction[14:12];
    rs2 = instruction[24:20];
    a = operand_a[31:0];
    b = operand_b[31:0];
    c = operand_c[31:0];

    case (opcode)
      7'b1000011: begin
        pre = fp_fused_multiply_add_pre(a, b, c, 1'b0, 1'b0, rm);
        use_precalc = 1'b1;
      end
      7'b1000111: begin
        pre = fp_fused_multiply_add_pre(a, b, c, 1'b0, 1'b1, rm);
        use_precalc = 1'b1;
      end
      7'b1001011: begin
        pre = fp_fused_multiply_add_pre(a, b, c, 1'b1, 1'b0, rm);
        use_precalc = 1'b1;
      end
      7'b1001111: begin
        pre = fp_fused_multiply_add_pre(a, b, c, 1'b1, 1'b1, rm);
        use_precalc = 1'b1;
      end
      7'b1010011: begin
        case (funct7)
          7'b0000000: begin
            pre = fp_add_sub_pre(a, b, 1'b0, rm);
            use_precalc = 1'b1;
          end
          7'b0000100: begin
            pre = fp_add_sub_pre(a, b, 1'b1, rm);
            use_precalc = 1'b1;
          end
          7'b0001000: begin
            pre = fp_multiply_pre(a, b, rm);
            use_precalc = 1'b1;
          end
          // FDIV.S and FSQRT.S are handled by the iterative slow path below.
          // Keeping them out of this function prevents a combinational divider
          // and 64-step square-root network from being inferred in the fast
          // FPU request path.
          7'b0001100: result = '0;
          7'b0101100: result = '0;
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
          7'b1101000: begin
            pre = integer_to_fp_pre(operand_a, rs2[1:0], rm);
            use_precalc = 1'b1;
          end
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
    if (!use_precalc)
      pre.direct = result;
    return pre;
  endfunction

  function automatic fp_align_t execute_fp_align(
    input logic [31:0] instruction,
    input logic [XLEN-1:0] operand_a,
    input logic [XLEN-1:0] operand_b,
    input logic [XLEN-1:0] operand_c,
    input logic [2:0] rm
  );
    fp_precalc_t pre;
    fp_align_t al;
    fp_calc_t result;
    logic use_precalc;
    logic [6:0] opcode, funct7;
    logic [2:0] funct3;
    logic [4:0] rs2;
    logic [31:0] a, b, c;
    pre = '0;
    pre.rounding_mode = rm;
    al = '0;
    al.pre.rounding_mode = rm;
    result = '0;
    use_precalc = 1'b0;
    opcode = instruction[6:0];
    funct7 = instruction[31:25];
    funct3 = instruction[14:12];
    rs2 = instruction[24:20];
    a = operand_a[31:0];
    b = operand_b[31:0];
    c = operand_c[31:0];

    case (opcode)
      7'b1000011: begin
        al = fp_fma_align(a, b, c, 1'b0, 1'b0, rm);
        use_precalc = 1'b1;
      end
      7'b1000111: begin
        al = fp_fma_align(a, b, c, 1'b0, 1'b1, rm);
        use_precalc = 1'b1;
      end
      7'b1001011: begin
        al = fp_fma_align(a, b, c, 1'b1, 1'b0, rm);
        use_precalc = 1'b1;
      end
      7'b1001111: begin
        al = fp_fma_align(a, b, c, 1'b1, 1'b1, rm);
        use_precalc = 1'b1;
      end
      7'b1010011: begin
        case (funct7)
          7'b0000000: begin
            al = fp_add_sub_align(a, b, 1'b0, rm);
            use_precalc = 1'b1;
          end
          7'b0000100: begin
            al = fp_add_sub_align(a, b, 1'b1, rm);
            use_precalc = 1'b1;
          end
          7'b0001000: begin
            al.pre = fp_multiply_pre(a, b, rm);
            use_precalc = 1'b1;
          end
          // FDIV.S and FSQRT.S are handled by the iterative slow path below.
          // Keeping them out of this function prevents a combinational divider
          // and 64-step square-root network from being inferred in the fast
          // FPU request path.
          7'b0001100: result = '0;
          7'b0101100: result = '0;
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
          7'b1101000: begin
            al.pre = integer_to_fp_pre(operand_a, rs2[1:0], rm);
            use_precalc = 1'b1;
          end
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
    if (!use_precalc)
      al.pre.direct = result;
    return al;
  endfunction

  // Stage 2 of the split arithmetic path: the wide signed accumulate plus the
  // exact-zero sign rule and magnitude extraction.
  function automatic logic [MAGW:0] accumulate_sliced(
    input logic [MAGW:0] lhs,
    input logic [MAGW:0] rhs,
    input logic carry_in
  );
    localparam int GROUPS = (MAGW+4)/4;
    localparam int PADW = GROUPS*4;
    logic [PADW-1:0] ax, bx, assembled;
    logic [GROUPS-1:0] propagate, generate_carry, carry;
    logic [4:0] sum0 [0:GROUPS-1];
    logic [4:0] sum1 [0:GROUPS-1];
    logic term;
    ax = PADW'(lhs); bx = PADW'(rhs);
    for (int group = 0; group < GROUPS; group++) begin
      sum0[group] = {1'b0,ax[group*4 +: 4]} + {1'b0,bx[group*4 +: 4]};
      sum1[group] = {1'b0,ax[group*4 +: 4]} + {1'b0,bx[group*4 +: 4]} + 5'd1;
      propagate[group] = &(ax[group*4 +: 4] ^ bx[group*4 +: 4]);
      generate_carry[group] = sum0[group][4];
    end
    for (int group = 0; group < GROUPS; group++) begin
      term = carry_in;
      for (int earlier = 0; earlier < group; earlier++) term &= propagate[earlier];
      carry[group] = term;
      for (int source = 0; source < group; source++) begin
        term = generate_carry[source];
        for (int between = source+1; between < group; between++) term &= propagate[between];
        carry[group] |= term;
      end
      assembled[group*4 +: 4] = carry[group] ? sum1[group][3:0] : sum0[group][3:0];
    end
    return assembled[MAGW:0];
  endfunction

  function automatic fp_precalc_t fp_align_finish(
    input fp_align_t al
  );
    fp_precalc_t pre;
    fp_precalc_t pre_sum;
    fp_precalc_t pre_zero;
    fp_calc_t result;
    logic [MAGW:0] wx, wy, sum_add, dif_xy, dif_yx, magnitude;
    logic same_sign, x_ge, sum_zero, result_sign;

    // Three parallel adders instead of one add followed by a conditional
    // two's-complement negate (that was two full-width carry chains in
    // series).  Everything that does not depend on the adders -- sum_zero,
    // same_sign, the direct/zero payloads -- is built alongside them so the
    // only thing left behind the carry chain is a single select.
    wx = {1'b0, al.mag_x};
    wy = {1'b0, al.mag_y};
    same_sign = (al.neg_x == al.neg_y);
    sum_add   = accumulate_sliced(wx, wy, 1'b0);
    dif_xy    = accumulate_sliced(wx, ~wy, 1'b1);
    dif_yx    = accumulate_sliced(wy, ~wx, 1'b1);
    x_ge      = ~dif_xy[MAGW];
    sum_zero  = same_sign ? ((al.mag_x | al.mag_y) == '0)
                          : (al.mag_x == al.mag_y);

    result = '0;
    result.data[31] = exact_sum_zero_sign(al.zx_zero, al.zx_sign,
                                          al.zy_zero, al.zy_sign, al.rm);
    pre_zero = al.pre;
    pre_zero.needs_pack = 1'b0;
    pre_zero.direct = result;

    magnitude   = same_sign ? sum_add : (x_ge ? dif_xy : dif_yx);
    result_sign = same_sign ? al.neg_x : (x_ge ? al.neg_x : al.neg_y);

    pre_sum = al.pre;
    pre_sum.needs_pack   = 1'b1;
    pre_sum.sign         = result_sign;
    pre_sum.magnitude    = magnitude[MAGW-1:0];
    pre_sum.lsb_exponent = al.common_exponent - signed'(EXPW'(ALIGN_SH));
    pre_sum.extra_sticky = al.sticky;

    // One flat select.  Both control terms are ready long before `magnitude`.
    if (!al.sum_pending)
      pre = al.pre;
    else if (sum_zero)
      pre = pre_zero;
    else
      pre = pre_sum;
    return pre;
  endfunction


  function automatic fp_calc_t finalize_fp_pre(
    input fp_precalc_t pre
  );
    if (pre.needs_pack)
      return pack_finite(pre.sign, pre.magnitude, pre.lsb_exponent,
                         pre.rounding_mode, pre.extra_sticky);
    return pre.direct;
  endfunction

  // LATENCY>=6 gives multiplication/exponent preparation its own register
  // before the 80-bit sticky barrel shifts. Preserve the original alignment
  // helpers as the bit-exact LATENCY5 reference; replace their magnitude and
  // sticky outputs UNCONDITIONALLY so seed hardware has no shift-data cone.
  function automatic fp_align_seed_t prepare_align_seed(
    input logic [31:0] instruction,
    input logic [XLEN-1:0] a, b, c,
    input logic [2:0] rm
  );
    fp_align_seed_t seed;
    logic signed [EXPW-1:0] exponent_x, exponent_y;
    logic [23:0] ma, mb, pp00, pp01, pp10, pp11;
    seed = '0;
    seed.align = execute_fp_align(instruction, a, b, c, rm);
    seed.align.mag_x = '0;
    seed.align.mag_y = '0;
    seed.align.sticky = 1'b0;
    exponent_x = '0;
    exponent_y = '0;
    if (seed.align.sum_pending) begin
      if (instruction[6:0] == 7'b1010011) begin
        exponent_x = fp_lsb_exponent_n(a[31:0]);
        exponent_y = fp_lsb_exponent_n(b[31:0]);
        seed.align.mag_x = {{(MAGW-24){1'b0}}, fp_mantissa(a[31:0])} << ALIGN_SH;
        seed.align.mag_y = {{(MAGW-24){1'b0}}, fp_mantissa(b[31:0])} << ALIGN_SH;
      end else begin
        exponent_x = fp_lsb_exponent_n(a[31:0]) + fp_lsb_exponent_n(b[31:0]);
        exponent_y = fp_lsb_exponent_n(c[31:0]);
        seed.product_pending = 1'b1;
      end
      seed.shift_x = seed.align.common_exponent - exponent_x;
      seed.shift_y = seed.align.common_exponent - exponent_y;
    end
    if ((instruction[6:0] == 7'b1010011) &&
        (instruction[31:25] == 7'b0001000) && seed.align.pre.needs_pack) begin
      seed.product_pending = 1'b1;
      seed.product_precalc = 1'b1;
      // FMUL's finite magnitude is completed at the next existing boundary.
      // Clear it unconditionally in this branch so the full product is not
      // kept alongside the tiled multiplier by synthesis.
      seed.align.pre.magnitude = '0;
    end
    ma = fp_mantissa(a[31:0]);
    mb = fp_mantissa(b[31:0]);
    pp00 = ma[11:0] * mb[11:0];
    pp01 = ma[11:0] * mb[23:12];
    pp10 = ma[23:12] * mb[11:0];
    pp11 = ma[23:12] * mb[23:12];
    if (seed.product_pending) begin
      // Reuse otherwise unused seed magnitude bits, not four new payloads.
      seed.align.mag_x = '0;
      seed.align.mag_y = '0;
      seed.align.mag_x[71:0] = {pp10, pp01, pp00};
      seed.align.mag_y[23:0] = pp11;
      if (!seed.product_precalc)
        seed.align.mag_y[47:24] = fp_mantissa(c[31:0]);
    end
    return seed;
  endfunction

  function automatic fp_align_t finish_align_seed(input fp_align_seed_t seed);
    fp_align_t aligned;
    logic [47:0] row0, row1, row2, carry_save_sum, carry_save_carry, product;
    aligned = seed.align;
    row0 = {seed.align.mag_y[23:0], seed.align.mag_x[23:0]};
    row1 = {12'b0, seed.align.mag_x[47:24], 12'b0};
    row2 = {12'b0, seed.align.mag_x[71:48], 12'b0};
    carry_save_sum = row0 ^ row1 ^ row2;
    carry_save_carry = ((row0 & row1) | (row0 & row2) | (row1 & row2)) << 1;
    product = carry_save_sum + carry_save_carry;
    if (seed.product_pending) begin
      aligned.mag_x = '0;
      aligned.mag_y = '0;
      if (seed.product_precalc)
        aligned.pre.magnitude = {{(MAGW-48){1'b0}}, product};
      else begin
        aligned.mag_x = {{(MAGW-48){1'b0}}, product} << ALIGN_SH;
        aligned.mag_y = {{(MAGW-24){1'b0}}, seed.align.mag_y[47:24]} << ALIGN_SH;
      end
    end
    if (aligned.sum_pending) begin
      aligned.mag_x = right_shift_sticky(aligned.mag_x, seed.shift_x);
      aligned.mag_y = right_shift_sticky(aligned.mag_y, seed.shift_y);
      aligned.sticky = aligned.mag_x[0] || aligned.mag_y[0];
    end
    return aligned;
  endfunction

  always @* begin
    effective_rm = (rounding_mode_i == 3'b111) ? frm_i : rounding_mode_i;
    request_illegal_rm = effective_rm > 3'b100;
    request_precalc = execute_fp_pre(instruction_i, operand_a_i, operand_b_i,
                                     operand_c_i, effective_rm);
    request_align = execute_fp_align(instruction_i, operand_a_i, operand_b_i,
                                     operand_c_i, effective_rm);
    request_seed = prepare_align_seed(instruction_i, operand_a_i, operand_b_i,
                                     operand_c_i, effective_rm);
    seed_aligned = finish_align_seed(seed_calc_q);
    align_pre_calc = fp_align_finish(align_calc_q);

    request_is_divide = (instruction_i[6:0] == 7'b1010011) &&
                        (instruction_i[31:25] == 7'b0001100);
    request_is_sqrt = (instruction_i[6:0] == 7'b1010011) &&
                      (instruction_i[31:25] == 7'b0101100);
    request_is_slow = (request_is_divide || request_is_sqrt) &&
                      !request_illegal_rm;

    slow_special_calc = '0;
    slow_special_case = 1'b0;
    if (request_is_divide) begin
      slow_special_calc.data[31] = operand_a_i[31] ^ operand_b_i[31];
      if (fp_is_nan(operand_a_i[31:0]) || fp_is_nan(operand_b_i[31:0])) begin
        slow_special_case = 1'b1;
        slow_special_calc.data[31:0] = CANONICAL_NAN;
        if (fp_is_snan(operand_a_i[31:0]) ||
            fp_is_snan(operand_b_i[31:0]))
          slow_special_calc.flags = FFLAG_NV;
      end else if ((fp_is_zero(operand_a_i[31:0]) &&
                    fp_is_zero(operand_b_i[31:0])) ||
                   (fp_is_inf(operand_a_i[31:0]) &&
                    fp_is_inf(operand_b_i[31:0]))) begin
        slow_special_case = 1'b1;
        slow_special_calc.data[31:0] = CANONICAL_NAN;
        slow_special_calc.flags = FFLAG_NV;
      end else if (fp_is_inf(operand_a_i[31:0])) begin
        slow_special_case = 1'b1;
        slow_special_calc.data[31:0] = {
          operand_a_i[31] ^ operand_b_i[31], 8'hff, 23'h0
        };
      end else if (fp_is_inf(operand_b_i[31:0])) begin
        slow_special_case = 1'b1;
        slow_special_calc.data[31:0] = {
          operand_a_i[31] ^ operand_b_i[31], 31'h0
        };
      end else if (fp_is_zero(operand_b_i[31:0])) begin
        slow_special_case = 1'b1;
        slow_special_calc.data[31:0] = {
          operand_a_i[31] ^ operand_b_i[31], 8'hff, 23'h0
        };
        slow_special_calc.flags = FFLAG_DZ;
      end else if (fp_is_zero(operand_a_i[31:0])) begin
        slow_special_case = 1'b1;
        slow_special_calc.data[31:0] = {
          operand_a_i[31] ^ operand_b_i[31], 31'h0
        };
      end
    end else if (request_is_sqrt) begin
      if (fp_is_nan(operand_a_i[31:0])) begin
        slow_special_case = 1'b1;
        slow_special_calc.data[31:0] = CANONICAL_NAN;
        if (fp_is_snan(operand_a_i[31:0]))
          slow_special_calc.flags = FFLAG_NV;
      end else if (operand_a_i[31] && !fp_is_zero(operand_a_i[31:0])) begin
        slow_special_case = 1'b1;
        slow_special_calc.data[31:0] = CANONICAL_NAN;
        slow_special_calc.flags = FFLAG_NV;
      end else if (fp_is_inf(operand_a_i[31:0]) ||
                   fp_is_zero(operand_a_i[31:0])) begin
        slow_special_case = 1'b1;
        slow_special_calc.data[31:0] = operand_a_i[31:0];
      end
    end
  end

  always @* begin
    div_lz_a   = mantissa_lz(fp_mantissa(operand_a_i[31:0]));
    div_lz_b   = mantissa_lz(fp_mantissa(operand_b_i[31:0]));
    div_norm_a = fp_mantissa(operand_a_i[31:0]) << div_lz_a;
    div_norm_b = fp_mantissa(operand_b_i[31:0]) << div_lz_b;
    div_shifted_remainder = {div_remainder_q[23:0], div_numerator_q[DIV_NUMW-1]};
    div_quotient_bit = div_shifted_remainder >= {1'b0, div_divisor_q};
    div_next_remainder = div_quotient_bit ?
      div_shifted_remainder - {1'b0, div_divisor_q} :
      div_shifted_remainder;
    div_next_quotient = {div_quotient_q[DIV_NUMW-2:0], div_quotient_bit};

    sqrt_lz     = mantissa_lz(fp_mantissa(operand_a_i[31:0]));
    sqrt_norm_m = fp_mantissa(operand_a_i[31:0]) << sqrt_lz;
    sqrt_lsb    = fp_lsb_exponent_n(operand_a_i[31:0]) - signed'(EXPW'(sqrt_lz));
    sqrt_shifted_remainder = (sqrt_remainder_q << 2) |
      {{(SQRT_REMW-2){1'b0}}, sqrt_radicand_q[SQRT_RADW-1:SQRT_RADW-2]};
    sqrt_trial = {{(SQRT_REMW-SQRT_ROOTW-2){1'b0}}, sqrt_root_q, 2'b01};
    sqrt_root_bit = sqrt_shifted_remainder >= sqrt_trial;
    sqrt_next_remainder = sqrt_root_bit ?
      sqrt_shifted_remainder - sqrt_trial : sqrt_shifted_remainder;
    sqrt_next_root = {sqrt_root_q[SQRT_ROOTW-2:0], sqrt_root_bit};

    div_pack_calc = pack_finite(
      div_sign_q, {{(MAGW-DIV_NUMW){1'b0}}, div_quotient_q}, div_exponent_q,
      div_rm_q, div_remainder_q != 0);
    sqrt_pack_calc = pack_finite(
      1'b0, {{(MAGW-SQRT_ROOTW){1'b0}}, sqrt_root_q}, sqrt_exponent_q,
      sqrt_rm_q, sqrt_remainder_q != 0);
    request_final_calc = finalize_fp_pre(request_precalc);
    pre_norm_calc = normalize_fp_pre(pre_calc_q);
    pre_final_calc = finalize_fp_pre(pre_calc_q);
    norm_final_calc = finalize_fp_normalized(norm_calc_q);
  end

  // Keep the elastic-ready cone independent from the request arithmetic.
  // This prevents a false issue->request-data->ready combinational loop when
  // the FPU is connected to the global issue and writeback arbiters.
  always @* begin
    stage_ready[PIPE_STAGES-1] = !valid_q[PIPE_STAGES-1] ||
      (!slow_result_valid_q && result_ready_i);
    for (integer stage = PIPE_STAGES-2; stage >= 0; stage--)
      stage_ready[stage] = !valid_q[stage] || stage_ready[stage+1];
    norm_ready = !SPLIT_NORMALIZE || !norm_valid_q || stage_ready[0];
    pre_ready = !SPLIT_PREPACK || !pre_valid_q ||
                (SPLIT_NORMALIZE ? norm_ready : stage_ready[0]);
    align_ready = !SPLIT_ALIGN || !align_valid_q || pre_ready;
    seed_ready = !SPLIT_ALIGN_SHIFT || !seed_valid_q || align_ready;
    fast_pipe_empty = (!SPLIT_ALIGN_SHIFT || !seed_valid_q) &&
                      (!SPLIT_ALIGN || !align_valid_q) &&
                      (!SPLIT_PREPACK || !pre_valid_q) &&
                      (!SPLIT_NORMALIZE || !norm_valid_q) && !(|valid_q);
    if (request_is_slow)
      request_ready_o = !flush_valid_i && fast_pipe_empty &&
                        (slow_state_q == SLOW_IDLE) &&
                        !slow_result_valid_q;
    else
      request_ready_o = !flush_valid_i &&
                        (SPLIT_ALIGN_SHIFT ? seed_ready :
                         (SPLIT_ALIGN ? align_ready :
                          (SPLIT_PREPACK ? pre_ready : stage_ready[0]))) &&
                        (slow_state_q == SLOW_IDLE) &&
                        !slow_result_valid_q;
    request_accept = request_valid_i && request_ready_o;
    slow_request_accept = request_accept && request_is_slow;
    fast_request_accept = request_accept && !request_is_slow;
  end

  assign result_payload = slow_result_valid_q ? slow_payload_q :
                                                payload_q[PIPE_STAGES-1];
  assign result_valid_o = slow_result_valid_q || valid_q[PIPE_STAGES-1];
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
      pre_valid_q <= 1'b0;
      pre_sequence_q <= '0;
      pre_destination_valid_q <= 1'b0;
      pre_destination_class_q <= REG_NONE;
      pre_destination_phys_q <= '0;
      pre_exception_valid_q <= 1'b0;
      pre_exception_cause_q <= EXC_ILLEGAL_INSTRUCTION;
      pre_exception_tval_q <= '0;
      pre_calc_q <= '0;
      align_valid_q <= 1'b0;
      align_sequence_q <= '0;
      align_destination_valid_q <= 1'b0;
      align_destination_class_q <= REG_NONE;
      align_destination_phys_q <= '0;
      align_exception_valid_q <= 1'b0;
      align_exception_cause_q <= EXC_ILLEGAL_INSTRUCTION;
      align_exception_tval_q <= '0;
      align_calc_q <= '0;
      seed_valid_q <= 1'b0;
      seed_metadata_q <= '0;
      seed_calc_q <= '0;
      norm_valid_q <= 1'b0;
      norm_sequence_q <= '0;
      norm_destination_valid_q <= 1'b0;
      norm_destination_class_q <= REG_NONE;
      norm_destination_phys_q <= '0;
      norm_exception_valid_q <= 1'b0;
      norm_exception_cause_q <= EXC_ILLEGAL_INSTRUCTION;
      norm_exception_tval_q <= '0;
      norm_calc_q <= '0;
      slow_state_q <= SLOW_IDLE;
      slow_payload_q <= '0;
      slow_result_valid_q <= 1'b0;
      div_sign_q <= 1'b0;
      div_rm_q <= '0;
      div_exponent_q <= '0;
      div_divisor_q <= '0;
      div_numerator_q <= '0;
      div_remainder_q <= '0;
      div_quotient_q <= '0;
      div_count_q <= '0;
      sqrt_rm_q <= '0;
      sqrt_exponent_q <= '0;
      sqrt_radicand_q <= '0;
      sqrt_remainder_q <= '0;
      sqrt_root_q <= '0;
      sqrt_count_q <= '0;
      for (integer stage = 0; stage < PIPE_STAGES; stage++)
        payload_q[stage] <= '0;
    end else if (flush_valid_i) begin
      if (SPLIT_ALIGN_SHIFT && seed_valid_q &&
          killed_by_flush(seed_metadata_q.sequence_id))
        seed_valid_q <= 1'b0;
      if (SPLIT_ALIGN && align_valid_q && killed_by_flush(align_sequence_q))
        align_valid_q <= 1'b0;
      if (SPLIT_PREPACK && pre_valid_q && killed_by_flush(pre_sequence_q))
        pre_valid_q <= 1'b0;
      if (SPLIT_NORMALIZE && norm_valid_q &&
          killed_by_flush(norm_sequence_q))
        norm_valid_q <= 1'b0;
      for (integer stage = 0; stage < PIPE_STAGES; stage++)
        if (valid_q[stage] && killed_by_flush(payload_q[stage].sequence_id))
          valid_q[stage] <= 1'b0;
      if (((slow_state_q != SLOW_IDLE) || slow_result_valid_q) &&
          killed_by_flush(slow_payload_q.sequence_id)) begin
        slow_state_q <= SLOW_IDLE;
        slow_result_valid_q <= 1'b0;
      end
    end else begin
      if (slow_result_valid_q && result_ready_i)
        slow_result_valid_q <= 1'b0;

      for (integer stage = PIPE_STAGES-1; stage > 0; stage--) begin
        if (stage_ready[stage]) begin
          valid_q[stage] <= valid_q[stage-1];
          if (valid_q[stage-1])
            payload_q[stage] <= payload_q[stage-1];
        end
      end
      if (stage_ready[0]) begin
        if (SPLIT_PREPACK) begin
          valid_q[0] <= SPLIT_NORMALIZE ? norm_valid_q : pre_valid_q;
          if (SPLIT_NORMALIZE && norm_valid_q) begin
            payload_q[0].sequence_id <= norm_sequence_q;
            payload_q[0].destination_valid <= norm_destination_valid_q;
            payload_q[0].destination_class <= norm_destination_class_q;
            payload_q[0].destination_phys <= norm_destination_phys_q;
            payload_q[0].data <= norm_final_calc.data;
            payload_q[0].flags <= norm_exception_valid_q ? '0 :
                                  norm_final_calc.flags;
            payload_q[0].exception_valid <= norm_exception_valid_q;
            payload_q[0].exception_cause <= norm_exception_cause_q;
            payload_q[0].exception_tval <= norm_exception_tval_q;
          end else if (!SPLIT_NORMALIZE && pre_valid_q) begin
            payload_q[0].sequence_id <= pre_sequence_q;
            payload_q[0].destination_valid <= pre_destination_valid_q;
            payload_q[0].destination_class <= pre_destination_class_q;
            payload_q[0].destination_phys <= pre_destination_phys_q;
            payload_q[0].data <= pre_final_calc.data;
            payload_q[0].flags <= pre_exception_valid_q ? '0 :
                                  pre_final_calc.flags;
            payload_q[0].exception_valid <= pre_exception_valid_q;
            payload_q[0].exception_cause <= pre_exception_cause_q;
            payload_q[0].exception_tval <= pre_exception_tval_q;
          end
        end else begin
          valid_q[0] <= fast_request_accept;
          if (fast_request_accept) begin
            payload_q[0].sequence_id <= sequence_i;
            payload_q[0].destination_valid <= destination_valid_i;
            payload_q[0].destination_class <= destination_class_i;
            payload_q[0].destination_phys <= destination_phys_i;
            payload_q[0].data <= request_final_calc.data;
            payload_q[0].flags <= request_illegal_rm ? '0 :
                                  request_final_calc.flags;
            payload_q[0].exception_valid <= request_illegal_rm;
            payload_q[0].exception_cause <= EXC_ILLEGAL_INSTRUCTION;
            payload_q[0].exception_tval <= XLEN'(instruction_i);
          end
        end
      end

      if (SPLIT_NORMALIZE && norm_ready) begin
        norm_valid_q <= pre_valid_q;
        if (pre_valid_q) begin
          norm_sequence_q <= pre_sequence_q;
          norm_destination_valid_q <= pre_destination_valid_q;
          norm_destination_class_q <= pre_destination_class_q;
          norm_destination_phys_q <= pre_destination_phys_q;
          norm_exception_valid_q <= pre_exception_valid_q;
          norm_exception_cause_q <= pre_exception_cause_q;
          norm_exception_tval_q <= pre_exception_tval_q;
          norm_calc_q <= pre_norm_calc;
        end
      end

      if (SPLIT_PREPACK && pre_ready) begin
        pre_valid_q <= SPLIT_ALIGN ? align_valid_q : fast_request_accept;
        if (SPLIT_ALIGN && align_valid_q) begin
          pre_sequence_q <= align_sequence_q;
          pre_destination_valid_q <= align_destination_valid_q;
          pre_destination_class_q <= align_destination_class_q;
          pre_destination_phys_q <= align_destination_phys_q;
          pre_exception_valid_q <= align_exception_valid_q;
          pre_exception_cause_q <= align_exception_cause_q;
          pre_exception_tval_q <= align_exception_tval_q;
          pre_calc_q <= align_pre_calc;
        end else if (!SPLIT_ALIGN && fast_request_accept) begin
          pre_sequence_q <= sequence_i;
          pre_destination_valid_q <= destination_valid_i;
          pre_destination_class_q <= destination_class_i;
          pre_destination_phys_q <= destination_phys_i;
          pre_exception_valid_q <= request_illegal_rm;
          pre_exception_cause_q <= EXC_ILLEGAL_INSTRUCTION;
          pre_exception_tval_q <= XLEN'(instruction_i);
          pre_calc_q <= request_precalc;
        end
      end

      if (SPLIT_ALIGN && align_ready) begin
        align_valid_q <= SPLIT_ALIGN_SHIFT ? seed_valid_q : fast_request_accept;
        if (SPLIT_ALIGN_SHIFT && seed_valid_q) begin
          align_sequence_q <= seed_metadata_q.sequence_id;
          align_destination_valid_q <= seed_metadata_q.destination_valid;
          align_destination_class_q <= seed_metadata_q.destination_class;
          align_destination_phys_q <= seed_metadata_q.destination_phys;
          align_exception_valid_q <= seed_metadata_q.exception_valid;
          align_exception_cause_q <= seed_metadata_q.exception_cause;
          align_exception_tval_q <= seed_metadata_q.exception_tval;
          align_calc_q <= seed_aligned;
        end else if (!SPLIT_ALIGN_SHIFT && fast_request_accept) begin
          align_sequence_q <= sequence_i;
          align_destination_valid_q <= destination_valid_i;
          align_destination_class_q <= destination_class_i;
          align_destination_phys_q <= destination_phys_i;
          align_exception_valid_q <= request_illegal_rm;
          align_exception_cause_q <= EXC_ILLEGAL_INSTRUCTION;
          align_exception_tval_q <= XLEN'(instruction_i);
          align_calc_q <= request_align;
        end
      end
      if (SPLIT_ALIGN_SHIFT && seed_ready) begin
        seed_valid_q <= fast_request_accept;
        if (fast_request_accept) begin
          seed_metadata_q <= '0;
          seed_metadata_q.sequence_id <= sequence_i;
          seed_metadata_q.destination_valid <= destination_valid_i;
          seed_metadata_q.destination_class <= destination_class_i;
          seed_metadata_q.destination_phys <= destination_phys_i;
          seed_metadata_q.exception_valid <= request_illegal_rm;
          seed_metadata_q.exception_cause <= EXC_ILLEGAL_INSTRUCTION;
          seed_metadata_q.exception_tval <= XLEN'(instruction_i);
          seed_calc_q <= request_seed;
        end
      end

      if (slow_request_accept) begin
        slow_payload_q.sequence_id <= sequence_i;
        slow_payload_q.destination_valid <= destination_valid_i;
        slow_payload_q.destination_class <= destination_class_i;
        slow_payload_q.destination_phys <= destination_phys_i;
        slow_payload_q.data <= slow_special_calc.data;
        slow_payload_q.flags <= slow_special_calc.flags;
        slow_payload_q.exception_valid <= 1'b0;
        slow_payload_q.exception_cause <= EXC_ILLEGAL_INSTRUCTION;
        slow_payload_q.exception_tval <= '0;

        if (slow_special_case) begin
          slow_result_valid_q <= 1'b1;
        end else if (request_is_divide) begin
          div_sign_q <= operand_a_i[31] ^ operand_b_i[31];
          div_rm_q <= effective_rm;
          div_exponent_q <=
            (fp_lsb_exponent_n(operand_a_i[31:0]) - signed'(EXPW'(div_lz_a))) -
            (fp_lsb_exponent_n(operand_b_i[31:0]) - signed'(EXPW'(div_lz_b))) -
            signed'(EXPW'(DIV_FRAC));
          div_divisor_q <= div_norm_b;
          div_numerator_q <= {1'b0, div_norm_a, {DIV_FRAC{1'b0}}};
          div_remainder_q <= '0;
          div_quotient_q <= '0;
          div_count_q <= '0;
          slow_state_q <= SLOW_DIVIDE;
        end else begin
          sqrt_rm_q <= effective_rm;
          // radicand = m_norm << s, with s chosen so that (lsb - s) is even.
          if (sqrt_lsb & 1) begin
            sqrt_exponent_q <= (sqrt_lsb - signed'(EXPW'(SQRT_RADW - 25))) / 2;
            sqrt_radicand_q <=
              {{(SQRT_RADW-24){1'b0}}, sqrt_norm_m} << (SQRT_RADW - 25);
          end else begin
            sqrt_exponent_q <= (sqrt_lsb - signed'(EXPW'(SQRT_RADW - 24))) / 2;
            sqrt_radicand_q <=
              {{(SQRT_RADW-24){1'b0}}, sqrt_norm_m} << (SQRT_RADW - 24);
          end
          sqrt_remainder_q <= '0;
          sqrt_root_q <= '0;
          sqrt_count_q <= '0;
          slow_state_q <= SLOW_SQRT;
        end
      end else begin
        case (slow_state_q)
          SLOW_DIVIDE: begin
            div_numerator_q <= {div_numerator_q[DIV_NUMW-2:0], 1'b0};
            div_remainder_q <= div_next_remainder;
            div_quotient_q <= div_next_quotient;
            if (div_count_q == 7'(DIV_NUMW-1))
              slow_state_q <= SLOW_DIV_PACK;
            else
              div_count_q <= div_count_q + 1'b1;
          end
          SLOW_DIV_PACK: begin
            slow_payload_q.data <= div_pack_calc.data;
            slow_payload_q.flags <= div_pack_calc.flags;
            slow_result_valid_q <= 1'b1;
            slow_state_q <= SLOW_IDLE;
          end
          SLOW_SQRT: begin
            sqrt_radicand_q <= {sqrt_radicand_q[SQRT_RADW-3:0], 2'b0};
            sqrt_remainder_q <= sqrt_next_remainder;
            sqrt_root_q <= sqrt_next_root;
            if (sqrt_count_q == 7'(SQRT_ITERS - 1))
              slow_state_q <= SLOW_SQRT_PACK;
            else
              sqrt_count_q <= sqrt_count_q + 1'b1;
          end
          SLOW_SQRT_PACK: begin
            slow_payload_q.data <= sqrt_pack_calc.data;
            slow_payload_q.flags <= sqrt_pack_calc.flags;
            slow_result_valid_q <= 1'b1;
            slow_state_q <= SLOW_IDLE;
          end
          default: begin
          end
        endcase
      end
    end
  end

`ifndef SYNTHESIS
  always_comb begin
    if (rst_ni === 1'b1) begin
      if (result_valid_o && !result_exception_valid_o)
        assert (result_destination_class_o != REG_NONE ||
                !result_destination_valid_o);
    end
  end
`endif

  initial begin
    if ((XLEN != 32) && (XLEN != 64))
      $fatal(1, "FPU XLEN must be 32 or 64");
    if (LATENCY < 1)
      $fatal(1, "FPU LATENCY must be at least one cycle");
  end
endmodule
