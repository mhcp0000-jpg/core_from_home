#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: run_soc_elf_test.sh --elf FILE [options]

Options:
  --build-root DIR       Verilator output directory (default: /tmp/rv_soc_elf)
  --trace FILE           Commit CSV output path
  --jobs N               Parallel build jobs (default: host CPU count)
  --timeout-cycles N     Simulation timeout (default: 2000000)
  --verilator COMMAND    Verilator command (default: verilator)
EOF
}

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd -- "${script_dir}/.." && pwd)"
cd -- "$repo_root"
elf_path=""
build_root="${TMPDIR:-/tmp}/rv_soc_elf"
trace_path=""
jobs="$(getconf _NPROCESSORS_ONLN 2>/dev/null || printf '4')"
timeout_cycles=2000000
verilator_cmd="${VERILATOR:-verilator}"

while (($#)); do
  case "$1" in
    --elf) elf_path="$2"; shift 2 ;;
    --build-root) build_root="$2"; shift 2 ;;
    --trace) trace_path="$2"; shift 2 ;;
    --jobs) jobs="$2"; shift 2 ;;
    --timeout-cycles) timeout_cycles="$2"; shift 2 ;;
    --verilator) verilator_cmd="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) printf 'Unknown option: %s\n' "$1" >&2; usage >&2; exit 2 ;;
  esac
done

if [[ -z "$elf_path" || ! -f "$elf_path" ]]; then
  printf 'ELF file not found: %s\n' "$elf_path" >&2
  exit 2
fi
command -v "$verilator_cmd" >/dev/null || {
  printf 'Verilator not found: %s\n' "$verilator_cmd" >&2
  exit 2
}
command -v make >/dev/null || { printf 'GNU make not found\n' >&2; exit 2; }
command -v g++ >/dev/null || { printf 'g++ not found\n' >&2; exit 2; }

mkdir -p "$build_root"
build_root="$(cd -- "$build_root" && pwd)"
staged_elf="${build_root}/payload.elf"
cp -- "$elf_path" "$staged_elf"

sources=()
while IFS= read -r source; do
  source="${source%$'\r'}"
  [[ -z "${source//[[:space:]]/}" || "$source" == \#* ]] && continue
  sources+=("${repo_root}/${source}")
done < "${repo_root}/rtl/filelist.f"
sources+=(
  "${repo_root}/tb/e2e/dpi/rv_host_dpi.sv"
  "${repo_root}/tb/e2e/dpi/rv_commit_trace_logger.sv"
  "${repo_root}/tb/e2e/dpi/rv_soc_dpi_tb.sv"
  "${repo_root}/tb/e2e/dpi/elf_loader.cpp"
)

"$verilator_cmd" --cc --exe --timing --main -DSYNTHESIS -Wno-fatal \
  -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC --top-module rv_soc_dpi_tb \
  --Mdir "$build_root" "${sources[@]}"
make -j "$jobs" -C "$build_root" -f Vrv_soc_dpi_tb.mk

simulation_args=("+elf=${staged_elf}" "+timeout_cycles=${timeout_cycles}")
if [[ -n "$trace_path" ]]; then
  mkdir -p "$(dirname -- "$trace_path")"
  trace_path="$(cd -- "$(dirname -- "$trace_path")" && pwd)/$(basename -- "$trace_path")"
  simulation_args+=("+trace_file=${trace_path}")
fi
"${build_root}/Vrv_soc_dpi_tb" "${simulation_args[@]}"
