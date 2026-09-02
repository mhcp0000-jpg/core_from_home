# Xcelium / `verilog_sub` export

`sources_core.f`와 `sources_soc.f`는 repository root에서 직접 사용하는 Cadence
Xcelium용 compile-order file list다. package를 먼저, interface를 다음, core와 SoC
top을 마지막에 배치한다.

회사 서버로 self-contained bundle을 전달할 때는 다음 명령을 사용한다.

```bash
python3 scripts/export_verilog_sub.py --output out/verilog_sub
```

생성 디렉터리는 다음 파일을 포함한다.

```text
verilog_sub/
  rtl/                       copied synthesizable RTL
  config/                    generated memory-map contract
  tb/fixtures/bootrom/       default Boot ROM image
  filelist/core_rtl.f        core-only relative file list
  filelist/soc_rtl.f         full-SoC relative file list
  verilog_sub.f              soc_rtl.f와 같은 root-level entry
  scripts/run_xcelium.sh     compile/run wrapper
  manifest.json              source revision, map, SHA-256
```

서버 testbench는 bundle에 복사하지 않는다. 서버 환경의 기존 TB file list를 그대로
두고 다음처럼 core/SoC RTL 앞에 연결한다.

```bash
/path/to/verilog_sub/scripts/run_xcelium.sh compile
/path/to/verilog_sub/scripts/run_xcelium.sh run server_tb_top tb/filelist.f \
  +elf=/absolute/test.elf
```

wrapper는 호출 당시 server working directory를 변경하지 않는다. 따라서 기존
`tb/filelist.f` 내부의 상대경로 의미가 보존된다. `verilog_sub.f`의 RTL 항목만 bundle
root 기준 절대경로로 확장해 `xrun`에 넘긴다.

서버 flow가 자체 `xrun` 명령을 소유하면 wrapper 없이 다음 항목만 추가한다.

```bash
xrun -64bit -sv -f /path/to/verilog_sub/verilog_sub.f \
  -f /path/to/server/tb/filelist.f -top server_tb_top
```

`verilog_sub.f`의 경로는 bundle root 기준이다. wrapper 없이 다른 directory에서
직접 `-f`만 전달하면 RTL 상대경로가 틀어질 수 있으므로 bundle root에서 실행하거나
server flow가 source path를 절대경로로 변환해야 한다. DPI, server Host monitor와
server `tohost` protocol은 기존 검증
환경이 소유한다. 현재 repository의 Verilator DPI testbench는 의도적으로 export하지
않는다.
