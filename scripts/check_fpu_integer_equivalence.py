#!/usr/bin/env python3
"""Prove actual FP-to-integer helpers against immutable RTL (two-state SAT).

Generated sources/reports belong below ignored out/. This checks result and
flags, not the pipeline or an independent IEEE/ISA specification.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess


HELPERS = ("fp_is_nan", "fp_is_inf", "fp_mantissa", "fp_lsb_exponent",
           "fp_lsb_exponent_n", "round_up", "fp_to_integer")


def extract(source, name):
    matches = [body for body in re.findall(
        r"function\s+automatic\b[\s\S]*?endfunction", source)
        if re.search(r"\b" + name + r"\s*\(", body.split(";", 1)[0])]
    if len(matches) != 1:
        raise ValueError(f"Expected exactly one RTL helper {name}, got {len(matches)}")
    return matches[0]


def wrapper(name, source, width):
    exponent_width = re.search(r"localparam\s+int\s+unsigned\s+EXPW\s*=\s*(\d+)\s*;", source)
    if not exponent_width:
        raise ValueError("Missing actual EXPW constant")
    flags = re.findall(r"localparam\s+logic\s*\[4:0\]\s+FFLAG_(?:NX|NV)\s*=\s*[^;]+;", source)
    calculation_type = re.search(
        r"typedef\s+struct\s+packed\s*\{\s*logic\s*\[XLEN-1:0\]\s*data;"
        r"\s*logic\s*\[4:0\]\s*flags;\s*\}\s*fp_calc_t;", source)
    if len(flags) != 2 or calculation_type is None:
        raise ValueError("Actual flag constants/fp_calc_t layout not supported; update proof explicitly")
    helpers = "\n".join(extract(source, helper) for helper in HELPERS)
    return f"""
module {name}(input logic [31:0] a_i, input logic [1:0] kind_i,
              input logic [2:0] rm_i, output logic [{width+4}:0] result_o);
  localparam int XLEN={width}, EXPW={int(exponent_width.group(1))};
  {chr(10).join(flags)}
  {calculation_type.group(0)}
  {helpers}
  assign result_o=fp_to_integer(a_i,kind_i,rm_i);
endmodule
"""


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--yosys", default="yosys")
    parser.add_argument("--reference", default="2b17093")
    parser.add_argument("--width", type=int, choices=(32, 64), default=32)
    parser.add_argument("--kind", type=int, choices=range(4), default=None,
                        help="Optional destination-kind partition; otherwise all kinds")
    parser.add_argument("--timeout", type=int, default=180)
    parser.add_argument("--output", type=Path, default=Path("out/fpu_integer_equivalence"))
    args = parser.parse_args()
    if args.timeout < 1:
        parser.error("timeout must be positive")
    root = Path(os.path.abspath(__file__)).parent.parent
    yosys = shutil.which(args.yosys)
    if not yosys:
        raise SystemExit(f"Yosys not found: {args.yosys}")
    yosys = str(Path(yosys).absolute())
    commit = subprocess.check_output(["git", "rev-parse", "--verify", args.reference+"^{commit}"],
                                     cwd=root, text=True).strip()
    reference = subprocess.check_output(["git", "show", commit+":rtl/backend/rv_fpu.sv"],
                                        cwd=root, text=True, encoding="utf-8")
    source = (root/"rtl/backend/rv_fpu.sv").read_text(encoding="utf-8")
    output = args.output.absolute()
    output.mkdir(parents=True, exist_ok=True)
    fixture = wrapper("fcvt_current", source, args.width) + wrapper("fcvt_reference", reference, args.width)
    fixture += f"""
module fcvt_miter(input logic [31:0] a_i, input logic [1:0] kind_i,
                  input logic [2:0] rm_i, output logic equal_o);
  logic [{args.width+4}:0] current_result, reference_result;
  fcvt_current current_i(a_i,kind_i,rm_i,current_result);
  fcvt_reference reference_i(a_i,kind_i,rm_i,reference_result);
  assign equal_o=(current_result==reference_result);
endmodule
"""
    (output/"miter.sv").write_text(fixture, encoding="utf-8")
    partition = "" if args.kind is None else f" -set kind_i {args.kind}"
    command = ("read_slang --top fcvt_miter miter.sv; prep -top fcvt_miter -flatten; "
               f"sat -prove equal_o 1 -verify -show-inputs{partition}")
    report = dict(passed=False, status="running", width=args.width, kind=args.kind,
                  reference_commit=commit, command=command,
                  rtl_sha256=hashlib.sha256((root/"rtl/backend/rv_fpu.sv").read_bytes()).hexdigest(),
                  fixture_sha256=hashlib.sha256(fixture.encode()).hexdigest(),
                  scope="Actual helper result/flags, all FP32 bits and RM0..7, two-state; not pipeline/ISA proof")
    (output/"report.json").write_text(json.dumps(report, indent=2)+"\n", encoding="utf-8")
    (output/"proof.log").write_text("", encoding="utf-8")
    environment = os.environ.copy()
    runtime = Path(yosys).parent.parent/"lib"
    if os.name == "nt" and runtime.is_dir():
        environment["PATH"] = str(runtime)+os.pathsep+environment.get("PATH", "")
    try:
        with (output/"console.log").open("w", encoding="utf-8") as log:
            completed = subprocess.run([yosys, "-Q", "-T", "-l", "proof.log", "-p", command],
                                       cwd=output, env=environment, stdout=log,
                                       stderr=subprocess.STDOUT, timeout=args.timeout)
        proof = (output/"proof.log").read_text(encoding="utf-8")
        report["passed"] = completed.returncode == 0 and "no model found: SUCCESS!" in proof
        report["yosys_exit_code"] = completed.returncode
        report["status"] = "passed" if report["passed"] else "failed"
    except subprocess.TimeoutExpired:
        report["status"] = "timeout"
    finally:
        (output/"report.json").write_text(json.dumps(report, indent=2)+"\n", encoding="utf-8")
    if not report["passed"]:
        raise SystemExit(f"{report['status'].upper()}: inspect {output}")
    print(f"PASS: actual FP-to-integer helpers XLEN={args.width}, kind={args.kind}, all FP32 bits/RM")


if __name__ == "__main__":
    main()
