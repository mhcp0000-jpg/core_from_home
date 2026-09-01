/* RV32 TIM/HostIF port for the upstream EEMBC CoreMark sources. */
#ifndef CORE_PORTME_H
#define CORE_PORTME_H

#define HAS_FLOAT 0
#define HAS_TIME_H 0
#define USE_CLOCK 0
#define HAS_STDIO 0
#define HAS_PRINTF 0

#define COMPILER_VERSION "GCC " __VERSION__
#ifndef FLAGS_STR
#define FLAGS_STR "-O2 -march=rv32imc_zicsr_zifencei -mabi=ilp32"
#endif
#define COMPILER_FLAGS FLAGS_STR
#define MEM_LOCATION "ITIM code / DTIM static data (1:1 core-local)"

typedef signed char ee_s8;
typedef unsigned char ee_u8;
typedef signed short ee_s16;
typedef unsigned short ee_u16;
typedef signed int ee_s32;
typedef unsigned int ee_u32;
typedef ee_u32 ee_ptr_int;
typedef ee_u32 ee_size_t;
typedef ee_u32 ee_f32;

#ifndef NULL
#define NULL ((void *)0)
#endif

#define align_mem(x) (void *)(4 + (((ee_ptr_int)(x) - 1) & ~3u))

/* mcycle is 64-bit even on RV32, avoiding practical benchmark wraparound. */
#define CORETIMETYPE unsigned long long
typedef unsigned long long CORE_TICKS;

#ifndef SEED_METHOD
#define SEED_METHOD SEED_VOLATILE
#endif
#ifndef MEM_METHOD
#define MEM_METHOD MEM_STATIC
#endif
#ifndef MULTITHREAD
#define MULTITHREAD 1
#endif
#define USE_PTHREAD 0
#define USE_FORK 0
#define USE_SOCKET 0

#ifndef MAIN_HAS_NOARGC
#define MAIN_HAS_NOARGC 1
#endif
#ifndef MAIN_HAS_NORETURN
#define MAIN_HAS_NORETURN 0
#endif

extern ee_u32 default_num_contexts;

typedef struct CORE_PORTABLE_S {
  ee_u8 portable_id;
} core_portable;

void portable_init(core_portable *p, int *argc, char *argv[]);
void portable_fini(core_portable *p);
int ee_printf(const char *fmt, ...);

#endif
