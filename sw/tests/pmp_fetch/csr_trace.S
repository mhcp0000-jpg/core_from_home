.section .text.init,"ax",@progbits
.option norvc
.option norelax
.globl _start
_start:
  la t0, handler
  csrw mtvec,t0
  li t0,0x12
  li t1,1
check_rw: csrrw a0,mscratch,t0
check_rs: csrrs a1,mscratch,t1
check_rc: csrrc a2,mscratch,t1
check_rwi: csrrwi a3,mscratch,5
check_rsi: csrrsi a4,mscratch,2
check_rci: csrrci a5,mscratch,1
check_read: csrrs a6,mscratch,zero
check_nord: csrrw zero,mscratch,zero
check_readi: csrrsi a7,mscratch,0
check_illegal: csrrw a0,cycle,t0
1: j 1b
.balign 16
handler:
  lui t0,0x80020
  li t1,1
  sw t1,0(t0)
2: j 2b
.section .htif,"aw",@progbits
.balign 8
.globl tohost
tohost: .dword 0
.globl fromhost
fromhost: .dword 0
