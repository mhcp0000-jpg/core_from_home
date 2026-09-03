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
5.050으로 실행했다. `SYNTHESIS`를 정의하지 않아 RTL assertion을 활성화했으며,
time-zero 4-state assertion guard와 IFU/dual-LSU stalled-request hold 수정 이후의
결과다.

```text
80020000 D tohost
80020008 D fromhost
80020010 d syscall_block
[BOOTROM][0] loading hex file: tb/fixtures/bootrom/bootrom_host_jump.hex
[BOOTROM][0] hex loaded: word[0]=02028293000012b7 word[1]=0080029330529073 depth=512
[TB][255] Boot ROM WFI retired: lane=0 pc=0x00001018
[HOST-DPI][255] Boot ROM WFI observed; starting ELF load
[HOST-DPI][255] ELF parsed: entry=0x80000000 segments=2
[HOST-DPI][930] segment[0] complete
[HOST-DPI][1130] segment[1] complete
[TB][1205] boot mailbox ready: entry=0x80000000 flags=0x00000001
[TB][1255] CLINT MSIP asserted; software interrupt is pending
[HOST-DPI][1280] CLINT MSIP write acknowledged
[TB][1385] CLINT MSIP cleared by Boot ROM handler
HTIF direct-string print PASS
HTIF proxy write syscall PASS
[host-finish code=0]
HTIF TEST PASS
```

결론: direct string, proxy write, FROMHOST acknowledgement와 TOHOST=1 종료가 모두
정상 동작했고 실행 중 assertion failure가 없었다. 전체 directed regression도
RV32IMF/RV32C/M-U privilege ELF의 architectural trace까지 통과했다. 개발 PC에는
회사 `verilog_sub`/Xcelium이 없으므로 같은 filelist와 DPI shared library의 실제
Cadence 4-state 실행은 Linux 서버에서 최종 교차 확인한다.

2026-09-03에는 Xcelium 정지 위치를 식별할 수 있도록 위 startup/ELF/MSIP 진단 로그를
추가한 뒤 같은 HTIF smoke ELF를 다시 실행했다. RTL parse/elaboration과 최종 HTIF
PASS가 유지됐으며, 16 KiB 단위 ELF 진행률 및 100,000-cycle heartbeat도 지원한다.
