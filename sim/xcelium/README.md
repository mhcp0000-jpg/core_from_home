# Xcelium `verilog_sub` + HTIF 실행 가이드

이 폴더만 보면 Linux 서버 실행 경로를 찾을 수 있도록 구성한다. 여기서
`verilog_sub`는 폴더 이름이 아니라 회사 서버의 Xcelium 제출 명령이다.

## 가장 간단한 실행

`run_verilog_sub.sh` 상단의 다음 한 줄만 실제 RISC-V ELF 절대경로로 바꾼다.

```bash
BINARY="/server/project/test/program.elf"
```

그 다음 repository root에서 실행한다.

```bash
chmod +x sim/xcelium/*.sh
./sim/xcelium/run_verilog_sub.sh
```

파일을 수정하지 않고 한 번만 실행할 때는 환경변수도 사용할 수 있다.

```bash
BINARY=/server/project/test/program.elf ./sim/xcelium/run_verilog_sub.sh
```

기본 simulator command는 `verilog_sub`다. 서버에서 command 이름만 다르면 다음처럼
덮어쓸 수 있다.

```bash
VERILOG_SUB=my_verilog_sub BINARY=/server/project/test/program.elf \
  ./sim/xcelium/run_verilog_sub.sh
```

회사 서버의 실제 호출 방식에 맞춰 compile/elaborate와 simulation을 두 job으로
제출한다.

```text
verilog_sub -Is -compile isrun.scr -RTL_ASSERTIONS=0
verilog_sub -Is -short   issim.scr -BINARY=... -SV_LIB=... -TIMEOUT_CYCLES=...
```

`run_verilog_sub.sh`가 저장소의 `tb/e2e/dpi/elf_loader.cpp`로 DPI shared library를
먼저 생성한다. 그 다음 `isrun.scr`가 source list를 사용해 Xcelium snapshot을 만들고,
`issim.scr`가 같은 snapshot에 생성된 DPI library와 ELF plusarg를 연결해 실행한다.
외부 프로젝트의 기존 `.so` 파일은 필요하지 않다.

서버 기본 compile은 `-define SYNTHESIS`를 사용한다. 기능 RTL과 reset은 그대로이고
simulation-only assertion만 제외된다. assertion까지 검사할 때는 다음처럼 실행한다.

```bash
RTL_ASSERTIONS=1 BINARY=/server/path/program.elf \
  ./sim/xcelium/run_verilog_sub.sh
```

## 파일 구조

```text
sim/xcelium/
  setup_env.sh          CORE_ROOT/RTL_DIR/TB_DIR/XCELIUM_DIR 설정
  setup_env.csh         csh/tcsh 서버용 setenv 환경 파일
  rtl.f                 합성 RTL compile-order filelist
  htif_tb.f             DPI Host와 server test top filelist
  run_verilog_sub.sh    DPI build 및 compile/sim job 제출
  isrun.scr             compile/elaborate queue에서 실행되는 Xcelium script
  issim.scr             short queue에서 실행되는 simulation script
  build_htif_smoke.sh   제공된 최소 HTIF ELF 생성
```

`rtl.f`와 `htif_tb.f`는 checkout의 절대경로를 하드코딩하지 않고 다음 형식을 쓴다.

```text
$RTL_DIR/backend/rv_int_alu.sv
$TB_DIR/e2e/dpi/rv_host_dpi.sv
```

직접 job을 제출할 때는 먼저 환경 파일을 source한다.

```bash
source sim/xcelium/setup_env.sh
verilog_sub -Is -compile "$XCELIUM_DIR/isrun.scr" -RTL_ASSERTIONS=0
verilog_sub -Is -short "$XCELIUM_DIR/issim.scr" \
  -BINARY=/server/project/test/program.elf \
  -SV_LIB="$CORE_ROOT/sim/xcelium/out/libcore_htif_dpi.so" \
  -TIMEOUT_CYCLES=2000000
```

`CONFIG`/`CY_LATEST`는 기존 환경의 제출 설정일 뿐 현재 RTL 및 Xcelium 실행에는
필요하지 않아 제거했다. 서버의 Xcelium 설치 위치가 다를 때만 환경 파일을 지정한다.

```bash
XCELIUM_ENV_CSH=/path/to/XCELIUM/gcc_env64.csh \
  BINARY=/server/project/test/program.elf ./sim/xcelium/run_verilog_sub.sh
```

csh/tcsh 환경에서는 repository root에서 다음을 사용한다.

```csh
source sim/xcelium/setup_env.csh
```

## DPI/HTIF 동작

```text
ELF → DPI-C parser → Host AXI → Main Xbar → ITIM/DTIM

Core store → LSU/SQ commit → D-Fabric → DTIM.TOHOST
                                          ↓ Host AXI polling
                                      DPI print/exit
                                          ↓
Host response → Host AXI → Main Xbar → DTIM.FROMHOST
```

기본 mailbox는 다음 두 개의 64-bit word다.

| 이름 | 주소 | 의미 |
|---|---:|---|
| TOHOST | `0x8002_0000` | target가 Host request 게시 |
| FROMHOST | `0x8002_0008` | Host가 target response 게시 |

지원하는 request는 다음과 같다.

- raw `TOHOST=1`: PASS 및 simulation 종료
- raw odd completion: `(value >> 1)`을 FAIL code로 종료
- raw even address: 해당 주소의 NUL-terminated 문자열 출력
- HTIF device 1, command 1: low byte console 출력
- HTIF device 0, command 0: proxy syscall block의 `write(64)`, `exit(93)`,
  `exit_group(94)` 처리

RV32가 64-bit mailbox를 두 번의 store로 쓰는 경우를 위해 Host는 settling interval 후
같은 값을 다시 읽은 뒤 request를 처리한다. 처리 순서는 TOHOST clear, 요청 수행,
필요한 FROMHOST response 기록이다.

## ELF 요구조건

- ELF32 little-endian RISC-V
- 모든 `PT_LOAD` segment가 ITIM 또는 DTIM 안에 위치
- 일반 data가 mailbox 16 bytes를 덮지 않도록 linker script에서 예약
- ELF entry는 ITIM 안에 위치

가능하면 실행 전에 확인한다.

```bash
riscv-none-elf-readelf -h -l program.elf
riscv-none-elf-nm -n program.elf | grep -E ' (tohost|fromhost)$'
```

심볼을 제공하는 ELF라면 주소가 각각 `80020000`, `80020008`이어야 한다. 주소를
코드에 직접 사용한 ELF는 심볼이 없어도 실행할 수 있다.

## 제공 smoke test

RISC-V GNU toolchain이 PATH에 있다면 다음으로 작은 ELF를 만든다.

```bash
./sim/xcelium/build_htif_smoke.sh
BINARY="$PWD/out/xcelium_htif/htif_smoke.elf" \
  ./sim/xcelium/run_verilog_sub.sh
```

정상 출력은 다음과 같다.

```text
HTIF direct-string print PASS
HTIF proxy write syscall PASS
[host-finish code=0]
HTIF TEST PASS
```

현재 개발 PC에는 Xcelium/verilog_sub가 없으므로 실제 Cadence command는 서버에서
최종 확인해야 한다. 동일 RTL/TB/DPI는 Verilator E2E에서 위 출력과 PASS까지 검증했다.

## 호환 파일

`sources_core.f`, `sources_soc.f`, `run_xcelium.sh`는 이전 직접-xrun/export 흐름을
깨지 않기 위해 유지한다. 신규 서버 검증은 `setup_env.sh`, `rtl.f`, `htif_tb.f`,
`run_verilog_sub.sh`, `isrun.scr`, `issim.scr`를 기준으로 한다.
