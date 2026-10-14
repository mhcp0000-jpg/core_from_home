#!/usr/bin/env python3
"""Prove the extracted staged-head request gate for arbitrary binary inputs.

This checks pending-head recognition/request suppression, NOT full CSR or
ROB/flush/interrupt/CoreMark/ISA/timing behavior. No sequence-cohort assumption.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess


def sha(data):
    return hashlib.sha256(data).hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--rtl", type=Path, required=True)
    parser.add_argument("--out", type=Path, required=True)
    parser.add_argument("--yosys", type=Path, required=True)
    parser.add_argument("--emit-only", action="store_true", help="Prepare fixtures without executing proof; never reports PASS")
    args = parser.parse_args()
    raw = args.rtl.read_bytes()
    text = raw.decode("utf-8-sig").replace("\r\n", "\n")
    begin = text.index("  assign head_completion_inflight =")
    end = text.index("\n\n  always_comb begin", begin)
    block = text[begin:end]
    if block.count("assign ") != 2 or "assign head_special_request =" not in block:
        raise ValueError("Unexpected actual head gate boundary")
    out = args.out.absolute()
    if os.name == "nt" and not str(out).isascii():
        parser.error("Use an owned ASCII subst alias for output")
    out.mkdir(parents=True, exist_ok=True)
    env = os.environ.copy()
    env["PATH"] = str(args.yosys.parent) + os.pathsep + str(args.yosys.parent.parent / "lib") + os.pathsep + env.get("PATH", "")
    report = dict(passed=False, status="prepared" if args.emit_only else "running",
                  backend_sha256=sha(raw), block_sha256=sha(block.encode()), cases=[],
                  scope="Actual extracted pending-head/request gate, arbitrary binary flags/valids/sequences; no cohort assumption; NOT full CSR/ROB/flush/IRQ/CoreMark/ISA/IEEE-X/STA")
    for width, pipelined, negative in [(1,False,False),(1,True,False),
                                     (8,False,False),(8,True,False),
                                     (16,False,False),(16,True,False),(8,True,True)]:
        run = out / f"s{width}_p{int(pipelined)}_negative{int(negative)}"
        run.mkdir(exist_ok=True)
        implementation = block
        if negative:
            needle = "rob_complete_valid[3]"
            if implementation.count(needle) != 1:
                raise ValueError("Missing live lane3 negative target")
            implementation = implementation.replace(needle, "1'b0")
        fixture = f"""module head_gate_miter #(
parameter int ROB_SEQ_WIDTH={width}, parameter bit ROB_COMPLETION_PIPELINE={int(pipelined)}
)(input logic [3:0] rob_complete_valid,
input logic [3:0][ROB_SEQ_WIDTH-1:0] rob_complete_sequence,
input logic [ROB_SEQ_WIDTH-1:0] rob_head_sequence,
input logic head_is_special_instruction,rob_head_complete,flush_valid,system_redirect_pending_q,
output logic equal_o);
logic head_completion_inflight,head_special_request;
{implementation}
wire [3:0] head_matches;
for (genvar slot=0;slot<4;slot++) begin
  assign head_matches[slot]=rob_complete_valid[slot] && (rob_complete_sequence[slot]==rob_head_sequence);
end
wire pending=ROB_COMPLETION_PIPELINE && (|head_matches);
wire request=head_is_special_instruction && !rob_head_complete && !flush_valid &&
  !system_redirect_pending_q && !pending;
assign equal_o=(head_completion_inflight==pending) && (head_special_request==request);
endmodule
"""
        (run / "miter.sv").write_text(fixture, encoding="utf-8")
        (run / "proof.ys").write_text(
            "read_slang --top head_gate_miter miter.sv\n"
            "prep -top head_gate_miter\nflatten\ntechmap\nopt\n"
            "sat -verify -prove equal_o 1 -timeout 30\n", encoding="utf-8")
        case = dict(sequence_width=width,pipelined=pipelined,negative=negative,
                    passed=False,native_exit=None,fixture_sha256=sha(fixture.encode()))
        if not args.emit_only:
            with (run / "proof.log").open("w", encoding="utf-8") as log:
                result = subprocess.run([str(args.yosys),"-Q","-T","-s","proof.ys"],
                    cwd=run,env=env,stdout=log,stderr=subprocess.STDOUT,timeout=60)
            transcript = (run / "proof.log").read_text(encoding="utf-8", errors="replace")
            case["native_exit"] = result.returncode
            case["passed"] = (result.returncode!=0 and "proof did fail" in transcript) if negative else (
                result.returncode==0 and "no model found: SUCCESS!" in transcript)
        report["cases"].append(case)
        (out / "report.json").write_text(json.dumps(report,indent=2)+"\n",encoding="utf-8")
        if not args.emit_only and not case["passed"]:
            raise RuntimeError(f"Unexpected gate proof result: {run}")
    if not args.emit_only:
        report.update(passed=True,status="passed")
    (out / "report.json").write_text(json.dumps(report,indent=2)+"\n",encoding="utf-8")
    print("PREPARED; proof NOT executed" if args.emit_only else "PASS head request gate and wrong-lane negative")


if __name__ == "__main__":
    main()
