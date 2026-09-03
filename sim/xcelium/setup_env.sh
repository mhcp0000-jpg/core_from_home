#!/usr/bin/env bash
# Source this file from any directory: source /path/to/core/sim/xcelium/setup_env.sh

_rv_setup_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
export CORE_ROOT="$(cd -- "${_rv_setup_dir}/../.." && pwd)"
export RTL_DIR="${CORE_ROOT}/rtl"
export TB_DIR="${CORE_ROOT}/tb"
export XCELIUM_DIR="${CORE_ROOT}/sim/xcelium"
unset _rv_setup_dir

printf 'CORE_ROOT   = %s\n' "${CORE_ROOT}"
printf 'RTL_DIR     = %s\n' "${RTL_DIR}"
printf 'TB_DIR      = %s\n' "${TB_DIR}"
printf 'XCELIUM_DIR = %s\n' "${XCELIUM_DIR}"
