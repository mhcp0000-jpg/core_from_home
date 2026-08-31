# RV OoO Core SoC

RV32IMFC를 1차 타깃으로 하는 2-wide out-of-order RISC-V 코어와 AXI4 SoC 프로젝트입니다.
데이터 경로와 주소 경로는 처음부터 `XLEN` 파라미터를 사용하여 RV64IMFC로 확장할 수 있게 설계합니다.

초기 SoC는 128 KiB ITIM/DTIM, CLINT, PLIC, Boot ROM, HostIF와 DPI Host ELF loader 경계를 포함합니다. 현재 단계는 **M0 완료, M1/M2/M3/M4 기능 통합 진행 중**입니다. SoC interconnect/peripheral과 2-wide frontend/decode, dual-lane rename, ROB, unified issue queue/global 2-wide issue, INT/FP physical register file, ALU 2개, branch, multiplier, iterative divider가 하나의 backend로 연결됐습니다. dual LSU/AGU, LQ/SQ, committed-store buffer와 D-memory response도 통합되어 conservative memory ordering, store-to-load forwarding, commit 이후 store visibility, branch recovery를 실행 시뮬레이션으로 검증합니다. commit-time CSR, M/U privilege state, precise exception/interrupt, `MRET`, `WFI`, `FENCE/FENCE.I`와 8-entry OFF/TOR/NA4/NAPOT PMP R/W/X checker도 IFU/dual-LSU에 통합됐습니다. 실행 가능한 Boot ROM은 `mtvec=ITIM_BASE`, MSIE/MIE 설정 뒤 WFI에 진입하며, SystemVerilog Host AXI BFM으로 ITIM/DTIM을 적재하고 CLINT MSIP를 발생시켜 ITIM 벡터 명령 retire까지 확인했습니다. FPU datapath, branch predictor와 DPI-C ELF parser/자동 loader는 아직 남아 있으므로 전체 RV32IMFC software를 부팅하는 완료 단계는 아닙니다.

## 문서

- [통합 Hardware Design Description](docs/HDD_Core_Architecture.md) — core/SoC/interface/memory map/boot/검증/구현 계획의 단일 기준 문서

## 디렉터리

```text
docs/                 설계 문서와 단계별 완료 조건
rtl/                  합성 가능한 SystemVerilog RTL
  frontend/           fetch queue, sequential fetch, align, C expansion
  backend/            rename, ROB, issue, execute, LSU, commit
  lib/                공용 하드웨어 프리미티브
  soc/                AXI Xbar, I/D fabric, TIM, CLINT, PLIC, Boot ROM
tb/                   testbench와 reference-model 연동(예정)
scripts/              parse/elaboration 및 Icarus 단위 회귀 스크립트
```

## ISA 기준선

- RV32I 2.1 / RV64I 2.1
- M 2.0
- F 2.2
- C 2.0
- Zicsr 2.0, Zifencei 2.0
- Machine privileged architecture 1.13

F 확장은 Zicsr에 의존하므로 실제 ISA 문자열은 `RV32IMFC_Zicsr_Zifencei`로 관리합니다.

## 시작점

SoC 합성 최상위는 `rtl/soc/rv_soc_top.sv`, 독립 core 최상위는 `rtl/rv_ooo_core.sv`, 공통 제어 타입은 `rtl/rv_ooo_pkg.sv`입니다.
기본 설정은 RV32이며 `XLEN=64` 구성 검증을 항상 병행합니다.

SoC 주소와 용량은 `rtl/soc/rv_soc_pkg.sv`가 단일 기준입니다. Boot ROM,
CLINT, PLIC, HostIF, ITIM, DTIM의 `*_BASE_ADDR`와 `*_SIZE_KB`, HostIF/interrupt
controller register offset을 이 package에서 변경할 수 있습니다. `rv_soc_top`도
같은 값을 parameter로 노출하므로 특정 test instance만 별도 주소맵으로 구성할
수 있으며, `rv_soc_map_check`가 정렬·영역 중첩·주소 overflow를 elaboration에서
검사합니다.

구조 parse/elaboration 확인:

```powershell
python -m pip install -r requirements-dev.txt
python scripts/check_rtl.py
```

신규 core 블록의 Icarus 사이클 단위 회귀:

```powershell
powershell -ExecutionPolicy Bypass -File scripts/run_unit_tests.ps1
```

Icarus 회귀는 decoder/C expander, divider, fetch queue, LSU AGU, LSQ ordering/tombstone/device-store path, store buffer, writeback/recovery buffer, CSR/privilege/trap 상태 전이와 PMP mode/priority/permission을 검증합니다.

Boot ROM→WFI→Host AXI ITIM/DTIM 적재→CLINT MSIP→ITIM vector 실행 흐름은 다음으로 확인할 수 있습니다.

```powershell
powershell -ExecutionPolicy Bypass -File scripts/run_soc_boot_test.ps1
```

현재 구현 단계에서는 남은 코어 구조를 먼저 완성하고, 이후 단위·통합·ISA 회귀를 한 번에 수행해 부족한 부분을 보완합니다. 따라서 각 신규 모듈 커밋은 통합 검증 전까지 구조 구현 체크포인트로 취급합니다.
`-DSYNTHESIS`는 Icarus가 지원하지 않는 SVA 구문만 제외하며 RTL 데이터 경로는
동일하게 시뮬레이션합니다.

integer/branch/dual-LSU/privileged 통합 backend 회귀(Verilator + w64devkit):

```powershell
powershell -ExecutionPolicy Bypass -File scripts/run_integration_tests.ps1
```

이 통합 회귀는 out-of-order 완료와 in-order retire, branch squash, store→load forwarding,
store의 commit 전 외부 비가시성, dual-LSU 독립 load와 load sign extension뿐 아니라
CSR old-value/commit ordering, WFI wake, MSIP trap, mtvec redirect, MRET 복귀와 ECALL precise trap을 확인합니다.
추가로 MPRV=U에서 PMP가 거부한 load/store가 precise access fault를 만들고 D-memory에는 전혀 요청되지 않는지도 확인합니다.
