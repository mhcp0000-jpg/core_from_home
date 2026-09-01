/* Default map. Configured projects regenerate this file automatically. */
#ifndef RV_SOC_MEMORY_MAP_H
#define RV_SOC_MEMORY_MAP_H
#define BOOTROM_BASE_ADDR 0x00001000u
#define BOOTROM_SIZE_KB 4u
#define CLINT_BASE_ADDR 0x00200000u
#define CLINT_SIZE_KB 64u
#define PLIC_BASE_ADDR 0x0c000000u
#define PLIC_SIZE_KB 4096u
#define HOSTIF_BASE_ADDR 0x10000000u
#define HOSTIF_SIZE_KB 4u
#define ITIM_BASE_ADDR 0x80000000u
#define ITIM_SIZE_KB 128u
#define DTIM_BASE_ADDR 0x80020000u
#define DTIM_SIZE_KB 128u
#define BOOT_MTVEC_ADDR 0x80000000u
#endif
