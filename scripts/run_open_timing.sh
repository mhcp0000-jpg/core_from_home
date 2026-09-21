#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
mode="${1:-all}"
build_root="${BUILD_ROOT:-/tmp/rv_ooo_open_timing}"
liberty="${NANGATE45_LIBERTY:-}"
yosys_bin="${YOSYS_BIN:-yosys}"
target_delay_ps="${TARGET_DELAY_PS:-10000}"

if [[ -z "$liberty" || ! -f "$liberty" ]]; then
  echo "Set NANGATE45_LIBERTY to a valid standard-cell .lib file." >&2
  exit 2
fi
if ! command -v "$yosys_bin" >/dev/null 2>&1; then
  echo "Yosys was not found; set YOSYS_BIN or add it to PATH." >&2
  exit 2
fi

mkdir -p "$build_root"
sources="$repo_root/sim/xcelium/sources_core.f"
constraint="$repo_root/synth/open_source/nangate45_abc.constr"

run_yosys() {
  local name="$1"
  local command="$2"
  local run_dir="$build_root/$name"
  mkdir -p "$run_dir"
  (cd "$repo_root" && "$yosys_bin" -q -l "$run_dir/synth.log" -p "$command" \
    >"$run_dir/console.log" 2>&1)
  echo "PASS $name: $run_dir/synth.log"
}

if [[ "$mode" == "check" || "$mode" == "all" ]]; then
  run_yosys rv_ooo_core_check \
    "read_slang --std 1800-2017 --single-unit --ignore-assertions --ignore-initial --top rv_ooo_core -f $sources; hierarchy -check -top rv_ooo_core; proc; check; stat"
fi

if [[ "$mode" == "blocks" || "$mode" == "all" ]]; then
  blocks=(
    "rv_writeback_arbiter|rv_writeback_arbiter|-G SOURCE_COUNT=11|full"
    "rv_lsq|rv_lsq||macro"
    "rv_fpu|rv_fpu||full"
    "rv_issue_queue|rv_issue_queue|-G ENTRIES=56|macro"
    "rv_rob|rv_rob||macro"
    "rv_rename2|rv_rename2||full"
    "rv_pmp|rv_pmp|-G CHECK_PORTS=8|full"
    "rv_issue_arbiter|rv_issue_arbiter|-G CANDIDATE_COUNT=2|full"
  )
  printf 'block,flow,delay_ps,area_um2_excluding_memories,log\n' \
    >"$build_root/timing_summary.csv"
  for spec in "${blocks[@]}"; do
    IFS='|' read -r name top args flow <<<"$spec"
    if [[ "$flow" == "macro" ]]; then
      lowering="proc; flatten; opt -fast; memory_collect; techmap; opt -fast"
    else
      lowering="synth -top $top -flatten -noshare -noabc"
    fi
    command="read_slang --std 1800-2017 --single-unit --ignore-assertions --ignore-initial --top $top $args -f $sources; hierarchy -check -top $top; $lowering; dfflibmap -liberty $liberty; abc -liberty $liberty -constr $constraint -D $target_delay_ps; clean; read_liberty -lib $liberty; check; stat -liberty $liberty"
    run_yosys "$name" "$command"
    log="$build_root/$name/synth.log"
    delay="$(grep -Eo 'Delay[[:space:]]*=[[:space:]]*[0-9.]+[[:space:]]*ps' "$log" | tail -1 | grep -Eo '[0-9.]+' || true)"
    area="$(grep -Eo "Chip area for module '[^']+':[[:space:]]*[0-9.]+" "$log" | tail -1 | grep -Eo '[0-9.]+$' || true)"
    printf '%s,%s,%s,%s,%s\n' "$name" "$flow" "$delay" "$area" "$log" \
      >>"$build_root/timing_summary.csv"
  done
  echo "Timing summary: $build_root/timing_summary.csv"
fi
