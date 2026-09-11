# RISC-V DV FP/MMU SoC smoke 결과

실행일: 2026-09-11  
결과: **PASS**

## 실행 정보

- GitHub Actions run: [#16 — `34607227176`](https://github.com/mhcp0000-jpg/core_from_home/actions/runs/34607227176)
- Job: [`rv32imfc-stress`](https://github.com/mhcp0000-jpg/core_from_home/actions/runs/34607227176/job/103288522291)
- 공식 테스트 이름: `riscv_floating_point_mmu_stress_test`
- seed: `1`
- 사용 RTL: commit `cf763a7` (Verilator 5.050)

## 이번 smoke 프로파일

현재 저장소의 재현 가능한 pyflow 경로에 맞춰 RV32IMF random/hazard load-store stream을
사용했습니다. `instr_cnt=50`, `num_of_sub_program=0`, random/hazard 비율은 각각 40%이며
compressed instruction과 unaligned access 생성은 끕니다. 따라서 이 결과는 공식 이름을
사용한 RTL/SoC 통합 smoke이며, riscv-dv의 전체 SV/UVM 4-stream 장기 생성 결과나
Spike/Sail ISA differential sign-off를 의미하지 않습니다. 전체 공식 프로파일은
Xcelium/UVM 서버에서 별도 실행해야 합니다.

## 확인된 흐름

1. Verilator 5.050으로 RTL이 compile/elaborate 되었습니다.
2. Boot ROM이 로드되고 `pc=0x00001018`의 WFI retire가 관찰되었습니다.
3. Host DPI가 ELF의 2개 `PT_LOAD` segment를 Host AXI로 적재했습니다.
   - segment 0: `0x80000000`, 4,148 bytes
   - segment 1: `0x80020000`, 56,400 bytes
   - 총 60,548 bytes readback exact-compare PASS
4. Boot entry `0x80000000` 및 boot-ready mailbox를 기록하고 CLINT MSIP
   (`0x02000000`)를 assert했습니다.
5. Boot ROM이 MSIP를 clear한 뒤 payload가 `0x80000000`에서 실행되었습니다.
6. 최종 Host mailbox 결과가 `HTIF TEST PASS`로 종료되었습니다.

## 산출물

Actions run의 `riscv-dv-fp-stress-seed-1` artifact에 생성 assembly, ELF, disassembly,
console log, `commit_trace.csv`가 포함됩니다.  
[artifact 다운로드 페이지](https://github.com/mhcp0000-jpg/core_from_home/actions/runs/34607227176/artifacts/10265939142)  
SHA-256: `bf9e1a85fefc0f225b112d71c28f3d9149eb47bc5d084c4e31c3236285277a96`

