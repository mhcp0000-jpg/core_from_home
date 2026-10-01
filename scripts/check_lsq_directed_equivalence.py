#!/usr/bin/env python3
"""Replay the maintained LSQ directed tests against immutable reference RTL.

Compare every public output, including invalid payload, and resident predicates
at both clock edges. This is directed cycle equivalence, NOT exhaustive formal
or random-state proof. Run with both EarlyLoadSelect/AGU bypass configurations.
Generated fixtures, hashes, compiler output and results stay below ignored out/.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess


def ports(source):
    header = re.sub(r"//[^\n]*", "", source.split(") (", 1)[1].split(");", 1)[0])
    result = []
    for item in header.split(","):
        match = re.fullmatch(r"\s*(input|output)\s+(.+?(?:\]|\s))([A-Za-z_]\w*)\s*", item, re.S)
        if not match:
            raise ValueError(f"Unsupported port declaration: {item}")
        result.append((match[1], " ".join(match[2].split()), match[3]))
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--reference", default="081e714")
    parser.add_argument("--rtl", type=Path, help="Optional saved candidate RTL")
    parser.add_argument("--early", type=int, choices=(0, 1), default=1)
    parser.add_argument("--bypass", type=int, choices=(0, 1), default=1)
    parser.add_argument("--jobs", type=int, default=2)
    parser.add_argument("--verilator", default="verilator_bin.exe" if os.name == "nt" else "verilator")
    parser.add_argument("--make", default="make")
    parser.add_argument("--output", type=Path, default=Path("out/lsq_directed_equivalence"))
    args = parser.parse_args()
    if args.jobs < 1:
        parser.error("jobs must be positive")
    root = Path(os.path.abspath(__file__)).parent.parent
    verilator, make = shutil.which(args.verilator), shutil.which(args.make)
    if not verilator or not make:
        raise SystemExit("Verilator and GNU make must be on PATH or passed explicitly")
    commit = subprocess.check_output(["git", "rev-parse", "--verify", args.reference + "^{commit}"], cwd=root, text=True).strip()
    reference = subprocess.check_output(["git", "show", commit + ":rtl/backend/rv_lsq.sv"], cwd=root, text=True, encoding="utf-8")
    rtl_path = args.rtl.absolute() if args.rtl else root / "rtl/backend/rv_lsq.sv"
    pkg_path, tb_path = root / "rtl/rv_ooo_pkg.sv", root / "tb/unit/backend/rv_lsq_tb.sv"
    actual = rtl_path.read_text(encoding="utf-8")
    interface = ports(actual)
    if interface != ports(reference):
        raise ValueError("Interface changed: update the proof harness explicitly")
    outputs = [name for direction, _, name in interface if direction == "output"]
    connections = ",\n".join(f".{name}({'u_test.u_dut.' + name if direction == 'input' else ''})" for direction, _, name in interface)
    equality = " &&\n".join(f"(u_test.u_dut.{name} === u_ref.{name})" for name in outputs)
    harness = f"""module lsq_directed_equiv_tb;
  rv_lsq_tb #(.EarlyLoadSelect({args.early}),.AguLoadBypass({args.bypass})) u_test();
  rv_lsq_reference #(.EARLY_LOAD_SELECT({args.early}),.AGU_LOAD_BYPASS({args.bypass}),.LQ_ENTRIES(4),.SQ_ENTRIES(4)) u_ref({connections});
  integer comparisons=0;
  always @(posedge u_test.clk or negedge u_test.clk) begin
    #2;
    if (u_test.rst_n) begin
      if (!({equality})) $fatal(1,"LSQ public output mismatch comparison=%0d",comparisons);
      if (u_test.u_dut.candidate_resident !== u_ref.candidate_resident)
        $fatal(1,"LSQ resident predicate mismatch");
      comparisons++;
    end
  end
  final $display("LSQ directed reference equality PASS comparisons=%0d outputs={len(outputs)} early={args.early} bypass={args.bypass}",comparisons);
endmodule
"""
    output = args.output.absolute()
    if os.name == "nt" and not str(output).isascii():
        raise SystemExit("Run from an ASCII subst drive or use an ASCII output path on Windows")
    output.mkdir(parents=True, exist_ok=True)
    copies = {"pkg.sv": pkg_path.read_text(encoding="utf-8"), "candidate.sv": actual,
              "reference.sv": re.sub(r"\bmodule\s+rv_lsq\b", "module rv_lsq_reference", reference, count=1),
              "directed_tb.sv": tb_path.read_text(encoding="utf-8"), "equiv_tb.sv": harness}
    for name, content in copies.items():
        (output / name).write_text(content, encoding="utf-8")
    report = dict(passed=False, status="running", reference_commit=commit, early=args.early, bypass=args.bypass,
                  scope="Maintained directed LSQ TB; all public outputs plus resident predicates at both clock edges; not exhaustive",
                  rtl_sha256=hashlib.sha256(rtl_path.read_bytes()).hexdigest(),
                  fixture_sha256={name: hashlib.sha256(content.encode()).hexdigest() for name, content in copies.items()})
    report_path = output / "report.json"
    report_path.write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    commands = [[verilator, "--cc", "--exe", "--main", "--timing", "--assert", "-Wno-fatal", "-Werror-UNOPTFLAT",
                 "--top-module", "lsq_directed_equiv_tb", "--Mdir", "build", *copies],
                [make, "-j", str(args.jobs), "-C", "build", "-f", "Vlsq_directed_equiv_tb.mk", "CXX=g++", "CC=gcc", "LINK=g++", "VM_PARALLEL_BUILDS=1"],
                [str(output / "build" / ("Vlsq_directed_equiv_tb.exe" if os.name == "nt" else "Vlsq_directed_equiv_tb"))]]
    for index, command in enumerate(commands):
        with (output / ("result.log" if index == 2 else f"build{index}.log")).open("w", encoding="utf-8") as log:
            result = subprocess.run(command, cwd=output, stdout=log, stderr=subprocess.STDOUT)
        if result.returncode:
            report.update(status="failed", failed_step=index, exit_code=result.returncode)
            report_path.write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
            raise SystemExit(result.returncode)
    result_text = (output / "result.log").read_text(encoding="utf-8")
    match = re.search(r"LSQ directed reference equality PASS comparisons=(\d+)", result_text)
    if not match or int(match[1]) < 1 or "rv_lsq_tb PASS" not in result_text:
        raise SystemExit("Missing directed-test or equality completion marker")
    report.update(passed=True, status="passed", comparisons=int(match[1]), output_count=len(outputs))
    report_path.write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    print(f"PASS early={args.early} bypass={args.bypass} comparisons={match[1]} all {len(outputs)} public outputs + resident predicates")


if __name__ == "__main__":
    main()
