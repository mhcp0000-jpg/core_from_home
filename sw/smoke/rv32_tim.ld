OUTPUT_ARCH(riscv)
ENTRY(_start)

MEMORY
{
  ITIM (rx)  : ORIGIN = 0x80000000, LENGTH = 128K
  DTIM (rwx) : ORIGIN = 0x80020000, LENGTH = 128K
}

SECTIONS
{
  .text : ALIGN(4)
  {
    KEEP(*(.text.init))
    *(.text .text.*)
    *(.rodata .rodata.*)
  } > ITIM

  .data : ALIGN(16)
  {
    *(.sdata .sdata.*)
    *(.data .data.*)
  } > DTIM

  .bss (NOLOAD) : ALIGN(16)
  {
    __bss_start = .;
    *(.sbss .sbss.*)
    *(.bss .bss.*)
    *(COMMON)
    __bss_end = .;
  } > DTIM

  __stack_top = ORIGIN(DTIM) + LENGTH(DTIM) - 16;

  /DISCARD/ :
  {
    *(.comment)
    *(.note*)
    *(.eh_frame*)
  }
}
