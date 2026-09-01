# CoreMark short RTL benchmark

이 디렉터리는 upstream EEMBC CoreMark 1.0 소스를 수정하지 않고 현재
RV32 OoO SoC에서 실행하기 위한 bare-metal port다. 기본 실행은
`ITERATIONS=2`이며 128 KiB ITIM에 code/rodata, 128 KiB DTIM에
data/bss/stack을 둔다. cache가 없는 초기 TIM 모델의 1:1 local-memory
성능을 측정한다.

## 중요한 결과 분류

이 실행은 **기능 검증을 겸한 non-certified implementation estimate**다.
CoreMark의 공식 보고 규칙은 최소 10초 실행과 정해진 validation 절차를
요구한다. RTL 시뮬레이션 시간을 줄이기 위해 1~2 iteration만 실행하므로,
CRC가 모두 맞더라도 공식 인증 CoreMark score로 발표하면 안 된다.

측정값의 의미는 다음과 같다.

| 값 | 계산/의미 |
|---|---|
| cycles | timed region 전후 `mcycle` 차이 |
| retired instructions | timed region 전후 `minstret` 차이 |
| IPC | `retired instructions / cycles` |
| cycles/iteration | `cycles / iterations` |
| estimated CoreMark/MHz | `iterations * 1,000,000 / cycles` |

`CoreMark/MHz`는 frequency-independent cycle estimate다. 실제 합성 후
CoreMark/sec를 얻으려면 이 값에 구현 clock MHz를 곱한다. ITIM/DTIM이
core clock과 1:1이라는 현재 모델에만 그대로 적용할 수 있다.

## 소스와 재현성

실행 스크립트는 공식 `eembc/coremark` 저장소의 commit
`1f483d5b8316753a742cbf5590caf5bd0a4e4777`을 사용한다. clean checkout과
정확한 commit을 검사한 뒤 다음 upstream 파일을 직접 컴파일한다.

- `core_list_join.c`
- `core_main.c`
- `core_matrix.c`
- `core_state.c`
- `core_util.c`
- `coremark.h`

로컬 파일의 역할은 다음과 같다.

| 파일 | 역할 |
|---|---|
| `port/core_portme.h` | RV32 type, static-memory, no-libc, timing 설정 |
| `port/core_portme.c` | `mcycle/minstret` 측정, CRC 수집, HostIF 결과 전송 |
| `rv32_start.S` | CLINT MSIP clear, DTIM stack 설정, `main` 호출 |
| `rv32_tim.ld` | ITIM/DTIM section과 stack 배치 |

## 실행

Windows PowerShell:

```powershell
.\scripts\run_coremark.ps1 `
  -Iterations 2 `
  -CoreMarkRoot C:\rv_build\coremark-src `
  -PublishRoot .\verification\benchmarks\coremark
```

Linux:

```bash
./scripts/run_coremark.sh \
  --iterations 2 \
  --coremark-root /opt/src/coremark \
  --publish-root verification/benchmarks/coremark
```

`CoreMarkRoot`를 생략하면 artifact 디렉터리 아래에 공식 저장소를 clone한다.
Windows는 기본 xPack toolchain/Verilator 경로를 사용하며 parameter로 바꿀
수 있다. Linux는 `riscv-none-elf-*`, `verilator`, `make`, `g++`가 PATH에
있어야 한다.

## HostIF 결과 packet

`portable_fini()`는 HostIF `TOHOST`에 아래 12 word를 순서대로 쓴 뒤
`EXIT_CODE=0`을 쓴다. 이 방식은 printf/UART가 benchmark 시간과 로그 크기를
왜곡하지 않게 한다.

| Word | 내용 |
|---:|---|
| 0 | magic/version `0x434d0001` |
| 1 | iteration count |
| 2..3 | cycles low/high |
| 4..5 | retired instructions low/high |
| 6 | seed CRC |
| 7..10 | list, matrix, state, final CRC |
| 11 | status bitfield |

status bit 0은 알려진 2K performance seed, bit 1은 CRC error, bit 2는
datatype error, bit 3은 10초 미만, bit 4는 port configuration error다.
짧은 정상 실행의 bit 3은 예상된 값이며 실패로 취급하지 않는다. 반면 seed,
list(`e714`), matrix(`1fd7`), state(`8e3a`) CRC와 bit 1/2/4는 반드시
검사한다.

## 산출물

PowerShell runner는 ELF를 외부 artifact 디렉터리에 두고 disassembly,
ELF headers, symbols, full simulation log, 사람이 읽는 result log, JSON
result를 만든다. `-PublishRoot`를 지정했을 때만 Git으로 관리할 작은 검증
산출물을 복사하며 ELF/map/Verilator build tree는 복사하지 않는다.

공식 규칙과 일반 포팅 절차는 upstream
[CoreMark README](https://github.com/eembc/coremark/blob/main/README.md)와
[barebones porting guide](https://github.com/eembc/coremark/blob/main/barebones_porting.md)를
기준으로 한다.
