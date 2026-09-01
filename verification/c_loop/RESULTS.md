# RV32IMFC GCC C/ASM loop 검증 결과

검증일은 2026-09-01이며, xPack RISC-V GCC 15.2.0-1로 실제 C와 startup assembly를 `rv32imfc_zicsr_zifencei/ilp32f` ELF로 빌드해 DPI Host loader로 ITIM/DTIM에 적재한 뒤 SoC 전체를 실행했다.

## 입력 소스와 실행 방법

- C workload: [`sw/smoke/rv32_loop_smoke.c`](../../sw/smoke/rv32_loop_smoke.c)
- startup/HostIF exit: [`sw/smoke/rv32_start.S`](../../sw/smoke/rv32_start.S)
- ITIM/DTIM linker script: [`sw/smoke/rv32_tim.ld`](../../sw/smoke/rv32_tim.ld)
- build/run/check script: [`scripts/run_c_loop_test.ps1`](../../scripts/run_c_loop_test.ps1)

```powershell
powershell -ExecutionPolicy Bypass -File scripts/run_c_loop_test.ps1 `
  -PublishRoot verification/c_loop
```

컴파일 핵심 옵션은 `-march=rv32imfc_zicsr_zifencei -mabi=ilp32f -O1 -fno-unroll-loops -ffreestanding -nostdlib`이다. `.text`는 ITIM `0x8000_0000`, writable data/BSS/stack은 DTIM `0x8002_0000` 이후에 배치한다.

## 테스트 내용과 예상값

C의 8회 `for` loop에서 각 원소에 대해 integer multiply/add, DTIM store 후 load, float multiply/add, int-to-float convert, FP store 후 load를 수행한다.

| 항목 | 예상값 | 관측/판정 |
|---|---|---|
| integer output | `8, 1, 26, 21, 0, 41, 40, 21` | C self-check PASS |
| integer sum | `158` | C self-check PASS |
| FP output | `8.75, 2.5, 28.25, 24.0, 3.75, 45.5, 45.25, 27.0` | C self-check PASS |
| FP sum | `185.0f`, bits `0x43390000` | C self-check PASS |
| Host signature | `0x009e00b9` | 관측 PASS |
| Host exit | `0` | 관측 PASS |
| ITIM payload commit | 1개 이상 | `357` |
| FP register commit | 1개 이상 | `68` |
| dual-commit lane 1 | 1개 이상 | `121` |
| payload trap | `0` | `0` |

최종 출력 요약은 [`rv32_loop_smoke.result.log`](rv32_loop_smoke.result.log), 모든 architectural retire는 [`rv32_loop_smoke_commit.csv`](rv32_loop_smoke_commit.csv)에 있다. ELF 구조는 [`rv32_loop_smoke.headers`](rv32_loop_smoke.headers), symbol 배치는 [`rv32_loop_smoke.symbols`](rv32_loop_smoke.symbols), 실제 GCC 생성 명령은 [`rv32_loop_smoke.disasm`](rv32_loop_smoke.disasm)에서 확인할 수 있다.

## 검증 중 발견해 수정한 결함

실제 compiler workload가 기존 directed assembly에서 드러나지 않던 세 가지 경계를 찾았다.

1. RV32 `C.FLW/C.FSW/C.FLWSP/C.FSWSP` expansion을 추가하고 RV64의 같은 encoding인 `C.LD/C.SD/C.LDSP/C.SDSP`와 XLEN으로 구분했다.
2. branch recovery와 같은 cycle의 older load response가 LSQ에서 유실되어 retirement가 멈추는 문제를 수정했다.
3. branch recovery와 같은 cycle의 older writeback wakeup이 surviving IQ entry에서 유실되는 문제를 수정했다.

각 recovery 동시성 결함에는 재현 단위 테스트를 추가했다. 이 결과는 directed baseline 통과를 뜻하며 Spike/Sail differential, riscv-arch-test, random/formal sign-off를 대신하지 않는다.
