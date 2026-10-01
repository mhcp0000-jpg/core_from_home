#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
mode="${1:-all}"
build_root="${BUILD_ROOT:-/tmp/rv_ooo_open_timing}"
liberty="${NANGATE45_LIBERTY:-}"
yosys_bin="${YOSYS_BIN:-yosys}"
target_delay_ps="${TARGET_DELAY_PS:-1000}"

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
  # Write the actual budget and inputs before mapping. A different ABC target
  # is not an RTL improvement/regression comparison.
  {
    printf 'block=%s\nabc_target_delay_ps=%s\ncommand=%s\n' "$name" "$target_delay_ps" "$command"
    sha256sum "$liberty" "$constraint" "$sources"
    while IFS= read -r source_path; do
      source_path="${source_path%$'\r'}"
      [[ -z "$source_path" || "$source_path" == \#* || "$source_path" == //* ]] && continue
      sha256sum "$repo_root/$source_path"
    done < "$sources"
  } > "$run_dir/run_manifest.txt"
  (cd "$repo_root" && "$yosys_bin" -q -l "$run_dir/synth.log" -p "$command" \
    >"$run_dir/console.log" 2>&1)
  echo "PASS $name: $run_dir/synth.log"
}

if [[ "$mode" == "check" || "$mode" == "all" ]]; then
  run_yosys rv_ooo_core_check \
    "read_slang --std 1800-2017 --single-unit --ignore-assertions --ignore-initial --top rv_ooo_core -G EARLY_LOAD_SELECT=${EARLY_LOAD_SELECT:-1} -G AGU_LOAD_BYPASS=${AGU_LOAD_BYPASS:-0} -G COMPATIBLE_PAIR_SELECT=${COMPATIBLE_PAIR_SELECT:-0} -f $sources; hierarchy -check -top rv_ooo_core; proc; check; stat"
fi

if [[ "$mode" == "blocks" || "$mode" == "all" ]]; then
  blocks=(
    "rv_writeback_arbiter|rv_writeback_arbiter|-G SOURCE_COUNT=11|full"
    "rv_lsq|rv_lsq||macro"
    "rv_fpu|rv_fpu|-G LATENCY=5|full"
    "rv_fpu6|rv_fpu|-G LATENCY=6|full"
    "rv_issue_queue|rv_issue_queue|-G ENTRIES=56 -G WRITEBACK_PORTS=8|macro"
    "rv_rob|rv_rob|-G LIVE_QUERY_PORTS=11|macro"
    "rv_rename2|rv_rename2||full"
    "rv_pmp|rv_pmp|-G CHECK_PORTS=8|full"
    "rv_issue_arbiter|rv_issue_arbiter|-G CANDIDATE_COUNT=2 -G AGE_ORDERED=1|full"
    # 아래 6개는 원래 screening list에 없었다.  실제 최장 block이었던
    # rv_store_buffer / rv_lsu_cluster가 그 때문에 보이지 않았다.
    "rv_store_buffer|rv_store_buffer||full"
    "rv_lsu_cluster|rv_lsu_cluster|-G AGU_DEPTH=2|macro"
    "rv_multiplier|rv_multiplier||full"
    "rv_divider|rv_divider||full"
    "rv_fetch_queue|rv_fetch_queue||full"
    "rv_frontend|rv_frontend||full|trim"
    "rv_csr_file|rv_csr_file||full"
    "rv_int_alu|rv_int_alu||full"
    "rv_int_alu64|rv_int_alu|-G XLEN=64|full"
    "rv_branch_unit|rv_branch_unit||full"
    "rv_decode2|rv_decode2||full"
    "rv_trap_controller|rv_trap_controller||full"
    "rv_branch_recovery|rv_branch_recovery||full"
    "rv_int_prf|rv_phys_regfile|-G PHYS_REGS=80 -G READ_PORTS=8 -G ZERO_REGISTER=1 -G WRITE_BYPASS=0|full"
    "rv_fp_prf|rv_phys_regfile|-G PHYS_REGS=80 -G READ_PORTS=8 -G WRITE_BYPASS=0|full"
    "rv_lsu_pipe|rv_lsu_pipe|-G DEPTH=2|full"
    "rv_exec_result_buffer|rv_exec_result_buffer|-G DEPTH=2|full"
    "rv_fence_controller|rv_fence_controller||full"
  )
  # Whole-backend / whole-core는 block 단위 측정이 볼 수 없는 cross-module
  # 경로(LSQ -> store_buffer -> writeback -> IQ -> mul)를 잡는다.  단, yosys
  # 기본 ABC script의 scorr/dc2/retime은 60만 cell 네트워크에서 사실상
  # 끝나지 않으므로 delay 중심으로 다듬은 script를 쓴다.
  if [[ "${INCLUDE_WHOLE_TOP:-0}" == "1" ]]; then
    blocks+=(
      "rv_backend|rv_backend||macro|trim"
      "rv_ooo_core|rv_ooo_core||macro|trim"
    )
  fi
  # Comma-separated BLOCK_FILTER is optional, matching the PowerShell runner.
  requested_blocks=()
  if [[ -n "${BLOCK_FILTER:-}" ]]; then
    IFS=',' read -r -a requested_blocks <<<"$BLOCK_FILTER"
    for requested in "${requested_blocks[@]}"; do
      found=0
      for spec in "${blocks[@]}"; do
        [[ "${spec%%|*}" != "$requested" ]] || found=1
      done
      if [[ "$found" == "0" ]]; then
        echo "Unknown BLOCK_FILTER entry: $requested" >&2
        exit 2
      fi
    done
  fi
  printf 'block,flow,parameters,memory_model,delay_ps,area_um2_excluding_memories,log\n' \
    >"$build_root/timing_summary.csv"
  for spec in "${blocks[@]}"; do
    IFS='|' read -r name top args flow abc_mode <<<"$spec"
    case "$top" in
      rv_lsq|rv_lsu_cluster|rv_backend|rv_ooo_core) args+=" -G EARLY_LOAD_SELECT=${EARLY_LOAD_SELECT:-1} -G AGU_LOAD_BYPASS=${AGU_LOAD_BYPASS:-0}" ;;
    esac
    if [[ "${COMPATIBLE_PAIR_SELECT:-0}" == "1" ]]; then
      case "$top" in
        rv_issue_queue|rv_backend|rv_ooo_core) args+=" -G COMPATIBLE_PAIR_SELECT=1" ;;
      esac
    fi
    if [[ "${#requested_blocks[@]}" != "0" ]]; then
      selected=0
      for requested in "${requested_blocks[@]}"; do
        [[ "$name" != "$requested" ]] || selected=1
      done
      [[ "$selected" != "0" ]] || continue
    fi
    abc_option=""
    if [[ "$abc_mode" == "trim" ]]; then
      mkdir -p "$build_root/$name"
      cat >"$build_root/$name/abc_trim.scr" <<SCR
strash
&get -n
&dch -f
&nf -D $target_delay_ps
&put
buffer
upsize -D $target_delay_ps
dnsize -D $target_delay_ps
stime -p
SCR
      abc_option="-script $build_root/$name/abc_trim.scr "
    fi
    if [[ "$flow" == "macro" ]]; then
      lowering="proc; flatten; opt -fast; memory_collect; techmap; opt -fast"
    else
      lowering="synth -top $top -flatten -noshare -noabc"
    fi
    command="read_slang --std 1800-2017 --single-unit --ignore-assertions --ignore-initial --top $top $args -f $sources; hierarchy -check -top $top; $lowering; dfflibmap -liberty $liberty; abc ${abc_option}-liberty $liberty -constr $constraint -D $target_delay_ps; clean; read_liberty -lib $liberty; check; stat -liberty $liberty"
    run_yosys "$name" "$command"
    log="$build_root/$name/synth.log"
    delay="$(grep -Eo 'Delay[[:space:]]*=[[:space:]]*[0-9.]+[[:space:]]*ps' "$log" | tail -1 | grep -Eo '[0-9.]+' || true)"
    area="$(grep -Eo "Chip area for module '[^']+':[[:space:]]*[0-9.]+" "$log" | tail -1 | grep -Eo '[0-9.]+$' || true)"
    memory_model="mapped flops"
    [[ "$flow" != "macro" ]] || memory_model="unmapped arrays; read paths omitted"
    printf '%s,%s,%s,%s,%s,%s,%s\n' "$name" "$flow" "$args" "$memory_model" "$delay" "$area" "$log" \
      >>"$build_root/timing_summary.csv"
  done
  echo "Timing summary: $build_root/timing_summary.csv"
fi
