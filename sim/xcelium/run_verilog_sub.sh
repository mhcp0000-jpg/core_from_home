#!/usr/bin/env bash
set -euo pipefail

# ---------------------------------------------------------------------------
# 사용자 설정: 아래 BINARY 한 줄에 실행할 RISC-V ELF 절대경로를 입력하세요.
# 환경변수 BINARY로도 덮어쓸 수 있습니다.
# ---------------------------------------------------------------------------
BINARY="${BINARY:-/ABSOLUTE/PATH/TO/YOUR_PROGRAM.elf}"

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=setup_env.sh
source "${script_dir}/setup_env.sh"

VERILOG_SUB="${VERILOG_SUB:-verilog_sub}"
BUILD_DIR="${HTIF_BUILD_DIR:-${CORE_ROOT}/out/xcelium_htif}"
TIMEOUT_CYCLES="${TIMEOUT_CYCLES:-2000000}"
CXX_BIN="${CXX:-g++}"

if [[ "${BINARY}" == "/ABSOLUTE/PATH/TO/YOUR_PROGRAM.elf" ]]; then
  printf 'run_verilog_sub.sh의 BINARY= 줄에 ELF 절대경로를 입력하세요.\n' >&2
  exit 2
fi
if [[ ! -f "${BINARY}" ]]; then
  printf 'ELF 파일을 찾을 수 없습니다: %s\n' "${BINARY}" >&2
  exit 2
fi
if ! command -v "${VERILOG_SUB}" >/dev/null 2>&1; then
  printf 'verilog_sub 명령을 찾을 수 없습니다: %s\n' "${VERILOG_SUB}" >&2
  exit 2
fi
if ! command -v "${CXX_BIN}" >/dev/null 2>&1; then
  printf 'DPI library 빌드용 C++ compiler를 찾을 수 없습니다: %s\n' "${CXX_BIN}" >&2
  exit 2
fi

mkdir -p "${BUILD_DIR}"
dpi_library="${BUILD_DIR}/libcore_htif_dpi.so"
"${CXX_BIN}" -std=c++17 -O2 -fPIC -shared \
  "${TB_DIR}/e2e/dpi/elf_loader.cpp" -o "${dpi_library}"

# File-list paths use RTL_DIR/TB_DIR. Run from CORE_ROOT as well so the BootROM
# $readmemh relative path has an unambiguous base directory.
cd "${CORE_ROOT}"
exec "${VERILOG_SUB}" \
  -64bit -sv -timescale 1ns/1ps +define+SYNTHESIS \
  -f "${XCELIUM_DIR}/rtl.f" \
  -f "${XCELIUM_DIR}/htif_tb.f" \
  -top rv_soc_htif_dpi_tb \
  -sv_lib "${dpi_library}" \
  -access +rwc \
  -xmlibdirname "${BUILD_DIR}/xcelium.d" \
  -l "${BUILD_DIR}/verilog_sub.log" \
  "+elf=${BINARY}" \
  "+timeout_cycles=${TIMEOUT_CYCLES}" \
  "$@"
