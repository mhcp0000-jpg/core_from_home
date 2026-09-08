/* Cached instruction authorization must not survive a PMP CSR write.
 * WARM=1 first executes victim; FLUSH=1 adds a software FENCE.I control.
 * A correctly enforced denial exits with HTIF code 1 intentionally.
 * Compare the commit trace: an exit code alone is not a test verdict.
 */
.section .text.init,"ax",@progbits
.option norvc
.option norelax
.globl _start
_start:
  la t0, handler
  csrw mtvec,t0
  li s0,0
#if WARM
  jal ra,victim
#else
  nop
#endif
  li t0,0x20000200
  csrw pmpaddr0,t0
  li t0,0x90
  csrw pmpcfg0,t0
#if FLUSH
  fence.i
#else
  nop
#endif
  jal ra,victim
  lui t0,0x80020
  li t1,1
  sw t1,0(t0)
1: j 1b
.org 0x200
handler:
  csrr s1,mcause
  csrr s2,mtval
  lui t0,0x80020
  li t1,3
  sw t1,0(t0)
2: j 2b
.org 0x800
victim:
  addi s0,s0,1
  ret
.section .htif,"aw",@progbits
.balign 8
.globl tohost
tohost: .dword 0
.globl fromhost
fromhost: .dword 0
