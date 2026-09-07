# riscv-dv 기반 arithmetic smoke

공식 https://github.com/chipsalliance/riscv-dv 의 `pygen/experimental`
`riscv_rand_instr`로 생성한 RV32I 산술/논리/시프트/비교 명령 256개(seed=7)를
실행한다. 정식 SV/UVM riscv_arithmetic_basic_test 전체 실행은 아니다.
Windows에서 기본 pygen의 pyboolector 의존성 설치가 되지 않아 공식 experimental
생성기를 사용했다. 생성기 소스 파일별 SHA-256은 expected.json에 기록한다.

## 테스트 구조

- Boot ROM WFI → DPI ELF 적재 → MSIP → ELF entry의 기존 HTIF 경로를 사용한다.
- `_start`는 `0x80000166`으로 이동한다.
- `0x80000166: c.j main` → `0x800008fc: lui s6,0x80000`으로 서버 문제의
  점프 주소와 main 첫 명령을 재현한다.
- x1–x31 초기값을 설정한 뒤 `0x800009f8`부터 256개 명령을 실행한다.
- TOHOST(0x80020000)에 1을 기록하여 실행을 종료한다.
- 종료만으로 산술 PASS를 판정하지 않는다. Python 참조 연산으로 계산한
  각 명령의 PC/목적지/write-enable/32-bit 결과를 commit CSV와 순서대로 비교한다.
  ELF 실행 중 trap이 하나라도 있거나 main 진입/명령 수가 다르면 실패한다.
  ELF 진입 전 Boot ROM PC=0x101c의 MSIP(cause=3)는 정확히 한 번 있어야 한다.

`test.S`: 실제 조립 소스. `test.elf`: 서버에 바로 올릴 ELF.
`expected.json`: seed, 생성기 해시, 명령별 기대값.
`commit_trace.csv`: 전체 architectural commit 기록.
`simulation.txt`: 실행 로그. `result.txt`: 참조 비교 결과.

## 재실행

Linux 서버에서는 저장소 루트에서 다음과 같이 기존 runner를 사용한다.
기본 서버 ELF 설정은 변경하지 않는다.

```bash
BINARY="$PWD/verification/tests/dv_arithmetic_smoke/test.elf" \
  ./sim/xcelium/run_verilog_sub.sh
python3 scripts/dv_arithmetic_smoke.py \
  --output verification/tests/dv_arithmetic_smoke \
  --trace sim/xcelium/out/commit_trace.csv
```

ELF 재컴파일:

```bash
riscv-none-elf-gcc -march=rv32imc_zicsr -mabi=ilp32 \
  -nostdlib -nostartfiles -static -Wl,--build-id=none \
  -T sw/tests/htif_smoke/rv32_htif.ld \
  verification/tests/dv_arithmetic_smoke/test.S \
  -o verification/tests/dv_arithmetic_smoke/test.elf
```

생성을 다시 하려면 공식 riscv-dv를 내려받고 `python-constraint==1.4.0`,
`bitstring==4.4.0`을 설치한 다음 실행한다. 소스가 변경되면 같은 seed여도
다른 결과가 나올 수 있으므로 보관된 test.S/expected.json이 이번 실행의 기준이다.

```bash
python3 scripts/dv_arithmetic_smoke.py --dv-root /path/to/riscv-dv \
  --seed 7 --count 256 --output out/dv_regenerated
```

Windows 로컬 실행은 `scripts/run_soc_elf_test.ps1 -Htif -ElfPath ...
-TracePath ...`를 사용한다. 현재 runner는 `-DSYNTHESIS`로 assertion을 끄므로
이 실행은 Xcelium 4-state/assertion 검증을 대체하지 않는다. M/F 연산,
LSU stress, privilege/trap recovery와 서버 원본 ELF의 재현도 별도 검증 대상이다.
