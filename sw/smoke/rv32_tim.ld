OUTPUT_ARCH(riscv)
ENTRY(_start)

MEMORY
{
  /* Default package map: executable/constant data in ITIM, mutable state in
     DTIM.  Both regions are loaded from ELF PT_LOAD segments by the DPI host. */
  ITIM (rx)  : ORIGIN = 0x80000000, LENGTH = 128K
  DTIM (rwx) : ORIGIN = 0x80020000, LENGTH = 128K
}

SECTIONS
{
  .text : ALIGN(4)
  {
    /* _start must remain first because the Boot ROM mtvec/entry is ITIM base. */
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
    /* The ELF loader zero-fills PT_LOAD memsz-filesz for this NOLOAD range. */
    __bss_start = .;
    *(.sbss .sbss.*)
    *(.bss .bss.*)
    *(COMMON)
    __bss_end = .;
  } > DTIM

  /* Reserve the final 16 bytes and keep the initial stack naturally aligned. */
  __stack_top = ORIGIN(DTIM) + LENGTH(DTIM) - 16;

  /DISCARD/ :
  {
    *(.comment)
    *(.note*)
    *(.eh_frame*)
  }
}
