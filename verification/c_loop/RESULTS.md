# RV32IMFC GCC C/ASM loop 검증 가이드 및 결과

이 디렉터리는 단순 PASS 스크린샷이 아니라, 실제 C 프로그램이 어떤 경로로 실행됐고 무엇을 근거로 통과했다고 판단했는지를 재현할 수 있게 보관한 검증 묶음이다. 검증일은 2026-09-01이며 xPack RISC-V GCC 15.2.0-1을 사용했다.

## 1. 이 테스트가 확인하는 것

테스트는 수작업으로 opcode만 나열한 assembly가 아니다. GCC가 C의 loop와 데이터 의존성을 실제 RV32IMFC 명령으로 변환하고, 생성된 ELF가 아래 전체 경로를 통과하는지 확인한다.

```text
rv32_loop_smoke.c + rv32_start.S + rv32_tim.ld
                  │
                  ▼  riscv-none-elf-gcc
             RV32IMFC ELF
                  │
                  ▼  DPI host / AXI4 PT_LOAD
         ITIM instructions + DTIM data
                  │
                  ▼  CLINT MSIP wake-up
  fetch → decode/C-expand → rename → IQ → execute/dual-LSU
                  │
                  ▼
       writeback → ROB in-order commit
                  │
                  ▼
       HostIF signature + exit(0) + commit CSV
```

따라서 이 테스트의 PASS는 최소한 다음이 한 프로그램 안에서 함께 동작했음을 뜻한다.

| C 동작 | 대표 생성 명령 | 주로 확인되는 하드웨어 |
|---|---|---|
| 배열 index/address 계산 | `SLLI`, `ADD`, `AUIPC`, `ADDI` | 정수 ALU, PRF, dependency wakeup |
| 정수 multiply/add | `MUL`, `ADDI`, `ADD` | multiplier, ALU, IQ OoO scheduling |
| 정수 배열 store 후 load | `SW/C.SW`, `LW/C.LW` | dual LSU/AGU, SQ/LQ, store buffer, DTIM |
| FP 배열 load/store | `FLW/C.FLW`, `FSW/C.FSW` | C expander, FP PRF, dual LSU/LSQ |
| FP multiply/add | `FMUL.S`, `FADD.S` | RV32F execution/writeback |
| integer→float | `FCVT.S.W` | INT/FP operand and destination paths |
| 결과 비교 | `FEQ.S`, `BEQ/BNE` | FPU compare, branch unit/predictor |
| 8회 loop | backward `BNE` | prediction, mispredict recovery, ROB squash |
| 함수 call/return | compressed call/return 포함 | frontend alignment, C expansion, redirect |
| 결과 보고 | HostIF MMIO `SW` | commit-only device-store visibility, AXI path |

## 2. 소스 파일별 역할

| 파일 | 역할 |
|---|---|
| [`sw/smoke/rv32_loop_smoke.c`](../../sw/smoke/rv32_loop_smoke.c) | integer/FP/load-store loop, 예상 배열 비교, DTIM 결과 블록과 Host signature 생성 |
| [`sw/smoke/rv32_start.S`](../../sw/smoke/rv32_start.S) | CLINT MSIP clear, stack 초기화, `main` 호출, HostIF exit code 기록, 종료 후 WFI |
| [`sw/smoke/rv32_tim.ld`](../../sw/smoke/rv32_tim.ld) | ITIM/DTIM section 배치, entry point와 stack top 정의 |
| [`scripts/run_c_loop_test.ps1`](../../scripts/run_c_loop_test.ps1) | tool 확인, ELF build, disassembly 생성, SoC 실행, Host/commit 자동 판정, 산출물 publish |

이 프로그램은 `-nostdlib -nostartfiles`인 freestanding C다. libc, 운영체제, `printf`에 의존하지 않으며 startup과 종료 protocol을 테스트 자체가 명시한다. 입출력 배열을 `volatile`로 둔 이유는 GCC가 계산을 상수화하거나 DTIM 접근을 제거하지 못하게 하기 위해서다.

## 3. 실행 및 부트 순서

1. GCC가 `.text/.rodata`와 `.data/.bss`를 별도 PT_LOAD segment로 가진 ELF32를 만든다.
2. DPI Host가 AXI4로 ITIM `0x8000_0000`과 DTIM `0x8002_0000`에 segment를 적재하고 BSS 범위를 zero-fill한다.
3. Host가 HostIF boot entry/flags를 기록한 뒤 CLINT `MSIP`를 마지막으로 기록한다.
4. Boot ROM에서 WFI 중이던 core가 machine software interrupt를 받고 `mtvec=0x8000_0000`으로 이동한다.
5. `_start`가 CLINT `MSIP`를 clear하고 `sp=0x8003_fff0`을 설정한 뒤 `main`을 호출한다.
6. `main`이 계산과 self-check를 끝낸 후 HostIF `TOHOST(+0x0c)`에 signature를 기록한다.
7. `_start`가 `main`의 반환값을 HostIF `EXIT_CODE(+0x14)`에 기록한다. testbench는 exit 0을 확인하고 종료한다.

## 4. C 계산식과 반복별 정답

각 반복에서 다음 계산을 수행한다.

```text
scaled[i] = integer_input[i] × (i + 1) + 5
mixed[i]  = fp_input[i] × 1.5 + float(scaled[i])
```

각 결과는 DTIM output 배열에 store한 뒤 다시 load해서 누적한다. 따라서 최종 합이 맞으려면 계산뿐 아니라 해당 store/load 경로도 올바르게 동작해야 한다.

| i | integer input | i+1 | scaled/output | integer 누적합 | FP input | FP×1.5 | mixed/output | FP 누적합 |
|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| 0 | 3 | 1 | 8 | 8 | 0.5 | 0.75 | 8.75 | 8.75 |
| 1 | -2 | 2 | 1 | 9 | 1.0 | 1.50 | 2.50 | 11.25 |
| 2 | 7 | 3 | 26 | 35 | 1.5 | 2.25 | 28.25 | 39.50 |
| 3 | 4 | 4 | 21 | 56 | 2.0 | 3.00 | 24.00 | 63.50 |
| 4 | -1 | 5 | 0 | 56 | 2.5 | 3.75 | 3.75 | 67.25 |
| 5 | 6 | 6 | 41 | 97 | 3.0 | 4.50 | 45.50 | 112.75 |
| 6 | 5 | 7 | 40 | 137 | 3.5 | 5.25 | 45.25 | 158.00 |
| 7 | 2 | 8 | 21 | 158 | 4.0 | 6.00 | 27.00 | 185.00 |

`main`은 output 원소 16개와 두 누적합을 다시 검사한다. 하나라도 다르면 `mismatch_mask`에 대응 bit를 기록하고 1을 반환한다.

| mismatch bit | 의미 |
|---|---|
| `[7:0]` | `integer_output[i]` 불일치 |
| `[15:8]` | `fp_output[i]` 불일치 |
| `[16]` | integer sum이 158이 아님 |
| `[17]` | FP sum이 185.0이 아님 |

## 5. ELF와 메모리 배치

[`rv32_loop_smoke.headers`](rv32_loop_smoke.headers)는 ELF32 little-endian RISC-V, RVC 및 single-float ABI flag를 확인한다. 실제 symbol 배치는 다음과 같으며 전체 목록은 [`rv32_loop_smoke.symbols`](rv32_loop_smoke.symbols)에 있다.

| 주소 | symbol/영역 | 의미 |
|---|---|---|
| `0x8000_0000` | `_start` | Boot ROM interrupt 진입점 |
| `0x8000_0022` | `main` | C workload |
| `0x8000_0154` | `expected_fp` | ITIM의 read-only FP 정답 |
| `0x8000_0174` | `expected_integer` | ITIM의 read-only integer 정답 |
| `0x8002_0000` | `fp_input` | DTIM 초기 FP 입력 |
| `0x8002_0020` | `integer_input` | DTIM 초기 integer 입력 |
| `0x8002_0040` | `result_signature` | debugger용 실제 합/마지막 값/mismatch |
| `0x8002_0054` | `fp_output` | DTIM FP 출력 배열 |
| `0x8002_0074` | `integer_output` | DTIM integer 출력 배열 |
| `0x8003_fff0` | `__stack_top` | DTIM stack 시작점 |

## 6. 자동 PASS 판정 기준

Host event와 commit trace를 서로 다른 관점에서 검사한다.

| 검사 | 요구값 | 실제 결과 | 의미 |
|---|---:|---:|---|
| C self-check | 모든 비교 일치 | PASS | `main` 반환값 0 |
| Host signature | `0x009e00b9` | `0x009e00b9` | 상위 16-bit integer 158, 하위 16-bit FP 185 |
| Host exit | `0` | `0` | startup/HostIF 종료 protocol 정상 |
| ITIM payload commit | 1개 이상 | `357` | C/ASM payload가 실제 retire됨 |
| FP destination commit | 1개 이상 | `68` | FP 연산 결과가 architectural state에 반영됨 |
| lane-1 commit | 1개 이상 | `121` | 2-wide retire 경로가 실제 사용됨 |
| payload trap | `0` | `0` | C payload에서 예외가 발생하지 않음 |

`357`은 C 본문만의 source statement 수가 아니라 `_start`, 첫 계산 loop, self-check loop, signature 저장과 반환까지 ITIM에서 commit된 동적 instruction 수다. lane-1 commit `121`은 121개 instruction이 같은 cycle의 lane 0 뒤에서 두 번째로 retire됐다는 뜻이다. 이것은 dual-issue 경로가 사용됐다는 증거지만 매 cycle IPC=2였다는 의미는 아니다.

## 7. commit CSV 읽는 방법

[`rv32_loop_smoke_commit.csv`](rv32_loop_smoke_commit.csv)는 speculative writeback이 아닌 ROB in-order retire에서 기록한다.

```text
order,cycle,lane,pc,instruction,rd_write,rd_fp,rd,wdata,trap,cause,tval
```

| 열 | 설명 |
|---|---|
| `order` | 전체 architectural commit 순서 |
| `cycle` | testbench clock 기준 commit cycle |
| `lane` | 같은 cycle의 첫 번째/두 번째 retire lane |
| `pc`, `instruction` | retire된 PC와 canonical/raw instruction 값 |
| `rd_write` | destination register write 여부 |
| `rd_fp` | 0이면 integer PRF, 1이면 FP PRF destination |
| `rd`, `wdata` | architectural destination 번호와 최종 값 |
| `trap`, `cause`, `tval` | precise trap record와 원인 정보 |

Boot ROM의 의도된 MSIP trap record는 payload 밖에 있다. 자동 판정은 PC가 ITIM base 이상인 payload 357개만 분리하여 trap 0을 요구한다. [`rv32_loop_smoke.disasm`](rv32_loop_smoke.disasm)과 PC를 맞춰 보면 C statement가 어떤 instruction sequence로 실행됐는지 추적할 수 있다.

## 8. 저장된 산출물

| 산출물 | 읽는 목적 |
|---|---|
| [`rv32_loop_smoke.result.log`](rv32_loop_smoke.result.log) | 사람이 빠르게 확인하는 최종 PASS와 핵심 수치 |
| [`rv32_loop_smoke_commit.csv`](rv32_loop_smoke_commit.csv) | 364개 전체 architectural record(boot 포함), cycle/lane/register 결과 분석 |
| [`rv32_loop_smoke.disasm`](rv32_loop_smoke.disasm) | GCC가 생성한 instruction과 C/ASM symbol의 대응 |
| [`rv32_loop_smoke.headers`](rv32_loop_smoke.headers) | ELF class, ISA flags, entry, PT_LOAD 주소/권한 확인 |
| [`rv32_loop_smoke.symbols`](rv32_loop_smoke.symbols) | ITIM/DTIM object의 실제 주소 확인 |

ELF binary와 linker map은 재생성 가능하고 repository 크기를 불필요하게 키우므로 commit하지 않는다. 기본 실행 시 전체 build/simulator 출력은 `C:\rv_build\c_loop_smoke\rv32_loop_smoke.sim.log`에 남고, repository에는 장기 비교에 유용한 요약과 architectural trace만 보관한다.

## 9. 재현 방법

필요 도구는 xPack RISC-V GCC 15.2.0-1, Verilator 5.050, w64devkit이며 기본 설치 경로가 다르면 script parameter로 지정한다.

```powershell
powershell -ExecutionPolicy Bypass -File scripts/run_c_loop_test.ps1 `
  -ToolchainRoot C:\rv_toolchains\xpack-riscv-none-elf-gcc-15.2.0-1 `
  -ArtifactRoot C:\rv_build\c_loop_smoke `
  -PublishRoot verification\c_loop `
  -BuildJobs 4 `
  -TimeoutCycles 100000
```

`PublishRoot`를 생략하면 repository 파일은 건드리지 않고 `ArtifactRoot`에만 결과를 만든다. 실패 시 script는 signature, exit, payload trap, FP commit, lane-1 commit 중 어느 계약이 깨졌는지를 exception으로 표시한다.

## 10. 이 테스트로 발견한 결함

실제 compiler workload가 기존 directed assembly에서 드러나지 않던 세 가지 경계를 찾았다.

1. RV32 `C.FLW/C.FSW/C.FLWSP/C.FSWSP` expansion을 추가하고 RV64의 같은 encoding인 `C.LD/C.SD/C.LDSP/C.SDSP`와 XLEN으로 구분했다.
2. branch recovery와 같은 cycle의 older load response가 LSQ에서 유실되어 retirement가 멈추는 문제를 수정했다.
3. branch recovery와 같은 cycle의 older writeback wakeup이 surviving IQ entry에서 유실되는 문제를 수정했다.

각 recovery 동시성 결함에는 재현 단위 테스트를 추가했다. 수정 후 기존 parse/elaboration, Icarus 단위 15종, Verilator 블록 11종, backend/SoC boot, RV32IMF/RV32C/M-U ELF 회귀도 다시 통과했다.

## 11. 해석 범위와 남은 한계

이 결과로 기본 integer/FP/dual-LSU/branch/ROB 파이프라인의 compiler-driven end-to-end 동작은 확인됐다. 그러나 아래까지 자동으로 증명하는 것은 아니다.

- libc, `printf`, heap, syscall 또는 운영체제 실행
- 모든 RV32IMFC opcode와 rounding/exception 조합
- 장시간 random dependency, 모든 bank conflict와 interrupt timing
- cycle-accurate Cortex-A53 성능 비교 또는 목표 주파수/PPA
- cache/MMU/S-mode처럼 아직 baseline 범위 밖인 구조

즉, 현재 판정은 “기본 freestanding C 프로그램이 실제 GCC ELF로 SoC 전체에서 정확히 실행된다”이며 전체 ISA나 상용화 sign-off와는 구분한다.
