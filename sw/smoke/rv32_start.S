  .section .text.init, "ax", @progbits
  .option norvc
  .globl _start
  .type _start, @function
_start:
  lui   t0, 0x00200
  sw    zero, 0(t0)
  la    sp, __stack_top
  call  main
  lui   t0, 0x10000
  sw    a0, 0x14(t0)
1:
  wfi
  j     1b
  .size _start, .-_start
