# CoreMark 2-iteration RTL result

## 결론

2026-09-02에 공식 EEMBC CoreMark source를 현재 RV32 OoO SoC에서 2회
실행했다. 알려진 2K performance CRC가 모두 일치했고 HostIF exit code 0으로
완료했다. compressed control-flow의 raw encoding을 predictor resolve까지 보존한
최종 측정 결과는 **483,143 cycles**, **576,450 retired instructions**, **IPC
1.193125**, **추정 4.139561 CoreMark/MHz**다. 직전 v1.12.1 baseline 대비
cycle은 **9.49% 감소**, IPC는 **10.49% 증가**했다.

이 값은 RTL 구조 비교용 **non-certified implementation estimate**다. 실행이
CoreMark의 공식 최소 10초 조건보다 짧으므로 공식 제출 또는 타 제품의 공인
CoreMark 점수와 직접 비교하는 용도로 사용하면 안 된다.

## 정확히 무엇을 실행했는가

| 항목 | 값 |
|---|---|
| Upstream | `eembc/coremark` |
| Commit | `1f483d5b8316753a742cbf5590caf5bd0a4e4777` |
| Source mode | 2K performance, static memory, one context |
| Iterations | 2 |
| Compiler | xPack RISC-V GCC 15.2.0-1 |
| ISA / ABI | `rv32imc_zicsr_zifencei` / `ilp32` |
| Optimization | `-O2` |
| Code memory | ITIM `0x8000_0000`, 128 KiB |
| Data/stack | DTIM `0x8002_0000`, 128 KiB |
| ELF footprint | text 11,284 B, data 12 B, bss 2,068 B |

공식 algorithm source는 repository에 복제하거나 수정하지 않았다. runner가
clean upstream checkout과 commit을 검사하고, 이 저장소의
`sw/benchmarks/coremark/port`만 platform port로 함께 컴파일했다.

## 기능 결과

| Check | Expected | Observed | 결과 |
|---|---:|---:|---|
| seed CRC | `e9f5` | `e9f5` | PASS |
| list CRC | `e714` | `e714` | PASS |
| matrix CRC | `1fd7` | `1fd7` | PASS |
| state CRC | `8e3a` | `8e3a` | PASS |
| final CRC | iteration dependent | `72be` | 기록 |
| datatype/port/CRC error | 0 | 0 | PASS |
| HostIF exit | 0 | 0 | PASS |

status `0x00000009`는 bit 0(known 2K performance seed)과 bit 3(shorter than
10 seconds)만 설정됐음을 뜻한다. bit 3은 이번 짧은 RTL 실행에서 의도한
결과이며 CRC 오류가 아니다.

## 성능 산식

timed region 전후의 machine CSR을 RV32 high-low-high 순서로 안정적으로 읽었다.

```text
cycles                 = 483143
retired instructions   = 576450
cycles / iteration     = 483143 / 2 = 241571.5
instructions / iter.   = 576450 / 2 = 288225
IPC                    = 576450 / 483143 = 1.193125
estimated CoreMark/MHz = 2 * 1000000 / 483143 = 4.139561
```

예를 들어 향후 합성 결과가 100 MHz이고 TIM이 core와 1:1로 동작한다면 단순
cycle estimate는 약 413.96 CoreMark/sec다. 이는 예시 환산일 뿐 현재 RTL의
실제 Fmax를 측정한 결과가 아니다.

## 이 workload가 발견한 RTL 결함

첫 실행은 약 712,439 simulation cycle에서 멈췄다. branch recovery와 같은
cycle에 pre-flush LQ view의 younger load가 D-memory request를 발행했고, LSQ는
해당 entry를 flush했다. 늦게 돌아온 response ID가 이미 재사용된 LQ index를
가리키면서 LSQ는 새 load를 완료로 표시했지만 writeback metadata는 옛 ROB
sequence를 담아 ROB completion이 폐기됐다. 그 결과 ROB head load가 영구
미완료 상태가 됐다.

`rv_lsu_cluster`가 `flush_valid_i`인 cycle에는 speculative memory-read request와
store-to-load forward handshake를 시작하지 않도록 수정했다. 동시에 flush
cycle의 speculative D-memory read가 0임을 검사하는 assertion을 추가했다.
수정 후 동일 ELF가 최초 baseline 684,571 timed cycles에 CRC/exit PASS로
완료했다. 아래 성능 변경은 이 correctness fix 이후 별도로 적용했다.

## 병목 profile과 변경 결과

software가 timed region 경계에 HostIF marker를 기록하고 testbench profiler는 그
사이만 관측한다. Boot/ELF load/interrupt/결과 출력은 제외된다. A/B 결과는 다음과
같다.

| 구성 | cycles | IPC | CoreMark/MHz estimate |
|---|---:|---:|---:|
| 최초 공개 baseline | 684,571 | 0.842060 | 2.921538 |
| marker 포함 profile baseline | 688,060 | 0.837790 | 2.906723 |
| IFU/I-Fabric same-cycle handoff | 653,304 | 0.882361 | 3.061362 |
| PC bimodal predictor | 614,717 | 0.937749 | 3.253530 |
| bimodal/gshare tournament | 604,885 | 0.952991 | 3.306414 |
| + 16-entry target/loop block buffer | 548,343 | 1.051258 | 3.647352 |
| 32-entry capacity experiment | 548,318 | 1.051306 | 3.647518 |
| + zero-bubble target redirect/fill | 537,249 | 1.072966 | 3.722669 |
| + split store-address/data issue | **533,820** | **1.079858** | **3.746581** |
| + raw compressed-branch resolve | **483,143** | **1.193125** | **4.139561** |

최종 profiler의 marker-window 483,190 cycles에는 marker 처리 차이가 포함된다.
핵심 관측값은 branch mispredict 7,477회, frontend empty 54,547 cycles,
IQ nonempty/no-issue 103,442 cycles, ROB-head incomplete 118,573 cycles,
unknown older-store-address load stall 24,043 cycles, D-memory wait 60,828 cycles다.
frontend empty는 queue-zero 43,584와 incomplete-instruction 10,963으로 분해됐고,
predicted redirect 82,541회 중 target-buffer hit는 62,879회였다. replay register
counter는 0이며 target hit 다음 cycle의 empty는 2,566회다. event는 서로 겹칠 수
있으므로 cycle 감소량으로 단순 합산하지 않는다.

branch checkpoint 8→16, LQ 24→32 증설은 성능 변화가 없어 되돌렸다. lane-1
load 동시 retire도 최종 predictor 구성에서 112 cycles 느려져 되돌렸다. target
buffer 16→32 entry는 25 cycle만 줄어 추가 면적을 정당화하지 못해 되돌렸다.
raw C-branch resolve 적용 후 checkpoint 8→16 재실험도 426 cycle만 감소해 8개를
유지했다. ROB 64/checkpoint 16 조합도 607 cycle 이득뿐이라 ROB 48을 유지했다.
현재 채택한 변경은 IF response/next-request same-cycle handoff, tournament
predictor, redirect-cycle target request, 16-entry target/loop block buffer,
redirect+queue-fill 원자 처리와 split store-address/data issue다.

split store는 base가 먼저 준비되면 address-only phase로 SQ address/mask를 확정한다.
store data가 늦으면 동일 IQ entry가 ROB sequence와 SQ index를 유지하다 data
writeback에 다시 wakeup된다. data-only phase는 기존 주소를 보존하고 이 최종
phase에서만 ROB store completion을 만든다. 따라서 load ordering stall을 줄이면서
uncommitted store의 외부 visibility는 여전히 ROB-head commit으로 제한된다.

compressed instruction은 execution에서 canonical 32-bit expansion을 사용하지만,
predictor query/resolve/commit은 instruction length와 일치하는 raw encoding을 사용해야
한다. 기존 backend는 resolve metadata에 canonical instruction을 저장하면서 length는
`INST_LEN_16`으로 유지했다. 이 조합은 C.Bxx/C.J/C.JR/C.JALR 분류와 PHT/BTB/RAS
학습 및 mispredict history recovery를 누락시켰다. raw instruction을 보존하도록
수정한 결과 branch mispredict는 33,832→7,477(-77.9%), frontend empty는
106,010→54,547(-48.5%), architectural cycle은 533,820→483,143(-9.49%)가 됐다.
최종 branch profile은 conditional 106,465/7,195(resolve/miss), direct jump
11,233/0, indirect jump 4,333/282, call 3,659/4, return 3,694/278이다.

## 보존 파일

| 파일 | 내용 |
|---|---|
| `coremark.result.log` | 사람이 읽는 결과 요약 |
| `coremark.result.json` | 자동 처리 가능한 metric/CRC |
| `coremark.perf.json` | timed-region pipeline stall/event/occupancy profile |
| `coremark.sim.log` | Verilator build, ordered HostIF packet, exit log |
| `coremark.disasm` | 실제 실행 ELF의 source/interleaved disassembly |
| `coremark.headers` | ELF header와 ITIM/DTIM PT_LOAD layout |
| `coremark.symbols` | 링크된 symbol 주소 |

재생성 명령:

```powershell
powershell -ExecutionPolicy Bypass -File scripts/run_coremark.ps1 `
  -Iterations 2 `
  -PublishRoot verification/benchmarks/coremark
```

공식 benchmark 규칙은 [CoreMark README](https://github.com/eembc/coremark/blob/main/README.md),
port 요구는 [barebones porting guide](https://github.com/eembc/coremark/blob/main/barebones_porting.md)를
참조한다.
