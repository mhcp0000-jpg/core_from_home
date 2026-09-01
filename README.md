# RV OoO Core SoC

RV32IMFC를 1차 타깃으로 하는 2-wide out-of-order RISC-V 코어와 AXI4 SoC 프로젝트입니다.
데이터 경로와 주소 경로는 처음부터 `XLEN` 파라미터를 사용하여 RV64IMFC로 확장할 수 있게 설계합니다.

초기 SoC는 128 KiB ITIM/DTIM, CLINT, PLIC, Boot ROM, HostIF와 DPI Host ELF loader를 포함합니다. 현재 단계는 **RV32IMFC 1차 RTL 통합 및 directed verification 완료, 전체 ISA differential 진행 전**입니다. SoC interconnect/peripheral과 2-wide frontend/decode, dual-lane rename, ROB, unified issue queue/global 2-wide issue, INT/FP physical register file, ALU 2개, branch, multiplier, iterative divider, RV32F 실행기가 하나의 backend로 연결됐습니다. dual LSU/AGU, LQ/SQ, committed-store buffer는 conservative memory ordering, store-to-load forwarding과 commit 이후 store visibility를 구현합니다. commit-time CSR, M/U privilege, precise trap, `MRET`, `WFI`, `FENCE/FENCE.I`와 8-entry PMP도 IFU/dual-LSU에 통합됐으며 trap/interrupt와 fence drain은 독립 controller 경계로 분리했습니다. frontend에는 256-entry 4-way BTB, 2048-entry gshare, 16-entry RAS가 연결됐고, DPI-C는 ELF32/ELF64 PT_LOAD를 Host AXI로 적재한 뒤 HostIF와 CLINT MSIP를 순서대로 기록합니다. parse/elaboration, Icarus 단위 15종, Verilator 블록 11종, backend 통합, Boot ROM 부트, DPI ELF end-to-end가 통과했습니다. 실제 RV32IMF, 혼합폭 RV32C, M/U privilege ELF의 ROB commit trace도 예상 결과와 exact-match합니다. GCC 15.2로 빌드한 C integer/FP/load-store loop도 357개 payload commit, FP write 68개, lane-1 commit 121개, payload trap 0개로 self-check/HostIF exit(0)을 통과했습니다. C/CSR/FENCE의 모든 조합과 random long-run, Spike/Sail 및 riscv-arch-test는 아직 sign-off되지 않았습니다.

## 문서

- [통합 Hardware Design Description](docs/HDD_Core_Architecture.md) — core/SoC/interface/memory map/boot/검증/구현 계획의 단일 기준 문서
  - [전체 SoC architecture](docs/HDD_Core_Architecture.md#31-전체-soc-architecture) · [구조도 크게 보기](docs/diagrams/soc-architecture.svg)
  - [코어 내부 microarchitecture](docs/HDD_Core_Architecture.md#32-코어-내부-microarchitecture) · [구조도 크게 보기](docs/diagrams/core-microarchitecture.svg)
- [GCC C/ASM loop 검증 결과](verification/tests/rv32_c_loop/RESULTS.md) — 사용 소스, 예상값, 실제 HostIF/commit 결과와 재현 명령

## 디렉터리

```text
docs/
  HDD_Core_Architecture.md       단일 설계 기준 문서와 module interface

rtl/
  rv_ooo_pkg.sv                  core 공용 type/parameter
  rv_ooo_core.sv                 독립 core top
  frontend/                      fetch, predictor, C align/expansion
  backend/                       decode, rename, ROB, IQ, execute, LSU, commit
  soc/                           AXI, I/D fabric, TIM, CLINT, PLIC, Boot/HostIF

sw/
  tests/
    rv32_c_loop/                 C source, startup ASM, linker script 한 세트

tb/
  unit/
    frontend/                    frontend module 단위 testbench
    backend/                     backend module 단위 testbench
    soc/                         bus/fabric/peripheral 단위 testbench
  integration/
    backend/                     OoO backend 통합 testbench
    soc/                         Boot ROM부터 SoC top까지 통합 testbench
  e2e/dpi/                       ELF loader, Host model, commit logger, E2E top
  fixtures/bootrom/              test 전용 Boot ROM image
  elaboration/                   parameter/address-map elaboration smoke top
  filelist_elab.f                RTL+elaboration source list

scripts/                         build_/run_/verify_ 접두사 기반 실행 도구

config/                          주소 맵 JSON, C/ASM 상수, Host 실행 기본값

verification/
  tests/
    rv32_c_loop/                 결과 설명, commit CSV, disassembly, ELF metadata
```

파일 배치 원칙은 `rtl=합성 대상`, `tb=검증 하드웨어/host`, `sw=core에서 실행할 프로그램`, `verification=보존할 결과`, `scripts=재현 명령`이다. 단위 testbench는 대상 RTL 영역과 동일한 `frontend/backend/soc` 이름을 사용하고, 여러 영역을 연결하는 testbench만 `integration` 또는 `e2e`에 둔다.

`sw/tests/<case>`와 `verification/tests/<case>`는 같은 case 이름을 사용한다. 예를 들어 `rv32_c_loop`의 입력 소스는 `sw/tests/rv32_c_loop`, 장기 보존할 결과와 해설은 `verification/tests/rv32_c_loop`에 있다. 시뮬레이터 바이너리나 ELF 같은 재생성 가능한 중간 산출물은 repository에 넣지 않고 실행 시 지정한 `ArtifactRoot`에만 생성한다.

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

주소 맵과 Host ELF 환경이 다른 새 프로젝트 복사본은 대화형 생성기로 만들 수 있습니다.
원본 폴더는 수정하지 않으며, BootROM/CLINT/PLIC/HostIF/ITIM/DTIM의 시작 주소와
KiB 크기, boot mtvec, BootROM image, 기본 DPI ELF와 artifact 폴더를 차례로 묻습니다.

```powershell
# Windows
scripts/configure_project.ps1
```

```bash
# Linux
chmod +x scripts/configure_project.sh
./scripts/configure_project.sh
```

질문 없이 서버 설정 파일로 생성할 수도 있습니다.

```bash
./scripts/configure_project.sh --non-interactive \
  --config config/soc_project.example.json \
  --output ../company_rv_core
```

생성된 폴더의 `config/soc_project.json`은 최종 설정 기록이고, `rv_soc_pkg.sv`,
C linker script, C/assembly MMIO 상수와 BootROM HEX는 이 값으로 함께 생성됩니다.
기본 ELF를 지정했다면 `./scripts/run_configured_elf.sh` 또는
`scripts/run_configured_elf.ps1` 한 번으로 DPI Host를 실행합니다. Linux runner는
PATH의 `verilator`, `make`, `g++`, `python3`를 사용합니다.

ROB retire 로그는 `order,cycle,lane,pc,instruction,rd_write,rd_fp,rd,wdata,trap,cause,tval` CSV로 기록됩니다. speculative WB에는 나중에 squash될 결과가 포함되므로 정답 비교에는 쓰지 않고, architectural state가 확정되는 in-order commit 경계를 ISA reference 비교점으로 사용합니다.

현재 directed 검증 전체를 한 번에 실행하려면 다음 명령을 사용합니다. 이 스크립트는 self-contained ELF 3종을 생성하고 Boot ROM→WFI→Host AXI 적재→CLINT MSIP→ITIM 실행→HostIF exit(0)을 반복합니다. RV32IMF 24개 payload의 INT/FP 결과, 혼합 16/32-bit RV32C 18개 payload와 branch squash/FENCE, MRET 이후 U-mode illegal CSR·ECALL trap 및 M-mode 복귀를 각각 ROB commit CSV와 exact-match합니다.

```powershell
powershell -ExecutionPolicy Bypass -File scripts/run_verification.ps1
```

이 명령은 각 회귀의 DPI/Verilator build cache를 `<ArtifactRoot>/soc_elf_build`에 격리한다. 다른 경로를 원하면 `-ArtifactRoot`나 `-SocElfBuildRoot`를 지정하면 된다.

실제 GCC가 생성한 RV32IMFC C/ASM loop를 다시 빌드하고 실행하려면 다음을 사용합니다. 결과 요약, ELF header/symbol/disassembly와 전체 ROB commit CSV는 `verification/tests/rv32_c_loop`에 보관합니다.

```powershell
powershell -ExecutionPolicy Bypass -File scripts/run_c_loop_test.ps1 `
  -PublishRoot verification/tests/rv32_c_loop
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
