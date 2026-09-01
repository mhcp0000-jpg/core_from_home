#!/usr/bin/env bash
set -euo pipefail

iterations=2
artifact_root="${TMPDIR:-/tmp}/coremark_rtl"
coremark_root=""
publish_root=""
jobs="$(getconf _NPROCESSORS_ONLN 2>/dev/null || printf '4')"
timeout_cycles=50000000
tool_prefix="${RISCV_TOOL_PREFIX:-riscv-none-elf-}"
commit="1f483d5b8316753a742cbf5590caf5bd0a4e4777"

while (($#)); do
  case "$1" in
    --iterations) iterations="$2"; shift 2 ;;
    --artifact-root) artifact_root="$2"; shift 2 ;;
    --coremark-root) coremark_root="$2"; shift 2 ;;
    --publish-root) publish_root="$2"; shift 2 ;;
    --jobs) jobs="$2"; shift 2 ;;
    --timeout-cycles) timeout_cycles="$2"; shift 2 ;;
    --tool-prefix) tool_prefix="$2"; shift 2 ;;
    *) printf 'Unknown option: %s\n' "$1" >&2; exit 2 ;;
  esac
done

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd -- "${script_dir}/.." && pwd)"
mkdir -p "$artifact_root"
[[ -n "$coremark_root" ]] || coremark_root="${artifact_root}/upstream-coremark"
if [[ ! -f "${coremark_root}/core_main.c" ]]; then
  git clone https://github.com/eembc/coremark.git "$coremark_root"
  git -C "$coremark_root" checkout --detach "$commit"
fi
[[ "$(git -C "$coremark_root" rev-parse HEAD)" == "$commit" ]] || {
  printf 'CoreMark checkout is not pinned to %s\n' "$commit" >&2; exit 2;
}
[[ -z "$(git -C "$coremark_root" status --porcelain)" ]] || {
  printf 'CoreMark checkout has local modifications\n' >&2; exit 2;
}

gcc="${tool_prefix}gcc"
objdump="${tool_prefix}objdump"
readelf="${tool_prefix}readelf"
nm="${tool_prefix}nm"
size_tool="${tool_prefix}size"
for tool in "$gcc" "$objdump" "$readelf" "$nm" "$size_tool"; do
  command -v "$tool" >/dev/null || { printf 'Tool not found: %s\n' "$tool" >&2; exit 2; }
done

elf="${artifact_root}/coremark.elf"
port="${repo_root}/sw/benchmarks/coremark/port"
"$gcc" -march=rv32imc_zicsr_zifencei -mabi=ilp32 -mcmodel=medany \
  -msmall-data-limit=0 -O2 -ffreestanding -fno-builtin -fno-common \
  -fno-asynchronous-unwind-tables -fno-unwind-tables \
  -ffunction-sections -fdata-sections -Wall -Wextra \
  -I "$port" -I "$coremark_root" -DPERFORMANCE_RUN=1 \
  -DITERATIONS="$iterations" -DTOTAL_DATA_SIZE=2000 \
  -DMAIN_HAS_NOARGC=1 -DMEM_METHOD=MEM_STATIC -DMULTITHREAD=1 \
  "${repo_root}/sw/benchmarks/coremark/rv32_start.S" \
  "${port}/core_portme.c" \
  "${coremark_root}/core_list_join.c" "${coremark_root}/core_main.c" \
  "${coremark_root}/core_matrix.c" "${coremark_root}/core_state.c" \
  "${coremark_root}/core_util.c" -nostdlib -nostartfiles -Wl,--gc-sections \
  -Wl,--build-id=none -Wl,-Map,"${artifact_root}/coremark.map" \
  -T "${repo_root}/sw/benchmarks/coremark/rv32_tim.ld" -lgcc -o "$elf"
"$objdump" -d -S "$elf" > "${artifact_root}/coremark.disasm"
"$readelf" -h -l "$elf" > "${artifact_root}/coremark.headers"
"$nm" -n "$elf" > "${artifact_root}/coremark.symbols"

"${script_dir}/run_soc_elf_test.sh" --elf "$elf" \
  --build-root "${artifact_root}/soc_elf_build" --jobs "$jobs" \
  --timeout-cycles "$timeout_cycles" \
  --perf "${artifact_root}/coremark.perf.json" | tee "${artifact_root}/coremark.sim.log"

# The PowerShell runner produces the canonical parsed report.  Linux keeps the
# raw structured HostIF packet easy to inspect without requiring Python/jq.
grep '\[host-event kind=0 data=' "${artifact_root}/coremark.sim.log" \
  > "${artifact_root}/coremark.result.log"
grep -q 'data=0x434d0001' "${artifact_root}/coremark.result.log"
grep -q '\[host-finish code=0\]' "${artifact_root}/coremark.sim.log"
[[ -s "${artifact_root}/coremark.perf.json" ]] || {
  printf 'CoreMark performance profile was not produced\n' >&2; exit 2;
}

if [[ -n "$publish_root" ]]; then
  mkdir -p "$publish_root"
  cp "${artifact_root}"/coremark.{disasm,headers,symbols,sim.log,result.log,perf.json} \
    "$publish_root/"
fi
printf 'CoreMark short RTL run PASS; parse raw HostIF packet in %s\n' \
  "${artifact_root}/coremark.result.log"
