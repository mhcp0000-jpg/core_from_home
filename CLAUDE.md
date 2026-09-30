# Core development handoff

이 파일은 사람과 Claude Code/Codex가 같은 작업 상태에서 이어서 개발하기 위한 짧은 체크리스트다. 상세 설계의 authoritative source는 `docs/HDD_Core_Architecture.md`다.

## 현재 기준

- Branch: `main`
- 현재 RTL checkpoint: backend leaf timing candidates v1.18.12; whole-path regression unresolved (2026-09-30)
- 비교 기준 RTL commit: `8f1c6ba Store fetch responses in a circular block queue (v1.18.11)`
- 이전 RTL commit: `be78fec Document backend timing checkpoint` (v1.18.3)
- v1.18.11 commit 범위: frontend queue RTL/queue TB/HDD/그림/본 체크리스트; 사용자 소유 untracked 파일과 `debug.txt`는 제외
- v1.18.3 서버 STA checkpoint는 IQ/LQ/SQ selector, rename resource-return,
  FPU 4-stage 경계를 포함한다.
- Core top: `rv_ooo_core` (`rtl/rv_ooo_core.sv`)
- SoC top: `rv_soc_top` (`rtl/soc/rv_soc_top.sv`)
- Core source list: `sim/xcelium/sources_core.f`
- SoC/Xcelium source list와 실행법: `sim/xcelium/README.md`
- 목표: RV32IMFC, 2-wide dual issue, OoO execute/in-order dual commit, dual LSU/LSQ, precise trap/interrupt, RV64 확장 가능 구조

## 작업 체크리스트

- [ ] 서버 목표: 최소 1 GHz, 도전 1.2 GHz 이상. 같은 overhead 가정 시 1.2 GHz arrival 약 0.6475 ns; 실제 SDC 확인 필요. Nangate45를 2 nm로 환산하지 말 것.
- [x] Backend leaf 후보: ALU32 1096.49→994.88 ps, ALU64 2118.34→993.54, DIV2232.56→1901.92, MUL2675.43→2378.11(area −46.2%), WB2048.74→1691.00(area −16.1%). latency 불변.
- [x] 전체 후보 CoreMark assertion-enabled PASS, 477687/576450/IPC1.206753, v1.18.11과 profiler 전체 counter 동일. block17/backend integration/최신 C FP signature009e00b9 exit0 PASS.
- [ ] **전체 backend regression 발견**: 4369.34→4495.60 ps(+2.9%), area322203.672→314537.818. parallel bypass leaf 개선만으로 채택 불가. priority bypass 원복 ablation은4444.72ps/322502.390(+1.7%delay), macro start=`u_iq.valid_vec[43]`. 다음은 IQ→연결 경로. 1.2 GHz 달성 주장 금지.
- [x] 최종 priority bypass RTL 재회귀: CoreMark 모든 profiler counter 동일, assertion-enabled C FP exit0, Yosys whole-core structural check PASS. randomized equivalence ALU/DIV/MUL RV32/RV64 각150000 및WB30000 PASS. baseline MUL stall SVA는 flush예외가 누락되어 수정; baseline fuzz는 SYNTHESIS로 built-inSVA만 끄고 equality/$fatal 유지.
- [ ] 재현: `powershell -ExecutionPolicy Bypass -File scripts/run_backend_timing_equivalence.ps1` (reference git8f1c6ba, ignored out/, RV32/64 ALU/DIV/MUL150000 each, WB30000). 단위 수치와 전체/서버 STA를 반드시 분리할 것.

- [x] v1.18.11 후보: 32×16-bit parcel ring → 4×128-bit block ring + direct redirect offset. frontend 3,774.23 → 2,940.50 ps(−22.1%), area 349,936.83 → 342,718.92 µm²(−2.1%). unit PASS, CoreMark CRC/status/exit PASS.
- [x] 후보 비교: one-hot pointer(queue 1,807.10 ps), fixed-head shift(frontend 4,164.89 ps), 8-entry FTB(3,917.58 ps), parallel availability threshold(4,182.80 ps)는 모두 timing 악화로 원복. threshold/block-ring 30,000 random cycle equivalence + threshold assertion-enabled full SoC CoreMark PASS.
- [ ] v1.18.11 official CoreMark 477,687 cycles / 576,450 instret / IPC 1.206753. v1.18.10 477,680 대비 +7 cycle(+0.0015%); 엄밀한 IPC 비감소 조건은 미충족. profiler는 477,743/576,462. 서버 0.8142 ns target 미확인.
- [ ] 다음 frontend 후보: fill/predecode에서 direct target 또는 FTB index를 register에 미리 저장해 queue read→target add→FTB read 직렬 경로 제거. cross-block 명령과 FTB refill metadata/PMP invalidation까지 설계 후 측정.

- [x] ROB/RAT/RRAT/free-list/PRF/IQ/WB/branch recovery 기본 구조 구현
- [x] dual LSU, LQ/SQ, store-to-load forwarding, commit-only store visibility 구현
- [x] IFU/predictor, CSR M/U, PMP, CLINT/PLIC, ITIM/DTIM, AXI SoC/DPI ELF 경로 구현
- [x] CoreMark 2 iteration: 468,930 cycles, IPC 1.229288, 4.265029 CoreMark/MHz, CRC/exit PASS
- [x] WB arbitration 직렬 age scan 제거: 공개 preflight 15.936 ns → 2.347 ns
- [x] LSQ load oldest-two 직렬 scan 제거: 9.993 ns → 6.379 ns (면적 증가 주의)
- [x] FPU 내부 실제 pipeline cut 구현: align/product/accumulate → register → normalize/round/pack
- [x] FPU 기본 총 latency=3 및 throughput=1/cycle 유지
- [x] FPU 6,470-vector differential, unit/block/backend, GCC C/FP/LSU ELF PASS
- [x] FPU 공개 5 ns target preflight: 7.293 ns → 5.079 ns, 39,951.1 → 34,531.1 um^2
- [x] FPU 변경 뒤 CoreMark cycle/IPC가 정확히 동일함을 확인
- [x] HDD v1.18.2와 `docs/diagrams/modules/rv_fpu.svg`를 최신 FPU RTL에 맞춰 완료
- [x] `git diff --check`, 최종 회귀 결과 확인 후 FPU 변경만 선별 commit/push
- [x] 56-entry IQ 구조 검토: 균형 tournament tree + resource-return 경로 분리로 1 ns preflight 6,180.63 → 3,309.81 ps
- [x] LQ oldest-two tournament tree와 SQ 4-level youngest-match reduction tree: 5,785.50 → 2,472.17 ps, area 41,782.2 → 23,994.8 um^2
- [x] v1.18.3 회귀: block 17종 PASS, backend integration PASS, FPU differential 6,470 vectors PASS, GCC C/FP ELF PASS(event 0x009e00b9, exit 0, FP commit 68, payload trap 0)
- [x] v1.18.3 CoreMark: 468,408 cycles, 576,450 instret, IPC 1.230658, CRC/exit PASS (baseline 468,930 / 1.229288 대비 522 cycles 감소)
- [x] `rv_backend.sv`와 differential TB를 `rv_fpu.LATENCY=4`로 통일
- [x] `docs/diagrams/modules/rv_fpu.svg`를 v1.18.3 FPU 내부 구조에 맞춰 갱신
- [x] v1.18.3 변경분 선별 commit/push (사용자 소유 untracked 파일 제외)
- [x] FPU critical path 원인 규명: `LATENCY` 3/4/5/6 sweep에서 4 이상부터 critical start point가 `div_quotient_q`로 고정되고 delay가 4.7~4.8 ns에서 평탄해진다. 병목은 add/FMA가 아니라 iterative FDIV/FSQRT의 `pack_finite`(normalize+round+pack)와 sqrt recurrence의 128-bit 비교다. fast pipe 추가 분할은 이득 없음
- [x] CoreMark ELF가 soft-float(`rv32imc`)임을 확인. FP latency 변경은 CoreMark cycle에 영향이 없으므로(`LATENCY=3`/`4` 모두 468,408) FP 판정은 6,470-vector differential과 GCC C/FP ELF로 한다. C/FP ELF 마지막 commit cycle만 910 → 911
- [x] 공개 timing screening blind spot 제거: `scripts/run_open_timing.ps1`의 `$blocks`에 `rv_store_buffer`, `rv_lsu_cluster`, `rv_multiplier`, `rv_divider`, `rv_fetch_queue`, `rv_csr_file` 추가. 실제 최장 block이었던 store_buffer(6,027.28 ps)/lsu_cluster(6,270.32 ps)가 여기 빠져 있어 보이지 않았다
- [x] v1.18.4 구조 수정 5건: store_buffer youngest-match reduction tree(6,027.28 → 1,616.02 ps), ROB flush-keep popcount tree(3,036.22 → 1,243.73 ps), LSQ binary-search allocator, IQ popcount count + age-ordering matrix(3,493.28 → 2,945.19 ps), multiplier stage0 재배치. lsu_cluster 6,270.32 → 2,456.02 ps
- [x] v1.18.4 FPU 4단계: (a) align/accumulate 분리 + negate folding으로 `LATENCY=5`, (b) `MAGW` 128 → 80, (c) 직렬 add→negate를 병렬 3-가산기로 + `DIV_FRAC` 52 → 28, (d) `normalize_fp_pre`/`pack_finite` 지수 산술 16-bit 재구성, (e) FSQRT 피연산자 정규화로 radicand/root/remainder 128/64/130 → 58/29/60 bit. **4,709.85 → 2,906.45 ps(−38.3%), area 34,131.5 → 26,913.9 um^2(−21.1%)**
- [x] 반복 지연 개선: FDIV 77 → 53 cycle, FSQRT 64 → 29 cycle (피연산자 정규화가 선행 조건. 정규화 없이 `DIV_FRAC=28`로 낮추면 vector 1550에서 1 ULP 오차)
- [x] v1.18.4 회귀: check_rtl 40 구성 PASS, unit 18종 중 17 PASS(`rv_fetch_queue_tb`는 손대지 않은 `f634128`도 동일하게 실패하는 Verilator 전용 환경 artifact), block 17종 PASS, backend integration PASS, FPU differential 6,470 vectors PASS, GCC C/FP ELF PASS(commit trace md5 baseline과 동일)
- [x] v1.18.4 FPU 등가 co-sim: 변경 전 모듈을 `rv_fpu_ref`로 rename해 bit 단위 비교. FDIV 14,600 + 5-op 32,900 + FSQRT 24,170 = **71,670 vectors 모두 data/fflags bit-exact**
- [x] v1.18.4 CoreMark: **468,408 cycles, 576,462 instret, IPC 1.230684**, 593,268행 commit trace md5가 baseline과 완전 일치 (CRC/exit PASS)
- [x] 폭 vs 지연 관계 규명: 같은 flow에서 순수 가산기 W=32→128일 때 area는 3.97배 선형, delay는 2.01배(≈√W). 즉 **폭 축소는 area 레버이고 timing 레버는 직렬 캐리 체인의 개수**다. `fp_align_finish`의 뒤쪽 negate 하나가 스테이지의 40%(1,332 ps)였고, `normalize_fp_pre`는 LZC 뒤 32-bit integer 산술 직렬 연결이 대부분이었다
- [x] v1.18.5 FPU 추가 2단계: (a) 정렬 단에 그대로 남아 있던 32-bit 지수 산술을 `EXPW=16`으로 통일(`lsb(a)+lsb(b)` → `max` → `common-own` → barrel shift가 직렬 32-bit 3연타였다) + sticky mask 비교를 7-bit로 축소 → 2,906.45 → 2,590.69 ps, (b) `fp_align_finish`의 중첩 early-return을 평탄한 select 한 번으로 → **2,513.04 ps**. be78fec 대비 **−46.6%, area −20.9%**
- [x] v1.18.5 IQ 추가 2단계: (a) `am_second`가 `am_first`를 기다리며 ENTRIES-wide 축약을 두 번 직렬로 돌던 것을 saturating {any, ge2} 트리 하나로 통합(oldest = count 0, second = count 1) → 2,832.49 ps, (b) candidate payload를 인코더 + ENTRIES:1 mux 대신 `cand_payload_t` one-hot AND-OR로 → **2,422.98 ps**. be78fec 대비 **−30.6%**, area 277,138.2 → 225,992.5 um^2로 v1.18.4의 +16.2% 절충이 해소되어 baseline보다 **−5.2%**
- [x] 설계 최장 block 6,270.32 → **2,513.04 ps (−59.9%)**. 순서는 FPU 2,513.04 > lsu_cluster 2,456.02 > IQ 2,422.98
- [x] v1.18.5 회귀: check_rtl 40 구성 PASS, unit 17/18 PASS(`rv_fetch_queue_tb` 기존 환경 artifact), block 17종 PASS, backend integration PASS, FPU differential 6,470 vectors PASS, FPU 등가 co-sim 57,070 vectors bit-exact, GCC C/FP ELF PASS, CoreMark **468,408 cycles / IPC 1.230684** 및 593,268행 commit trace md5 동일
- [x] **전체 backend(Top) 합성 성공.** 멈추던 원인은 도구 문제가 아니라 yosys ABC 기본 script의 `scorr`/`dc2`/`dretime`/`retime`이 610,696 cell 네트워크에서 끝나지 않는 것이었다(21분간 CPU 97%, 로그 진행 0). delay 중심 script(`strash;&get -n;&dch -f;&nf -D t;&put;buffer;upsize;dnsize;stime -p`)로 바꾸니 **약 25분에 완주**. `retime`은 register를 옮겨 경로 해석을 무의미하게 만들므로 뺀 것이 맞다
- [x] `scripts/run_open_timing.ps1`/`.sh`의 whole-top 항목(`rv_backend`, `rv_ooo_core`)이 이 trim script를 쓰도록 수정. ps1은 `-IncludeWholeTop`, bash는 `INCLUDE_WHOLE_TOP=1`. ABC의 `source`는 yosys placeholder `{D}`를 전개하지 않으므로 delay target은 script 파일에 직접 써 넣는다
- [x] **서버 STA 경로가 PC flow에서 재현됐다.** flatten 후에도 계층 이름이 남아 ABC start-point가 `u_lsu_cluster.u_lsq.candidate_found[0]`으로 찍히며, 이는 사용자가 서버에서 본 `lsu_cluster/lsq/candidate_index_reg → mul/stage0`과 같은 register 그룹이다. 앞으로 서버를 기다리지 않고 이 경로를 반복 측정할 수 있다
- [x] whole-backend delay: `be78fec` 14,827.02 ps → v1.18.5 **8,072.33 ps (−45.6%)**. area 284,938.40 → 322,086.37 um^2(+13.0%, 대부분 56x56 age matrix FF. DFF 3,379 → 6,568). **시작점은 여전히 LSQ candidate**
- [x] 보정계수 측정(같은 lowering + 같은 trim script로 단일 block 재측정): FPU 2,513.04 → 2,925.11 ps(1.16배), IQ 2,422.98 → 3,608.58 ps(1.49배). 이 기준으로 whole-backend 8,072 ps는 정식 flow 환산 약 **5.4~7.0 ns**, 설계 최장 block의 **2~2.7배**
- [x] 차이의 정체: `LSQ candidate → store_buffer CAM/youngest → lsu_cluster completion → writeback_arbiter 11-source → IQ tag_wakes → select → issue arbiter → multiplier stage0` 다섯 모듈 사이에 **중간 register가 하나도 없다**. block screening은 이 경로를 다섯 조각으로 나눠 보므로 각 조각을 줄여도 합은 남는다. v1.18.5에서 다섯 모듈을 전부 줄였는데도 start-point가 그대로인 것이 그 증거다
- [ ] whole-top 실행 비용: 전처리(read_slang~dfflibmap) 약 8분 + ABC 약 25분, peak 메모리 약 5 GB. 매 변경마다는 무겁고 라운드 종료 sign-off 용도가 적당하다
- [x] v1.18.7 모듈 경계 조합 경로 추적 도구 `scripts/find_comb_chains.py` 추가: hierarchy JSON에서 모듈별 입력→출력 조합 arc와 top 연결을 따라 register 없이 여러 모듈을 지나는 사슬을 나열한다(사용법은 파일 머리말). 모듈 hop 수는 delay가 아니므로 위치 파악용이고 delay는 whole-top 합성으로 확인한다
- [x] 진단: `FU 결과 reg → writeback arbiter(FF 0) → IQ wakeup/select → issue arbiter(FF 0) → PRF(비동기 read + write-through) → FU → 결과 reg`가 한 cycle 조합 루프였고, load는 그 앞에 LQ candidate → SQ/SB CAM → forward가 붙었다. writeback grant → result buffer ready → issue mask backpressure 경로, recovery flush → IQ payload/PRF 주소 경로도 겹쳐 있었다
- [x] IPC 사전 측정: writeback wakeup 전부 등록 E1 **+18.96%**, fast source만 직접 E2a **+9.27%**, mul/div/fpu까지 직접 E2x +9.27% → 비용은 전부 load. CoreMark load 완료는 memory 107,913 / forwarding 1,286(1.2%)
- [x] 수정 A (producer-side wakeup): 목적지를 쓰는 source 7개가 결과를 제시하는 동안 직접 wakeup + operand bypass. source 2..9 pass-through skid, `rv_exec_result_buffer` `DEPTH=2`(기본 1 유지), `rv_phys_regfile` `WRITE_BYPASS=0`(기본 1 유지), system op는 grant 다음 cycle 등록 wakeup(flush 게이트 없음), squash된 outstanding load 응답은 `rv_lsu_cluster.load_meta_live_q`로 목적지 claim 제거, IQ payload는 flush로 게이트하지 않음(valid만)
- [x] 수정 B: store→load forwarding 완료를 `rv_lsu_cluster.forward_q`로 등록(forwarded load만 +1 cycle, memory 응답은 same-cycle 유지)
- [x] 결과: whole-backend **8,072.33 → 6,291.77(A) → 5,687.73 ps(B), −29.5%**. start-point가 `u_lsu_cluster.u_lsq.candidate_found`에서 **`fetch_instr_i` → decode → rename → dispatch → `u_iq.age_matrix_q`**로 이동. whole-backend area 322,086.37 → 376,587.11 um^2(+16.9%), DFF 6,568 → 7,366. IQ block(wake port 4→8) 2,422.98 → 2,426.64 ps, area +6.8%
- [x] CoreMark **468,967 cycles(+0.119%) / IPC 1.229217**, CRC/exit PASS, cycle·lane 열을 뺀 commit trace는 `mcycle` 읽기 2건과 종료 후 출력 명령만 다르고 576k 명령 본문 동일. cycle 증가는 분기 예측 학습 시점 변화 잡음
- [x] 검증: check_rtl 40 구성, unit 18종(`rv_fetch_queue_tb` 기존 artifact 제외 PASS) + 신규 `rv_exec_result_buffer_depth2_tb`(200k cycle 무작위, 참조 모델 일치, `run_unit_tests.ps1` 등록), block 17종, backend integration, C/FP ELF trace md5 동일. **전부 assertion 활성(-DSYNTHESIS 없이)으로도 PASS**
- [x] **기존 문제 발견 → v1.18.8에서 수정:** `rtl/soc/rv_local_mem_if.sv:54` `p_request_stable_when_stalled`가 CoreMark sim 시각 177,545(약 17,750 cycle)에서 실패(`be78fec`에서도 동일). 원인은 `rv_d_fabric` outbound 선택이 매 cycle age로 재계산돼, bridge busy로 stall 중인 younger load를 뒤에 나타난 older load로 바꾼 것(ITIM 상수 load가 outbound 경유). 기존 실행 스크립트가 모두 `-DSYNTHESIS`라 가려졌다
- [x] ~~다음 1: dispatch 경로(`fetch → decode → rename → dispatch`)에 decode→rename pipeline register~~ → v1.18.8에서 완료(아래)
- [ ] 다음 2: issue 루프(`IQ select → arbiter → PRF/bypass → FU`)는 이제 register에서 시작. 더 줄이려면 issue→execute register + issue-time 추정 wakeup
- [x] v1.18.8 수정 A: `rv_backend`에 decode→dispatch uop register(`uq_q`, 1 bundle, 35 필드×2 lane) 추가. rename/ROB/IQ/LSQ/checkpoint 할당은 등록된 `dec_*`에서 계산, `rv_decode2`는 무수정. 모든 flush에서 비움(아직 ROB sequence 없음 = 전부 younger, flush는 항상 redirect 동반). `uq_hold`(serial barrier / system redirect pending / register 안 serializing op) 동안 새 bundle을 받지 않아 decode가 항상 post-serialization CSR 상태(`mstatus.FS`)를 본다. serializing bundle dispatch cycle에는 register를 명시적으로 비운다(누락 시 같은 bundle 반복 dispatch — backend integration TB가 검출)
- [x] v1.18.8 수정 B: `rv_rename2` 수락 판정을 free bitmap `{any, ≥2}` 균형 tree(`free_any_ge2`) + class별 필요 수 비교(`allocation_count_ok`)로 병렬화. tag 선택 encoder는 그대로라 할당 tag 동일, 기존 직렬 판정과의 일치를 assertion으로 상시 확인. block 1,783.48 → 1,668.06 ps(−6.5%), area −1.7%
- [x] v1.18.8 수정 C: `rv_lsu_pipe` `DEPTH=2`(기본 1 유지) 2-entry 순서 buffer, `issue_ready`는 등록된 점유만 봄 → `PMP → completion 판정 → AGU ready → issue select` 경로 제거. `rv_lsu_cluster.AGU_DEPTH`(기본 1)로 전달, backend에서 2. 신규 `rv_lsu_pipe_depth2_tb`(200k cycle 무작위, 참조 모델 일치, `run_unit_tests.ps1` 등록). CoreMark cycle/trace가 B와 비트 동일(IPC 비용 0)
- [x] 결과: whole-backend **5,687.73 → 4,794.04(A) → 5,005.97(B) → 4,438.31 ps(C), −22.0%** (v1.18.5 대비 −45.0%). area 376,587.11 → 383,862.21 um^2(+1.9%), DFF 7,366 → 8,287. B 수치 상승은 B와 무관한 PMP 경로가 최장으로 보고된 ABC 매핑 변동(같은 경로도 run마다 수 % 흔들림). 최장 경로는 이제 `dmem_rsp_replay_i → load 완료 → producer wakeup → select → ALU → g_fast[0]` (v1.18.7에서 IPC 때문에 의도적으로 남긴 load same-cycle wakeup)
- [x] CoreMark **477,581 cycles / IPC 1.207046**: v1.18.7 대비 +1.84%, 기준 468,930 대비 +1.845%. mispredict 7,204 → 7,504, return mispredict 262 → 411. 비용 대부분은 redirect penalty +1 cycle, return 증가분은 RAS가 recovery 때 pointer만 복원해 wrong-path call 덮어쓰기가 늘어난 것
- [x] 검증: check_rtl 40 구성, unit 20종(`rv_fetch_queue_tb` 기존 artifact 제외 PASS), block 17종, backend integration(MPRV 복구 대기 조건을 `rob_empty && !dec_valid`로 확장), C/FP ELF trace(cycle/lane 제외) 동일, CoreMark 명령 본문 trace 동일. **전부 assertion 활성으로도 PASS**
- [x] v1.18.8 fabric 수정: `rv_d_fabric` CLINT/outbound 선택을 grant 후 accept까지 고정(`clint_lock_q`/`outbound_lock_q`) + lock 유지 assertion. CoreMark 477,581 → **477,685 cycles(+0.02%) / IPC 1.206783**, CRC(seedcrc 0xe9f5, list 0xe714, matrix 0x1fd7, state 0x8e3a, final 0x72be, status 0x9) 일치, 명령 본문 trace 동일. `rv_d_fabric` wrapper(DTIM 1 KiB) 1,002.91 → 999.78 ps, area +1.3%
- [x] **모든 assertion 활성(비활성화 없음)**: unit 20종(`rv_fetch_queue_tb` 기존 artifact 제외), block 17종, backend integration, C/FP ELF, CoreMark PASS, assertion 실패 0
- [ ] 다음 1: load 응답 same-cycle wakeup → select 경로. 단순 등록은 +9%급이라 issue→execute register + issue-time 추정 wakeup(hit 가정 + replay) 필요
- [ ] 다음 2: `rob trap → trap_controller → recovery flush → IQ candidate_valid → select → FU`(7 모듈). architectural redirect 1 cycle 등록 후보
- [ ] 다음 3: RAS top entry를 recovery snapshot에 포함해 return mispredict 증가분 회수
- [x] v1.18.9 `rv_ooo_core` Top(macro flow, v1.18.8 RTL): **4,685.99 ps**, area 433,875.53 um^2, DFF 8,681. 최장은 frontend `fetch_queue.count_q → 길이 판정 → predictor direct-target → predicted redirect → FTB lookup → IFU PMP → fetch queue fill(byte_d)`. `rv_frontend` 단독 3,551.26 ps(IFU PMP가 밖이라 잘림)
- [x] D-bus 응답 경로가 긴 이유: 한 cycle 안에 wakeup + select + port 중재 + payload + operand/bypass + 실행. 가장 큰 직렬 요소는 `rv_issue_arbiter`(sequence 재비교·port pair 탐색)와 barrier sequence 비교
- [x] 수정: `rv_issue_arbiter` `AGE_ORDERED`(기본 0 유지, backend 1) block 988.72 → 571.38 ps. 일반 탐색과의 일치를 같은 process assertion + 신규 `rv_issue_arbiter_age_tb`(200k)로 확인. serializing lane 0 bundle을 분리 dispatch해 issue 경로의 barrier 비교 제거(assertion으로 보장)
- [x] 결과: backend **4,438.31 → 3,972.90 ps(−10.5%)**, area 383,862.21 → 383,266.10 um^2. 최장은 ALU back-to-back 루프(`g_fast[0]` → wakeup → select → 중재 → ALU → `g_fast[0]`). CoreMark **477,689 cycles(+4) / IPC 1.206773**, CRC 동일. unit 21종·block 17종·backend int·C/FP ELF·CoreMark 전부 assertion 활성 PASS
- [x] **측정 맹점 발견:** whole-top macro flow는 `$mem`의 variable-address async read 경로(49개 array: PRF, fetch queue byte, predictor table, load_meta, LSQ/SB, branch_cp 등)를 ABC에서 잘라 낙관적이다. 신규 `scripts/run_analysis_netlist.sh`(reset 비활성 + memory 개별 mapping)로 `rv_frontend` 3,551.26 → **4,194.16 ps**(table flop화 area 365,932 um^2), `rv_backend`(issue 루프 array만 mapping) 4,282.91 ps(최장이 FPU로 보고 = whole-top ABC ±10% 흔들림). ROB/checkpoint/branch info/LSQ·SB는 7 GB 한계로 미mapping — 서버에서 동일 script 권장
- [x] 신규 `scripts/trace_named_path.py`: pre-ABC 넷리스트에서 named 신호로 경로 단계를 표시(단위 delay, 직렬 loop 과대평가 — 단계 이름 붙이기 용도)
- [x] v1.18.10 frontend critical feedback 최적화: fetch queue를 64-byte shift 배열에서 32×16-bit circular parcel 구조로 변경(leaf 1,960.94 → 1,635.94 ps, area 27,933.72 → 12,829.45 µm²). 두 lane direct target 후보는 PHT와 병렬 생성하되 FTB wide data read는 선택된 한 번만 수행
- [x] FTB entry에 current-response PMP allow[7:0]을 data와 함께 저장하고 hit에서 복원. PMP/privilege/FENCE.I 변경은 기존 architectural redirect가 FTB를 invalidate하므로 stale 권한 재사용 없음. `predictor → FTB → IFU PMP → fault_q`에서 PMP 직렬 cone 제거
- [x] 동일 open-cell A/B: 2-port wide FTB+parcel 4,227.85 ps → **selected 1-read FTB+cached PMP 3,774.23 ps**, area 354,776.17 → 349,936.83 µm². two-wide data read(4,692.21), parcel valid bitmap(합성 폭증), BTB-ahead+verify(4,029.86)는 폐기
- [x] v1.18.10 CoreMark: **477,680 cycles**(v1.18.9 대비 −9), profiler retired 576,462 기준 normalized IPC 1.206795(기준 1.206773), CRC/status/exit PASS. marker-window 표시는 retired 576,450 기준 IPC 1.206770. 동일 ELF를 `--assert` 활성 full-SoC로 재실행해 동일 perf 수치와 exit 0 확인
- [ ] 서버 2 nm STA 재측정 필요: 사용자 관측 1.5 ns/666 MHz 경로가 1 ns를 통과하는지는 서버 library/constraint 결과로만 확정한다. 이번 open-cell 수치는 후보 상대 비교이며 1 GHz 보장이 아님
- [ ] 다음 A(결정 필요): backend issue/execute 분리 + select 시점 ALU wakeup. load/mul/div/FPU 소비자 +1 cycle(E2a 기준 CoreMark 약 +9%), DTIM hit 가정 wakeup + replay로 회수 가능
- [ ] 다음 B(결정 필요): frontend 예측을 fetch block 주소 기반(ahead)으로 바꾸거나 한 단 등록(taken마다 bubble). predictor table async read → sync read(SRAM) 전환과 함께
- [ ] 다음 C(area): `branch_*_q`를 ROB sequence(256) 대신 ROB index(48)로 → 약 60k → 11k bit
- [x] SystemVerilog 캐스팅 함정 기록: 이항 연산의 한쪽이 unsigned면 식 전체가 unsigned가 된다. `sqrt_lsb - EXPW'(34)`가 unsigned가 되어 음수 지수에서 `/2`가 깨졌고 FSQRT vector 3442가 실패했다. 모든 폭 캐스트는 `signed'(EXPW'(x))`로 써야 한다(원래 코드는 `int'()`라 드러나지 않았다)
- [x] 도구 제약 두 가지: age 트리를 절차적 3중 루프로 쓰면 21k 반복이라 slang `--unroll-limit 4000`을 넘으므로 `generate`로 기술한다. Verilator는 레벨 배열을 한 덩어리로 보고 UNOPTFLAT(순환 조합 논리)로 오인하므로 선언에 `/* verilator split_var */`가 필요하다
- [ ] 다음 후보 1: `rv_fpu` 2,513.04 ps — 81-bit 누산 캐리 체인이 바닥(순수 80-bit 가산기 1,940.60 ps, 현재는 그 1.29배). near/far 2-path FMA 또는 누산 단 추가 분할(`LATENCY=6`)
- [ ] 다음 후보 2: `rv_issue_queue` 2,422.98 ps — `tag_wakes` → `ready_now` → age tree → one-hot fan-in 약 20 논리 단. speculative(issue-time) wakeup + shadow window가 필요
- [ ] 다음 후보 3: `rv_lsu_cluster` 2,456.02 ps
- [ ] hard-float benchmark 확보 (FDIV/FSQRT 반복 축소의 cycle 이득을 볼 수 있는 지표가 현재 없다)

## v1.18.3 변경/검증 요약

- `rtl/backend/rv_issue_queue.sv`: oldest-two 선택을 균형 tournament tree로 교체하고,
  issue로 해방된 slot을 같은 cycle에 재할당하지 않도록 바꿨다. full IQ는 다음 cycle에
  재사용한다. `tb/unit/backend/rv_issue_queue_tb.sv`가 이 새 계약을 검사한다.
- `rtl/backend/rv_lsq.sv`: LQ oldest-two tournament tree와 SQ 16-entry forwarding의
  4-level youngest-match reduction tree.
- `rtl/backend/rv_rename2.sv`: commit이 반환한 stale physical tag를 same-cycle
  allocation에 노출하지 않고 registered free list에서만 할당한다. checkpoint payload에는
  반환 bit가 반영된다.
- `rtl/backend/rv_fpu.sv`: pre-pack 경계 추가 분할 및 module/backend 기본 `LATENCY` 3 → 4.
- `scripts/run_open_timing.ps1`: `pre_abc.rtlil`/`mapped.v` 저장, critical start/end
  point를 `timing_summary.csv`에 기록, `-IncludeWholeTop`으로 rv_backend/rv_ooo_core 옵션 추가.

공개 1 ns preflight (Nangate45 typical, wire-load 없음, memory macro 제외):

| Block | v1.18.2 | v1.18.3 | area v1.18.2 → v1.18.3 |
|---|---:|---:|---|
| Issue queue 56 | 6,180.63 ps | 3,309.81 ps | 24,502.6 → 32,082.8 um^2 (+30.9%) |
| LSQ | 5,785.50 ps | 2,472.17 ps | 41,782.2 → 23,994.8 um^2 (-42.6%) |
| FPU (LATENCY=4) | 5,079.32 ps | 4,828.67 ps | 34,531.1 → 33,600.9 um^2 |
| Rename2 | 1,899.51 ps | 1,783.48 ps | 69,771.3 → 70,444.0 um^2 |

최장 block이 IQ → FPU로 이동했다(6,180.63 → 4,828.67 ps, -21.9%). WB arbiter, ROB,
PMP, issue arbiter는 변화 없다. 상세 표와 검증 로그는 HDD 18.6.3의 v1.18.3 절에 있다.

검증은 Yosys 0.69+77 / ABC 1.01 / Verilator 5.053에서 재실행했다. Windows 정규
Icarus unit 18종, Verilator block 17종과 backend integration은 모두 PASS다. 별도
Verilator 실행의 `rv_fetch_queue_tb` 한 건은 baseline `f634128`과 동일한 simulator
환경 차이로 분류했다.

## v1.18.2 FPU 변경 요약

- `rtl/backend/rv_fpu.sv`: `LATENCY>=3`에서 pre-normalization register 추가. `LATENCY=1/2`는 호환용 unsplit 경로.
- `tb/unit/backend/rv_fpu_diff_tb.sv`: 당시 6,470 vectors가 `LATENCY=3` split 경로를 검사하도록 변경했으며 v1.18.3부터는 `LATENCY=4`를 검사한다.
- `tb/unit/backend/rv_fpu_tb.sv`: sequence-wrap flush 실패 진단 강화.
- `sw/tests/rv32_c_loop/rv32_start.S`: reset의 `mstatus.FS=Off` 뒤 FP payload 실행 전에 FS=Dirty 설정.
- HDD v1.18.2와 FPU block diagram까지 RTL과 동기화했다. 최신 commit은 `git log -1 --oneline`으로 확인한다.

다음 사용자 소유 untracked 파일/폴더는 명시적 요청 없이 수정·삭제·stage하지 않는다.

- `Claude 피드백/`
- `debug.txt`
- `scripts/compare_spike_retire.py`
- `scripts/generate_internal_diagrams.py`
- `scripts/test_compare_spike_retire.py`

## Windows 도구 위치

| 용도 | 기본 위치 |
|---|---|
| Verilator 5.050 | `C:\rv_toolchains\verilator-5.050\bin\verilator_bin.exe` |
| make/g++ | `C:\rv_toolchains\w64devkit-2.9.1\w64devkit\bin` |
| Icarus | `C:\iverilog\bin\iverilog.exe`, 같은 폴더의 `vvp.exe` |
| Yosys/ABC/Slang plugin | `C:\rv_toolchains\oss-cad-suite\bin` |
| Nangate45 Liberty | `C:\rv_toolchains\libs\nangate45\NangateOpenCellLibrary_typical.lib` |
| RISC-V GCC 15.2 | `C:\rv_toolchains\xpack-riscv-none-elf-gcc-15.2.0-1\bin` |
| 기본 build artifact | `C:\rv_build\...` |

스크립트 parameter로 다른 설치 위치를 넘길 수 있다. Linux에서는 `scripts/run_open_timing.sh`, `scripts/run_coremark.sh`, `scripts/run_configured_elf.sh`와 서버 Xcelium flow를 사용한다.

## 자주 쓰는 검증 명령

PowerShell에서 repository root를 current directory로 두고 실행한다.

```powershell
# 빠른 정적 검사
python scripts/check_rtl.py

# Icarus unit 18종
powershell -ExecutionPolicy Bypass -File scripts/run_unit_tests.ps1

# Verilator block 17종
powershell -ExecutionPolicy Bypass -File scripts/run_block_tests.ps1 `
  -BuildRoot C:\rv_build\block_tests_handoff -BuildJobs 4

# Verilator backend 통합
powershell -ExecutionPolicy Bypass -File scripts/run_integration_tests.ps1 `
  -BuildRoot C:\rv_build\backend_handoff -BuildJobs 4

# GCC C/FP/INT/LSU ELF + DPI SoC
powershell -ExecutionPolicy Bypass -File scripts/run_c_loop_test.ps1 `
  -ArtifactRoot C:\rv_build\c_loop_handoff

# 전체 회귀
powershell -ExecutionPolicy Bypass -File scripts/run_verification.ps1 `
  -ArtifactRoot C:\rv_build\verification_handoff -BuildJobs 4
```

Verilator 스크립트는 한글 repository path 문제를 피하기 위해 빈 drive letter에 `subst`를 걸어 ASCII 경로로 build한다. 두 Verilator runner를 동시에 실행하면 같은 drive letter를 놓고 충돌할 수 있으므로 기본적으로 순차 실행한다.

## 공개 합성/타이밍 preflight

```powershell
# rv_ooo_core hierarchy/process/loop check
powershell -ExecutionPolicy Bypass -File scripts/run_open_timing.ps1 `
  -Mode Check -BuildRoot C:\rv_build\open_timing_check

# FPU만 5 ns ABC target으로 mapping
powershell -ExecutionPolicy Bypass -File scripts/run_open_timing.ps1 `
  -Mode Blocks -BlockFilter rv_fpu -TargetDelayPs 5000 `
  -BuildRoot C:\rv_build\open_timing_fpu

# 모든 등록 block의 10 ns screening
powershell -ExecutionPolicy Bypass -File scripts/run_open_timing.ps1 `
  -Mode Blocks -TargetDelayPs 10000 -BuildRoot C:\rv_build\open_timing_blocks
```

각 결과는 `<BuildRoot>/<block>/synth.log`에 있다. 이 수치는 Nangate45, wire-load 없음, memory macro 미포함인 상대 비교용이다. 최종 Fmax/area 판단은 회사 서버의 실제 Liberty, SRAM, clock uncertainty, PVT 조건으로 한다.

## CoreMark 재현

```powershell
powershell -ExecutionPolicy Bypass -File scripts/run_coremark.ps1 `
  -ArtifactRoot C:\rv_build\coremark_handoff `
  -CoreMarkRoot C:\rv_build\coremark_rtl\upstream-coremark `
  -SocElfBuildRoot C:\rv_build\coremark_handoff\soc_build
```

기대값은 `cycles=468930`, `retired=576450`, `IPC=1.229288`, `status=0x9`, exit 0이다.
v1.18.3~v1.18.6 작업 트리의 기대값은 `cycles=468408`, `retired=576462`, `IPC=1.230684`, v1.18.7은 `cycles=468967`, `IPC=1.229217`, v1.18.8은 `cycles=477685`, `IPC=1.206783`, v1.18.9는 `cycles=477689`, `IPC=1.206773`이다(CRC seedcrc 0xe9f5 / list 0xe714 / matrix 0x1fd7 / state 0x8e3a / final 0x72be, status 0x9). 결과 요약은 `coremark.result.log/json`, 상세 병목은 `coremark.perf.json`에서 본다.

## 현재 작업을 마칠 때

1. HDD/그림을 RTL과 동기화한다.
2. `git diff --check`와 `git status --short`로 사용자 파일 혼입 여부를 확인한다.
3. 최소 unit/block/backend/C-loop/CoreMark 결과를 기록한다.
4. 위에 적힌 사용자 소유 untracked 파일은 stage하지 않는다.
5. commit/push 뒤 이 체크리스트의 commit/status를 갱신한다.
