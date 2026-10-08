"""Check the exact PMP region decoder without the access/comparator cone.

All cfg bits, encoded address and TOR predecessor address are arbitrary.
Lookup/interface/parameter checks must remain byte-identical to the immutable
reference. Thus only the saved decoder is partitioned, not PMP permissions.
Binary SAT and mandatory wrong-upper-bound negative control; not IEEE-X/ISA.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess


def split(source):
    begin = source.index("  logic [7:0] entry_cfg_decoded")
    end = source.index("  // All regions and accesses retain exclusive high bounds.", begin)
    return source[begin:end], source[:begin]+source[end:]


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--rtl",type=Path,required=True)
    parser.add_argument("--reference",default="e9d135b")
    parser.add_argument("--yosys",required=True)
    parser.add_argument("--output",type=Path,required=True)
    args=parser.parse_args()
    root=Path(os.path.abspath(__file__)).parent.parent
    candidate=args.rtl.read_text(encoding="utf-8")
    commit=subprocess.check_output(["git","rev-parse",args.reference+"^{commit}"],cwd=root,text=True).strip()
    reference=subprocess.check_output(["git","show",commit+":rtl/backend/rv_pmp.sv"],cwd=root,text=True)
    decoder,remaining=split(candidate)
    golden,original_remaining=split(reference)
    if remaining!=original_remaining:
        raise ValueError("Unexpected change outside region decoder")
    yosys=shutil.which(args.yosys)
    if not yosys: raise ValueError("Missing Yosys")
    output=args.output.absolute()
    if not output.is_relative_to(root): raise ValueError("Output must stay below workspace")
    output.mkdir(parents=True,exist_ok=True)
    env=os.environ.copy()
    env["PATH"]=str(Path(yosys).parent.parent/"lib")+os.pathsep+env.get("PATH","")
    report=dict(passed=False,reference=commit,source_sha256=hashlib.sha256(args.rtl.read_bytes()).hexdigest(),
                unchanged_remaining_rtl=True,cases=[],
                scope="Exact region decoder, all binary cfg/address/TOR predecessor; lookup and interface unchanged; NOT IEEE-X/independent ISA/STA")
    for width,negative in [(4,False),(8,False),(16,False),(32,False),(56,False),(64,False),(32,True)]:
        case=f"a{width}"+("_negative" if negative else "")
        chosen=decoder
        if negative:
            needle="region_high_decoded[entry] = {napot_high_encoded[entry], 2'b00};"
            if needle not in chosen: raise ValueError("Negative target missing")
            chosen=chosen.replace(needle,"region_high_decoded[entry] = {napot_high_encoded[entry], 2'b00} ^ (PADDR_WIDTH+1)'(4);")
        def module(name,body):
            return f"""module {name} #(parameter int PADDR_WIDTH={width},PMP_ENTRIES=2,PMP_ADDR_WIDTH=PADDR_WIDTH-2)(
input logic [15:0] pmpcfg_i,
input logic [2*PMP_ADDR_WIDTH-1:0] pmpaddr_i,
output logic [PADDR_WIDTH:0] low_o,high_o);
{body}
assign low_o=region_low_decoded[1];
assign high_o=region_high_decoded[1];
endmodule
"""
        fixture=module("decode_dut",chosen)+module("decode_ref",golden)+f"""module decode_miter(
input logic [15:0] cfg,
input logic [{2*(width-2)-1}:0] addr,
output logic equal_o);
logic [{width}:0] low_d,high_d,low_r,high_r;
decode_dut dut(cfg,addr,low_d,high_d);
decode_ref ref_i(cfg,addr,low_r,high_r);
assign equal_o={{low_d,high_d}}=={{low_r,high_r}};
endmodule
"""
        (output/f"{case}.sv").write_text(fixture,encoding="utf-8")
        cmd=f"read_slang --single-unit --no-implicit-memories --top decode_miter {case}.sv; prep -top decode_miter -flatten; opt; sat -verify -prove equal_o 1 -show-inputs"
        with (output/f"{case}.log").open("w",encoding="utf-8") as log:
            result=subprocess.run([yosys,"-Q","-T","-p",cmd],cwd=output,env=env,stdout=log,stderr=subprocess.STDOUT,timeout=120)
        contents=(output/f"{case}.log").read_text(encoding="utf-8")
        passed=(result.returncode!=0 and "proof did fail" in contents) if negative else (result.returncode==0 and "SUCCESS!" in contents)
        report["cases"].append(dict(case=case,negative=negative,passed=passed,exit_code=result.returncode))
        (output/"report.json").write_text(json.dumps(report,indent=2)+"\n",encoding="utf-8")
        if not passed: raise SystemExit(f"FAIL/INCOMPLETE {case}")
        print(f"PASS {case}",flush=True)
    report["passed"]=True
    (output/"report.json").write_text(json.dumps(report,indent=2)+"\n",encoding="utf-8")


if __name__=="__main__": main()
