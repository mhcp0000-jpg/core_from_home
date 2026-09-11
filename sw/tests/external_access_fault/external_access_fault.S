  .section .text.init
  .globl _start
_start:
  la    t0, trap_handler
  csrw  mtvec, t0
  li    s0, 0

  # Aligned addresses outside every SoC decode window must complete with an
  # AXI DECERR and become precise access faults, rather than hanging the ROB.
  li    t0, -56                 # 0xffff_ffc8
aligned_load:
  lw    t1, 0(t0)              # expected mcause=5

  li    t0, -56
aligned_store:
  sw    zero, 0(t0)            # expected mcause=7

  # Misalignment has priority over address decoding. These operations must
  # trap in the LSU before any D-fabric/AXI transaction is emitted.
  li    t0, -53                 # 0xffff_ffcb
misaligned_load:
  lw    t1, 0(t0)              # expected mcause=4

  li    t0, -53
misaligned_store:
  sw    zero, 0(t0)            # expected mcause=6

  # The same odd address is legal for byte accesses. It must therefore reach
  # the default error slave and return access fault, not misalignment.
  li    t0, -53
unmapped_byte_load:
  lbu   t1, 0(t0)              # expected mcause=5

  li    t0, -53
unmapped_byte_store:
  sb    zero, 0(t0)            # expected mcause=7

  li    t0, 6
  bne   s0, t0, test_fail

test_pass:
  li    t0, 0x80020000         # TOHOST
  li    t1, 1
  sw    t1, 0(t0)
1:
  wfi
  j     1b

test_fail:
  li    t0, 0x80020000
  li    t1, 3                  # standard HTIF odd failure code
  sw    t1, 0(t0)
2:
  wfi
  j     2b

  .balign 4
trap_handler:
  csrr  t1, mcause
  csrr  t2, mtval

  beqz  s0, check_aligned_load
  li    t3, 1
  beq   s0, t3, check_aligned_store
  li    t3, 2
  beq   s0, t3, check_misaligned_load
  li    t3, 3
  beq   s0, t3, check_misaligned_store
  li    t3, 4
  beq   s0, t3, check_byte_load
  li    t3, 5
  beq   s0, t3, check_byte_store
  j     test_fail

check_aligned_load:
  li    t3, 5
  bne   t1, t3, test_fail
  li    t3, -56
  bne   t2, t3, test_fail
  j     trap_ok

check_aligned_store:
  li    t3, 7
  bne   t1, t3, test_fail
  li    t3, -56
  bne   t2, t3, test_fail
  j     trap_ok

check_misaligned_load:
  li    t3, 4
  bne   t1, t3, test_fail
  li    t3, -53
  bne   t2, t3, test_fail
  j     trap_ok

check_misaligned_store:
  li    t3, 6
  bne   t1, t3, test_fail
  li    t3, -53
  bne   t2, t3, test_fail
  j     trap_ok

check_byte_load:
  li    t3, 5
  bne   t1, t3, test_fail
  li    t3, -53
  bne   t2, t3, test_fail
  j     trap_ok

check_byte_store:
  li    t3, 7
  bne   t1, t3, test_fail
  li    t3, -53
  bne   t2, t3, test_fail

trap_ok:
  addi  s0, s0, 1
  csrr  t0, mepc
  addi  t0, t0, 4
  csrw  mepc, t0
  mret

  .section .htif,"aw",@progbits
  .balign 8
  .globl tohost
tohost:
  .dword 0
  .globl fromhost
fromhost:
  .dword 0
