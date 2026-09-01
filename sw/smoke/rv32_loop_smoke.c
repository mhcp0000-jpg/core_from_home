#include <stdint.h>

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

  for (uint32_t i = 0; i < ELEMENT_COUNT; ++i) {
    const int32_t scaled = integer_input[i] * (int32_t)(i + 1u) + 5;
    integer_output[i] = scaled;
    integer_sum += integer_output[i];

    const float mixed = fp_input[i] * 1.5f + (float)scaled;
    fp_output[i] = mixed;
    fp_sum += fp_output[i];
  }

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

  result_signature.integer_sum = integer_sum;
  result_signature.fp_sum = fp_sum;
  result_signature.integer_last = integer_output[ELEMENT_COUNT - 1];
  result_signature.fp_last = fp_output[ELEMENT_COUNT - 1];
  result_signature.mismatch_mask = mismatch;

  /* 158 (0x009e) and 185 (0x00b9) form an externally checked signature. */
  volatile uint32_t *const hostif =
    (volatile uint32_t *)(uintptr_t)HOSTIF_BASE_ADDR;
  hostif[HOSTIF_TOHOST_INDEX] =
    ((uint32_t)integer_sum << 16) | ((uint32_t)fp_sum & 0xffffu);

  return mismatch == 0u ? 0 : 1;
}
