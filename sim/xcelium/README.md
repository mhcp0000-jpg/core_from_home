# Xcelium `verilog_sub` + HTIF 실행 가이드

## FSDB 파형 생성

`run_verilog_sub.sh`는 기본적으로 FSDB를 활성화하며 결과는 다음 위치에 생성된다.

```text
sim/xcelium/out/waves.fsdb
```

기본 실행은 Xcelium 환경을 읽은 뒤 `VERDI_HOME`과 `NOVAS_HOME` 아래의 Xcelium/IUS
`debpli`를 자동 탐색한다. 서버의 위치가 다르면 library나 entry-point 포함 spec을
직접 지정한다.

```bash
FSDB_PLI=/tools/verdi/share/PLI/XCELIUM/LINUX64/boot/debpli \
  BINARY=/server/path/test.elf ./sim/xcelium/run_verilog_sub.sh

# site 설정이 FSDB PLI를 Xcelium에 이미 등록한 경우
FSDB_PLI=builtin BINARY=/server/path/test.elf \
  ./sim/xcelium/run_verilog_sub.sh
```

실제 PLI 경로를 찾는 예시는 다음과 같다.

```bash
find "${VERDI_HOME:-${NOVAS_HOME:-/tools/verdi}}/share/PLI" \
  -path '*/LINUX64/boot/debpli*' -print
```

실행 로그에 `[FSDB] opening ...`이 나타나야 dump가 시작된 것이다. 코어가
멈추거나 timeout에 도달해도 중간까지의 파형을 읽을 수 있도록 기본 100,000
cycle마다 `$fsdbDumpflush`를 수행한다. 주기와 파일 경로는 바꿀 수 있다.

```bash
FSDB_FILE=/server/scratch/my_test.fsdb FSDB_FLUSH_CYCLES=10000 \
  BINARY=/server/path/test.elf ./sim/xcelium/run_verilog_sub.sh
```

기본 dump는 `rv_soc_htif_dpi_tb` 아래 전체 hierarchy와 일반 신호를 대상으로 한다.
ITIM/DTIM 같은 multidimensional memory까지 필요하면 다음 옵션을 사용한다. 파일이
매우 커질 수 있으므로 기본값은 0이다.

```bash
FSDB_DUMP_MDA=1 BINARY=/server/path/test.elf \
  ./sim/xcelium/run_verilog_sub.sh
```

성능 회귀처럼 파형이 필요 없는 실행에서는 끌 수 있다. 이때 `RV_FSDB`가 정의되지
않고 PLI도 load하지 않으므로 기존 환경과 동일하게 동작한다.

```bash
FSDB_ENABLE=0 BINARY=/server/path/test.elf \
  ./sim/xcelium/run_verilog_sub.sh
```

FSDB 활성화 시 compile job과 simulation job 양쪽에 같은 PLI 설정을 전달해야 한다.
직접 `verilog_sub`를 호출한다면 `isrun.scr`와 `issim.scr` 모두에
`-FSDB_ENABLE=1 -FSDB_PLI=...`를 넘기고, simulation job에는 `-FSDB_FILE=...`도
넘긴다. 저장소 runner는 이 전달을 자동으로 처리한다.

현재 Windows 로컬 검증에서는 `RV_FSDB`가 꺼진 Verilator SoC 전체 build/run이
PASS했다. 실제 FSDB PLI load와 파일 생성은 Xcelium/Verdi가 설치된 Linux 서버에서
확인해야 한다. 실패하면 `compile.log`의 `FSDB compile PLI`, `simulation.log`의
`[FSDB] opening` 및 runner가 출력한 `FSDB output` 경로를 먼저 확인한다.

## Commit 로그의 GPR/CSR 구분

기존 `rd_we/rd_fp/rd/wdata`는 목적지 integer/FP register write를 뜻한다.
추가된 `gpr_we`와 `fpr_we`로 두 register file을 구분한다.
CSR 명령은 같은 commit 줄에
`csr_valid/ csr_we/ csr_addr/ csr_name/ csr_wdata`가 추가된다.
`csr_valid=1`은 정상 retire된 CSR 명령, `csr_we=1`은 그 명령의 CSR write
intent가 commit된 것을 뜻한다. `csr_wdata`는 CSRRS/CSRRC의 set/clear까지
반영한 write 요청 값이며, WARL 변환/locked PMP write 무시 이후 실제 저장값을
보장하는 readback은 아니다. 실제 값은 후속 CSRR의 GPR `wdata`로 확인한다.

- CSRRW: `wdata`는 rd로 반환된 이전 CSR 값, `csr_wdata`는 새 write 요청 값.
- `rd=x0` CSRRW: `gpr_we=0`, `csr_we=1`로 CSR write만 표시한다.
- CSRRS/CSRRC의 rs1=x0 또는 immediate=0: CSR read만 하므로 `csr_we=0`.
- illegal CSR trap이나 squash된 명령에는 CSR write commit을 표시하지 않는다.

값은 ROB commit edge의 CSR pending transaction에서 직접 샘플링한다.
현재 CSR 명령은 lane 0에서만 commit하며 lane 1의 CSR 필드는 0이다.
로그 줄 맨 끝에는 `mnemonic=CSRRW`처럼 사람이 읽을 수 있는 명령어 이름이
표시되며, CSV의 마지막 `mnemonic` 열에도 동일한 이름을 기록한다. 압축 명령은
`C.ADDI`, `C.J` 형식으로 구분한다. `csr_addr=0x340` 옆에는
`csr_name=mscratch`처럼 구현 CSR 이름을 표시하고, 유효한 CSR transaction이
아니면 `none`, 주소가 표에 없으면 `unknown`으로 표시한다. CSV는 기존 12개 열
뒤에 GPR/CSR 필드와 이름 필드를 추가했으므로 기존 열 이름은 유지된다.

| 주소 | 출력 이름 | 주소 | 출력 이름 |
|---:|---|---:|---|
| `0x001` | `fflags` | `0x002` | `frm` |
| `0x003` | `fcsr` | `0x300` | `mstatus` |
| `0x301` | `misa` | `0x304` | `mie` |
| `0x305` | `mtvec` | `0x306` | `mcounteren` |
| `0x340` | `mscratch` | `0x341` | `mepc` |
| `0x342` | `mcause` | `0x343` | `mtval` |
| `0x344` | `mip` | `0x3A0–0x3A3` | `pmpcfg0–3` |
| `0x3B0–0x3B7` | `pmpaddr0–7` | `0xB00/0xB80` | `mcycle/mcycleh` |
| `0xB02/0xB82` | `minstret/minstreth` | `0xC00/0xC80` | `cycle/cycleh` |
| `0xC01/0xC81` | `time/timeh` | `0xC02/0xC82` | `instret/instreth` |
| `0xF11–0xF14` | `mvendorid–mhartid` | | |

이 폴더만 보면 Linux 서버 실행 경로를 찾을 수 있도록 구성한다. 여기서
`verilog_sub`는 폴더 이름이 아니라 회사 서버의 Xcelium 제출 명령이다.

## 가장 간단한 실행

`run_verilog_sub.sh`는 다음 서버 ELF를 기본값으로 사용한다.

```bash
BINARY="/user/rocket/user/jeemin/project/TEST/DM_base/riscv_arithmetic_basic_test_0.elf"
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
  -TIMEOUT_CYCLES=2000000 \
  -ELF_VERIFY=1
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

## 시작 로그와 정지 위치 확인

simulation이 시작되면 다음 단계가 순서대로 출력된다.

```text
[BOOTROM] loading hex file: ...
[BOOTROM] hex loaded: word[0]=... word[1]=...
[TB] rv_soc_htif_dpi_tb started ...
[COMMIT] trace file opened: .../commit_trace.csv
[COMMIT] live logger enabled: every retired instruction
[TB] reset deasserted
[HOST-DPI] SoC ready; waiting for Boot ROM WFI retire
[TB] Boot ROM WFI retired ...
[HOST-DPI] Boot ROM WFI observed; starting ELF load
[HOST-DPI] opening ELF: ...
[HOST-DPI] ELF parsed: entry=... segments=...
[HOST-DPI] segment[N] load progress ...
[HOST-DPI] ELF AXI readback verification enabled
[HOST-DPI] segment[N] readback progress ...
[HOST-DPI] segment[N] readback PASS checked=... bytes
[HOST-DPI] ELF AXI readback PASS total=... bytes
[TB] boot mailbox ready ...
[TB] CLINT MSIP asserted; software interrupt is pending
[HOST-DPI] CLINT MSIP write acknowledged
[TB] CLINT MSIP cleared by Boot ROM handler
```

ELF segment 전송과 readback은 각각 16 KiB마다 진행률을 출력한다. readback은
Host AXI→Main Xbar→I/D local fabric→ITIM/DTIM의 실제 경로로 모든 최종 `PT_LOAD`
바이트와 BSS zero-fill을 다시 읽어 source ELF와 비교한다. 겹치는 segment의 byte는
마지막 PT_LOAD가 소유하는 것으로 계산한다. mismatch는 segment, 정확한 주소,
expected/actual byte와 64-bit read beat를 출력하고 Boot entry/MSIP write 전에 중단한다.

readback은 기본 ON이다. 큰 ELF에서는 적재 뒤 동일 크기의 read traffic이 추가되므로
timeout을 여유 있게 설정한다. loader와 무관한 디버깅에서만
`ELF_VERIFY=0`으로 끌 수 있다.

장시간 변화가 없을 때는 기본
100,000 cycle마다 heartbeat가 현재 `soc_ready`, `boot_wait`, ELF load 상태와 최근
commit trace PC를 출력한다. 간격은 plusarg로 바꿀 수 있고 `0`이면 끈다.

모든 retire 명령은 제한 없이 Xcelium 콘솔/`simulation.log`에 `[COMMIT]` 형식으로
출력되고, 동시에 `sim/xcelium/out/commit_trace.csv`에 저장된다. CSV는 order, cycle,
lane, PC, instruction, integer/FP destination과 write data, trap/cause/tval을 포함한다.
코어가 retire를 멈추더라도 주기적으로 file buffer를 flush하므로 실행 중인 서버에서
다음처럼 마지막 명령을 확인할 수 있다.

```bash
tail -n 40 sim/xcelium/out/commit_trace.csv
```

```bash
TIMEOUT_CYCLES=5000000 HEARTBEAT_CYCLES=20000 ELF_VERIFY=1 \
  BINARY=/server/path/program.elf ./sim/xcelium/run_verilog_sub.sh
```

첫 `[TB]` 로그도 없다면 RTL 실행 전인 elaboration/DPI loading 단계 문제이고,
`SoC ready` 이후 멈추면 Boot ROM fetch/WFI 경로, segment 진행 중 멈추면 해당 Host AXI
write의 ready/response 경로를 우선 확인한다. load는 PASS하지만 readback에서 멈추면
Host AXI read response 경로를, readback mismatch가 뜨면 출력된 첫 주소의 ELF program
header/file byte와 TIM 값을 우선 비교한다. readback까지 PASS했는데 fetch에서 같은
주소가 `0`으로 보이면 ELF loader가 아니라 IFU PMP/fabric response 선택 경로를 조사한다.

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
