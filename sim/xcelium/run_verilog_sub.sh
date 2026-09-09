#!/usr/bin/env bash
set -euo pipefail

# ---------------------------------------------------------------------------
# 기본 ELF는 서버의 riscv-dv arithmetic test입니다.
# 다른 ELF가 필요할 때만 환경변수 BINARY로 덮어씁니다.
# ---------------------------------------------------------------------------
BINARY="${BINARY:-/user/rocket/user/jeemin/project/TEST/DM_base/riscv_arithmetic_basic_test_0.elf}"

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=setup_env.sh
source "${script_dir}/setup_env.sh"

VERILOG_SUB="${VERILOG_SUB:-verilog_sub}"
BUILD_DIR="${HTIF_BUILD_DIR:-${CORE_ROOT}/sim/xcelium/out}"
TIMEOUT_CYCLES="${TIMEOUT_CYCLES:-2000000}"
HEARTBEAT_CYCLES="${HEARTBEAT_CYCLES:-100000}"
ELF_VERIFY="${ELF_VERIFY:-1}"
RTL_ASSERTIONS="${RTL_ASSERTIONS:-0}"
TRACE_FILE="${TRACE_FILE:-${BUILD_DIR}/commit_trace.csv}"
FSDB_ENABLE="${FSDB_ENABLE:-1}"
DUMP_DIR="${DUMP:-${BUILD_DIR}}"
FSDB_FILE="${FSDB_FILE:-${DUMP_DIR}/binary.fsdb}"
FSDB_DUMP_MDA="${FSDB_DUMP_MDA:-0}"
FSDB_FLUSH_CYCLES="${FSDB_FLUSH_CYCLES:-100000}"
CXX_BIN="${CXX:-g++}"
COMPILE_SCRIPT="${COMPILE_SCRIPT:-${XCELIUM_DIR}/isrun.scr}"
SIM_SCRIPT="${SIM_SCRIPT:-${XCELIUM_DIR}/issim.scr}"

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
if [[ "${FSDB_ENABLE}" != "0" && "${FSDB_ENABLE}" != "1" ]]; then
  printf 'FSDB_ENABLE must be 0 or 1: %s\n' "${FSDB_ENABLE}" >&2
  exit 2
fi
if [[ "${ELF_VERIFY}" != "0" && "${ELF_VERIFY}" != "1" ]]; then
  printf 'ELF_VERIFY must be 0 or 1: %s\n' "${ELF_VERIFY}" >&2
  exit 2
fi
if [[ "${FSDB_DUMP_MDA}" != "0" && "${FSDB_DUMP_MDA}" != "1" ]]; then
  printf 'FSDB_DUMP_MDA must be 0 or 1: %s\n' "${FSDB_DUMP_MDA}" >&2
  exit 2
fi

mkdir -p "${BUILD_DIR}"
if [[ "${FSDB_ENABLE}" == "1" ]]; then
  mkdir -p "$(dirname -- "${FSDB_FILE}")"
  printf 'FSDB enabled: +fsdbfile=%s mda=%s flush_cycles=%s\n' \
    "${FSDB_FILE}" "${FSDB_DUMP_MDA}" "${FSDB_FLUSH_CYCLES}"
else
  printf 'FSDB disabled (FSDB_ENABLE=0)\n'
fi
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
  -RTL_ASSERTIONS="${RTL_ASSERTIONS}" \
  -FSDB_ENABLE="${FSDB_ENABLE}"

printf 'Step 2: Running simulation with ELF: %s\n' "${BINARY}"
"${VERILOG_SUB}" -Is -short "${SIM_SCRIPT}" \
  -BINARY="${BINARY}" \
  -SV_LIB="${dpi_library}" \
  -TIMEOUT_CYCLES="${TIMEOUT_CYCLES}" \
  -HEARTBEAT_CYCLES="${HEARTBEAT_CYCLES}" \
  -ELF_VERIFY="${ELF_VERIFY}" \
  -TRACE_FILE="${TRACE_FILE}" \
  -FSDB_ENABLE="${FSDB_ENABLE}" \
  -FSDB_FILE="${FSDB_FILE}" \
  -FSDB_DUMP_MDA="${FSDB_DUMP_MDA}" \
  -FSDB_FLUSH_CYCLES="${FSDB_FLUSH_CYCLES}" \
  "$@"
