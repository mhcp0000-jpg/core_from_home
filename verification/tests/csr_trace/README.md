# CSR/GPR commit 로그 구분

소스: `sw/tests/pmp_fetch/csr_trace.S`.
mscratch에서 CSRRW/S/C 및 immediate 3종을 실행하고, read-only(rs1/zimm=0),
rd=x0 write와 read-only cycle CSR에 대한 illegal write를 검사한다.
GPR에는 old CSR value가, `csr_wdata`에는 set/clear까지 적용한 새 write 요청
값이 찍혀야 한다. 이 테스트는 WARL이 없는 mscratch를 사용한다.
`csr_wdata`는 일반적으로 WARL/lock 적용 후 실제 저장값 readback은 아니다.

`test.elf`는 실행 ELF, `symbols.txt`는 각 검사 명령의 PC, `commit_trace.csv`는
전체 실행 결과, `simulation.txt`는 콘솔 출력이다. 기대 결과는 checker 안에
독립적인 상수로 정의되어 있다. CSR 명령 9개와 illegal write 1개를 검사한다.

로컬 Verilator 5.050 SoC 실행 및 checker: PASS. 이 실행은 기존 SoC 빌드의
`SYNTHESIS` 설정을 사용하므로 전체 SVA 검증이나 Xcelium 실행 결과는 아니다.

```bash
BINARY="$PWD/verification/tests/csr_trace/test.elf" ./sim/xcelium/run_verilog_sub.sh
# 새 실행의 commit_trace.csv를 이 테스트 결과 디렉터리에 복사한 후:
python3 scripts/check_csr_trace.py verification/tests/csr_trace
```

서버에서 로컬 검증 로그를 덮어쓰지 않으려면 symbols.txt와 새 CSV를 별도
디렉터리에 놓고 해당 경로를 checker에 넘긴다. 테스트 종료는 HTIF exit 0이며
예상된 cycle CSR illegal-write cause=2가 한 번 발생한다. Boot ROM MSIP는 별도다.
