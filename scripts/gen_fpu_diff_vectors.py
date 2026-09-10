#!/usr/bin/env python3
"""Generate deterministic RV32F arithmetic vectors from an exact rational oracle.

The oracle never evaluates an operation with the host floating-point unit.  Every
finite binary32 operand is decoded to Fraction, the requested operation is done
exactly, and the result is rounded once to binary32 for each RISC-V rounding mode.
"""

from __future__ import annotations

import argparse
import math
import random
from fractions import Fraction
from pathlib import Path


RNE, RTZ, RDN, RUP, RMM = range(5)
NX, UF, OF, DZ, NV = 0x01, 0x02, 0x04, 0x08, 0x10
CANONICAL_NAN = 0x7FC00000

OP_ADD = 0
OP_SUB = 1
OP_MUL = 2
OP_DIV = 3
OP_FMADD = 4
OP_FMSUB = 5
OP_FNMSUB = 6
OP_FNMADD = 7
OP_SQRT = 8
OP_FSGNJ = 9
OP_FSGNJN = 10
OP_FSGNJX = 11
OP_FMIN = 12
OP_FMAX = 13
OP_FEQ = 14
OP_FLT = 15
OP_FLE = 16
OP_FCVT_W_S = 17
OP_FCVT_WU_S = 18
OP_FCVT_S_W = 19
OP_FCVT_S_WU = 20
OP_FCLASS = 21
OP_FMV_X_W = 22
OP_FMV_W_X = 23


def sign(bits: int) -> int:
    return bits >> 31


def exponent(bits: int) -> int:
    return (bits >> 23) & 0xFF


def fraction_field(bits: int) -> int:
    return bits & 0x7FFFFF


def is_nan(bits: int) -> bool:
    return exponent(bits) == 0xFF and fraction_field(bits) != 0


def is_snan(bits: int) -> bool:
    return is_nan(bits) and (bits & 0x400000) == 0


def is_inf(bits: int) -> bool:
    return exponent(bits) == 0xFF and fraction_field(bits) == 0


def is_zero(bits: int) -> bool:
    return (bits & 0x7FFFFFFF) == 0


def finite_fraction(bits: int) -> Fraction:
    exp = exponent(bits)
    frac = fraction_field(bits)
    if exp == 0:
        mantissa = frac
        power = -149
    else:
        mantissa = (1 << 23) | frac
        power = exp - 150
    value = Fraction(mantissa << power, 1) if power >= 0 else Fraction(mantissa, 1 << -power)
    return -value if sign(bits) else value


def floor_log2(value: Fraction) -> int:
    numerator = value.numerator
    denominator = value.denominator
    estimate = numerator.bit_length() - denominator.bit_length()
    if estimate >= 0:
        if numerator < (denominator << estimate):
            estimate -= 1
    elif (numerator << -estimate) < denominator:
        estimate -= 1
    return estimate


def round_integer(numerator: int, denominator: int, negative: bool, rm: int) -> tuple[int, bool]:
    quotient, remainder = divmod(numerator, denominator)
    if remainder == 0:
        return quotient, False
    if rm == RNE:
        increment = (remainder * 2 > denominator) or (
            remainder * 2 == denominator and (quotient & 1) != 0
        )
    elif rm == RTZ:
        increment = False
    elif rm == RDN:
        increment = negative
    elif rm == RUP:
        increment = not negative
    elif rm == RMM:
        increment = remainder * 2 >= denominator
    else:
        raise ValueError(f"unsupported rounding mode {rm}")
    return quotient + int(increment), True


def scaled_ratio(value: Fraction, binary_power: int) -> tuple[int, int]:
    if binary_power >= 0:
        return value.numerator, value.denominator << binary_power
    return value.numerator << -binary_power, value.denominator


def overflow_result(negative: bool, rm: int) -> int:
    toward_infinity = rm in (RNE, RMM) or (rm == RUP and not negative) or (rm == RDN and negative)
    magnitude = 0x7F800000 if toward_infinity else 0x7F7FFFFF
    return (int(negative) << 31) | magnitude


def round_binary32(value: Fraction, rm: int, zero_negative: bool = False) -> tuple[int, int]:
    if value == 0:
        return int(zero_negative) << 31, 0

    negative = value < 0
    magnitude = -value if negative else value
    unbiased = floor_log2(magnitude)

    if unbiased >= -126:
        numerator, denominator = scaled_ratio(magnitude, unbiased - 23)
        significand, inexact = round_integer(numerator, denominator, negative, rm)
        if significand >= (1 << 24):
            significand >>= 1
            unbiased += 1
        if unbiased > 127:
            return overflow_result(negative, rm), OF | NX
        result = (int(negative) << 31) | ((unbiased + 127) << 23) | (significand & 0x7FFFFF)
        return result, NX if inexact else 0

    numerator, denominator = scaled_ratio(magnitude, -149)
    significand, inexact = round_integer(numerator, denominator, negative, rm)
    if significand >= (1 << 23):
        result = (int(negative) << 31) | (1 << 23)
        return result, NX if inexact else 0
    result = (int(negative) << 31) | significand
    flags = NX | UF if inexact else 0
    return result, flags


def round_sqrt_integer(value: Fraction, binary_power: int, rm: int) -> tuple[int, bool]:
    numerator, denominator = scaled_ratio(value, binary_power * 2)
    quotient = math.isqrt(numerator // denominator)
    exact = quotient * quotient * denominator == numerator
    if exact:
        return quotient, False
    midpoint_left = numerator * 4
    midpoint_right = (2 * quotient + 1) ** 2 * denominator
    if rm == RNE:
        increment = midpoint_left > midpoint_right or (
            midpoint_left == midpoint_right and (quotient & 1) != 0
        )
    elif rm in (RTZ, RDN):
        increment = False
    elif rm == RUP:
        increment = True
    elif rm == RMM:
        increment = midpoint_left >= midpoint_right
    else:
        raise ValueError(f"unsupported rounding mode {rm}")
    return quotient + int(increment), True


def square_root(a: int, rm: int) -> tuple[int, int]:
    if is_nan(a):
        return CANONICAL_NAN, NV if is_snan(a) else 0
    if sign(a) and not is_zero(a):
        return CANONICAL_NAN, NV
    if is_inf(a) or is_zero(a):
        return a, 0

    value = finite_fraction(a)
    unbiased = floor_log2(value) // 2
    if unbiased >= -126:
        significand, inexact = round_sqrt_integer(value, unbiased - 23, rm)
        if significand >= (1 << 24):
            significand >>= 1
            unbiased += 1
        result = ((unbiased + 127) << 23) | (significand & 0x7FFFFF)
        return result, NX if inexact else 0

    significand, inexact = round_sqrt_integer(value, -149, rm)
    if significand >= (1 << 23):
        return 0x00800000, NX if inexact else 0
    flags = NX | UF if inexact else 0
    return significand, flags


def ordered_less(a: int, b: int) -> bool:
    if a == b or (is_zero(a) and is_zero(b)):
        return False
    if sign(a) != sign(b):
        return bool(sign(a))
    if sign(a):
        return (a & 0x7FFFFFFF) > (b & 0x7FFFFFFF)
    return (a & 0x7FFFFFFF) < (b & 0x7FFFFFFF)


def min_max(a: int, b: int, select_max: bool) -> tuple[int, int]:
    flags = NV if is_snan(a) or is_snan(b) else 0
    if is_nan(a) and is_nan(b):
        return CANONICAL_NAN, flags
    if is_nan(a):
        return b, flags
    if is_nan(b):
        return a, flags
    if is_zero(a) and is_zero(b):
        result_sign = (sign(a) & sign(b)) if select_max else (sign(a) | sign(b))
        return result_sign << 31, flags
    less = ordered_less(a, b)
    return ((b if less else a) if select_max else (a if less else b)), flags


def compare(a: int, b: int, operation: int) -> tuple[int, int]:
    if is_nan(a) or is_nan(b):
        invalid = operation != OP_FEQ or is_snan(a) or is_snan(b)
        return 0, NV if invalid else 0
    equal = a == b or (is_zero(a) and is_zero(b))
    less = ordered_less(a, b)
    if operation == OP_FEQ:
        return int(equal), 0
    if operation == OP_FLT:
        return int(less), 0
    return int(less or equal), 0


def fp_to_integer(a: int, unsigned: bool, rm: int) -> tuple[int, int]:
    if is_nan(a) or is_inf(a):
        if unsigned:
            result = 0 if (is_inf(a) and sign(a)) else 0xFFFFFFFF
        else:
            result = 0x80000000 if (is_inf(a) and sign(a)) else 0x7FFFFFFF
        return result, NV

    value = finite_fraction(a)
    negative = value < 0
    magnitude = -value if negative else value
    rounded, inexact = round_integer(
        magnitude.numerator, magnitude.denominator, negative, rm
    )
    if unsigned:
        invalid = (negative and rounded != 0) or rounded > 0xFFFFFFFF
        if invalid:
            return (0 if negative else 0xFFFFFFFF), NV
        result = rounded
    else:
        invalid = (negative and rounded > 0x80000000) or (
            not negative and rounded > 0x7FFFFFFF
        )
        if invalid:
            return (0x80000000 if negative else 0x7FFFFFFF), NV
        result = (-rounded if negative else rounded) & 0xFFFFFFFF
    return result, NX if inexact else 0


def integer_to_fp(a: int, unsigned: bool, rm: int) -> tuple[int, int]:
    value = a if unsigned or a < 0x80000000 else a - (1 << 32)
    return round_binary32(Fraction(value, 1), rm)


def classify(a: int) -> int:
    negative = sign(a)
    exp = exponent(a)
    frac = fraction_field(a)
    if is_inf(a):
        return 1 << (0 if negative else 7)
    if is_nan(a):
        return 1 << (8 if is_snan(a) else 9)
    if is_zero(a):
        return 1 << (3 if negative else 4)
    if exp == 0:
        return 1 << (2 if negative else 5)
    return 1 << (1 if negative else 6)


def exact_zero_sign(lhs_zero: bool, lhs_sign: int, rhs_zero: bool, rhs_sign: int, rm: int) -> bool:
    if lhs_zero and rhs_zero and lhs_sign == rhs_sign:
        return bool(lhs_sign)
    return rm == RDN


def add_sub(a: int, b: int, subtract: bool, rm: int) -> tuple[int, int]:
    sign_a = sign(a)
    sign_b = sign(b) ^ int(subtract)
    if is_nan(a) or is_nan(b):
        return CANONICAL_NAN, NV if is_snan(a) or is_snan(b) else 0
    if is_inf(a) and is_inf(b) and sign_a != sign_b:
        return CANONICAL_NAN, NV
    if is_inf(a):
        return (sign_a << 31) | 0x7F800000, 0
    if is_inf(b):
        return (sign_b << 31) | 0x7F800000, 0
    rhs = -finite_fraction(b) if subtract else finite_fraction(b)
    value = finite_fraction(a) + rhs
    zero_negative = exact_zero_sign(is_zero(a), sign_a, is_zero(b), sign_b, rm)
    return round_binary32(value, rm, zero_negative)


def multiply(a: int, b: int, rm: int) -> tuple[int, int]:
    result_sign = sign(a) ^ sign(b)
    if is_nan(a) or is_nan(b):
        return CANONICAL_NAN, NV if is_snan(a) or is_snan(b) else 0
    if (is_inf(a) and is_zero(b)) or (is_zero(a) and is_inf(b)):
        return CANONICAL_NAN, NV
    if is_inf(a) or is_inf(b):
        return (result_sign << 31) | 0x7F800000, 0
    if is_zero(a) or is_zero(b):
        return result_sign << 31, 0
    return round_binary32(finite_fraction(a) * finite_fraction(b), rm)


def divide(a: int, b: int, rm: int) -> tuple[int, int]:
    result_sign = sign(a) ^ sign(b)
    if is_nan(a) or is_nan(b):
        return CANONICAL_NAN, NV if is_snan(a) or is_snan(b) else 0
    if (is_zero(a) and is_zero(b)) or (is_inf(a) and is_inf(b)):
        return CANONICAL_NAN, NV
    if is_inf(a):
        return (result_sign << 31) | 0x7F800000, 0
    if is_inf(b):
        return result_sign << 31, 0
    if is_zero(b):
        return (result_sign << 31) | 0x7F800000, DZ
    if is_zero(a):
        return result_sign << 31, 0
    return round_binary32(finite_fraction(a) / finite_fraction(b), rm)


def fused(a: int, b: int, c: int, negate_product: bool, negate_c: bool, rm: int) -> tuple[int, int]:
    product_sign = sign(a) ^ sign(b) ^ int(negate_product)
    c_sign = sign(c) ^ int(negate_c)
    invalid_product = (is_inf(a) and is_zero(b)) or (is_zero(a) and is_inf(b))
    if is_nan(a) or is_nan(b) or is_nan(c):
        invalid = invalid_product or is_snan(a) or is_snan(b) or is_snan(c)
        return CANONICAL_NAN, NV if invalid else 0
    if invalid_product:
        return CANONICAL_NAN, NV
    if (is_inf(a) or is_inf(b)) and is_inf(c) and product_sign != c_sign:
        return CANONICAL_NAN, NV
    if is_inf(a) or is_inf(b):
        return (product_sign << 31) | 0x7F800000, 0
    if is_inf(c):
        return (c_sign << 31) | 0x7F800000, 0

    product = finite_fraction(a) * finite_fraction(b)
    addend = finite_fraction(c)
    if negate_product:
        product = -product
    if negate_c:
        addend = -addend
    value = product + addend
    product_zero = is_zero(a) or is_zero(b)
    zero_negative = exact_zero_sign(product_zero, product_sign, is_zero(c), c_sign, rm)
    return round_binary32(value, rm, zero_negative)


def execute(operation: int, rm: int, a: int, b: int, c: int) -> tuple[int, int]:
    if operation == OP_ADD:
        return add_sub(a, b, False, rm)
    if operation == OP_SUB:
        return add_sub(a, b, True, rm)
    if operation == OP_MUL:
        return multiply(a, b, rm)
    if operation == OP_DIV:
        return divide(a, b, rm)
    if operation == OP_FMADD:
        return fused(a, b, c, False, False, rm)
    if operation == OP_FMSUB:
        return fused(a, b, c, False, True, rm)
    if operation == OP_FNMSUB:
        return fused(a, b, c, True, False, rm)
    if operation == OP_FNMADD:
        return fused(a, b, c, True, True, rm)
    if operation == OP_SQRT:
        return square_root(a, rm)
    if operation == OP_FSGNJ:
        return (a & 0x7FFFFFFF) | (b & 0x80000000), 0
    if operation == OP_FSGNJN:
        return (a & 0x7FFFFFFF) | ((~b) & 0x80000000), 0
    if operation == OP_FSGNJX:
        return (a & 0x7FFFFFFF) | ((a ^ b) & 0x80000000), 0
    if operation == OP_FMIN:
        return min_max(a, b, False)
    if operation == OP_FMAX:
        return min_max(a, b, True)
    if operation in (OP_FEQ, OP_FLT, OP_FLE):
        return compare(a, b, operation)
    if operation == OP_FCVT_W_S:
        return fp_to_integer(a, False, rm)
    if operation == OP_FCVT_WU_S:
        return fp_to_integer(a, True, rm)
    if operation == OP_FCVT_S_W:
        return integer_to_fp(a, False, rm)
    if operation == OP_FCVT_S_WU:
        return integer_to_fp(a, True, rm)
    if operation == OP_FCLASS:
        return classify(a), 0
    if operation in (OP_FMV_X_W, OP_FMV_W_X):
        return a, 0
    raise ValueError(f"unsupported operation {operation}")


SPECIAL = [
    0x00000000, 0x80000000,
    0x00000001, 0x80000001, 0x007FFFFF, 0x807FFFFF,
    0x00800000, 0x80800000, 0x3F000000, 0xBF000000,
    0x3F800000, 0xBF800000, 0x40000000, 0xC0000000,
    0x7F7FFFFF, 0xFF7FFFFF, 0x7F800000, 0xFF800000,
    0x7FC00001, 0xFFC12345, 0x7F800001, 0xFF800001,
]

INT_SPECIAL = [
    0x00000000, 0x00000001, 0x00000002, 0x007FFFFF,
    0x00800000, 0x00FFFFFF, 0x01000000, 0x01000001,
    0x3FFFFFFF, 0x40000000, 0x7FFFFFFE, 0x7FFFFFFF,
    0x80000000, 0x80000001, 0xFFFFFFFE, 0xFFFFFFFF,
]


def random_finite(rng: random.Random) -> int:
    exp = rng.choice([0, 0, 1, 2, 3, 16, 63, 126, 127, 128, 190, 252, 253, 254, rng.randrange(255)])
    frac = rng.getrandbits(23)
    if exp == 0 and rng.randrange(8) == 0:
        frac = 0
    return (rng.getrandbits(1) << 31) | (exp << 23) | frac


def build_vectors(seed: int, random_per_op_rm: int) -> list[tuple[int, int, int, int, int, int, int]]:
    rng = random.Random(seed)
    vectors: list[tuple[int, int, int, int, int, int, int]] = []
    operations = range(24)

    for operation in operations:
        uses_rounding = operation <= OP_SQRT or OP_FCVT_W_S <= operation <= OP_FCVT_S_WU
        integer_source = operation in (OP_FCVT_S_W, OP_FCVT_S_WU, OP_FMV_W_X)
        rounding_modes = range(5) if uses_rounding else (RNE,)
        operand_values = INT_SPECIAL if integer_source else SPECIAL
        for rm in rounding_modes:
            for index, a in enumerate(operand_values):
                b = SPECIAL[(index * 7 + operation * 3 + rm) % len(SPECIAL)]
                c = SPECIAL[(index * 11 + operation + rm * 5) % len(SPECIAL)]
                expected, flags = execute(operation, rm, a, b, c)
                vectors.append((operation, rm, a, b, c, expected, flags))
            for _ in range(random_per_op_rm):
                a = rng.getrandbits(32) if integer_source else random_finite(rng)
                b = random_finite(rng)
                c = random_finite(rng)
                expected, flags = execute(operation, rm, a, b, c)
                vectors.append((operation, rm, a, b, c, expected, flags))
    return vectors


def corner_vectors() -> list[tuple[int, int, int, int, int, int, int]]:
    """Cross special classes and deliberately hit cancellation/rounding edges.

    Kept separate from the fast checked-in manifest so extended runs are opt-in.
    Expected results use the same exact rational oracle, not the RTL algorithm.
    """
    vectors = []

    def append(op: int, rm: int, a: int, b: int = 0, c: int = 0) -> None:
        result, flags = execute(op, rm, a, b, c)
        vectors.append((op, rm, a, b, c, result, flags))

    for op in (OP_ADD, OP_SUB, OP_MUL, OP_DIV, OP_FMIN, OP_FMAX,
               OP_FEQ, OP_FLT, OP_FLE):
        for rm in (range(5) if op <= OP_DIV else (RNE,)):
            for a in SPECIAL:
                for b in SPECIAL:
                    append(op, rm, a, b)

    # Include both zero signs, both infinity signs, signaling/quiet NaN,
    # smallest subnormal, largest finite, and ordinary positive/negative values.
    fma_classes = (0, 0x80000000, 1, 0x3F800000, 0xBF800000,
                   0x7F7FFFFF, 0x7F800000, 0xFF800000,
                   0x7FC00001, 0x7F800001)
    for op in range(OP_FMADD, OP_FNMADD + 1):
        for rm in range(5):
            for a in fma_classes:
                for b in fma_classes:
                    for c in fma_classes:
                        append(op, rm, a, b, c)

    for rm in range(5):
        # Adjacent values around zero, min-normal, half integers and integer
        # conversion saturation thresholds. Exercise both signs.
        for center in (1, 0x00800000, 0x3F000000, 0x3FC00000,
                       0x4B800000, 0x4F000000, 0x4F800000, 0x7F7FFFFF):
            for delta in range(-2, 3):
                for sign_bit in (0, 0x80000000):
                    a = max(0, center + delta) | sign_bit
                    for op in (OP_SQRT, OP_FCVT_W_S, OP_FCVT_WU_S):
                        append(op, rm, a)
        for exp in (1, 2, 24, 64, 126, 127, 128, 200, 253, 254):
            a = exp << 23
            for delta in (-1, 0, 1):
                b = (a + delta) ^ 0x80000000
                append(OP_ADD, rm, a, b)
                # FMA cancellation with an unrounded product residue.
                for op in range(OP_FMADD, OP_FNMADD + 1):
                    append(op, rm, a + 1, 0x3F800001, b)
        for a in (0x3F800000, 0x3F800001, 0xBF800000, 0xBF800001):
            for b in (0x337FFFFF, 0x33800000, 0x33800001):
                append(OP_ADD, rm, a, b)
                append(OP_SUB, rm, a, b)
    return vectors


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--output", type=Path, default=Path("tb/fixtures/fpu/fpu_diff_vectors.hex"))
    parser.add_argument("--seed", type=lambda value: int(value, 0), default=0x5EED1234)
    parser.add_argument("--random-per-op-rm", type=int, default=64)
    parser.add_argument("--corners", action="store_true",
                        help="add special-class cross products and rounding/conversion boundaries")
    parser.add_argument("--check", action="store_true", help="fail if the checked-in vector file is stale")
    args = parser.parse_args()

    assert add_sub(0x00000000, 0x00000000, False, RDN) == (0x00000000, 0)
    assert add_sub(0x00000000, 0x80000000, False, RDN) == (0x80000000, 0)
    assert fused(0x7F7FFFFF, 0x00000000, 0x007FFFFF, False, False, RNE) == (0x007FFFFF, 0)
    assert multiply(0x00000001, 0x3F000000, RNE) == (0x00000000, UF | NX)
    assert multiply(0x00000001, 0x3F000000, RUP) == (0x00000001, UF | NX)
    assert divide(0x3F800000, 0x00000000, RNE) == (0x7F800000, DZ)
    assert square_root(0x40800000, RNE) == (0x40000000, 0)
    assert square_root(0xBF800000, RNE) == (CANONICAL_NAN, NV)
    assert fp_to_integer(0x40600000, False, RNE) == (4, NX)
    assert fp_to_integer(0xBF000000, True, RTZ) == (0, NX)
    assert integer_to_fp(0xFFFFFFFF, True, RNE) == (0x4F800000, NX)
    assert min_max(0x00000000, 0x80000000, False) == (0x80000000, 0)
    assert classify(0x7F800001) == 0x100

    vectors = build_vectors(args.seed, args.random_per_op_rm)
    if args.corners:
        vectors.extend(corner_vectors())
    content = "".join(
        f"{operation:x} {rm:x} {a:08x} {b:08x} {c:08x} {expected:08x} {flags:02x}\n"
        for operation, rm, a, b, c, expected, flags in vectors
    )
    if args.check:
        if not args.output.is_file() or args.output.read_text(encoding="ascii") != content:
            raise SystemExit(
                f"stale FPU vectors: regenerate with {Path(__file__).name} --output {args.output}"
            )
        print(f"verified {len(vectors)} exact RV32F vectors: {args.output}")
    else:
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(content, encoding="ascii", newline="\n")
        print(f"generated {len(vectors)} exact RV32F vectors: {args.output}")


if __name__ == "__main__":
    main()
