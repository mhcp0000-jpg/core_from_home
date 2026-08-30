# RV OoO Core SoC

RV32IMFC를 1차 타깃으로 하는 2-wide out-of-order RISC-V 코어와 AXI4 SoC 프로젝트입니다.
데이터 경로와 주소 경로는 처음부터 `XLEN` 파라미터를 사용하여 RV64IMFC로 확장할 수 있게 설계합니다.

초기 SoC는 128 KiB ITIM/DTIM, CLINT, PLIC, Boot ROM, HostIF와 DPI Host ELF loader를 포함합니다. 현재 단계는 **M0 완료, M1 진행 중**입니다. SoC interconnect/peripheral 연결이 구현됐고, core 내부는 standalone dual-lane rename, ROB, split issue queue, global issue arbiter, physical register file, integer ALU/branch와 multiplier까지 구현됐습니다. Decode/divider/CSR/LSQ owner/통합 Backend와 Boot ROM 실행 image, DPI ELF loader/BFM은 아직 구현 전이므로 software를 실행하는 기능 코어 단계는 아닙니다.

## 문서

- [통합 Hardware Design Description](docs/HDD_Core_Architecture.md) — core/SoC/interface/memory map/boot/검증/구현 계획의 단일 기준 문서

## 디렉터리

```text
docs/                 설계 문서와 단계별 완료 조건
rtl/                  합성 가능한 SystemVerilog RTL
  frontend/           fetch, predictor, align, C expansion
  backend/            rename, ROB, issue, execute, LSU, commit
  lib/                공용 하드웨어 프리미티브
  soc/                AXI Xbar, I/D fabric, TIM, CLINT, PLIC, Boot ROM
tb/                   testbench와 reference-model 연동(예정)
scripts/              lint/build/formal 실행 스크립트(예정)
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
