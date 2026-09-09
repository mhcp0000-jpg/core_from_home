# PMP 16-byte fetch-block boundary 회귀

`pmpaddr0=0x2000023f`, `pmpcfg0=0x0000000f`로 PMP0를 unlocked
TOR/RWX `[0, 0x800008fc)`로 설정한 뒤 M-mode에서 정확히
`0x800008fc`의 32-bit instruction을 실행한다. 이 instruction의 두 2-byte parcel은
PMP entry와 match하지 않으므로 M-mode default allow로 정상 retire해야 한다.

과거 RTL은 `0x800008f0~0x800008ff` 16-byte transport block 전체를 하나의 PMP
operation으로 검사했다. 그 결과 TOR와 partial match가 되어 실제 ITIM request를
막고 instruction access fault를 만들었다. 수정 RTL은 16-byte ITIM bandwidth를
유지하되 8개의 2-byte permission을 fetch queue byte metadata로 보관한다.

재현 source는 `sw/tests/pmp_fetch/parcel_boundary.S`, linker script는
`sw/tests/htif_smoke/rv32_htif.ld`다. Linux에서 다음처럼 다시 빌드하고 실행한다.

```bash
riscv-none-elf-gcc -march=rv32imc_zicsr_zifencei -mabi=ilp32 \
  -nostdlib -nostartfiles -static -Wl,--build-id=none \
  -T sw/tests/htif_smoke/rv32_htif.ld \
  sw/tests/pmp_fetch/parcel_boundary.S \
  -o verification/tests/pmp_fetch_boundary/test.elf

BINARY="$PWD/verification/tests/pmp_fetch_boundary/test.elf" \
  ./sim/xcelium/run_verilog_sub.sh
python3 scripts/check_pmp_fetch_boundary.py \
  sim/xcelium/out/commit_trace.csv
```

정상 결과는 DPI AXI readback PASS, `HTIF TEST PASS`, checker PASS이며
`0x800008fc`가 `instr=80000b37`, `trap=0`으로 commit trace에 있어야 한다.
