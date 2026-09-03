  .section .text.init
  .globl _start
_start:
  la    t0, tohost
  la    t1, direct_message

  # Bare-metal print request: TOHOST receives a NUL-terminated string address.
  sw    t1, 0(t0)
  sw    zero, 4(t0)

1:
  la    t2, fromhost
  lw    t3, 0(t2)
  beqz  t3, 1b
  sw    zero, 0(t2)
  sw    zero, 4(t2)

  # Standard HTIF proxy syscall request: the request block starts with
  # write(1, proxy_message, proxy_message_size).
  la    t1, syscall_block
  sw    t1, 0(t0)
  sw    zero, 4(t0)
3:
  lw    t3, 0(t2)
  beqz  t3, 3b
  sw    zero, 0(t2)
  sw    zero, 4(t2)

  # Minimal riscv-tests convention: TOHOST=1 means PASS and finish.
  li    t3, 1
  sw    t3, 0(t0)
  sw    zero, 4(t0)
2:
  wfi
  j     2b

  .section .rodata
direct_message:
  .asciz "HTIF direct-string print PASS\n"
proxy_message:
  .ascii "HTIF proxy write syscall PASS\n"
proxy_message_end:

  .section .htif,"aw",@progbits
  .balign 8
  .globl tohost
tohost:
  .dword 0
  .globl fromhost
fromhost:
  .dword 0
  .balign 8
syscall_block:
  .dword 64
  .dword 1
  .dword proxy_message
  .dword proxy_message_end - proxy_message
