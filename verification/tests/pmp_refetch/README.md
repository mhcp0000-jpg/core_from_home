# PMP CSR commit 이후 refetch 회귀

2026-09-08. `sw/tests/pmp_fetch/protection_change.S`를 현재 RTL로 실행했다.
PMP 변경 전에 victim(0x80000800)을 실행해서 버퍼를 채운 뒤, 해당 4-byte를
locked NA4/X=0으로 바꾸고 다시 호출한다. 정상 결과는 두 번째 호출의
instruction access fault다. 예외 handler가 의도적으로 TOHOST=3(exit code 1)을
기록하므로 simulator의 `HTIF TEST FAIL code=1`만 보고 회귀 실패로 판정하면 안 된다.
아래 checker가 정확한 PC/cause/tval/실행 횟수/handler 진입을 검증한다.

| Case | WARM | FLUSH(FENCE.I) | 결과 |
|---|---|---|---|
| cold | 0 | 0 | victim 실행 0회, cause=1 1회, checker PASS |
| warm | 1 | 0 | victim 실행 1회, cause=1 1회, checker PASS |
| fenced | 1 | 1 | victim 실행 1회, cause=1 1회, checker PASS |

수정 전 b54201a에서는 warm의 victim이 2회 실행되어 checker가 실패한다.
수정 후 세 case 모두 통과했다. trap controller 단위 시험은 Verilator 5.050
`--assert`로 PMP commit 이전 redirect 금지, commit 다음 cycle의 next-PC
redirect, one-cycle pulse 및 기존 interrupt/WFI 우선순위를 검증했다.
SoC 시험은 기존 runner의 `-DSYNTHESIS` 설정이며 Xcelium 검증은 미실시다.
산술 256개 기대값 비교 회귀와 RV32/RV64 parse/elaboration도 통과했다.

이 보완은 PMP write commit 뒤 queue/target-buffer/epoch 및 younger uop를
architectural redirect로 폐기한다. TOR 상한 0x800008fc를 걸치는 16-byte fetch
문제는 별개로 아직 재현되며 수정 완료가 아니다.

## 재실행

각 이름의 `.elf`가 payload, `.csv`가 전체 commit, `.txt`가 콘솔 출력이다.
Linux 서버에서는 다음처럼 기존 runner로 실행한 뒤 checker를 실행한다.

```bash
BINARY="$PWD/verification/tests/pmp_refetch/warm.elf" ./sim/xcelium/run_verilog_sub.sh
python3 scripts/check_pmp_refetch_trace.py sim/xcelium/out/commit_trace.csv --warm 1
```

소스 재컴파일 시 cold는 `-DWARM=0 -DFLUSH=0`, warm은 `-DWARM=1 -DFLUSH=0`,
fenced는 `-DWARM=1 -DFLUSH=1`을 사용한다. 기본 SoC 주소맵용 테스트다.

```bash
riscv-none-elf-gcc -march=rv32imc_zicsr_zifencei -mabi=ilp32 \
  -nostdlib -nostartfiles -Wl,--build-id=none -DWARM=1 -DFLUSH=0 \
  -T sw/tests/htif_smoke/rv32_htif.ld sw/tests/pmp_fetch/protection_change.S \
  -o warm.elf
```
