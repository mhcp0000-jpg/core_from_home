#!/usr/bin/env bash
# Timing-analysis netlist for a whole top (not for area/sign-off).
#
# The regular whole-top flow keeps inferred memories as $mem macros, so ABC
# treats their read data as primary inputs: every *variable-address async
# read* (PRF, fetch-queue bytes, predictor tables, load metadata, LSQ ...) is
# silently cut out of the timing.  This script
#   * ties rst_ni inactive (per-entry reset loops otherwise become hundreds
#     of memory write ports and memory_map runs out of memory; the reset mux
#     at each flop D is lost, about one gate),
#   * maps the memories matching INCLUDE and not EXCLUDE to flops + mux trees,
#     ONE memory_map command per memory (a single multi-memory selection
#     exhausted memory in yosys 0.69),
#   * techmaps in a second yosys process, and writes pre_abc.il for
#     scripts/run_open_timing.sh-style ABC (trim script).
#
# usage: scripts/run_analysis_netlist.sh <top> <out_dir> [EXCLUDE_RE] [INCLUDE_RE]
#   e.g. scripts/run_analysis_netlist.sh rv_frontend build/ana_fe
set -euo pipefail
top="$1"; d="$2"; exclude="${3:-^NONE$}"; include="${4:-.}"
lib="${NANGATE_LIB:-/root/tools/lib/NangateOpenCellLibrary_typical.lib}"
repo="$(cd "$(dirname "$0")/.." && pwd)"
mkdir -p "$d"; d="$(cd "$d" && pwd)"
cd "$repo"
common="read_slang --std 1800-2017 --single-unit --ignore-assertions --ignore-initial --top $top -f sim/xcelium/sources_core.f; hierarchy -check -top $top; proc; opt_clean; memory_collect; flatten; delete -port w:rst_ni; connect -set rst_ni 1'1; opt -fast; opt_mem; memory_collect"
yosys -q -p "$common; tee -o $d/mems.txt select -list t:\$mem_v2" > /dev/null 2>&1
{
  echo "read_slang --std 1800-2017 --single-unit --ignore-assertions --ignore-initial --top $top -f sim/xcelium/sources_core.f"
  echo "hierarchy -check -top $top"; echo proc; echo opt_clean; echo memory_collect; echo flatten
  echo "delete -port w:rst_ni"; echo "connect -set rst_ni 1'1"; echo "opt -fast"; echo opt_mem; echo memory_collect
  grep -v "^$" $d/mems.txt | sed "s#^$top/##" | grep -E "$include" | grep -v -E "$exclude" | sed 's/^/memory_map c:/'
  echo "opt -fast"
  echo "write_rtlil $d/stage1.il"
} > $d/stage1.ys
yosys -q -l $d/stage1.log -s $d/stage1.ys > /dev/null 2>&1
yosys -q -l $d/stage2.log -p "read_rtlil $d/stage1.il; techmap; opt -fast; dfflibmap -liberty $lib; write_rtlil $d/pre_abc.il" > /dev/null 2>&1
grep -E "mapped .* cells to" $d/stage2.log | tail -1
echo "memories left as macros: $(grep -c 'cell \$mem_v2' $d/pre_abc.il || true)"
ls -la $d/pre_abc.il
