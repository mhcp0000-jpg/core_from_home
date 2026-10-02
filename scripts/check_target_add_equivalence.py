#!/usr/bin/env python3
"""Check the actual target_add functions: all two-state inputs plus X/Z probes.

This checks arithmetic helpers, not instruction decoding or whole-module state.
Artifacts are frozen before proof and contain the actual source/helper hashes.
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
    pattern = r"function automatic logic \[XLEN-1:0\] target_add\([\s\S]*?endfunction"
    functions = re.findall(pattern, source)
    if len(functions) != 1:
        raise ValueError("Expected exactly one target_add function")
    return functions[0]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--rtl", default="rtl/frontend/rv_branch_predictor.sv")
    parser.add_argument("--baseline", default="081e714")
    parser.add_argument("--reference-module",
                        choices=("rtl/frontend/rv_branch_predictor.sv", "rtl/backend/rv_branch_unit.sv"),
                        default="rtl/frontend/rv_branch_predictor.sv")
    parser.add_argument("--xlen", type=int, choices=(32, 64), default=32)
    parser.add_argument("--out", type=Path, required=True)
    parser.add_argument("--yosys", type=Path)
    parser.add_argument("--iverilog", type=Path)
    parser.add_argument("--vvp", type=Path)
    parser.add_argument("--timeout", type=int, default=120)
    args = parser.parse_args()
    if args.timeout <= 0:
        parser.error("timeout must be positive")
    repo = Path(__file__).resolve().parent.parent
    source_path = Path(args.rtl)
    if not source_path.is_absolute():
        source_path = repo / source_path
    # Explicit reference identity: archived candidates need not retain their module filename.
    reference_path = args.reference_module
    candidate_bytes = source_path.read_bytes()
    reference_bytes = subprocess.check_output(
        ["git", "show", f"{args.baseline}:{reference_path}"], cwd=repo)
    reference_commit = subprocess.check_output(
        ["git", "rev-parse", args.baseline], cwd=repo, text=True).strip()
    candidate = extract(candidate_bytes.decode("utf-8-sig"))
    reference = extract(reference_bytes.decode("utf-8-sig"))
    reference = reference.replace("target_add", "target_add_ref")
    fixture = f"""module target_add_miter #(parameter int XLEN={args.xlen})(
 input logic [XLEN-1:0] lhs,rhs,
 output logic [XLEN-1:0] candidate_o,reference_o,native_o,
 output logic equal_o);
{candidate}
{reference}
assign candidate_o=target_add(lhs,rhs);
assign reference_o=target_add_ref(lhs,rhs);
assign native_o=lhs+rhs;
assign equal_o=(candidate_o==reference_o) && (candidate_o==native_o);
endmodule
"""
    testbench = f"""module target_add_fourstate_tb;
 localparam int XLEN={args.xlen};
 logic [XLEN-1:0] lhs,rhs,candidate_o,reference_o,native_o;
 logic equal_o;
 target_add_miter #(.XLEN(XLEN)) dut(.*);
 initial begin
   for(int trial=0;trial<8192;trial++) begin
     lhs={{$urandom,$urandom}};rhs={{$urandom,$urandom}};
     case(trial%12)
       0: lhs='x;
       1: rhs='z;
       2: lhs[trial%XLEN]=1'bx;
       3: rhs[trial%XLEN]=1'bz;
       4: begin lhs='1;rhs=1;end
       5: begin lhs='0;rhs='0;end
       6: begin lhs='1;rhs='0;end
       7: begin lhs='1;rhs[0]=1'bx;end
       8: begin lhs='0;rhs[XLEN-1]=1'bx;end
       9: begin lhs=XLEN'(64'hfffffffffffffffe);rhs=3;end
       10: begin lhs=XLEN'(64'h7777777777777777);rhs=XLEN'(64'h8888888888888889);end
       11: begin lhs=XLEN'(64'h0fff0fff0fff0fff);rhs=XLEN'(64'h0001000100010001);end
     endcase
     #1;
     // Native addition's X granularity can differ; preserve the original helper.
     if(candidate_o !== reference_o) $fatal(1,"target_add X/Z mismatch trial=%0d",trial);
   end
   $display("Actual target_add four-state PASS XLEN=%0d vectors=8192",XLEN);
   $finish;
 end
endmodule
"""
    out = args.out.absolute()
    if os.name == "nt" and not str(out).isascii():
        parser.error("Use an ASCII Windows output path, e.g. a subst drive")
    out.mkdir(parents=True, exist_ok=True)
    def find_tool(explicit, name, windows):
        tool = explicit or shutil.which(name)
        if not tool and os.name == "nt":
            tool = windows
        if not tool or not Path(tool).is_file():
            raise FileNotFoundError(f"Pass --{name} to an installed executable")
        return str(tool)
    yosys = find_tool(args.yosys, "yosys", "C:/rv_toolchains/oss-cad-suite/bin/yosys.exe")
    iverilog = find_tool(args.iverilog, "iverilog", "C:/iverilog/bin/iverilog.exe")
    vvp = find_tool(args.vvp, "vvp", "C:/iverilog/bin/vvp.exe")
    (out / "miter.sv").write_text(fixture, encoding="utf-8")
    (out / "fourstate_tb.sv").write_text(testbench, encoding="utf-8")
    command = ("read_slang --std 1800-2017 --top target_add_miter miter.sv; "
               "prep -top target_add_miter; flatten; memory_map; opt; techmap; opt; "
               f"sat -verify -prove equal_o 1 -timeout {args.timeout}")
    sha = lambda value: hashlib.sha256(value).hexdigest()
    report = dict(status="running", reference_commit=reference_commit, xlen=args.xlen,
                  reference_module=reference_path, candidate_sha256=sha(candidate_bytes),
                  candidate_helper_sha256=sha(candidate.encode()),
                  reference_helper_sha256=sha(reference.encode()), fixture_sha256=sha(fixture.encode()),
                  scope="Actual target_add helper; all two-state input combinations against baseline/native; 8192 X/Z simulation probes, not whole-module or ISA proof")
    env = os.environ.copy()
    if os.name == "nt":
        env["PATH"] = str(Path(yosys).parent.parent / "lib") + os.pathsep + env.get("PATH", "")
    (out / "report.json").write_text(json.dumps(report, indent=2), encoding="utf-8")
    try:
        for name, argv in [("proof", [yosys, "-Q", "-T", "-p", command]),
                           ("compile", [iverilog, "-g2012", "-s", "target_add_fourstate_tb",
                                        "-o", "fourstate.vvp", "miter.sv", "fourstate_tb.sv"]),
                           ("fourstate", [vvp, "fourstate.vvp"])]:
            with (out / f"{name}.log").open("w", encoding="utf-8") as log:
                result = subprocess.run(argv, cwd=out, env=env, stdout=log,
                                        stderr=subprocess.STDOUT, timeout=args.timeout + 10)
            if result.returncode:
                raise RuntimeError(f"{name} failed: {out / (name + '.log')}")
        if "SAT proof finished - no model found: SUCCESS!" not in (out / "proof.log").read_text():
            raise RuntimeError("No completed SAT proof")
        marker = f"Actual target_add four-state PASS XLEN={args.xlen} vectors=8192"
        if marker not in (out / "fourstate.log").read_text():
            raise RuntimeError("No completed four-state simulation")
        report["status"] = "passed"
        print(f"PASS target_add XLEN={args.xlen}: unconstrained SAT + 8192 X/Z probes")
    except subprocess.TimeoutExpired:
        report["status"] = "timeout"
        raise
    except Exception:
        report["status"] = "failed"
        raise
    finally:
        (out / "report.json").write_text(json.dumps(report, indent=2), encoding="utf-8")


if __name__ == "__main__":
    main()
