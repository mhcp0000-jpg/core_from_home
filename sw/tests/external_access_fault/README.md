# External/misaligned data-access regression

`external_access_fault.S`는 core에서 발생한 load/store가 LSU, D-fabric,
local-to-AXI bridge, Main AXI4 Xbar와 default error slave를 왕복한 뒤 precise
exception으로 완료되는지 확인하는 bare-metal HTIF self-check다.

검사 순서와 기대값은 다음과 같다.

| operation | effective address | expected `mcause` | expected `mtval` | bus request |
|---|---:|---:|---:|---|
| LW | `0xffff_ffc8` | 5, load access fault | `0xffff_ffc8` | one read, DECERR |
| SW | `0xffff_ffc8` | 7, store access fault | `0xffff_ffc8` | one committed write, DECERR |
| LW | `0xffff_ffcb` | 4, load address misaligned | `0xffff_ffcb` | none |
| SW | `0xffff_ffcb` | 6, store address misaligned | `0xffff_ffcb` | none |
| LBU | `0xffff_ffcb` | 5, load access fault | `0xffff_ffcb` | one read, DECERR |
| SB | `0xffff_ffcb` | 7, store access fault | `0xffff_ffcb` | one committed write, DECERR |

trap handler는 매 exception에서 `mcause`와 `mtval`을 검사하고 `mepc += 4`로
faulting instruction을 건너뛴다. 여섯 개가 모두 맞으면 TOHOST에 1을 기록한다.
handler가 `mepc`를 갱신하지 않고 `mret`하면 동일 load/store가 반복되어 core가
멈춘 것처럼 보이므로, 외부 주소를 의도적으로 만드는 시험에는 복구 정책이
반드시 필요하다.

빌드 및 Windows Verilator full-SoC 실행 예시는 다음과 같다.

```powershell
riscv-none-elf-gcc -march=rv32imc_zicsr -mabi=ilp32 `
  -nostdlib -nostartfiles -Wl,--no-relax `
  -T sw/tests/htif_smoke/rv32_htif.ld `
  -o out/external_access_fault.elf `
  sw/tests/external_access_fault/external_access_fault.S

./scripts/run_soc_elf_test.ps1 -Htif `
  -ElfPath out/external_access_fault.elf `
  -TracePath out/external_access_fault_commit.csv `
  -TimeoutCycles 100000
```

2026-09-11 local full-SoC 결과는 여섯 exception 모두 기대 cause/tval과 일치했고
`HTIF TEST PASS`, host exit code 0이었다. 같은 시점의 backend integration test도
misaligned access가 D-memory로 빠져나가지 않는 것과 aligned unmapped access가
요청/오류 응답 각 1회 후 precise trap이 되는 것을 검사한다.
