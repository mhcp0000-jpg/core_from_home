# 서버 실행 로그 전달 위치

서버에서 발생한 commit/trap 문제를 전달할 때
[`commit_trap_log.txt`](./commit_trap_log.txt)를 GitHub에서 직접 편집하거나,
로컬에서 내용을 붙여 넣은 뒤 커밋·푸시한다.

로그는 자르거나 정렬하지 말고 원문 순서 그대로 넣는다. 특히 ELF loader 메시지,
trap 직전 commit, `cause`, `tval`, timeout 메시지가 함께 있어야 원인을 구분할 수 있다.

## 2026-09-14: PC 0x80000a78 이후 정지 조사

원본 서버 로그는 `commit_trap_log.txt`에 그대로 보존한다. 다음 명령은
`0x80000a7c: f4d2d903 (lhu s2,-179(t0))`이고 마지막 t0 값은 `0x8002d9dd`다.
따라서 접근 주소는 `0x8002d92a`: 기본 DTIM 내부이고 halfword 정렬이다.
뒤 LBU도 같은 주소다. 마지막 commit만으로 ELF loader/PMP/LSU/버스 중
어느 부분의 정지인지 확정할 수는 없다.

로컬 directed reconstruction:
[`server_a7c_load_pair.S`](../../../sw/tests/htif_smoke/server_a7c_load_pair.S)
는 보고된 PC와 raw instruction을 보존하되 초기화와 data는 통제한 별도 테스트다.
원본 riscv-dv ELF가 아니며 원본 재현 성공/버그 수정으로 보고하지 않는다.
최신 RTL을 Verilator 5.050으로 빌드한 실행에서 LHU=0x5a5a, LBU=0x5a,
후속 store/load=0x11→0x22→0x44 및 HTIF PASS를 확인했다.
해당 runner는 `SYNTHESIS` define을 사용하므로 이 결과는 assertion-enabled 또는
Xcelium 4-state 통과를 의미하지 않는다.

### 다음 서버 실행

TB가 바뀌었으므로 **기존 snapshot 재실행이 아니라 compile/elaborate부터** 실행한다.
`run_verilog_sub.sh`는 이제 기본으로 `LSU_TRACE=1`을 `issim.scr`에 전달한다.
서버에서 수정한 스크립트를 유지한다면 실제 xrun 실행 인자에 `+lsu_trace=1`을 추가한다.
출력량 제한 없이 모든 accepted Core D-memory request/response를 출력한다.
끄려면 `LSU_TRACE=0` 또는 직접 `+lsu_trace=0`을 사용한다.

- `[LSU-REQ]`: lane, transaction ID, ROB sequence, read/write, 주소, 크기, data/mask.
- `[LSU-RSP]`: lane, transaction ID, response/error/replay, 반환 data.
- `[STALL][LQ]`: valid/address-ready/issued/completed/killed/exception/device bitmap.
- `[STALL][D0/D1]`: pending request/response, hold buffer, load candidate, stall reason, WB ready.
- `[STALL][LQn]`: 살아 있는 load의 sequence/address/destination/mask.

`[STALL]`은 기존처럼 256 idle cycle 이후 출력된다. **시뮬레이션 시간이 전혀 진행하지 않는
delta-cycle 정지라면 clock 기반 monitor도 실행되지 않는다.** 그런 경우 마지막 simulation
time, Xcelium interrupt 시 실행 위치, FSDB 마지막 신호 상태를 함께 전달한다.
시간이 진행하는데 `[STALL]`이 없다면 시작의 `retirement-stall monitor compiled` 배너와
실행 top/snapshot을 먼저 확인한다. 진단 출력은 요청/응답을 강제로 완료시키지 않는다.

원본 ELF와 초기 loader/PMP/CSR 로그부터 정지 후 `[STALL]`까지의 simulation.log를
함께 올려야 원래 상태를 재현하고 RTL 수정 여부를 판단할 수 있다.

### `Claude 피드백` 가설 대조 결과

`rv_lsu_cluster` 출력만 보면 stalled request 저장소가 없지만 실제 연결에는 그 바깥
`rv_ooo_core.dmem_hold_*_q[1:0]`가 있다. empty hold entry는 backend request를 받아
backend `ready`를 올리고, fabric `ready=0`이면 ID/address/size/sequence를 register에
저장해 외부 handshake까지 유지한다. 따라서 cluster만 보고 “lane request가 사라진다”고
결론내리면 top-level data path 한 단계가 누락된다.

보고된 두 raw load와 PC/주소를 재구성하여 Verilator `--assert`로 실행했다.
같은 bank/row의 LHU/LBU가 각각 retire했고 HTIF PASS했으며
`rv_local_mem_if.p_request_stable_when_stalled`를 포함한 assertion failure는 없었다.
현재 RTL 기준으로 해당 문서의 **1순위 request-drop 가설은 재현되지 않았고 구조상 배제**한다.

4-state Icarus probe에서 unwritten `rv_sram_1r1w.mem` read가
`read_valid=1, read_data=64'hxxxx...`인 것은 확인했다. 즉 미초기화 data가 이후 PRF를
거쳐 address/control에 사용되면 X 기반 simulation deadlock 가능성은 존재한다.
그러나 SRAM response valid 자체는 나온다. 이번 로그에는 첫 LHU retire가 없으므로
“그 LHU가 X data로 완료된 뒤 다음 주소를 오염시켰다”는 설명은 현재 정지 지점과 맞지 않는다.
원본 ELF에서 `0x8002d92a`가 PT_LOAD `memsz` 범위에 포함되는지는 loader segment 로그로
확인해야 한다. loader는 각 PT_LOAD의 `memsz` 전체를 쓰고 `filesz..memsz`는 0으로 채우므로,
포함된 주소라면 X 전제도 성립하지 않는다.

Claude 문서에 기록된 replay predicate, invalid LQ response ID guard, direct-store gating은
별도 방어성 검토 항목이지만 이번 DTIM load pair에서 해당 조건이 발생했다는 증거는 없다.

### 2026-09-14 두 번째 서버 로그: issue-arbiter ASRTST

새 로그의 `rv_issue_arbiter.sv` line 166/168은 각각 “grant된 candidate가 valid”와
“grant port가 candidate mask에 포함” assertion이었다. backend 연결에서
`port_ready_i='1`이므로 ready assertion(line 167)이 실패하지 않은 것은 예상과 일치한다.

기존 assertion은 grant를 만드는 `always_comb`와 **별도** `always_comb`에 있었다.
upstream candidate가 바뀐 delta에서 검사 블록이 먼저 실행되면 이전 grant를 새
valid/mask와 비교하여 166/168만 거짓 실패할 수 있다. 검사를 grant producer block의
마지막으로 이동하고 unknown input을 제외했다. issue 선택 기능식은 바꾸지 않았다.

이 로그는 마지막 commit cycle 184520, 정상 LSU response time 1845235 NS 직후
`Multiple control-C's detected`로 끝난다. 256 idle-cycle `[STALL]` snapshot이나 timeout이
없으므로 이 조각만으로 functional deadlock을 입증하지 않는다. assertion flood로
Xcelium 실행이 매우 느려진 상태에서 수동 중단한 것으로 해석한다.

수정 후 source parse/elaboration, 13개 block regression, assertion-enabled 동일-bank
load-pair SoC run을 통과했다. 서버에서는 새 snapshot으로 다시 compile하고 같은 ELF를
중단하지 않은 채 `[STALL]`, timeout 또는 HTIF 종료 중 하나가 나올 때까지 실행한다.

### 2026-09-14 세 번째 서버 로그: Store Buffer 응답 edge에서 time 정지

issue-arbiter assertion을 수정한 새 snapshot에서도 이전 실행과 정확히 같은
`1845235 NS`에서 로그가 끝났다. 마지막 transaction의 `id=0x21`은 load ID가 아니라
상위 비트 `10`인 Store Buffer entry 1의 write response다. 마지막 commit은
`0x800072e4: c9710113 (ADDI)`이며, 그 뒤 256 idle-cycle snapshot도 나오지 않았다.
따라서 이번 로그는 이전의 동일-bank LHU/LBU 가설과 무관하고, 정상적인 장기 ROB stall보다
Store Buffer response의 `done_q` NBA update 직후 simulation delta가 수렴하지 않는 경우를
우선 조사해야 한다.

TB는 이제 Store Buffer response마다 다음 두 줄을 출력한다.

- `[SB-RSP-PRE]`: response posedge의 NBA 적용 전 FIFO head/tail/count 및 valid/sent/done.
- `[SB-RSP-POST]`: 같은 timestep의 postponed region, 즉 NBA와 조합 논리가 수렴한 뒤 상태.

같은 시각에 PRE만 있고 POST가 없으면 clock-based deadlock이 아니라 해당 edge의
zero-delay convergence failure가 확정된다. POST까지 있고 다음 clock이 없다면 TB/DPI 또는
simulator 실행 제어를 별도로 확인한다. compile script에는 Cadence의
`-gateloopwarn`도 추가했으므로 zero-delay loop를 검출하면 Xcelium이 무한 실행 대신
loop warning과 정지 지점을 남긴다. 이 옵션은 `-access +rwc`와 함께 사용되며,
정지된 interactive prompt에서는 `drivers -active`로 활성 driver 목록을 확인할 수 있다.

이 진단도 RTL/TB 변경이므로 반드시 compile/elaborate job부터 다시 수행한다.

### 2026-09-15: LSQ device-permit 조합 고리 제거

전체 SoC top을 Verilator `--report-unoptflat`로 다시 검사하면서 다음 구조적
조합 고리를 확인했다.

```text
device_load_permit
  -> rv_lsq.g_order_check (permit 기반 load 발행 판정)
  -> load_candidate_sequence
  -> rv_lsu_cluster (ROB-head sequence 비교)
  -> device_load_permit
```

기능식상 `load_candidate_sequence`는 permit과 무관하지만, 기존 RTL은 후보의
identity/metadata 출력과 permit 기반 valid/stall 판정을 하나의 procedural block에서
함께 만들었다. 이 때문에 simulator dependency graph에는 실제 순환 cone이 생겼다.
Store Buffer response와 같은 edge에서 ROB head 또는 memory-idle 상태가 바뀌면
`device_load_permit`도 바뀌므로, Xcelium의 event scheduling에서 같은 timestep이
수렴하지 않는 서버 증상과 일치한다. 이 순환 구조가 존재했다는 사실은 확인했지만,
원본 riscv-dv ELF의 Xcelium 정지가 이 고리 하나로 완전히 해소됐는지는 서버의 새
snapshot 실행으로 마지막 확인이 필요하다.

수정 후에는 LSQ를 다음 두 개의 단방향 cone으로 분리했다.

1. `candidate_found/index/sequence`에서 candidate identity와 address/mask/size를 생성한다.
2. 그 결과와 `device_load_permit`를 받아 valid/forward/memory-read/stall만 판정한다.

Store Buffer CAM, Issue Queue oldest-first 선택, Writeback 중재도 출력값 또는 module
temporary를 같은 combinational block에서 다시 읽지 않도록 local work 변수와
single-point output assignment로 정리했다. 향후 같은 문제가 재유입되지 않도록
Verilator ELF runner는 `UNOPTFLAT`을 error로 취급한다.

로컬 확인 결과:

- source parse/elaboration 통과
- Icarus 4-state unit regression 18개 통과
- Verilator block regression 17개 통과
- assertion-enabled HTIF SoC directed ELF 통과
- full SoC top `--report-unoptflat` 결과 순환 경고 0개
- Store Buffer response + same-beat younger enqueue + active forwarding query 전용 회귀 통과

서버에서는 이 변경 commit을 받은 뒤 기존 snapshot을 재사용하지 말고 compile/elaborate부터
한 번만 다시 수행한다. 정상이라면 마지막 `[LSU-RSP]` 뒤에 `[SB-RSP-POST]`와 다음
clock의 commit/heartbeat가 이어져야 한다.

### 서버에서 xcelium 폴더를 교체하는 경우

회사 전용 tool/queue/license 설정은 유지해도 된다. 아래 항목은 최신 소스와 일치시킨다.

| 확인 항목 | 일치해야 하는 내용 |
|---|---|
| `CORE_ROOT`, `RTL_DIR`, `TB_DIR` | 실제 pull한 저장소의 RTL/TB 절대경로 |
| `rtl.f`, `htif_tb.f` | 최신 module 및 `rv_soc_htif_dpi_tb` / logger / DPI 파일 |
| compile `-top` | `rv_soc_htif_dpi_tb` |
| compile/run `-snapshot`, `-xmlibdirname` | 양쪽에서 정확히 같은 값 |
| compile 성공 | queue job 제출 성공만이 아니라 실제 elaborate 성공 확인 |
| 빌드 산출물 | 다른 checkout의 `out/xcelium.d` snapshot을 복사해서 재사용하지 않음 |
| 실행 배너 | `retirement-stall monitor compiled`, `[LSU-TRACE] enabled=1` 확인 |

`issim.scr`의 `xrun -R`은 소스 재컴파일 명령이 아니다. 회사 wrapper가 compile job을
비동기로 제출한다면 compile 완료 전에 sim job을 시작하는지까지 확인해야 한다.
wrapper 구현은 이 저장소에 없으므로 현재 그 동작을 확인했다고 간주하지 않는다.

### 재구성 테스트 빌드 예시 (저장소 루트)

```sh
mkdir -p /tmp/core-a7c-check
riscv-none-elf-gcc -march=rv32imfc_zicsr_zifencei -mabi=ilp32f \
  -nostdlib -nostartfiles -Wl,-T,sw/tests/htif_smoke/rv32_htif.ld \
  -Wl,--build-id=none -o /tmp/core-a7c-check/load_pair.elf \
  sw/tests/htif_smoke/server_a7c_load_pair.S
BINARY=/tmp/core-a7c-check/load_pair.elf bash sim/xcelium/run_verilog_sub.sh
```

toolchain prefix는 서버 설치에 맞게 조정한다. 이 작은 테스트도 서버에서 멈추면
원본 DV 초기화 없이 재현되는 것이므로 실행환경/동일 주소 dual-load 경로를 좁힐 수 있다.
작은 테스트만 통과하면 원본 ELF 및 초기 상태와 비교를 계속해야 한다.
