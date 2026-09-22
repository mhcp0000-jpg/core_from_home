# Core development handoff

이 파일은 사람과 Claude Code/Codex가 같은 작업 상태에서 이어서 개발하기 위한 짧은 체크리스트다. 상세 설계의 authoritative source는 `docs/HDD_Core_Architecture.md`다.

## 현재 기준

- Branch: `main`
- v1.18.2 작업 시작 기준: `10a7713 Reduce backend arbitration timing depth`
- Core top: `rv_ooo_core` (`rtl/rv_ooo_core.sv`)
- SoC top: `rv_soc_top` (`rtl/soc/rv_soc_top.sv`)
- Core source list: `sim/xcelium/sources_core.f`
- SoC/Xcelium source list와 실행법: `sim/xcelium/README.md`
- 목표: RV32IMFC, 2-wide dual issue, OoO execute/in-order dual commit, dual LSU/LSQ, precise trap/interrupt, RV64 확장 가능 구조

## 작업 체크리스트

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
- [ ] 다음 병목 후보인 56-entry IQ(5 ns target 약 6.397 ns) 구조 검토
- [ ] 서버 library/constraint로 `rv_ooo_core` STA 재측정 후 다음 수정 우선순위 결정

## v1.18.2 FPU 변경 요약

- `rtl/backend/rv_fpu.sv`: `LATENCY>=3`에서 pre-normalization register 추가. `LATENCY=1/2`는 호환용 unsplit 경로.
- `tb/unit/backend/rv_fpu_diff_tb.sv`: 6,470 vectors가 `LATENCY=3` split 경로를 검사하도록 변경.
- `tb/unit/backend/rv_fpu_tb.sv`: sequence-wrap flush 실패 진단 강화.
- `sw/tests/rv32_c_loop/rv32_start.S`: reset의 `mstatus.FS=Off` 뒤 FP payload 실행 전에 FS=Dirty 설정.
- HDD v1.18.2와 FPU block diagram까지 RTL과 동기화했다. 최신 commit은 `git log -1 --oneline`으로 확인한다.

다음 사용자 소유 untracked 파일/폴더는 명시적 요청 없이 수정·삭제·stage하지 않는다.

- `Claude 피드백/`
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

기대값은 `cycles=468930`, `retired=576450`, `IPC=1.229288`, `status=0x9`, exit 0이다. 결과 요약은 `coremark.result.log/json`, 상세 병목은 `coremark.perf.json`에서 본다.

## 현재 작업을 마칠 때

1. HDD/그림을 RTL과 동기화한다.
2. `git diff --check`와 `git status --short`로 사용자 파일 혼입 여부를 확인한다.
3. 최소 unit/block/backend/C-loop/CoreMark 결과를 기록한다.
4. 위에 적힌 사용자 소유 untracked 파일은 stage하지 않는다.
5. commit/push 뒤 이 체크리스트의 commit/status를 갱신한다.
