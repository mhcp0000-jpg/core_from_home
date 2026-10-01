# Core development handoff

이 파일은 사람과 Claude Code/Codex가 같은 작업 상태에서 이어서 개발하기 위한 짧은 체크리스트다. 상세 설계의 authoritative source는 `docs/HDD_Core_Architecture.md`다.

## 현재 기준

- Branch: `main`
- 현재 설계 checkpoint: v1.18.20 queue availability + sequential BTB prelookup (2026-10-01). 이전 pushed 기준 `2b17093`(v1.18.19). 서버 STA 목표는 미확인.
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

- [x] v1.18.20: queue have1..4 threshold를 병렬화하고 sequential BTB PC0+2/+4 lookup 뒤 길이 mux를 배치. 추가 FF/stage/예측정책 변경 없음. predictor8구성×100000cycles/200000비교, queue16구성×60000cycles all-output equality+SVA PASS(immutable2b17093). frontend2564.64→2483.16→2443.47ps/area348869.906→365101.758. whole macro3036.62→2998.79ps/354977→352749.782(같은 target1000/AGU1); 이전v18 whole2925.99보다 느림을 숨기지 말 것. CoreMark IPC1.336361/profiler hash2BE75F…/C-FP009e00b9/35blocks PASS. filelists/top ports/FPU5 불변. 상세 HDD §5-10.
- [x] 미채택 후보: queue PC 두 adder 조기계산은2654.78ps로 악화하여 원복. FCVT65bit helper는 SAT32/64·대규모 corner equality PASS이나 최종 leaf2154.79ps vsoriginal2122.85로 악화; FPU6 조합 whole3080.75ps로 악화하여 backend/FPU production 변경 전부 원복. 테스트 보강만 유지한다.
- [x] GitHub pushed `081e714`(v20), top `rv_ooo_core`/기존filelist/AGU1. `out/queue_btb_checkpoint_perf.json` SHA2BE75F…와C-FP009e00b9/exit0도최신SVA 재build PASS.
- [x] 미채택 ROB completion one-hot routing: immutable081e714 대비RV32/64×ROB4/7/48 각60000cycle 모든 original public output+전체entry/head/tail/count/nextseq equality PASS. CoreMark profilerSHA2BE75F…/C-FP009e00b9/35blocks/integration PASS. 하지만whole2998.79→3047.90ps/352749.782→354461.226으로 악화하여 ROB/backend/새WB port를 모두 원복했다. current RTL에는 entry-mask feature가 없다. ROB 실험본은 ignored `out/rob_completion_candidate/rv_rob.sv`; `check_rob_completion_equivalence.py --rtl <실험본>`으로 재현 가능. named구조161~181units는STA아님.
- [x] 로컬 WB threshold2 후보: INT/FP2에서는 {any,ge2}로rank0/1/overflow만 계산. 추가state/정책/ports없음. 원본1722.21ps/10879.134→1430.84ps/10510.458(fullmap/target1000). SOURCE3/8/11, INT/FP1/2/3, RV32/64 6cfg all-public-output unconstrained SAT PASS(ABC simplify+SAT). raw SAT180s는timeout이지PASS아님. CoreMark hash2BE75F…/C-FP PASS, backend integration PASS. whole2998.79→2996.97ps/352749.782→357660.674로 timing실질중립/area+1.39%라 단독미푸시.
- [x] 미채택 WB threshold2+4: leaf1380.81ps/10383.576(원본1722.21/10879.134), full-output unconstrained two-state SAT 8cfg PASS, 최신SoC CoreMark hash2BE75F…/C-FP009e00b9/35blocks/integration PASS. 그러나 whole2998.79→3049.21ps/352749.782→360314.822으로 악화하여 WB production RTL 전체 원복. 실험본은 ignored `out/wb_threshold24_candidate.sv`; 최신 production WB는081e714 그대로다. leaf 개선을 whole 개선으로 주장하지 말 것.
- [x] 미채택 LSQ resident predicate 병렬화: EARLY0/1×AGU bypass0/1 directed test에서43개 public output+resident equality PASS(176/226/194/244 edge comparisons), 최신SoC CoreMark 전체perf SHA2BE75F…/C-FP009e00b9 PASS. 하지만 whole2998.79→3081.58ps/352749.782→355541.718로 악화해 원복. 실험본/로그/manifest는 ignored `out/lsq_resident_equiv_*/candidate.sv`, `out/timing_core_lsq_resident_predicate_1000`에 보관한다. directed equality를 exhaustive formal로 주장하지 말 것.
- [x] 미채택 LQ cached-order 후보: packed FF로 정확한 pair comparator를 allocation edge에 저장하고 원래 tournament merge/valid/tie를 유지(추가 scheduling cycle 없음). 32/64 PADDR×LQ4/7/24 SQ4/5/16 6cfg 각60000cycle all-output/원본state/cache equality PASS(36만cycle, protocol SVA 비활성). 최신 assertion-enabled SoC CoreMark hash2BE75F…/C-FP009e00b9/4cfg directed/integration/35blocks PASS. selector SAT4/7 PASS,24 raw180초TIMEOUT 후 gate simplification SAT PASS. 그러나 leaf2617.67/32440.828 vsbaseline2610.11/25489.982, whole3119.64/365175.44 vsbaseline2998.79/352749.782로 악화해 LSQ production RTL 전체 원복. 실험본은 ignored `out/lsq_cached_order_packed_random_32_24_16_1_1/candidate.sv`; 도구 `--rtl`로 재현가능. GitHub081e714에는 없음. 상세 HDD §5-11.
- [x] 미채택 ROB early-entry-mask + WB threshold2 조합: 최신SoC CoreMark hash2BE75F…/C-FP PASS이나 whole3106.21/357248.374로 기준2998.79/352749.782보다 악화해 세production RTL파일 모두원복. **추가 source-onehot SAT(무제약 입력)는 FAIL**: modulo age가 순환적/half-range 경계이면 rank 중복 가능. 기존WB public-output equality와 새mask identity 증명을 구분할 것. ROB count48만으로generation span<128을 보장한다고 주장하지말것(nextseq는flush에서도rewind하지않음). 현재 production RTL 전부081e714와 같으며, 이 counterexample은 실제SoC 실패를 재현한것이 아니다. 이후 mask재사용을다시시도한다면 실제 sequence-cohort invariant/ROB allocation span guard 또는robust중재를 먼저검증. conditional cohort SAT11source/32bit도180초timeout(미증명)이므로PASS아님. `out/rob_mask_wb_threshold2_sat_32` 실패증거보존.
- [x] v1.18.19: lane1 GH unshifted/shift0/shift1 table read를 lane0 valid/conditional/direction보다 먼저 병렬 계산하고 direction1bit만 선택. 추가 FF/stage/정책 변경 없음. immutable3f9b0ea 대비 RV32/RV64×PHT32/2048 각100000cycles/200000 all-public-output 비교+SVA PASS (`run_predictor_equivalence.ps1`). 블록35개 PASS. 동일 CoreMark431358/576450/IPC1.336361, profiler hash2BE75F… 전체 동일, C/FP009e00b9/exit0 PASS. frontend full-map target1000:2638.63→2564.64ps/area343400.946→348869.906; head-block→head-parcel-offset named trace73.9→63.0units (STA 아님). filelists/top ports/FP LAT5 불변. 새 whole-core/서버1.2GHz는 아직 미확인. 합성 top rv_ooo_core/AGU_LOAD_BYPASS=1.
- [ ] 동시 목표: 서버 2 nm STA **1.2 GHz 이상 + 동일 CoreMark official IPC 1.3 이상**. 최신 required0.8124ns 기준 동일overhead 가정1.2GHz arrival0.645733ns; 실제 SDC 확인 필요. Nangate45를 2 nm로 환산하지 말 것.
- [x] IQ allocator: 직렬 first-free 2회 → saturating any/ge2 + prefix tree one-hot. age-matrix update에 allocator one-hot 직접 사용. IQ 2443.77→1181.50 ps, whole backend(priority bypass, IQ만)4444.72→3619.99 ps. 4/7/56 entries ×30000 cycle equality PASS.
- [x] early-load `EARLY_LOAD_SELECT=1` 기본 채택: registered AGU raw preview로 identity를 예약하고 다음 cycle resident LQ로만 request 허용. fault/withheld-update/sequence/flush guard 및 conservative ordering 불변. A/B baseline은 PS `-CoreEarlyLoadSelect:$false` / timing·integration `-EarlyLoadSelect:$false`, Linux timing `EARLY_LOAD_SELECT=0`.
- [x] 같은 ELF official469739/576450/IPC1.227171, profiler469795/576462. CRC/exit PASS. 1.3 목표443423 cycles까지26316 cycle 추가 절감 필요. 최신 `out/iq_preview_fpu_csr_final_perf.json`. C/FP signature009e00b9 exit0 PASS.
- [x] FPU 81-bit add/sub를4-bit carry-select/prefix로:2712.96→2241.24 ps, area+1.8%. LATENCY5 불변. static/dynamic 각113600 RV32F vectors PASS. `run_fpu_corners.py --simulator verilator` 재현 가능.
- [x] CSR byte-parallel counter increment:1870.55→1263.57 ps. 400032-vector builtin-add oracle +기존 CSR architectural tests PASS, assertion-enabled block18 runs PASS (`out/iq_fpu_csr_final_blocks3.log`).
- [x] priority bypass+IQ+preview+FPU+CSR whole3360.45 ps/316996.722 µm²: `out/timing_backend_iq_preview_fpu_csr_final/timing_summary.csv`. v12 대비 delay−24.4%. preview+LSU payload whole3710.52 ps였고 parallel bypass3790.32로 악화해 원복했다. parallel+FPU intermediate3702.34는 최종값 아님.
- [x] opt-in `COMPATIBLE_PAIR_SELECT=1`: singleton oldest port와 충돌하지 않는 oldest-ready second 후보를 parallel age matrix로 고름. issue폭/PRF port수2 불변. `-CoreCompatiblePairSelect` / integration·timing `-CompatiblePairSelect`. CoreMark468042/576450/IPC1.231620, preview 대비−1697cycles, conflict20523→3088. block19runs/integration PASS.
- [x] pair 후보 whole4152.96ps/336974.386µm² vs3360.45/316996.722: delay+23.6%, area+6.3%, 기본 채택 거부. opt-in만 남김(`out/timing_iq_compatible_pair/timing_summary.csv`). IQ leaf1181.50→1592.44ps/area+25%. 현재 defaults EARLY_LOAD_SELECT=1/COMPATIBLE_PAIR_SELECT=0, 기본IPC1.227171. block20runs/default whole-core structural PASS.
- [x] branch 비교/target 계산을 두 IQ 후보에서 port 중재와 병렬 수행 후 결과 선택: whole3360.45→3288.92 ps, area316996.722→320850.530. 1 logical branch issue port/2 combinational evaluator이며 latency 불변. issued legacy equality SVA +CoreMark 모든 profiler counter equality/C-FP/integration PASS. ALU도 후보 앞에서 계산한3309.26/324586.234 대안은 제거.
- [x] frontend predecode metadata와 predictor history-lookahead 후보는 cycle/counter equality PASS지만 whole frontend2940.50→3029.16/3190.37 ps로 악화해 모두 제거. cross-block C.NOP/JAL/stall/redirect RV32/RV64/PADDR32-alias TB는 유지.
- [x] opt-in `AGU_LOAD_BYPASS=1` fixed-lane 후보: official431783/576450/IPC1.335046, profiler431839/576462. CRC/status9/exit0, C-FP009e00b9/exit0, LSQ directed+SVA, backend integration PASS. 기본값0(기본IPC1.227171 유지). PS `-CoreAguLoadBypass` / integration·timing `-AguLoadBypass`, Linux timing `AGU_LOAD_BYPASS=1`.
- [x] bypass backpressure shadow의 duplicate identity를 SVA가 발견: 일반 selector에서 active bypass ID를 제외. 두 addressed load를 hold 후 dual acceptance하도록 integration BFM 보강(early older-load request를 성능 regression으로 오인하지 않음).
- [x] PMP permit가 store-CAM 앞에 들어간 병목 제거: raw identity/address로 ordering 병렬, final effect-valid만 authorization gate. LSU4432.01→3831.72→3682.26→2744.70 ps. permission/older-store blocking/store commit rule 불변.
- [x] late-permit25-case block/CoreMark 전체 profiler equality/integration/C-FP PASS. default0 CoreMark도 v13과 profiler hash E7DDA739… 동일. `out/agu_bypass_final_blocks.log`, `out/agu_bypass_late_permit_*`, `out/agu_bypass_default_*`.
- [x] raw identity를 ready와 무관하게 shadow해 ordering→ready→identity D feedback 제거; consumed ID는 resident issued/completed guard로 reject. leaf2744.70→2726.55 ps. 초기 shadow ELF431889/576450/IPC≈1.334718(이전 fixed431783와 혼용 금지).
- [x] backpressure stability SVA가 기존 stale blocked-bit replacement를 발견. eligible replacement가 있는 stale-blocked 전환에는 effect-valid를 막고 raw ordering은 유지해 blocked bit를 clear. LSQ EARLY0/1+bypass1 directed/stability SVA PASS (`out/lsq_agu_bypass_hold_0.log`, `_1.log`).
- [x] latest hold CoreMark A/B SVA PASS: bypass1 official431358/576450/IPC1.336361(profiler431414), bypass0 official469994/576450/IPC1.226505(profiler470050). CRC/status9/exit0, C-FP009e00b9/exit0 PASS. bypass1 PC/instr593267개 hash6d997065…이 hold 전 baseline과 같음. `out/agu_bypass_hold_*`.
- [x] latest hold25-case block regression 및 backend integration PASS (`out/agu_bypass_hold_blocks.log`, `out/agu_bypass_hold_integration.log`). bypass0의 extra shutdown PC80000f34 한 개는 host-finish 이후 로그 tail 차이이며 측정 instret576450은 같다.
- [x] latest hold whole `out/timing_backend_agu_bypass_hold/timing_summary.csv`: **3392.51 ps/327680.346 µm²**, LSU leaf2759.97/59114.244. branch-only3288.92 대비 delay+3.15%/area+2.13%, officialIPC1.336361. physical STA 아직없음. 초기 flexible/PMP-gated whole4872.52와 fixed3682-leaf 시점 whole4053.94는 최종 아님. 기본0 유지.
- [x] whole critical structure: `dmem_rsp_id_i[9]` → live load wakeup → IQ ready/age/select → FU mask → issue-port arbitration → `g_fast[0].u_buffer.payload_q[68]` push-enable. endpoint bit가 exception_tval이어도 branch datapath가 병목이라는 뜻은 아니다. `out/agu_bypass_hold_critical_path.log`.
- [x] parallel FTB tag checks/one-hot wide select 후보는 CoreMark 모든 counter equality와 RV32/RV64/PADDR32 cross-block, 25000-cycle independent FTB oracle PASS. 그러나 whole frontend2940.50→3043.41 ps/area342718.922→343633.696으로 악화해 production RTL 원복. oracle TB는 유지.
- [x] issue arbiter one-hot port choice/exclusion 채택: 262144 exhaustive cases에서 generic search와 all-output equality PASS. CoreMark all profiler counters/hash 동일(431414 profile cycles), C-FP009e00b9 exit0/backend integration/block26 runs PASS. whole backend **3392.51→3381.88 ps/327680.346→324563.092 µm²**. binary encode/decode는 exported port number에만 남김. `out/timing_backend_issue_onehot/timing_summary.csv`.
- [x] FTB independent25000-cycle oracle는 production 원복 후에도 PASS (`out/ftb_oracle_baseline.log`). Xcelium runner에 opt-in `AGU_LOAD_BYPASS=1` compile option 추가, HTIF TB actual config 로그 추가. Verilator preprocess0/1 및 define1 HTIF elaboration PASS; Xcelium 실행 자체는 서버에서 확인 필요.
- [x] 다음 whole critical: LSQ `candidate_index[0]` → resident/active sequence → older MMIO/unknown-address reduction → request-ready → candidate replacement → `candidate_sequence[9]`. `out/issue_onehot_critical_path.log`. 1.2GHz 서버 sign-off 아직없음.
- [x] LSQ per-entry parallel predicate/reduction 채택: officialIPC1.336361/all profiler hash2BE75F… 그대로. baseline0f654b4와 all-output cycle cosim EARLY0/1×BYPASS0/1 4조합 PASS. leaf2759.97→2850.11ps는 악화했지만 whole3381.88→3381.34ps(실질 timing 중립)/area324563.092→322202.608(−0.73%). `out/timing_backend_lsq_reduction/timing_summary.csv`.
- [x] sequence comparator 대안은 prototype에서65536 byte-pair equality+directed cosim PASS, leaf2850.11→2769.62ps지만 bypass baseline2759.97보다 여전히 느려 production 미반영. issued/completed 기반 refill은 official431701/IPC1.335299, block26/C-FP/integration PASS지만 leaf2850.11→2901.64ps 악화 및+343cycles 비용으로 원복; whole clock 개선이라고 주장하지 않음. candidate released through ready semantics 유지.
- [x] 최신 control/PRF leaf11종 합성 완료 (`out/timing_current_control_prf/timing_summary.csv`): rename1728.68/PMP1729.21/BRU1154.27/INT-PRF751.43/FP-PRF590.17/LSU-pipe998.50/result-buffer589.39/decode968.86/trap311.97/recovery194.12/fence137.78ps. leaf만으로 whole clock 주장 금지, PRF는 async mux 포함 full-map.
- [x] IQ FU predecode 채택: `candidate_fu_onehot_o`(16bits), 추가 state/stage/issue policy 없음. class/mask clocked SVA, 4/7/56-entry×30000-cycle all-output equality PASS. whole backend3381.34→3327.95ps/area322202.608→324267.566µm². `out/timing_backend_iq_fu_predecode/timing_summary.csv`. filelist 변경 없음.
- [x] frontend shared immediate decode +4-bit carry-select/prefix target adder 채택: full-map2940.50→2924.25ps/342718.922→341856.284µm². predictor policy/history/latency 불변. RV32/RV64 각296608-vector 독립 oracle PASS. `out/timing_frontend_target_add/timing_summary.csv`.
- [x] 최종 두 변경 포함 CoreMark bypass1 profiler hash2BE75F…/official431358/576450/IPC1.336361, bypass0 hash168A4957…/official469994/IPC1.226505 불변. C-FP009e00b9/exit0, backend integration, assertion-enabled block27 runs PASS.
- [x] 새 backend named-path: slow FPU valid → direct wake → IQ age-select → PRF/bypass operand → candidate branch compare → fast result payload. `out/iq_fu_predecode_critical_path.log`. 구조 추적이며 STA가 아니고 이전 push-enable 병목과 구분할 것.
- [x] pushed checkpoint `0e54dbb`(v1.18.15), filelists/top ports 불변. whole-core 재측정 `out/timing_core_iq_fu_target_add`:3353.10ps/363156.234µm², CSR system wake class→IQ select/operand→branch mispredict→fast payload. macro array read 경로 생략에 주의. 서버에 `rv_ooo_core.AGU_LOAD_BYPASS=1`을 명시하고 새로 elaboration/합성할 것.
- [x] BRU 4-bit group comparison+prefix target add 채택, latency 불변. native1154.27→comparator-only1173.41(거부)→comparison+add993.64ps. adder-only1028.52ps. RV32/RV64 각231072-vector oracle(정확한 taken target prediction 포함), CoreMark profiler hash2BE75F…/C-FP009e00b9/exit0 PASS. block28/integration PASS. 전체 backend3327.95→3127.15ps(−6.03%)/area324267.566→329313.054µm²(+1.56%), `out/timing_backend_branch_prefix_compare`.
- [x] IQ payload balanced OR tree는 ignored prototype만: 4/7/56-entry×30000-cycle all-output equality PASS. 최초 호출 치환 실수로 payload0/equality FAIL여서1000.96ps 수치는 무효. 수정 후1182.07ps/113355.634µm² vs현행1180.39/112963.550으로 악화, 채택 거부/production IQ 미변경. `out/iq_balanced_payload_equiv2.log`, `out/iq_balanced_payload_timing2.log`.
- [x] frontend block-step factoring 후보 거부/RTL 원복: request/redirect native equality SVA와 RV32/RV64/PADDR32 cross-block PASS, combined CoreMark hash2BE75F…/C-FP PASS. 그러나 full-map2924.25→3116.53ps/341856.284→342269.648µm²로 악화. `out/timing_frontend_parallel_block_step`, ignored prototype만 보관.
- [ ] 다음 최장 backend 경로는 FPU `pre_calc_q[99]`→`norm_calc_q[20]` 정규화 내부. `out/branch_prefix_fpu_critical_path.log`는 unit-delay LZC loop를 과대평가하므로 1353 units를 STA로 해석 금지. balanced highest-bit encoder / exponent arithmetic 후보를 latency5 유지 조건으로 먼저 검토할 것. backend FPU는 LATENCY5 override이고 standalone default는4임.
- [x] v1.18.16 pushed `ad9c042`, whole-core 재측정 `out/timing_core_branch_prefix_compare`:3353.10→3046.47ps/area363156.234→364484.106µm². accepted frontend(v15)+BRU(v16), AGU_LOAD_BYPASS=1. 새 critical PMP address→anonymous ROB memory write-enable `$161916` 구조 추적 중. macro read-array omission/서버1.2GHz 미확인 유지.
- [x] FPU balanced highest-bit 채택 후보: normalize+pack2122.85ps/27126.148µm² vsbaseline2241.24/27505.198. latency/FF/API 불변. RV32/RV64 각1141602-vector full-normalize/pack bit equality PASS, static/dynamic 각각113600 exact-rational vectors PASS. CoreMark hash2BE75F…/IPC1.336361, C-FP009e00b9 exit0, block28/backend integration PASS. FPU 단독 변경의 전체 backend `out/timing_backend_balanced_fpu_lzc`:3127.15→3036.55ps/area329313.054→326915.862. 후속 PMP/frontend 변경의 전체값으로 주장 금지.
- [x] PMP NAPOT odd-base high-bound bug red→green: pmpaddr0=0x1402/cfg0x19의5008~5010 region이 기존 OR bound에서는 empty. prefix-mask / encoded high increment로base+size를 구현, counter/dynamic size decode 제거. leaf1729.21→1584.01ps(단순ADD수정2516.20보다개선). PADDR32/64 각각8B~half-space, six even/odd bases 경계/lockedM/write/fullspace/wrap PASS (`out/pmp_prefix_32_result.log`, `out/pmp_prefix_64_result.log`). 큰 region에서 base가0으로wrap된 TB lower-overlap 기대값 수정(해당 access는 physicalwrap/nooverlap). 서버 hang 원인으로 단정 금지.
- [x] 서버 최신0e54dbb path: queue head_block→predictor(~0.5ns)→FTB→head_parcel_offset. arrival1.1855ns/required0.8124ns/slack−0.3731ns. `normal_fill_addr_i=outstanding_addr_q`로 주소 분리 + aligned tag compare/PC lowbits offset/invalid payload ungating. address-only2625.15ps, 최종normal_fill_valid도분리2638.63ps vsbaseline2924.25(−9.77%)/area343400.946vs341856.284(+0.45%). extra valid 분리는max0.51%비용 대신FTBhit→normal-offset-enable 경로제거. named구조115.3→91.4→73.9units/86→66→53gates는STA아님. 4구성×60000cycles equality/최상위주소블록 unit PASS, 최종 CoreMark hash2BE75F…/IPC1.336361 불변. block28/backend integration/C-FP009e00b9 exit0 PASS. filelists/top ports 불변, queue 내부 address/valid ports와params만추가.
- [x] 제외한 frontend 후보: flat one-hot parcel cursor3109.50ps(악화) 원복. late gshare LSB bank-select 단독2923.37vsungated2845.57로악화, normal-fill분리와결합2598.36ps는약1%개선이나 extra bank-read 없이nativehistory2625.15ps를선택(해당candidate미반영). predictor policy/latency불변.
- [x] v17 최종 whole-core `out/timing_core_separate_fill_valid_final`:3040.52ps/364956.522µm², ABC target1000ps. address-only ablation3109.23은 별도 구성으로 구분한다. 공개 macro array read omission에 주의. server1.2GHz sign-off 미확인.
- [x] v18 SB correctness bug red→green: SEQ8의10→210 gap에서old11111111을 반환. 이미 commit한 SB store는 ROB half-window 제약 밖이므로 FIFO head-relative age를 사용한다. 1-bit wrap-zone balanced tree로 sequence subtract 제거, iface/latency 불변. ENTRIES2/4/8 full query SAT 및16개 head partition 전체PASS, wrap/equal timestamp/dual-query/pop/partial/response+enqueue unit, independent FIFO-scan runtime SVA 포함. `out/sb_fifo_final_proof_*/report.json`.
- [x] v18 actualPMP는exclusive upper bound 유지+parallel first-match만 반영. immutablebd11890 full8-entry PADDR32/64 unconstrained reference-equivalence SAT(size0..7) PASS. `out/pmp_final_priority32/64/report.json`. Inclusive/cache 후보는current core에 없으며 당시조합proof와 혼동금지.
- [x] v18 동일 target1000 leafSB1695.10→1009.67ps/area31291.708, PMP1584.01→1557.48ps. whole-core `out/timing_core_fifo_final_1000`:3040.52→2925.99ps/area364956.522→357144.368(−3.77%delay/−2.14%area). CriticalFPissueoperand0[2]→alignment FF cone. `core_fifo_priority_named_paths.log`는구조모델일뿐ps아님.
- [x] v18 officialCoreMark431358/576450/IPC1.3363609809, profiler431414/576462/SHA2BE75F814945B8A2BFD6ACEF780D759148EDFE99C6AE0D4BEBA385C059B31355 그대로. final SoC+SVA C/FP009e00b9/exit0, backend integration+newSB assertions PASS. `out/fifo_final_*`와`out/fifo_backend_final_result.log`. block regression35구성PASS (`out/v18_fifo_blocks_final.log`). core는FPU5, filelists/외부ports불변.
- [x] optionalFPU6 seed→sticky-shift stage: leaf2122.85→2016.46ps/area+7.14%; static/dynamic113600each, RV32/64 993216alignment+seed vectors each, saturation/reset/selective/fullflush/DIV-no-overtake PASS. corePMPinclusive+FPU6 target1000 remap3072.66ps/338145.850으로v17보다느려현재core5유지. Backend6 활성화는현재SB수정과조합해별도전체측정할후속후보.
- [x] ABC budget 비교 오류 수정: 일부 신규run target10000은 baseline1000과 직접 비교 불가. `timing_core_lsq_registered_release`3664.88, `timing_core_fpu6_*`3732.63/3734.30, cache3740.14, `timing_core_fifo_age_priority`3876.38은10000자료. 실제corefifo1000은2925.99. PS/Linux default1000으로 통일, manifest/CSV target+library/constraint/sourcehash 기록. gate에는 같은 budget만 사용한다.
- [x] frontendCB/CJ/B/J별parallelprefix target-add zero-cycle후보: RV32/64 296608vectors각PASS이나full-map2638.63→2644.86ps/area343400.946→345994.446으로악화해원복. `out/timing_frontend_parallel_target_family`manifest1000. exacthead→offset구조73.9→75.6units. 다음병목은lane0 conditional/valid/taken→lane1 GH index→PHT read→redirect. Production predictor는기존sharedtargetadder. 서버fetchqueue→predictor→FTB→queue해결을확정하지말것.
- [ ] 다음은FPalignment과frontend후속후보를검토한다. Memory ordering/hold stability를약화시켜timing을맞추지말것. 회사서버에서v17/v18 frontend endpoint제거효과와새worstpath/1.2GHz를확인해야한다.
- [x] FPU helper SAT 재현script: Windows child PATH에oss-cad-suite/lib를추가해 DLL-loader대기 방지, 재실행시report를running/passedfalse로초기화해stalePASS방지. PATH미설정으로멈춘ownYosysPID15652만명령확인후정리. 최종`out/fpu_balanced_lzc_formal_final`/Unicode+space경로에서도SATPASS. helper-only2^80입력증명이며IEEE/pipeline전체증명아님.
- [x] `scripts/check_fpu_lzc_equivalence.py`는 현재 RTL helper를 그대로 추출해 ascending native reference와 Yosys/read_slang SAT 비교. 모든2^80 two-state 입력에 equality 증명 PASS; 공백 경로도 PASS. `out/fpu_balanced_lzc_formal/report.json`. 범위는 helper 조합 논리뿐이며 pipeline/IEEE 전체 증명으로 주장하지 말 것.
- [ ] 서버 STA/SDC 최신 결과 필요. 공개45nm 수치를2nm Fmax로 환산 금지. 1.2GHz+IPC1.3 동시 달성 아직 미증명.
- [x] checkpoint16 실험은 stall0이어도 CoreMark+77cycles/ROB-LSQ 압박 증가: default8 유지. benchmark predictor 튜닝/비현실적 memory latency 변경 금지. 다음 병목은 load-head90284/operand80625/frontendempty52103/portconflict20523, counter 중첩 주의.
- [x] Backend leaf 후보: ALU32 1096.49→994.88 ps, ALU64 2118.34→993.54, DIV2232.56→1901.92, MUL2675.43→2378.11(area −46.2%), WB2048.74→1691.00(area −16.1%). latency 불변.
- [x] 전체 후보 CoreMark assertion-enabled PASS, 477687/576450/IPC1.206753, v1.18.11과 profiler 전체 counter 동일. block17/backend integration/최신 C FP signature009e00b9 exit0 PASS.
- [ ] **전체 backend regression 발견**: 4369.34→4495.60 ps(+2.9%), area322203.672→314537.818. parallel bypass leaf 개선만으로 채택 불가. priority bypass 원복 ablation은4444.72ps/322502.390(+1.7%delay), macro start=`u_iq.valid_vec[43]`. 다음은 IQ→연결 경로. 1.2 GHz 달성 주장 금지.
- [x] 최종 priority bypass RTL 재회귀: CoreMark 모든 profiler counter 동일, assertion-enabled C FP exit0, Yosys whole-core structural check PASS. randomized equivalence ALU/DIV/MUL RV32/RV64 각150000 및WB30000 PASS. baseline MUL stall SVA는 flush예외가 누락되어 수정; baseline fuzz는 SYNTHESIS로 built-inSVA만 끄고 equality/$fatal 유지.
- [ ] 재현: `powershell -ExecutionPolicy Bypass -File scripts/run_backend_timing_equivalence.ps1` (reference git8f1c6ba, ignored out/, RV32/64 ALU/DIV/MUL150000 each, WB30000). 단위 수치와 전체/서버 STA를 반드시 분리할 것.

- [x] v1.18.11 후보: 32×16-bit parcel ring → 4×128-bit block ring + direct redirect offset. frontend 3,774.23 → 2,940.50 ps(−22.1%), area 349,936.83 → 342,718.92 µm²(−2.1%). unit PASS, CoreMark CRC/status/exit PASS.
- [x] 후보 비교: one-hot pointer(queue 1,807.10 ps), fixed-head shift(frontend 4,164.89 ps), 8-entry FTB(3,917.58 ps), parallel availability threshold(4,182.80 ps)는 모두 timing 악화로 원복. threshold/block-ring 30,000 random cycle equivalence + threshold assertion-enabled full SoC CoreMark PASS.
- [ ] v1.18.11 official CoreMark 477,687 cycles / 576,450 instret / IPC 1.206753. v1.18.10 477,680 대비 +7 cycle(+0.0015%); 엄밀한 IPC 비감소 조건은 미충족. profiler는 477,743/576,462. 서버 0.8142 ns target 미확인.
- [x] fill/predecode target metadata 후보는 cross-block/PADDR alias까지 검증했지만 whole timing/area regression으로 제거(위 v1.18.14 기록). 다음 frontend는 새 구조 후보를 근거로 측정할 것.

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
