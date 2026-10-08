"""Check a saved ROB decoded-head read against the native array selection.

Exact candidate generate block and exact packed entry type, arbitrary binary
stored bits and indices, undef-aware out-of-range equality. This checks only
read selection, not ROB sequential transitions, ISA, or timing.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--rtl", type=Path, required=True)
    parser.add_argument("--reference", default="e9d135b")
    parser.add_argument("--yosys", required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    root = Path(os.path.abspath(__file__)).parent.parent
    source = args.rtl.read_text(encoding="utf-8")
    commit = subprocess.check_output(["git", "rev-parse", args.reference+"^{commit}"], cwd=root, text=True).strip()
    reference = subprocess.check_output(["git", "show", commit+":rtl/backend/rv_rob.sv"], cwd=root, text=True, encoding="utf-8")
    entry_pattern = r"typedef struct packed \{.*?\} rob_entry_t;"
    entry = re.search(entry_pattern, source, re.S).group()
    if entry != re.search(entry_pattern, reference, re.S).group():
        raise ValueError("Entry type changed; revise the proof")
    start = source.index("  localparam int unsigned HEAD_READ_LEAVES")
    end = source.index("  function automatic logic", start)
    read_block = source[start:end]
    restored = source[:start]+source[end:]
    restored = restored.replace("head_read[0]", "entries_q[head_q]").replace("head_read[1]", "entries_q[head_plus_one]")
    restored = restored.replace("  assign head_plus_one = increment_index(head_q, 1);\n  always_comb begin", "  always_comb begin\n    head_plus_one = increment_index(head_q, 1);")
    # The read block and equivalent head-plus-one assignment are the ONLY
    # changes accepted. This enforces unchanged storage, reset and policies.
    if re.sub(r"\s+", " ", restored).strip() != re.sub(r"\s+", " ", reference).strip():
        raise ValueError("Unexpected RTL delta outside the head-read rewrite")
    yosys = shutil.which(args.yosys)
    if not yosys:
        raise SystemExit("Yosys missing")
    output = args.output.absolute()
    if os.name == "nt" and not str(output).isascii():
        raise SystemExit("Run through an ASCII subst drive")
    output.mkdir(parents=True, exist_ok=True)
    (output/"pkg.sv").write_text((root/"rtl/rv_ooo_pkg.sv").read_text(encoding="utf-8"), encoding="utf-8")
    environment = os.environ.copy()
    environment["PATH"] = str(Path(yosys).parent.parent/"lib")+os.pathsep+environment.get("PATH", "")
    report = dict(passed=False, reference=commit, rtl_sha256=hashlib.sha256(args.rtl.read_bytes()).hexdigest(),
                  unchanged_remaining_rtl=True, scope="Exact two-head read and entry type, arbitrary binary stored bits/indices, undef-aware; NOT sequential ROB/ISA/STA proof", cases=[])
    for width, rows, negative in [(32,48,False),(64,7,False),(32,7,True)]:
        name = f"w{width}_r{rows}"+("_negative" if negative else "")
        fixture = f"""package read_types;
import rv_ooo_pkg::*;
localparam int XLEN={width},SEQ_WIDTH=8,PHYS_TAG_WIDTH=7,LQ_INDEX_WIDTH=5,SQ_INDEX_WIDTH=4;
{entry}
endpackage
module read_miter #(parameter int ROB_ENTRIES={rows},ROB_INDEX_WIDTH=$clog2(ROB_ENTRIES))(
 input logic [ROB_ENTRIES-1:0][$bits(read_types::rob_entry_t)-1:0] state_i,
 input logic [ROB_INDEX_WIDTH-1:0] head_q, head_plus_one,
 output logic equal_o);
typedef read_types::rob_entry_t rob_entry_t;
rob_entry_t entries_q [0:ROB_ENTRIES-1];
for(genvar row=0;row<ROB_ENTRIES;row++) assign entries_q[row]=state_i[row];
{read_block}
assign equal_o=((head_read[0]{" ^ ENTRY_BITS'(1)" if negative else ""}) === entries_q[head_q]) &&
               (head_read[1] === entries_q[head_plus_one]);
endmodule
"""
        (output/f"{name}.sv").write_text(fixture, encoding="utf-8")
        command = (f"read_slang --single-unit --ignore-assertions --no-implicit-memories --top read_miter pkg.sv {name}.sv; "
                   "prep -top read_miter -flatten; opt; sat -enable_undef -set-def-inputs -verify -prove equal_o 1")
        with (output/f"{name}.log").open("w", encoding="utf-8") as log:
            result = subprocess.run([yosys,"-Q","-T","-p",command],cwd=output,env=environment,stdout=log,stderr=subprocess.STDOUT)
        log = (output/f"{name}.log").read_text(encoding="utf-8")
        passed = result.returncode != 0 and "proof did fail" in log if negative else result.returncode == 0 and "SUCCESS!" in log
        report["cases"].append(dict(name=name,passed=passed,negative=negative,exit_code=result.returncode))
        (output/"report.json").write_text(json.dumps(report,indent=2)+"\n",encoding="utf-8")
        if not passed:
            raise SystemExit(f"FAIL/INCOMPLETE {name}")
        print(f"PASS {name}",flush=True)
    report["passed"] = True
    (output/"report.json").write_text(json.dumps(report,indent=2)+"\n",encoding="utf-8")


if __name__ == "__main__":
    main()
