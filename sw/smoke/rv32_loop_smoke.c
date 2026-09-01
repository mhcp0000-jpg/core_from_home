#include <stdint.h>

/*
 * Compiler-driven end-to-end smoke test for the default SoC address map.
 *
 * This is intentionally freestanding: there is no C runtime or libc.  The
 * startup assembly supplies the stack, calls main(), and reports its return
 * value through HostIF.  Volatile DTIM arrays prevent GCC from replacing the
 * loop with constants, so the generated ELF must exercise both LSU paths.
 */
#define HOSTIF_BASE_ADDR 0x10000000u
#define HOSTIF_TOHOST_INDEX 3u

enum { ELEMENT_COUNT = 8 };

/* Volatile arrays force the generated program to exercise DTIM loads/stores. */
static volatile int32_t integer_input[ELEMENT_COUNT] = {
  3, -2, 7, 4, -1, 6, 5, 2
};
static volatile float fp_input[ELEMENT_COUNT] = {
  0.5f, 1.0f, 1.5f, 2.0f, 2.5f, 3.0f, 3.5f, 4.0f
};
static volatile int32_t integer_output[ELEMENT_COUNT];
static volatile float fp_output[ELEMENT_COUNT];

static const int32_t expected_integer[ELEMENT_COUNT] = {
  8, 1, 26, 21, 0, 41, 40, 21
};
static const float expected_fp[ELEMENT_COUNT] = {
  8.75f, 2.5f, 28.25f, 24.0f, 3.75f, 45.5f, 45.25f, 27.0f
};

typedef struct {
  int32_t integer_sum;
  float fp_sum;
  int32_t integer_last;
  float fp_last;
  uint32_t mismatch_mask;
} result_signature_t;

volatile result_signature_t result_signature;

int main(void) {
  int32_t integer_sum = 0;
  float fp_sum = 0.0f;

  /*
   * Per iteration:
   *   scaled = integer_input[i] * (i + 1) + 5
   *   mixed  = fp_input[i] * 1.5f + (float)scaled
   *
   * Reading each output back immediately makes a store/load dependency part
   * of the architectural result instead of merely generating dead stores.
   */
  for (uint32_t i = 0; i < ELEMENT_COUNT; ++i) {
    const int32_t scaled = integer_input[i] * (int32_t)(i + 1u) + 5;
    integer_output[i] = scaled;
    integer_sum += integer_output[i];

    const float mixed = fp_input[i] * 1.5f + (float)scaled;
    fp_output[i] = mixed;
    fp_sum += fp_output[i];
  }

  /* Every mismatch owns one bit, allowing a failing ELF to identify whether
   * an integer element, FP element, or final reduction was incorrect. */
  uint32_t mismatch = 0;
  for (uint32_t i = 0; i < ELEMENT_COUNT; ++i) {
    if (integer_output[i] != expected_integer[i]) {
      mismatch |= 1u << i;
    }
    if (fp_output[i] != expected_fp[i]) {
      mismatch |= 1u << (i + 8u);
    }
  }
  if (integer_sum != 158) {
    mismatch |= 1u << 16;
  }
  if (fp_sum != 185.0f) {
    mismatch |= 1u << 17;
  }

  /* Keep a debugger-readable result block in DTIM even on a failing run. */
  result_signature.integer_sum = integer_sum;
  result_signature.fp_sum = fp_sum;
  result_signature.integer_last = integer_output[ELEMENT_COUNT - 1];
  result_signature.fp_last = fp_output[ELEMENT_COUNT - 1];
  result_signature.mismatch_mask = mismatch;

  /*
   * HostIF +0x0c (TOHOST): 158 (0x009e) and 185 (0x00b9) form the externally
   * checked signature 0x009e00b9.  _start later writes main's return value to
   * HostIF +0x14 (EXIT_CODE), so both data correctness and program completion
   * are checked independently by the testbench.
   */
  volatile uint32_t *const hostif =
    (volatile uint32_t *)(uintptr_t)HOSTIF_BASE_ADDR;
  hostif[HOSTIF_TOHOST_INDEX] =
    ((uint32_t)integer_sum << 16) | ((uint32_t)fp_sum & 0xffffu);

  return mismatch == 0u ? 0 : 1;
}
