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
BUILD_DIR="${HTIF_BUILD_DIR:-${CORE_ROOT}/sim/xcelium/out}"
TIMEOUT_CYCLES="${TIMEOUT_CYCLES:-2000000}"
HEARTBEAT_CYCLES="${HEARTBEAT_CYCLES:-100000}"
RTL_ASSERTIONS="${RTL_ASSERTIONS:-0}"
CXX_BIN="${CXX:-g++}"
COMPILE_SCRIPT="${COMPILE_SCRIPT:-${XCELIUM_DIR}/isrun.scr}"
SIM_SCRIPT="${SIM_SCRIPT:-${XCELIUM_DIR}/issim.scr}"

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
if [[ ! -f "${COMPILE_SCRIPT}" ]]; then
  printf 'compile script를 찾을 수 없습니다: %s\n' "${COMPILE_SCRIPT}" >&2
  exit 2
fi
if [[ ! -f "${SIM_SCRIPT}" ]]; then
  printf 'simulation script를 찾을 수 없습니다: %s\n' "${SIM_SCRIPT}" >&2
  exit 2
fi

mkdir -p "${BUILD_DIR}"
dpi_library="${BUILD_DIR}/libcore_htif_dpi.so"
printf 'Building DPI library: %s\n' "${dpi_library}"
"${CXX_BIN}" -std=c++17 -O2 -fPIC -shared \
  "${TB_DIR}/e2e/dpi/elf_loader.cpp" -o "${dpi_library}"

# The company wrapper schedules these scripts on the compile and short queues.
# Absolute script paths and exported project paths make the jobs independent of
# the directory from which this runner was launched.
cd "${CORE_ROOT}"
printf 'Step 1: Compiling/elaborating RTL...\n'
"${VERILOG_SUB}" -Is -compile "${COMPILE_SCRIPT}" \
  -RTL_ASSERTIONS="${RTL_ASSERTIONS}"

printf 'Step 2: Running simulation with ELF: %s\n' "${BINARY}"
"${VERILOG_SUB}" -Is -short "${SIM_SCRIPT}" \
  -BINARY="${BINARY}" \
  -SV_LIB="${dpi_library}" \
  -TIMEOUT_CYCLES="${TIMEOUT_CYCLES}" \
  -HEARTBEAT_CYCLES="${HEARTBEAT_CYCLES}" \
  "$@"
