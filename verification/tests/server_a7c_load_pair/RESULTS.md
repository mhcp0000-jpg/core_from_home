# Server 0x80000a7c load-pair reconstruction — 2026-09-14

Status: **directed test PASS; original server hang NOT reproduced or fixed**.

- RTL baseline: `e40c2b6` (RTL unchanged from `20d833c`), with diagnostic TB additions.
- Simulator: Verilator 5.050, 2-state. Both normal and `--assert` builds were run.
- Compiler: xPack riscv-none-elf GCC 15.2.0, RV32IMFC+Zicsr+Zifencei, ilp32f.
- Input: [source](../../../sw/tests/htif_smoke/server_a7c_load_pair.S), [ELF](load_pair.elf).
- Results: [complete simulation log](verilator.log), [retirement CSV](commit.csv).
- Reproduction/server setup: [guide](../../../sim/xcelium/server_debug/README.md).

This is not an upstream-generated RISC-V DV test or the original user's ELF.
It preserves reported instruction words/PCs from 0x80000a74 through 0x80000abc;
initial registers, FP state and data are controlled locally. It does not prove
PMP/CSR initialization equivalence with the server.

| PC | Operation | Observed value |
|---|---|---|
| 80000a7c | LHU at 8002d92a | 00005a5a |
| 80000a80 | LBU at 8002d92a | 0000005a |
| 80000a9c | LB after SB a4 | 00000011 |
| 80000aa8 | LBU after SB s10 | 00000022 |
| 80000aac | LB after SB s10 | 00000022 |
| 80000af0 | LBU after final SB s3 | 00000044 |

Assembly checks these values and writes TOHOST=1 on success, 3 on mismatch.
The normal run and a second `scripts/run_soc_elf_test.ps1 -RtlAssertions` run both
finish with `HTIF TEST PASS`. The assertion-enabled run did not define `SYNTHESIS`
and did not fire `rv_local_mem_if.p_request_stable_when_stalled` or another SVA.
It observed LHU at 80000a7c and LBU at 80000a80 retiring normally.
`+lsu_trace=1` emits request/response
transactions without sampling. A separate `+lsu_trace=0` run also passes and
emits zero LSU-REQ/LSU-RSP lines. Xcelium execution and company wrapper behavior
have not been tested locally. No RTL functional fix is claimed.
