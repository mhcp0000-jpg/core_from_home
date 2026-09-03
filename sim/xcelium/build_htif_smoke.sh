#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=setup_env.sh
source "${script_dir}/setup_env.sh"

tool_prefix="${RISCV_TOOL_PREFIX:-riscv-none-elf-}"
output="${1:-${CORE_ROOT}/out/xcelium_htif/htif_smoke.elf}"
mkdir -p "$(dirname -- "${output}")"

"${tool_prefix}gcc" -march=rv32im_zicsr -mabi=ilp32 -mcmodel=medany \
  -nostdlib -nostartfiles -static -Wl,--build-id=none \
  -T "${CORE_ROOT}/sw/tests/htif_smoke/rv32_htif.ld" \
  "${CORE_ROOT}/sw/tests/htif_smoke/htif_smoke.S" -o "${output}"

"${tool_prefix}nm" -n "${output}" | grep -E ' (tohost|fromhost)$'
printf 'HTIF smoke ELF: %s\n' "${output}"
