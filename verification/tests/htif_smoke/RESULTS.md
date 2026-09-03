# RV32 HTIF DPI smoke result

목적은 서버용 DTIM mailbox 경로를 실제 ELF로 확인하는 것이다.

- ELF entry: `0x8000_0000`
- TOHOST: `0x8002_0000` (64-bit)
- FROMHOST: `0x8002_0008` (64-bit)
- print 1: TOHOST에 NUL-terminated string 주소 기록
- print 2: TOHOST에 proxy syscall block 주소 기록, `write(64)` 실행
- finish: TOHOST에 `1` 기록

입력은 `sw/tests/htif_smoke/htif_smoke.S`와 `rv32_htif.ld`이며 RV32IM_Zicsr
ELF로 빌드했다. ELF loader, Host AXI, Main Xbar, I/D inbound bridge, ITIM/DTIM,
Boot ROM entry jump와 HTIF polling을 포함하는 `rv_soc_htif_dpi_tb`를 Verilator
5.050으로 실행했다.

```text
80020000 D tohost
80020008 D fromhost
80020010 d syscall_block
HTIF direct-string print PASS
HTIF proxy write syscall PASS
[host-finish code=0]
HTIF TEST PASS
```

결론: direct string, proxy write, FROMHOST acknowledgement와 TOHOST=1 종료가 모두
정상 동작했다. 개발 PC에는 회사 `verilog_sub`/Xcelium이 없으므로 같은 filelist와
DPI shared library의 실제 Cadence 실행은 Linux 서버에서 확인한다.
