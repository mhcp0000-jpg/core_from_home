.section .text.init
.option norelax
.option norvc
.globl _start
_start:
  # PMP0 TOR=[0, 0x800008fc), RWX, unlocked.  Both halves of the
  # instruction at 0x800008fc are therefore unmatched M-mode accesses and
  # must succeed even though the 16-byte transport block begins at 0x...8f0.
  li t0, 0x2000023f
  csrw pmpaddr0, t0
  li t0, 0x0f
  csrw pmpcfg0, t0
  fence.i
  j boundary_entry

  .org 0x8fc
.globl boundary_entry
boundary_entry:
  lui s6, 0x80000
  lui t0, 0x80020
  addi t1, zero, 1
  sw zero, 4(t0)
  sw t1, 0(t0)
1:
  j 1b

.section .htif,"aw",@progbits
.balign 8
.globl tohost
tohost:
  .dword 0
.globl fromhost
fromhost:
  .dword 0
