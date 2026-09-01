#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd -- "${script_dir}/.." && pwd)"
# shellcheck source=/dev/null
source "${repo_root}/config/soc_project.env"

elf_path="${1:-$SOC_DEFAULT_ELF}"
if [[ -z "$elf_path" ]]; then
  printf 'No default ELF is configured. Pass one as the first argument.\n' >&2
  exit 2
fi
[[ "$elf_path" = /* ]] || elf_path="${repo_root}/${elf_path}"
artifact_root="$SOC_ARTIFACT_ROOT"
[[ "$artifact_root" = /* ]] || artifact_root="${repo_root}/${artifact_root}"

exec "${script_dir}/run_soc_elf_test.sh" \
  --elf "$elf_path" \
  --build-root "${artifact_root}/build" \
  --trace "${artifact_root}/commit.csv" \
  --timeout-cycles "$SOC_TIMEOUT_CYCLES"
