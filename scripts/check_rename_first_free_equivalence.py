#!/usr/bin/env python3
"""Prove exact INT/FP first-free helpers and unchanged remaining Rename RTL.

All bitmap bits are arbitrary binary, including empty/single/multiple-free.
This is a helper/restoration proof, not full sequential/IEEE-X/core/ISA/STA.
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


def extract(text, kind):
    match = re.search(
        r"  function automatic logic \[PHYS_TAG_WIDTH-1:0\] first_free_" + kind + r"\(.*?endfunction",
        text, re.S,
    )
    if not match:
        raise ValueError("Missing actual first-free function: " + kind)
    return match


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--rtl", type=Path, required=True)
    parser.add_argument("--reference", type=Path, required=True)
    parser.add_argument("--out", type=Path, required=True)
    parser.add_argument("--yosys", type=Path, required=True)
    args = parser.parse_args()
    actual_bytes, reference_bytes = args.rtl.read_bytes(), args.reference.read_bytes()
    actual = actual_bytes.decode("utf-8-sig").replace("\r\n", "\n")
    reference = reference_bytes.decode("utf-8-sig").replace("\r\n", "\n")
    restored = actual
    functions, reference_functions = {}, {}
    for kind in ("int", "fp"):
        match, original = extract(actual, kind), extract(reference, kind)
        functions[kind], reference_functions[kind] = match[0], original[0]
        restored_match = extract(restored, kind)
        restored = restored[:restored_match.start()] + original[0] + restored[restored_match.end():]
    if restored != reference:
        raise ValueError("Unproved changes outside the two exact encoder functions")
    out = args.out.absolute()
    if os.name == "nt" and not str(out).isascii():
        parser.error("Use an owned ASCII output alias")
    out.mkdir(parents=True, exist_ok=True)
    env = os.environ.copy()
    env["PATH"] = str(args.yosys.parent) + os.pathsep + str(args.yosys.parent.parent / "lib") + os.pathsep + env.get("PATH", "")
    report = dict(passed=False, candidate_sha256=sha(actual_bytes), reference_sha256=sha(reference_bytes),
        unchanged_remaining_rtl=True, function_sha256={kind:sha(body.encode()) for kind,body in functions.items()},
        cases=[],scope="Exact INT/FP first-free binary helpers, arbitrary full bitmaps, remaining Rename RTL identical; NOT sequential full-module/IEEE-X/core/ISA/STA proof")
    for int_regs, fp_regs, negative in [(32,32,False),(33,48,False),(64,80,False),
                                      (80,80,False),(96,128,False),(128,80,False),(80,80,True)]:
        width = max(1,(max(int_regs,fp_regs)-1).bit_length())
        run = out / f"i{int_regs}_f{fp_regs}_t{width}_negative{int(negative)}"
        run.mkdir(exist_ok=True)
        fp_helper = functions["fp"]
        if negative:
            needle = "return tree[1][PHYS_TAG_WIDTH-1:0];"
            if fp_helper.count(needle) != 1:
                raise ValueError("Missing live FP tag negative target")
            fp_helper = fp_helper.replace(needle,"return tree[1][PHYS_TAG_WIDTH-1:0] ^ PHYS_TAG_WIDTH'(1);")
        ref_int = reference_functions["int"].replace("first_free_int","first_free_int_ref")
        ref_fp = reference_functions["fp"].replace("first_free_fp","first_free_fp_ref")
        fixture = f"""module rename_encoder_miter #(
parameter int INT_PHYS_REGS={int_regs}, FP_PHYS_REGS={fp_regs}, PHYS_TAG_WIDTH={width}
)(input logic [INT_PHYS_REGS-1:0] int_bitmap_i,
input logic [FP_PHYS_REGS-1:0] fp_bitmap_i,output logic equal_o);
{functions['int']}
{fp_helper}
{ref_int}
{ref_fp}
assign equal_o=(first_free_int(int_bitmap_i)==first_free_int_ref(int_bitmap_i)) &&
  (first_free_fp(fp_bitmap_i)==first_free_fp_ref(fp_bitmap_i));
endmodule
"""
        (run / "miter.sv").write_text(fixture,encoding="utf-8")
        (run / "proof.ys").write_text(
            "read_slang --top rename_encoder_miter miter.sv\n"
            "prep -top rename_encoder_miter\nflatten\ntechmap\nopt\n"
            "sat -verify -prove equal_o 1 -timeout 90\n",encoding="utf-8")
        with (run / "proof.log").open("w",encoding="utf-8") as log:
            result = subprocess.run([str(args.yosys),"-Q","-T","-s","proof.ys"],
                cwd=run,env=env,stdout=log,stderr=subprocess.STDOUT,timeout=120)
        transcript = (run / "proof.log").read_text(encoding="utf-8",errors="replace")
        passed = (result.returncode!=0 and "proof did fail" in transcript) if negative else (
            result.returncode==0 and "no model found: SUCCESS!" in transcript)
        report["cases"].append(dict(int_regs=int_regs,fp_regs=fp_regs,tag_width=width,
            negative=negative,passed=passed,native_exit=result.returncode,fixture_sha256=sha(fixture.encode())))
        (out / "report.json").write_text(json.dumps(report,indent=2)+"\n",encoding="utf-8")
        if not passed:
            raise RuntimeError(f"Unexpected encoder proof result: {run}")
        print(f"PASS first-free INT={int_regs} FP={fp_regs} TAG={width} negative={negative}",flush=True)
    report["passed"] = True
    (out / "report.json").write_text(json.dumps(report,indent=2)+"\n",encoding="utf-8")


if __name__ == "__main__":
    main()
