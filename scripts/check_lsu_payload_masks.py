#!/usr/bin/env python3
"""Prove actual AGU depth2 payload D updates match original priority RTL.

All payload bits/reset/queue controls, including invalid-state combinations,
are arbitrary binary. Output data when invalid is preserved too. The valid
FSM, depth1, address/mask arithmetic and all remaining RTL must be unchanged.
Not IEEE-X/full core/ISA/timing signoff.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess


def sha(data):
    return hashlib.sha256(data).hexdigest()


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--rtl",type=Path,required=True)
    parser.add_argument("--reference",type=Path,required=True)
    parser.add_argument("--package",type=Path,required=True)
    parser.add_argument("--out",type=Path,required=True)
    parser.add_argument("--yosys",type=Path,required=True)
    args=parser.parse_args()
    raw,oldraw=args.rtl.read_bytes(),args.reference.read_bytes()
    current=raw.decode("utf-8-sig").replace("\r\n","\n")
    original=oldraw.decode("utf-8-sig").replace("\r\n","\n")
    origin_begin=original.index("    always_ff @(posedge clk_i) begin",original.index("    assign keep1 ="))
    origin_end=original.index("    assign update_valid_o",origin_begin)
    old_block=original[origin_begin:origin_end]
    begin=current.index("    // Preserve the exact queue/control priority")
    end=current.index("    assign update_valid_o",begin)
    changed=current[begin:end]
    select_begin=changed.index("    always_comb begin")
    data_begin=changed.index("    always_ff @(posedge clk_i) begin")
    valid_begin=changed.index("    always_ff @(posedge clk_i) begin",data_begin+1)
    selects=changed[select_begin:data_begin]
    data_block=changed[data_begin:valid_begin]
    valid_block=changed[valid_begin:]
    expected_valid_block=re.sub(r"^.*(?:head_q|tail_q) <=.*;\n", "",old_block,flags=re.M)
    if valid_block!=expected_valid_block:
        raise ValueError("Unproved valid FSM or queue-priority change")
    restored=current[:begin]+old_block+current[end:]
    additions=("    logic head_from_issue, head_from_tail, tail_from_issue;\n"
               "    localparam int unsigned PAYLOAD_BITS = $bits(update_payload_t);\n")
    if restored.count(additions)!=1:
        raise ValueError("Unexpected payload mask declarations")
    restored=restored.replace(additions,"",1)
    if restored!=original:
        raise ValueError("Unproved changes outside depth2 payload update")
    type_begin=original.index("  typedef struct packed {")
    type_end=original.index("  } update_payload_t;",type_begin)+len("  } update_payload_t;")
    payload_type=original[type_begin:type_end]
    ref=re.sub(r"^\s*(?:update_valid_q|valid1_q) <=.*;\n", "",old_block,flags=re.M)
    ref=ref.replace("always_ff @(posedge clk_i) begin","always_comb begin\n      reference_head=head_q; reference_tail=tail_q;",1)
    ref=ref.replace("head_q <=","reference_head =").replace("tail_q <=","reference_tail =")
    candidate=data_block.replace("always_ff @(posedge clk_i) begin","always_comb begin",1)
    candidate=candidate.replace("head_q <=","candidate_head =").replace("tail_q <=","candidate_tail =")
    out=args.out.absolute();out.mkdir(parents=True,exist_ok=True)
    if os.name=="nt" and not str(out).isascii(): parser.error("Use an owned ASCII alias")
    env=os.environ.copy();env["PATH"]=str(args.yosys.parent)+os.pathsep+str(args.yosys.parent.parent/"lib")+os.pathsep+env.get("PATH","")
    report=dict(passed=False,candidate_sha256=sha(raw),reference_sha256=sha(oldraw),
      unchanged_remaining_rtl=True,unchanged_valid_fsm=True,cases=[],
      scope="Actual depth2 packed payload next-state, arbitrary binary reset/control/data including invalid outputs; unchanged valid FSM/depth1/arithmetic/rest; NOT IEEE-X/fullcore/ISA/STA")
    for xlen,paddr,mem,negative in [(32,32,64,False),(32,32,32,False),(64,56,64,False),
                                  (64,56,128,False),(64,64,256,False),(32,32,64,True)]:
        run=out/f"x{xlen}_p{paddr}_m{mem}_negative{int(negative)}";run.mkdir(exist_ok=True)
        actual=candidate
        if negative:
            needle="(tail_q & {PAYLOAD_BITS{head_from_tail}})"
            if actual.count(needle)!=1: raise ValueError("Missing live tail-transfer negative target")
            actual=actual.replace(needle,"(issue_payload & {PAYLOAD_BITS{head_from_tail}})",1)
        # Non-ANSI ports permit the exact body-local packed typedef. Inputs
        # remain arbitrary SAT variables; equal_o must be a kept output.
        emitted=f"""module lsu_payload_miter(rst_ni,flush_valid_i,update_valid_q,push,pop,
keep0,keep1,head_q,tail_q,issue_payload,equal_o);
import rv_ooo_pkg::*;
localparam int XLEN={xlen}, PADDR_WIDTH={paddr}, MEM_DATA_WIDTH={mem},
MEM_BYTES=MEM_DATA_WIDTH/8, ROB_SEQ_WIDTH=8, LQ_INDEX_WIDTH=5, SQ_INDEX_WIDTH=4;
{payload_type}
localparam int PAYLOAD_BITS=$bits(update_payload_t);
input logic rst_ni,flush_valid_i,update_valid_q,push,pop,keep0,keep1;
input update_payload_t head_q,tail_q,issue_payload;
update_payload_t reference_head,reference_tail,candidate_head,candidate_tail;
logic head_from_issue,head_from_tail,tail_from_issue;
output wire equal_o;
assign equal_o=(reference_head==candidate_head) && (reference_tail==candidate_tail);
{ref}
{selects}
{actual}
endmodule
"""
        (run/"package.sv").write_bytes(args.package.read_bytes())
        (run/"miter.sv").write_text(emitted,encoding="utf-8")
        (run/"proof.ys").write_text("read_slang --top lsu_payload_miter package.sv miter.sv\n"
          "prep -top lsu_payload_miter\nflatten\ntechmap\nopt\nsat -verify -prove equal_o 1 -timeout 90\n",encoding="utf-8")
        with (run/"proof.log").open("w",encoding="utf-8") as log:
            result=subprocess.run([str(args.yosys),"-Q","-T","-s","proof.ys"],cwd=run,env=env,
              stdout=log,stderr=subprocess.STDOUT,timeout=120)
        transcript=(run/"proof.log").read_text(encoding="utf-8",errors="replace")
        passed=(result.returncode!=0 and "proof did fail" in transcript) if negative else (
          result.returncode==0 and "no model found: SUCCESS!" in transcript)
        report["cases"].append(dict(xlen=xlen,paddr=paddr,mem_width=mem,negative=negative,
          passed=passed,native_exit=result.returncode,fixture_sha256=sha(emitted.encode())))
        (out/"report.json").write_text(json.dumps(report,indent=2)+"\n",encoding="utf-8")
        if not passed: raise RuntimeError(f"Unexpected payload proof: {run}")
        print(f"PASS payload D XLEN={xlen} PADDR={paddr} MEM={mem} negative={negative}",flush=True)
    report["passed"]=True;(out/"report.json").write_text(json.dumps(report,indent=2)+"\n",encoding="utf-8")


if __name__=="__main__": main()
