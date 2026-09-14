/* Directed reconstruction of server_debug/commit_trap_log.txt (2026-09-14).
 * Not the user's original riscv-dv ELF: initialization and data are controlled.
 * Keep reported PCs and raw instructions unchanged through 0x80000abc.
 */
.section .text.init
.option norvc
.option norelax
.globl _start
_start:
  li t0, 0x6000
  csrs mstatus, t0
  fmv.w.x ft3, zero
  fmv.w.x fs8, zero
  fmv.w.x ft2, zero
  li a4, 0x11
  li s10, 0x22
  li s7, 0x33
  li s3, 0x44
  j entry_jump
  .org 0x282
entry_jump:
  .word 0x7f20006f
  .org 0xa74
main:
  .word 0x0002d297
  .word 0xf6928293
  .word 0xf4d2d903
  .word 0xf4d2cd83
  .word 0x0a729203
  .word 0x0d628203
  .word 0x0d62cc83
  .word 0x1181c847
  .word 0x0ce28b23
  .word 0x3401d273
  .word 0x0d628583
  .word 0x0da28b23
  .word 0x01a254b3
  .word 0x0d62cc83
  .word 0x0d628683
  .word 0x0d728b23
  .word 0x0d328b23
  .word 0x00028097
  .word 0x56e08093
  li t1, 0x5a5a
  bne s2, t1, fail
  li t1, 0x5a
  bne s11, t1, fail
  li t1, 0x11
  bne a1, t1, fail
  li t1, 0x22
  bne s9, t1, fail
  bne a3, t1, fail
  li t0, 0x8002dab3
  lbu t1, 0(t0)
  li t2, 0x44
  bne t1, t2, fail
  li t1, 1
  j finish
fail:
  li t1, 3
finish:
  la t0, tohost
  sw zero, 4(t0)
  sw t1, 0(t0)
1: j 1b
.section .htif,"aw",@progbits
.balign 8
.globl tohost, fromhost
tohost: .dword 0
fromhost: .dword 0
.section .data
  /* .data begins at 0x80020010 with the shared HTIF linker script. */
  .fill 0xdb00, 1, 0x5a
