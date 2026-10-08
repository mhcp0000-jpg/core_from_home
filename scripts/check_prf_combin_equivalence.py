"""PRF combinational equality for arbitrary binary state/inputs, undef tags.

State-transition and helper/outer-combin blocks must be text-identical to the
immutable reference (except the two read replacements). SAT checks every public
output after replacing identical FFs with shared arbitrary state inputs. This
is a structural induction argument, not an independent ISA or STA proof.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess

from check_wb_equivalence import ports


def ff_block(source):
    return source[source.index("  always_ff @(posedge clk_i)"):source.index("`ifndef SYNTHESIS")]


def model(source, name, cfg, negative=False):
    body = source.replace(ff_block(source), "")
    body = re.sub(r"\bmodule rv_phys_regfile\b", f"module {name}", body, count=1)
    body = body.replace("logic [DATA_WIDTH-1:0] data_q [0:PHYS_REGS-1];",
                        "wire [DATA_WIDTH-1:0] data_q [0:PHYS_REGS-1];\n"
                        "  for(genvar row=0;row<PHYS_REGS;row++) assign data_q[row]=state_data_i[row];")
    body = body.replace("logic [PHYS_REGS-1:0] ready_q;", "wire [PHYS_REGS-1:0] ready_q=state_ready_i;")
    body = body.replace("probe_ready_o\n", "probe_ready_o,\n"
                        "  input logic [PHYS_REGS-1:0][DATA_WIDTH-1:0] state_data_i,\n"
                        "  input logic [PHYS_REGS-1:0] state_ready_i\n", 1)
    for parameter, value in cfg.items():
        pattern = rf"(parameter (?:int unsigned|bit) {parameter}\s*=\s*)(?:1'b[01]|\d+)"
        body, count = re.subn(pattern, lambda m: m[1] + str(value), body)
        if count != 1:
            raise ValueError(f"Missing literal parameter {parameter}")
    if negative:
        target = "read_data_o[read_port]  = stored_read[read_port][DATA_WIDTH-1:0];"
        if target not in body:
            raise ValueError("Negative control target missing")
        body = body.replace(target, target[:-1] + " ^ DATA_WIDTH'(1);")
    return body


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--reference", default="e9d135b")
    parser.add_argument("--yosys", default="yosys")
    parser.add_argument("--output", type=Path, default=Path("out/prf_combin_formal"))
    parser.add_argument("--timeout", type=int, default=180)
    args = parser.parse_args()
    root = Path(os.path.abspath(__file__)).parent.parent
    yosys = shutil.which(args.yosys)
    if not yosys:
        raise SystemExit("Yosys not found")
    current = (root/"rtl/backend/rv_phys_regfile.sv").read_text(encoding="utf-8")
    commit = subprocess.check_output(["git", "rev-parse", args.reference+"^{commit}"], cwd=root, text=True).strip()
    reference = subprocess.check_output(["git", "show", commit+":rtl/backend/rv_phys_regfile.sv"],
                                        cwd=root, text=True, encoding="utf-8")
    if ff_block(current) != ff_block(reference):
        raise ValueError("State/reset transition changed; focused proof is not applicable")
    cb = current[current.index("  function automatic logic tag_is_allocated_this_cycle"):current.index("  always_ff")]
    rb = reference[reference.index("  function automatic logic tag_is_allocated_this_cycle"):reference.index("  always_ff")]
    cb = cb.replace("stored_read[read_port][DATA_WIDTH-1:0]", "data_q[read_addr_i[read_port]]")
    cb = cb.replace("stored_read[read_port][DATA_WIDTH]", "ready_q[read_addr_i[read_port]]")
    if cb != rb or ports(current) != ports(reference):
        raise ValueError("Additional helper, priority, query/probe, or interface changes need a broader proof")
    output = args.output.absolute()
    if os.name == "nt" and not str(output).isascii():
        raise SystemExit("Use an ASCII subst workspace path")
    output.mkdir(parents=True, exist_ok=True)
    interface = ports(current)
    # Data-read ports are independent replicas of the same generate/loop.
    # Prove one replica with the FULL 80-row state, not all 16 independent
    # replicas at once: undef SAT otherwise multiplies millions of clauses.
    # This is a partitioned port proof, not default-16-port sequential formal.
    configs = [(32,7,1,0,1),(32,80,1,0,1),(32,80,1,0,0),(64,7,1,1,1)]
    report = dict(passed=False, baseline=commit,
                  source_sha256=hashlib.sha256(current.encode()).hexdigest(),
                  identical_state_transition=True, identical_remaining_combinational_logic=True,
                  scope="Single independent data-read replica plus query/probe outputs, arbitrary binary state/inputs, undef-aware tags; text-identical sequential transition; NOT default-16-port sequential formal/ISA/STA signoff",
                  configurations=[])
    environment = os.environ.copy()
    environment["PATH"] = str(Path(yosys).absolute().parent.parent/"lib")+os.pathsep+environment.get("PATH", "")
    for width, rows, reads, bypass, zero in configs + [configs[0]]:
        negative = len(report["configurations"]) == len(configs)
        name = f"w{width}_r{rows}_p{reads}_b{bypass}_z{zero}" + ("_negative" if negative else "")
        cfg = dict(DATA_WIDTH=width, PHYS_REGS=rows, READ_PORTS=reads,
                   INITIAL_MAPPED_REGS=min(rows,32), WRITE_BYPASS=bypass, ZERO_REGISTER=zero)
        decl = "\n".join(f"localparam {parameter}={value};" for parameter,value in cfg.items())
        decl += "\nlocalparam TAG_WIDTH=7,QUERY_PORTS=6,WRITE_PORTS=2,ALLOC_PORTS=2;"
        inputs = [f"input {kind} {port}" for direction,kind,port in interface if direction=="input"]
        inputs += ["input logic [PHYS_REGS-1:0][DATA_WIDTH-1:0] state_data_i",
                   "input logic [PHYS_REGS-1:0] state_ready_i"]
        params = ",".join(f"parameter {parameter}={value}" for parameter,value in cfg.items())
        params += ",parameter TAG_WIDTH=7,QUERY_PORTS=6,WRITE_PORTS=2,ALLOC_PORTS=2"
        outputs = [(kind,port) for direction,kind,port in interface if direction=="output"]
        wires = "\n".join(f"{kind} {prefix}_{port};" for kind,port in outputs for prefix in ("dut","ref"))
        def inst(module,prefix):
            binds = ",".join(f".{port}({port if direction=='input' else prefix+'_'+port})"
                             for direction,_,port in interface)
            return f"{module} {prefix}_i({binds},.state_data_i(state_data_i),.state_ready_i(state_ready_i));"
        checks = " && ".join(f"(dut_{port} === ref_{port})" for _,port in outputs)
        fixture = model(current,"current_prf",cfg,negative) + model(reference,"reference_prf",cfg)
        fixture += f"\nmodule prf_miter #({params})({','.join(inputs)},output logic equal_o);\n{wires}\n{inst('current_prf','dut')}\n{inst('reference_prf','ref')}\nassign equal_o={checks};\nendmodule\n"
        (output/f"{name}.sv").write_text(fixture,encoding="utf-8")
        command = (f"read_slang --ignore-assertions --ignore-initial --no-implicit-memories --top prf_miter {name}.sv; "
                   "prep -top prf_miter -flatten; opt; sat -enable_undef -set-def-inputs -verify -prove equal_o 1 -show-inputs")
        with (output/f"{name}.log").open("w",encoding="utf-8") as log:
            result = subprocess.run([yosys,"-Q","-T","-p",command], cwd=output, env=environment,
                                    stdout=log,stderr=subprocess.STDOUT,timeout=args.timeout)
        log = (output/f"{name}.log").read_text(encoding="utf-8")
        passed = result.returncode != 0 and "proof did fail" in log if negative else result.returncode==0 and "SUCCESS!" in log
        report["configurations"].append(dict(name=name,passed=passed,negative=negative,exit_code=result.returncode))
        (output/"report.json").write_text(json.dumps(report,indent=2)+"\n",encoding="utf-8")
        if not passed:
            raise SystemExit(f"FAIL/INCOMPLETE: {name}")
        print(f"PASS {name}",flush=True)
    report["passed"]=True
    (output/"report.json").write_text(json.dumps(report,indent=2)+"\n",encoding="utf-8")


if __name__=="__main__":
    main()
