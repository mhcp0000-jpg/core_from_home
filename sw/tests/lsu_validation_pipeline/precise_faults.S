/* Self-checking RV32 validation-completion regression, stock SoC addresses.
 * Six precise faults plus ordinary store/load, WFI and machine SW interrupt.
 * Host event at 0x1000000c; host exit at 0x10000014 (NOT HTIF tohost).
 * Requires default CLINT=0x02000000 and TIM linker rv32_tim.ld.
 * No compressed instructions: each exception handler advances mepc by four.
 */
  .section .text.init,"ax",@progbits
  .option norvc
  .option norelax
  .globl _start
_start:
  li t0,0x02000000
  sw zero,0(t0)
  la t0,handler
  csrw mtvec,t0
  li s0,0
  li s4,0
  # Locked NAPOT deny [0x80030000,0x80030100), including M mode.
  li t0,0x2000c01f
  csrw pmpaddr0,t0
  li t0,0x98
  csrw pmpcfg0,t0

  li s1,4
  li s2,0x80021001
  la s3,fault0
fault0:
  lw t6,0(s2)
  li s1,6
  li s2,0x80021003
  la s3,fault1
fault1:
  sw zero,0(s2)
  li s1,5
  li s2,0x80030000
  la s3,fault2
fault2:
  lw t6,0(s2)
  li s1,7
  li s2,0x80030004
  la s3,fault3
fault3:
  sw zero,0(s2)
  # Baseline policy: alignment wins over simultaneous PMP denial.
  li s1,4
  li s2,0x80030001
  la s3,fault4
fault4:
  lw t6,0(s2)
  li s1,6
  li s2,0x80030003
  la s3,fault5
fault5:
  sw zero,0(s2)
  li t0,6
  bne s0,t0,fail
  li t0,0x80031000
  li t1,0x55aa0011
  sw t1,0(t0)
  lw t2,0(t0)
  bne t1,t2,fail

  li s4,1
  li t0,8
  csrs mie,t0
  csrs mstatus,t0
  li t0,0x02000000
  li t1,1
  sw t1,0(t0)
  wfi
after_interrupt:
  li t0,7
  bne s0,t0,fail
  li t0,0x10000000
  li t1,0x56414c07
  sw t1,0x0c(t0)
  sw zero,0x14(t0)
1: wfi
  j 1b

  .balign 4
handler:
  csrr t0,mcause
  bnez s4,handle_interrupt
  csrr t1,mtval
  csrr t2,mepc
  bne t0,s1,fail
  bne t1,s2,fail
  bne t2,s3,fail
  addi s0,s0,1
  addi t2,t2,4
  csrw mepc,t2
  mret
handle_interrupt:
  li t1,0x80000003
  bne t0,t1,fail
  csrr t1,mtval
  bnez t1,fail
  # Require a real retired WFI return boundary, not an arbitrary interrupt PC.
  csrr t1,mepc
  la t2,after_interrupt
  bne t1,t2,fail
  li t0,0x02000000
  sw zero,0(t0)
  csrw mie,zero
  addi s0,s0,1
  mret
fail:
  li t0,0x10000000
  li t1,0xdead0001
  sw t1,0x0c(t0)
  li t1,1
  sw t1,0x14(t0)
2: wfi
  j 2b
