/*
 * CoreMark timing and result transport for this core's freestanding RV32 SoC.
 * Upstream CoreMark remains unmodified; ee_printf is reduced to structured
 * HostIF telemetry so simulation does not spend cycles formatting text.
 */
#include <stdarg.h>
#include "coremark.h"

#define HOSTIF_BASE_ADDR 0x10000000u
#define HOSTIF_TOHOST_OFF 0x0cu
#define HOSTIF_EXIT_CODE_OFF 0x14u

#define RESULT_MAGIC 0x434d0001u /* "CM", protocol version 1 */
#define PERF_START_MAGIC 0x50460001u /* "PF", begin profiling window */
#define PERF_STOP_MAGIC  0x50460002u /* "PF", end profiling window */

#define STATUS_KNOWN_2K_PERFORMANCE (1u << 0)
#define STATUS_CRC_ERROR            (1u << 1)
#define STATUS_DATATYPE_ERROR       (1u << 2)
#define STATUS_SHORT_RUN            (1u << 3)
#define STATUS_PORT_ERROR           (1u << 4)

#ifndef ITERATIONS
#define ITERATIONS 2
#endif

volatile ee_s32 seed1_volatile = 0;
volatile ee_s32 seed2_volatile = 0;
volatile ee_s32 seed3_volatile = 0x66;
volatile ee_s32 seed4_volatile = ITERATIONS;
volatile ee_s32 seed5_volatile = 0;

ee_u32 default_num_contexts = 1;

static CORE_TICKS start_cycle;
static CORE_TICKS stop_cycle;
static CORE_TICKS start_instret;
static CORE_TICKS stop_instret;

static ee_u32 result_status;
static ee_u32 result_seedcrc;
static ee_u32 result_crclist;
static ee_u32 result_crcmatrix;
static ee_u32 result_crcstate;
static ee_u32 result_crcfinal;

static void host_send(ee_u32 value);

static CORE_TICKS read_mcycle64(void) {
  ee_u32 hi_before, lo, hi_after;
  do {
    __asm__ volatile("csrr %0, mcycleh" : "=r"(hi_before));
    __asm__ volatile("csrr %0, mcycle" : "=r"(lo));
    __asm__ volatile("csrr %0, mcycleh" : "=r"(hi_after));
  } while (hi_before != hi_after);
  return ((CORE_TICKS)hi_after << 32) | lo;
}

static CORE_TICKS read_minstret64(void) {
  ee_u32 hi_before, lo, hi_after;
  do {
    __asm__ volatile("csrr %0, minstreth" : "=r"(hi_before));
    __asm__ volatile("csrr %0, minstret" : "=r"(lo));
    __asm__ volatile("csrr %0, minstreth" : "=r"(hi_after));
  } while (hi_before != hi_after);
  return ((CORE_TICKS)hi_after << 32) | lo;
}

void start_time(void) {
  host_send(PERF_START_MAGIC);
  start_instret = read_minstret64();
  start_cycle = read_mcycle64();
}

void stop_time(void) {
  stop_cycle = read_mcycle64();
  stop_instret = read_minstret64();
  host_send(PERF_STOP_MAGIC);
}

CORE_TICKS get_time(void) { return stop_cycle - start_cycle; }

/* A nominal 100 MHz is used only by CoreMark's mandatory duration warning.
 * The runner computes frequency-independent CoreMark/MHz from raw cycles. */
secs_ret time_in_secs(CORE_TICKS ticks) {
  return (secs_ret)(ticks / 100000000ull);
}

static int str_equal(const char *a, const char *b) {
  while (*a && (*a == *b)) {
    ++a;
    ++b;
  }
  return *a == *b;
}

static int starts_with(const char *text, const char *prefix) {
  while (*prefix) {
    if (*text++ != *prefix++) return 0;
  }
  return 1;
}

/* Capture exactly the fields needed by the host-side report. */
int ee_printf(const char *fmt, ...) {
  va_list args;
  va_start(args, fmt);

  if (str_equal(fmt, "2K performance run parameters for coremark.\n")) {
    result_status |= STATUS_KNOWN_2K_PERFORMANCE;
  } else if (starts_with(fmt, "ERROR! Must execute for at least 10 secs")) {
    result_status |= STATUS_SHORT_RUN;
  } else if (starts_with(fmt, "ERROR: ee_") ||
             starts_with(fmt, "ERROR: Please modify the datatypes")) {
    result_status |= STATUS_DATATYPE_ERROR;
  } else if (starts_with(fmt, "[%u]ERROR! list crc")) {
    result_status |= STATUS_CRC_ERROR;
  } else if (starts_with(fmt, "[%u]ERROR! matrix crc")) {
    result_status |= STATUS_CRC_ERROR;
  } else if (starts_with(fmt, "[%u]ERROR! state crc")) {
    result_status |= STATUS_CRC_ERROR;
  } else if (str_equal(fmt, "seedcrc          : 0x%04x\n")) {
    result_seedcrc = (ee_u32)va_arg(args, int);
  } else if (str_equal(fmt, "[%d]crclist       : 0x%04x\n")) {
    (void)va_arg(args, int);
    result_crclist = (ee_u32)va_arg(args, int);
  } else if (str_equal(fmt, "[%d]crcmatrix     : 0x%04x\n")) {
    (void)va_arg(args, int);
    result_crcmatrix = (ee_u32)va_arg(args, int);
  } else if (str_equal(fmt, "[%d]crcstate      : 0x%04x\n")) {
    (void)va_arg(args, int);
    result_crcstate = (ee_u32)va_arg(args, int);
  } else if (str_equal(fmt, "[%d]crcfinal      : 0x%04x\n")) {
    (void)va_arg(args, int);
    result_crcfinal = (ee_u32)va_arg(args, int);
  }

  va_end(args);
  return 0;
}

void portable_init(core_portable *p, int *argc, char *argv[]) {
  (void)argc;
  (void)argv;
  result_status = 0;
  if ((sizeof(ee_ptr_int) != sizeof(ee_u8 *)) || (sizeof(ee_u32) != 4))
    result_status |= STATUS_PORT_ERROR;
  p->portable_id = 1;
}

static void host_send(ee_u32 value) {
  *(volatile ee_u32 *)(ee_ptr_int)(HOSTIF_BASE_ADDR + HOSTIF_TOHOST_OFF) = value;
}

void portable_fini(core_portable *p) {
  CORE_TICKS cycles = stop_cycle - start_cycle;
  CORE_TICKS instructions = stop_instret - start_instret;
  ee_u32 fatal = result_status &
                 (STATUS_CRC_ERROR | STATUS_DATATYPE_ERROR | STATUS_PORT_ERROR);

  p->portable_id = 0;
  host_send(RESULT_MAGIC);
  host_send((ee_u32)ITERATIONS);
  host_send((ee_u32)cycles);
  host_send((ee_u32)(cycles >> 32));
  host_send((ee_u32)instructions);
  host_send((ee_u32)(instructions >> 32));
  host_send(result_seedcrc);
  host_send(result_crclist);
  host_send(result_crcmatrix);
  host_send(result_crcstate);
  host_send(result_crcfinal);
  host_send(result_status);

  *(volatile ee_u32 *)(ee_ptr_int)(HOSTIF_BASE_ADDR + HOSTIF_EXIT_CODE_OFF) =
      (fatal == 0u && (result_status & STATUS_KNOWN_2K_PERFORMANCE)) ? 0u : 1u;
}

void *portable_malloc(ee_size_t size) {
  (void)size;
  return NULL;
}

void portable_free(void *p) { (void)p; }
