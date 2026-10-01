#!/usr/bin/env python3
"""Two-state SAT equality of all actual WB outputs against immutable RTL.

This is combinational reference equivalence, not an independent ISA proof.
Generated copies/logs/reports remain below ignored out/.
Windows Yosys/ABC requires an ASCII output path (run from an ASCII subst drive).
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
    parser.add_argument("--yosys", default="yosys")
    parser.add_argument("--width", type=int, choices=(32, 64), default=32)
    parser.add_argument("--sources", type=int, default=11)
    parser.add_argument("--int-ports", type=int, default=2)
    parser.add_argument("--fp-ports", type=int, default=2)
    parser.add_argument("--complete-ports", type=int, default=4)
    parser.add_argument("--timeout", type=int, default=180)
    parser.add_argument("--gate-simplify", action="store_true", help="Techmap and ABC-simplify the entire miter before SAT")
    parser.add_argument("--rtl", type=Path, help="Optional saved candidate RTL, otherwise current production RTL")
    parser.add_argument("--allow-completion-source", action="store_true", help="Validate the experimental one-hot source output in addition to original outputs")
    parser.add_argument("--assume-source-cohort", action="store_true", help="Check experimental source identity only when live sources share an unsigned <128 sequence window; does NOT prove that ROB enforces this")
    parser.add_argument("--output", type=Path, default=Path("out/wb_equivalence"))
    args = parser.parse_args()
    if args.sources<2 or args.int_ports<1 or args.fp_ports<1 or args.complete_ports<2 or args.timeout<1:
        parser.error("Invalid resource counts or timeout")
    if args.assume_source_cohort and not args.allow_completion_source:
        parser.error("--assume-source-cohort requires --allow-completion-source")
    root = Path(os.path.abspath(__file__)).parent.parent
    yosys = shutil.which(args.yosys)
    if not yosys:
        raise SystemExit("Yosys not found; pass --yosys")
    commit = subprocess.check_output(["git", "rev-parse", "--verify", args.reference+"^{commit}"], cwd=root, text=True).strip()
    reference = subprocess.check_output(["git", "show", commit+":rtl/backend/rv_writeback_arbiter.sv"], cwd=root, text=True, encoding="utf-8")
    actual_path = args.rtl.absolute() if args.rtl else root/"rtl/backend/rv_writeback_arbiter.sv"
    actual = actual_path.read_text(encoding="utf-8")
    interface = ports(actual)
    reference_interface = ports(reference)
    source_port = next((item for item in interface if item[2] == "complete_source_o"), None)
    original_interface = [item for item in interface if item[2] != "complete_source_o"] if args.allow_completion_source else interface
    if original_interface != reference_interface:
        raise ValueError("Interface delta requires explicit proof update")
    if args.allow_completion_source and source_port != ("output", "logic [ROB_COMPLETE_PORTS-1:0][SOURCE_COUNT-1:0]", "complete_source_o"):
        raise ValueError("Expected exact experimental completion source output")
    parameters = dict(XLEN=args.width, SOURCE_COUNT=args.sources, PHYS_TAG_WIDTH=7,
                      ROB_SEQ_WIDTH=8, INT_WRITE_PORTS=args.int_ports,
                      FP_WRITE_PORTS=args.fp_ports, ROB_COMPLETE_PORTS=args.complete_ports)
    declarations = ",".join(f"parameter int {name}={value}" for name,value in parameters.items())
    inputs = [f"input {kind} {name}" for direction,kind,name in interface if direction=="input"]
    if args.assume_source_cohort:
        inputs.append("input logic [ROB_SEQ_WIDTH-1:0] cohort_base_i")
    outputs = [(kind,name) for direction,kind,name in interface if direction=="output"]
    original_outputs = [(kind, name) for direction, kind, name in reference_interface if direction=="output"]
    signals = "\n".join(f"{kind} current_{name};" for kind,name in outputs) + "\n" + "\n".join(f"{kind} reference_{name};" for kind,name in original_outputs)
    bindings = ",".join(f".{name}({name})" for name in parameters)
    def instance(module, prefix, port_list):
        connections = ",".join(f".{name}({name if direction=='input' else prefix+'_'+name})" for direction,_,name in port_list)
        return f"{module} #({bindings}) {prefix}_i({connections});"
    predicates = [f"(current_{name}==reference_{name})" for _,name in original_outputs]
    identity_predicates = []
    if args.allow_completion_source:
        for slot in range(args.complete_ports):
            identity_predicates.append(f"(current_complete_valid_o[{slot}]==(|current_complete_source_o[{slot}]))")
            for source in range(args.sources):
                identity_predicates.append(f"(!current_complete_source_o[{slot}][{source}] || current_complete_sequence_o[{slot}]==source_sequence_i[{source}])")
                for other in range(source):
                    identity_predicates.append(f"!(current_complete_source_o[{slot}][{source}] && current_complete_source_o[{slot}][{other}])")
        identity = " && ".join(identity_predicates)
        if args.assume_source_cohort:
            # A size-cast subtraction is modulo 2**SEQ_WIDTH; MSB zero means
            # unsigned distance < half-range. Use comparison syntax accepted
            # by both Slang and other SystemVerilog frontends.
            cohort = " && ".join(f"(!(source_valid_i[{source}] && source_live_i[{source}]) || $unsigned(ROB_SEQ_WIDTH'(source_sequence_i[{source}]-cohort_base_i)) < (1 << (ROB_SEQ_WIDTH-1)))" for source in range(args.sources))
            predicates.append(f"(!({cohort}) || ({identity}))")
        else:
            predicates.append(f"({identity})")
    equalities = " && ".join(predicates)
    miter = f"module wb_miter #({declarations})({','.join(inputs)},output logic equal_o);\n{signals}\n{instance('rv_writeback_arbiter','current',interface)}\n{instance('wb_reference','reference',reference_interface)}\nassign equal_o={equalities};\nendmodule\n"
    output = args.output.absolute()
    if os.name=="nt" and not str(output).isascii():
        raise SystemExit("Windows Yosys/ABC needs an ASCII output path; map the repository with subst and run from that drive")
    output.mkdir(parents=True, exist_ok=True)
    package_path = root/"rtl/rv_ooo_pkg.sv"
    copies = {"pkg.sv":package_path.read_text(encoding="utf-8"), "candidate.sv":actual,
              "reference.sv":re.sub(r"\bmodule\s+rv_writeback_arbiter\b", "module wb_reference", reference, count=1), "miter.sv":miter}
    for name,contents in copies.items():
        (output/name).write_text(contents, encoding="utf-8")
    command = "read_slang --single-unit --ignore-assertions --ignore-initial --top wb_miter -DSYNTHESIS pkg.sv candidate.sv reference.sv miter.sv; prep -top wb_miter -flatten; "
    if args.gate_simplify:
        abc_path = Path(yosys).absolute().parent/("yosys-abc.exe" if os.name=="nt" else "yosys-abc")
        if not abc_path.is_file():
            raise SystemExit("Sibling yosys-abc not found for --gate-simplify")
        command += f'techmap; opt; abc -exe "{abc_path.as_posix()}" -g simple; opt; '
    command += "sat -prove equal_o 1 -verify -show-inputs"
    report = dict(passed=False, status="running", parameters=parameters, reference_commit=commit,
                  rtl_sha256=hashlib.sha256(actual_path.read_bytes()).hexdigest(), rtl_path=str(actual_path),
                  package_sha256=hashlib.sha256(package_path.read_bytes()).hexdigest(),
                  fixture_sha256={name:hashlib.sha256(contents.encode()).hexdigest() for name,contents in copies.items()},
                  command=command, completion_source_checked=args.allow_completion_source,
                  source_cohort_condition=args.assume_source_cohort,
                  scope="All original outputs unconditional; optional source identity conditional on explicit <half-range cohort if requested; two-state, no ROB/ISA/4-state proof")
    (output/"report.json").write_text(json.dumps(report,indent=2)+"\n",encoding="utf-8")
    (output/"proof.log").write_text("",encoding="utf-8")
    environment = os.environ.copy()
    runtime = Path(yosys).absolute().parent.parent/"lib"
    if os.name=="nt" and runtime.is_dir():
        environment["PATH"]=str(runtime)+os.pathsep+environment.get("PATH","")
    if os.name=="nt":
        temporary = output/"tmp"
        temporary.mkdir(exist_ok=True)
        environment["TEMP"] = str(temporary)
        environment["TMP"] = str(temporary)
    try:
        with (output/"console.log").open("w",encoding="utf-8") as log:
            argv = [yosys,"-Q","-T","-l","proof.log","-p",command]
            result = subprocess.Popen(argv,cwd=output,env=environment,stdout=log,stderr=subprocess.STDOUT,
                                      start_new_session=os.name!="nt")
            try:
                result.wait(timeout=args.timeout)
            except subprocess.TimeoutExpired:
                # Kill the owned process TREE before reaping Yosys; otherwise
                # a timed-out ABC child can remain consuming CPU on Windows.
                if os.name=="nt":
                    subprocess.run(["taskkill","/PID",str(result.pid),"/T","/F"],stdout=log,stderr=subprocess.STDOUT,check=False)
                else:
                    os.killpg(result.pid,9)
                if result.poll() is None:
                    result.kill()
                result.wait()
                raise
        report["passed"]=result.returncode==0 and "no model found: SUCCESS!" in (output/"proof.log").read_text(encoding="utf-8")
        report["status"]="passed" if report["passed"] else "failed"
        report["yosys_exit_code"]=result.returncode
    except subprocess.TimeoutExpired:
        report["status"]="timeout"
    finally:
        (output/"report.json").write_text(json.dumps(report,indent=2)+"\n",encoding="utf-8")
    if not report["passed"]:
        raise SystemExit(f"{report['status'].upper()}: inspect {output}")
    print(f"WB original-output SAT PASS XLEN={args.width} sources={args.sources} INT/FP={args.int_ports}/{args.fp_ports} COMPLETE={args.complete_ports}; source identity {'CONDITIONAL cohort only (ROB invariant unproven)' if args.assume_source_cohort else 'unconditional' if args.allow_completion_source else 'not checked'}")


if __name__=="__main__":
    main()
