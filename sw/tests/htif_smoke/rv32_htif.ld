OUTPUT_ARCH(riscv)
ENTRY(_start)

MEMORY
{
  ITIM (rx)  : ORIGIN = 0x80000000, LENGTH = 128K
  DTIM (rwx) : ORIGIN = 0x80020000, LENGTH = 128K
}

SECTIONS
{
  .text : ALIGN(16)
  {
    *(.text.init)
    *(.text .text.*)
    *(.rodata .rodata.*)
  } > ITIM

  .htif ORIGIN(DTIM) : ALIGN(8)
  {
    KEEP(*(.htif))
  } > DTIM

  ASSERT(tohost == 0x80020000, "tohost address mismatch")
  ASSERT(fromhost == 0x80020008, "fromhost address mismatch")

  .data : ALIGN(16)
  {
    *(.sdata .sdata.*)
    *(.data .data.*)
  } > DTIM

  .bss (NOLOAD) : ALIGN(16)
  {
    *(.sbss .sbss.*)
    *(.bss .bss.*)
    *(COMMON)
  } > DTIM

  __stack_top = ORIGIN(DTIM) + LENGTH(DTIM) - 16;
}
