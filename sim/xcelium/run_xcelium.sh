#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  ./run_xcelium.sh compile [extra xrun arguments...]
  ./run_xcelium.sh run <top-module> <server-tb-filelist.f> [extra xrun arguments...]

Environment:
  XRUN_BIN       Xcelium executable (default: xrun)
  XCELIUM_64BIT  Set to 0 to omit -64bit (default: 1)
  XCELIUM_WORK   Work directory relative to this bundle (default: xcelium.d)

The script preserves the caller's working directory so relative paths inside
the existing server testbench file list keep their original meaning. Bundle
RTL paths are expanded to absolute paths before invoking xrun.
EOF
}

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
if [[ -f "${script_dir}/../verilog_sub.f" ]]; then
  # Exported bundle layout: verilog_sub/scripts/run_xcelium.sh
  bundle_root="$(cd -- "${script_dir}/.." && pwd)"
else
  # Repository layout: sim/xcelium/run_xcelium.sh
  bundle_root="$(cd -- "${script_dir}/../.." && pwd)"
fi
xrun_bin="${XRUN_BIN:-xrun}"
work_dir_setting="${XCELIUM_WORK:-xcelium.d}"

if [[ $# -lt 1 ]]; then
  usage
  exit 2
fi

mode="$1"
shift

rtl_sources=()
while IFS= read -r source || [[ -n "${source}" ]]; do
  source="${source%%#*}"
  source="${source#"${source%%[![:space:]]*}"}"
  source="${source%"${source##*[![:space:]]}"}"
  [[ -z "${source}" ]] && continue
  rtl_sources+=("${bundle_root}/${source}")
done < "${bundle_root}/verilog_sub.f"

if [[ "${work_dir_setting}" = /* ]]; then
  work_dir="${work_dir_setting}"
else
  work_dir="${bundle_root}/${work_dir_setting}"
fi
common_args=(-sv "${rtl_sources[@]}" -xmlibdirname "${work_dir}")
if [[ "${XCELIUM_64BIT:-1}" != "0" ]]; then
  common_args=(-64bit "${common_args[@]}")
fi

mkdir -p "${bundle_root}/logs"

case "${mode}" in
  compile)
    "${xrun_bin}" "${common_args[@]}" -compile \
      -l "${bundle_root}/logs/xrun_compile.log" "$@"
    ;;
  run)
    if [[ $# -lt 2 ]]; then
      usage
      exit 2
    fi
    top_module="$1"
    tb_filelist_input="$2"
    shift 2
    if [[ ! -f "${tb_filelist_input}" ]]; then
      echo "Server testbench file list not found: ${tb_filelist_input}" >&2
      exit 2
    fi
    "${xrun_bin}" "${common_args[@]}" -f "${tb_filelist_input}" \
      -top "${top_module}" -access +rwc \
      -l "${bundle_root}/logs/xrun_run.log" "$@"
    ;;
  *)
    usage
    exit 2
    ;;
esac
