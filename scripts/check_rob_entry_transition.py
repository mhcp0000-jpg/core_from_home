"""Prove an exact saved ROB per-entry update against a frozen source.

Every original entry state bit and external control/payload is arbitrary.
The selected row number is also arbitrary: each constant-row comparison is
abstracted to the same row input in both wrappers. Remaining RTL and entry
type must be text-identical. Binary next-state SAT, not ISA or IEEE-X proof.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess


def extract(source):
    begin = source.index("  for (genvar entry = 0; entry < ROB_ENTRIES; entry++) begin : g_entry_storage")
    end = source.index("  assign count_o", begin)
    return source[begin:end], source[:begin] + source[end:]


def wrapper(source, name, width, rows, ports):
    entry = re.search(r"typedef struct packed \{.*?\} rob_entry_t;", source, re.S).group()
    after = re.search(r"function automatic logic sequence_after\(.*?endfunction", source, re.S).group()
    header = source.split(") (", 1)[1].split(");", 1)[0]
    header = re.sub(r"//[^\n]*", "", header)
    inputs = []
    for declaration in header.split(","):
        if declaration.strip().startswith("input"):
            inputs.append(" ".join(declaration.split()))
    inputs.extend([
        "input logic flush_boundary_found",
        "input logic [ROB_INDEX_WIDTH-1:0] head_q, head_plus_one, row_index_i",
        "input logic [1:0] retire_fire, accepted_alloc_count",
        "input logic [1:0][ROB_INDEX_WIDTH-1:0] alloc_index_o",
        "input logic [1:0][SEQ_WIDTH-1:0] alloc_sequence_o",
        "input logic [$bits(rob_entry_t)-1:0] state_i",
        "output rob_entry_t next_entry",
    ])
    block, _ = extract(source)
    block = block.replace("for (genvar entry = 0; entry < ROB_ENTRIES; entry++)", "if (1)")
    block = block.replace("ROB_INDEX_WIDTH'(entry)", "row_index_i")
    block = re.sub(r"entries_q\[entry\](\.\w+)?\s*<=",
                   lambda match: "next_entry" + (match[1] or "") + " =", block)
    block = block.replace("entries_q[entry]", "entry_state")
    block = block.replace("always_ff @(posedge clk_i) begin",
                          "always_comb begin\n      next_entry = entry_state;")
    if "entries_q" in block or "<=" in block or "genvar entry" in block:
        raise ValueError("Unsupported entry update syntax")
    return f"""module {name} #(
parameter int XLEN={width}, ROB_ENTRIES={rows}, SEQ_WIDTH=8,
PHYS_TAG_WIDTH=7, LQ_INDEX_WIDTH=5, SQ_INDEX_WIDTH=4,
COMPLETE_PORTS={ports}, LIVE_QUERY_PORTS=8,
ROB_INDEX_WIDTH=$clog2(ROB_ENTRIES), ROB_COUNT_WIDTH=$clog2(ROB_ENTRIES+1),
parameter type rob_entry_t=types_{name}::rob_entry_t
) ({','.join(inputs)});
import rv_ooo_pkg::*;
rob_entry_t entry_state;
assign entry_state = state_i;
{after}
{block}
endmodule
""", f"""package types_{name};
import rv_ooo_pkg::*;
localparam int XLEN={width},SEQ_WIDTH=8,PHYS_TAG_WIDTH=7,LQ_INDEX_WIDTH=5,SQ_INDEX_WIDTH=4;
{entry}
endpackage
"""


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--rtl", type=Path, required=True)
    parser.add_argument("--reference", type=Path, required=True)
    parser.add_argument("--yosys", required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    root = Path(os.path.abspath(__file__)).parent.parent
    source = args.rtl.read_text(encoding="utf-8")
    reference = args.reference.read_text(encoding="utf-8")
    if extract(source)[1] != extract(reference)[1]:
        raise ValueError("Unexpected delta outside the per-entry update block")
    yosys = shutil.which(args.yosys)
    if not yosys:
        raise ValueError("Yosys missing")
    output = args.output.absolute()
    if not output.is_relative_to(root):
        raise ValueError("Output must be below workspace")
    output.mkdir(parents=True, exist_ok=True)
    (output / "pkg.sv").write_text((root / "rtl/rv_ooo_pkg.sv").read_text(encoding="utf-8"), encoding="utf-8")
    env = os.environ.copy()
    env["PATH"] = str(Path(yosys).parent.parent / "lib") + os.pathsep + env.get("PATH", "")
    report = dict(passed=False, rtl_sha256=hashlib.sha256(args.rtl.read_bytes()).hexdigest(),
                  reference_sha256=hashlib.sha256(args.reference.read_bytes()).hexdigest(),
                  remaining_rtl_identical=True, cases=[],
                  scope="Exact per-entry binary next-state, arbitrary original state/controls/payload/row; NOT independent ISA, IEEE-X, sequential full-core or STA proof")
    for width, rows, ports, negative in [(32,48,4,False),(64,7,4,False),(32,48,1,False),(64,7,8,False),(32,48,4,True)]:
        case = f"w{width}_r{rows}_p{ports}" + ("_negative" if negative else "")
        fixture_source = source
        if negative:
            needle = "entries_q[entry].exception_tval <= exception_tree[1][XLEN-1:0];"
            if needle not in source:
                raise ValueError("Missing negative control target")
            fixture_source = source.replace(needle, "entries_q[entry].exception_tval <= exception_tree[1][XLEN-1:0] ^ XLEN'(1);")
        dut, dut_types = wrapper(fixture_source, "rob_entry_dut", width, rows, ports)
        ref, ref_types = wrapper(reference, "rob_entry_ref", width, rows, ports)
        (output / f"{case}.sv").write_text(dut_types+ref_types+dut+ref, encoding="utf-8")
        command = (f"read_slang --single-unit --no-implicit-memories pkg.sv {case}.sv; proc; opt -fast; "
                   "equiv_make rob_entry_ref rob_entry_dut entry_equiv; hierarchy -top entry_equiv; opt_clean; "
                   "equiv_simple; equiv_status -assert")
        with (output / f"{case}.log").open("w", encoding="utf-8") as log:
            result = subprocess.run([yosys,"-Q","-T","-p",command], cwd=output, env=env,
                                    stdout=log, stderr=subprocess.STDOUT, timeout=300)
        contents = (output / f"{case}.log").read_text(encoding="utf-8")
        passed = (result.returncode != 0 and "unproven $equiv" in contents) if negative else (
            result.returncode == 0 and "Equivalence successfully proven!" in contents)
        report["cases"].append(dict(case=case, negative=negative, passed=passed, exit_code=result.returncode))
        (output / "report.json").write_text(json.dumps(report, indent=2)+"\n",encoding="utf-8")
        if not passed:
            raise SystemExit(f"FAIL/INCOMPLETE {case}")
        print(f"PASS {case}", flush=True)
    report["passed"] = True
    (output / "report.json").write_text(json.dumps(report, indent=2)+"\n",encoding="utf-8")


if __name__ == "__main__":
    main()
