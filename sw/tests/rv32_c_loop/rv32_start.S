  .section .text.init, "ax", @progbits
  .option norvc
  .globl _start
  .type _start, @function
_start:
  # The Boot ROM wakes this payload with CLINT MSIP asserted.  Clear it first
  # so the core does not immediately take the same machine interrupt again.
  lui   t0, 0x00200
  sw    zero, 0(t0)

  # No CRT is linked.  The linker script supplies the top of the DTIM stack;
  # main does not return until all integer/FP/LSU self-checks have completed.
  la    sp, __stack_top
  call  main

  # HostIF +0x14 is EXIT_CODE.  a0=0 means all C self-checks passed; a0=1
  # means result_signature.mismatch_mask contains at least one failing bit.
  lui   t0, 0x10000
  sw    a0, 0x14(t0)

  # Keep architectural behavior deterministic if a host does not terminate
  # immediately after consuming EXIT_CODE.
1:
  wfi
  j     1b
  .size _start, .-_start
