# RV OoO Core SoC

RV32IMFC를 1차 타깃으로 하는 2-wide out-of-order RISC-V 코어와 AXI4 SoC 프로젝트입니다.
데이터 경로와 주소 경로는 처음부터 `XLEN` 파라미터를 사용하여 RV64IMFC로 확장할 수 있게 설계합니다.

초기 SoC는 128 KiB ITIM/DTIM, CLINT, PLIC, Boot ROM, HostIF와 DPI Host ELF loader를 포함합니다. 현재 단계는 **RV32IMFC 1차 RTL 통합 및 directed verification 완료, 전체 ISA differential 진행 전**입니다. SoC interconnect/peripheral과 2-wide frontend/decode, dual-lane rename, ROB, unified issue queue/global 2-wide issue, INT/FP physical register file, ALU 2개, branch, multiplier, iterative divider, RV32F 실행기가 하나의 backend로 연결됐습니다. dual LSU/AGU, LQ/SQ, committed-store buffer는 conservative memory ordering, store-to-load forwarding과 commit 이후 store visibility를 구현합니다. commit-time CSR, M/U privilege, precise trap, `MRET`, `WFI`, `FENCE/FENCE.I`와 8-entry PMP도 IFU/dual-LSU에 통합됐으며 trap/interrupt와 fence drain은 독립 controller 경계로 분리했습니다. frontend에는 256-entry 4-way BTB, 2048-entry gshare, 16-entry RAS가 연결됐고, DPI-C는 ELF32/ELF64 PT_LOAD를 Host AXI로 적재한 뒤 HostIF와 CLINT MSIP를 순서대로 기록합니다. parse/elaboration, Icarus 단위 15종, Verilator 블록 11종, backend 통합, Boot ROM 부트, DPI ELF end-to-end가 통과했습니다. 실제 RV32IMF, 혼합폭 RV32C, M/U privilege ELF의 ROB commit trace도 예상 결과와 exact-match합니다. C/CSR/FENCE의 모든 조합과 random long-run, Spike/Sail 및 riscv-arch-test는 아직 sign-off되지 않았습니다.

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
tb/                   unit/integration/SoC/DPI ELF testbench와 commit logger
scripts/              parse/elaboration, 단위·블록·통합·ELF 회귀 스크립트
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

core 블록의 Icarus 사이클 단위 회귀:

```powershell
powershell -ExecutionPolicy Bypass -File scripts/run_unit_tests.ps1
```

Icarus 회귀는 decoder/C expander, divider, RV32F 실행기, fetch queue, LSU AGU, LSQ ordering/tombstone/device-store path, store buffer, writeback/recovery buffer, CSR/privilege/trap 상태 전이와 PMP mode/priority/permission을 검증합니다.

Icarus가 가변 packed-array index를 elaboration하지 못하는 ROB/IQ/arbiter와 SoC 블록은 Verilator 회귀로 실행합니다.

```powershell
powershell -ExecutionPolicy Bypass -File scripts/run_block_tests.ps1
```

이 회귀는 ROB, issue queue/global arbiter, multiplier, branch predictor, AXI bridge, I/D fabric, SoC peripheral path, PLIC, CLINT 11종을 검증합니다.

Boot ROM→WFI→Host AXI ITIM/DTIM 적재→CLINT MSIP→ITIM vector 실행 흐름은 다음으로 확인할 수 있습니다.

```powershell
powershell -ExecutionPolicy Bypass -File scripts/run_soc_boot_test.ps1
```

DPI ELF SoC 실행 진입점은 다음과 같습니다.

```powershell
powershell -ExecutionPolicy Bypass -File scripts/run_soc_elf_test.ps1 `
  -ElfPath <riscv-elf-path> -TracePath C:\rv_build\commit.csv
```

ROB retire 로그는 `order,cycle,lane,pc,instruction,rd_write,rd_fp,rd,wdata,trap,cause,tval` CSV로 기록됩니다. speculative WB에는 나중에 squash될 결과가 포함되므로 정답 비교에는 쓰지 않고, architectural state가 확정되는 in-order commit 경계를 ISA reference 비교점으로 사용합니다.

현재 directed 검증 전체를 한 번에 실행하려면 다음 명령을 사용합니다. 이 스크립트는 self-contained ELF 3종을 생성하고 Boot ROM→WFI→Host AXI 적재→CLINT MSIP→ITIM 실행→HostIF exit(0)을 반복합니다. RV32IMF 24개 payload의 INT/FP 결과, 혼합 16/32-bit RV32C 18개 payload와 branch squash/FENCE, MRET 이후 U-mode illegal CSR·ECALL trap 및 M-mode 복귀를 각각 ROB commit CSV와 exact-match합니다.

```powershell
powershell -ExecutionPolicy Bypass -File scripts/run_verification.ps1
```

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
