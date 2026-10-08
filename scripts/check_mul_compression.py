"""Arithmetic partitions for a saved, same-latency multiplier candidate.

Exact source product generator at small widths, exact final-adder function at
64/128 bits, and binary signed-row recoding identity at 32/64 bits. These are
NOT an unbounded full 32x32/64x64 multiplier or cycle/ISA/IEEE-X/STA proof.
Native full-width cycle differential tests remain mandatory.
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
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--rtl",type=Path,required=True)
    parser.add_argument("--reference",default="e9d135b")
    parser.add_argument("--yosys",required=True)
    parser.add_argument("--output",type=Path,required=True)
    args=parser.parse_args()
    root=Path(os.path.abspath(__file__)).parent.parent
    source=args.rtl.read_text(encoding="utf-8")
    commit=subprocess.check_output(["git","rev-parse",args.reference+"^{commit}"],cwd=root,text=True).strip()
    reference=subprocess.check_output(["git","show",commit+":rtl/backend/rv_multiplier.sv"],cwd=root,text=True)
    if source[:source.index("  import rv_ooo_pkg::*;")]!=reference[:reference.index("  import rv_ooo_pkg::*;")]:
        raise ValueError("Multiplier interface changed")
    if source[source.index("  assign stage1_advance"): ]!=reference[reference.index("  assign stage1_advance"): ]:
        raise ValueError("State/reset/hold/flush/transport or checks changed")
    request=re.compile(r"typedef struct packed \{[^}]+\} multiply_request_t;",re.S)
    if request.search(source).group()!=request.search(reference).group():
        raise ValueError("Request storage type changed")
    begin=source.index("  function automatic int unsigned csa_rows")
    end=source.index("\n\n  function automatic logic sequence_is_younger",begin)
    product=source[begin:end]
    add=re.search(r"function automatic logic \[PRODUCT_WIDTH-1:0\] product_add\(.*?endfunction",source,re.S).group()
    correction_rhs=re.search(r"assign sign_correction\s*=\s*(.*?);",source,re.S).group(1)
    sum_rhs=re.search(r"assign csa\[level\+1\]\[node\]\s*=\s*([^;]+);",source,re.S).group(1)
    carry_rhs=re.search(r"g_carry\s+assign csa\[level\+1\]\[node\]\s*=\s*([^;]+);",source,re.S).group(1)
    yosys=shutil.which(args.yosys)
    if not yosys: raise ValueError("Missing Yosys")
    output=args.output.absolute()
    if not output.is_relative_to(root): raise ValueError("Output must stay inside workspace")
    output.mkdir(parents=True,exist_ok=True)
    env=os.environ.copy();env["PATH"]=str(Path(yosys).parent.parent/"lib")+os.pathsep+env.get("PATH","")
    report=dict(passed=False,source_sha256=hashlib.sha256(args.rtl.read_bytes()).hexdigest(),reference=commit,
                unchanged_interface_storage_transport=True,cases=[],
                scope="Exact small-width product generator SAT, 64/128-bit final-adder SAT, signed-row correction identity32/64; NOT unbounded full-width multiply/IEEE-X/ISA/STA")
    def prove(name,fixture,negative=False,partitions=None):
        (output/f"{name}.sv").write_text(fixture,encoding="utf-8")
        commands=[]
        for values in (partitions or [None]):
            sets="" if values is None else f" -set signed_a {values[0]} -set signed_b {values[1]}"
            commands.append(f"sat{sets} -verify -prove equal_o 1 -show-inputs")
        cmd=f"read_slang --single-unit --no-implicit-memories --top mul_miter {name}.sv; prep -top mul_miter -flatten; opt; "+"; ".join(commands)
        try:
            with (output/f"{name}.log").open("w",encoding="utf-8") as log:
                result=subprocess.run([yosys,"-Q","-T","-p",cmd],cwd=output,env=env,stdout=log,stderr=subprocess.STDOUT,timeout=120)
        except subprocess.TimeoutExpired:
            report["cases"].append(dict(case=name,passed=False,negative=negative,status="timeout",exit_code=None))
            (output/"report.json").write_text(json.dumps(report,indent=2)+"\n",encoding="utf-8")
            raise SystemExit(f"TIMEOUT/INCOMPLETE {name}")
        contents=(output/f"{name}.log").read_text(encoding="utf-8")
        passed=(result.returncode!=0 and "proof did fail" in contents) if negative else (
            result.returncode==0 and contents.count("no model found: SUCCESS!")==len(commands))
        report["cases"].append(dict(case=name,passed=passed,negative=negative,exit_code=result.returncode))
        (output/"report.json").write_text(json.dumps(report,indent=2)+"\n",encoding="utf-8")
        if not passed: raise SystemExit(f"FAIL/INCOMPLETE {name}")
        print(f"PASS {name}",flush=True)
    for width,negative in [(2,False),(4,False),(6,False),(4,True)]:
        name=f"product_w{width}"+("_negative" if negative else "")
        chosen=product
        if negative:
            chosen=chosen.replace("assign product_shared=product_add(csa[CSA_LEVELS][0],csa[CSA_LEVELS][1]);",
                "assign product_shared=product_add(csa[CSA_LEVELS][0],csa[CSA_LEVELS][1]) ^ PRODUCT_WIDTH'(1);")
        fixture=f"""module mul_miter(input logic [{width-1}:0] a,b,input logic signed_a,signed_b,output logic equal_o);
localparam int XLEN={width},PRODUCT_WIDTH=2*XLEN;
typedef struct packed {{logic [XLEN-1:0] operand_a,operand_b;}} request_t;
request_t stage0_q;
assign stage0_q={{a,b}};
logic [PRODUCT_WIDTH-1:0] product_shared;
{chosen}
logic signed [XLEN:0] ma,mb;
logic signed [PRODUCT_WIDTH+1:0] golden;
assign ma=$signed({{signed_a && a[XLEN-1],a}});
assign mb=$signed({{signed_b && b[XLEN-1],b}});
assign golden=ma*mb;
assign equal_o=(product_shared==golden[PRODUCT_WIDTH-1:0]);
endmodule
"""
        prove(name,fixture,negative,partitions=None if negative else [(0,0),(1,0),(0,1),(1,1)])
    for bits in (64,128):
        fixture=f"""module mul_miter(input logic [{bits-1}:0] a,b,output logic equal_o);
localparam int PRODUCT_WIDTH={bits};
{add}
assign equal_o=product_add(a,b)==(a+b);
endmodule
"""
        prove(f"final_add_b{bits}",fixture)
    def compress_terms(expression):
        for index,name in [(2,"c"),(1,"b"),(0,"a")]:
            expression=expression.replace(f"csa[level][BASE{('+'+str(index)) if index else ''}]",name)
        return expression
    fixture=f"""module mul_miter(input logic ai,bi,ci,output logic equal_o);
logic [1:0] a,b,c,s,carry;
assign a={{1'b0,ai}};assign b={{1'b0,bi}};assign c={{1'b0,ci}};
assign s={compress_terms(sum_rhs)};
assign carry={compress_terms(carry_rhs)};
assign equal_o=(s+carry)==(a+b+c);
endmodule
"""
    prove("exact_compressor_bit",fixture)
    for width in (32,64):
        fixture=f"""module mul_miter(input logic [{width-2}:0] ax,bx,input logic corner,
input logic signed_a,signed_b,output logic equal_o);
localparam int W={width},P=2*W;
logic [P-1:0] row_a,row_b,row_c,ref_a,ref_b,ref_c,correction,encoded,original;
assign row_a=P'(ax)<<(W-1);
assign row_b=P'(bx)<<(W-1);
assign row_c=P'(corner)<<(P-2);
assign ref_a=signed_a ? -row_a : row_a;
assign ref_b=signed_b ? -row_b : row_b;
assign ref_c=(signed_a ^ signed_b) ? -row_c : row_c;
assign correction={correction_rhs.replace('PRODUCT_WIDTH','P').replace('XLEN','W')};
assign encoded=(P'(ax ^ {{(W-1){{signed_a}}}})<<(W-1)) +
               (P'(bx ^ {{(W-1){{signed_b}}}})<<(W-1)) +
               (P'(corner ^ signed_a ^ signed_b)<<(P-2)) + correction;
assign original=ref_a+ref_b+ref_c;
assign equal_o=encoded==original;
endmodule
"""
        prove(f"sign_recoding_w{width}",fixture,partitions=[(0,0),(1,0),(0,1),(1,1)])
    report["passed"]=True
    (output/"report.json").write_text(json.dumps(report,indent=2)+"\n",encoding="utf-8")


if __name__=="__main__": main()
