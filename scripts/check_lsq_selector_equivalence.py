#!/usr/bin/env python3
"""SAT-check actual LSQ merge topology against immutable native selector.

Extracts the real selector/functions; substitutes arbitrary eligibility and
sequences. Cached-order bits are computed from those arbitrary sequences.
This proves the combinational selection, not sequential cache maintenance,
memory ordering, protocol behavior or 4-state simulation.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess


def function(source, name):
    match = re.search(r"  function automatic logic " + name + r"\([\s\S]*?  endfunction", source)
    if not match:
        raise ValueError(f"Function missing: {name}")
    return match[0]


def model(source, name, cached):
    start = source.index("  always_comb begin\n    logic [LQ_ENTRIES-1:0] eligible_work;")
    end = source.index("\n  always_comb begin\n    for (int unsigned lane", start)
    tree = source[start:end]
    classification = tree.index("    for (int unsigned entry = 0; entry < LQ_ENTRIES; entry++) begin")
    leaves = tree.index("    for (int unsigned leaf", classification)
    tree = tree[:classification] + tree[leaves:]
    tree = tree.replace("eligible_work = '0;", "eligible_work = eligible_i;", 1)
    declarations_start = source.index("  logic lq_select_valid ")
    declarations_end = source.index("\n  function automatic logic [LQ_INDEX_WIDTH-1:0] first_free_lq", declarations_start)
    declarations = source[declarations_start:declarations_end]
    helpers = function(source, "sequence_after") + "\n" + function(source, "lq_mask_before" if cached else "lq_select_before")
    cache = ""
    cache_declaration = ""
    if cached:
        cache_declaration = "logic [LQ_ENTRIES-1:0][LQ_ENTRIES-1:0] lq_order_q;"
        cache = """always_comb
    for(int row=0;row<LQ_ENTRIES;row++)
      for(int col=0;col<LQ_ENTRIES;col++)
        lq_order_q[row][col]=(lq_sequence_q[row]==lq_sequence_q[col]) ? (row<col) :
          sequence_after(lq_sequence_q[col],lq_sequence_q[row]);"""
    return f"""module {name} #(parameter int LQ_ENTRIES=24,SEQ_WIDTH=8,
  localparam int LQ_INDEX_WIDTH=$clog2(LQ_ENTRIES))(
  input logic [LQ_ENTRIES-1:0] eligible_i,
  input logic [LQ_ENTRIES-1:0][SEQ_WIDTH-1:0] sequence_i,
  output logic [1:0] selected_candidate_found,
  output logic [1:0][LQ_INDEX_WIDTH-1:0] selected_candidate_index,
  output logic [1:0][SEQ_WIDTH-1:0] selected_candidate_sequence);
  localparam int LQ_SELECT_TREE_LEVELS=$clog2(LQ_ENTRIES);
  localparam int LQ_SELECT_TREE_LEAVES=1<<LQ_SELECT_TREE_LEVELS;
  logic [SEQ_WIDTH-1:0] lq_sequence_q [0:LQ_ENTRIES-1];
  for(genvar entry=0;entry<LQ_ENTRIES;entry++) assign lq_sequence_q[entry]=sequence_i[entry];
  {declarations}
  {cache_declaration}
  {helpers}
  {cache}
  {tree}
endmodule
"""


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--reference", default="081e714")
    parser.add_argument("--rtl", type=Path, help="Optional saved candidate RTL")
    parser.add_argument("--loads", type=int, default=24)
    parser.add_argument("--yosys", default="yosys")
    parser.add_argument("--timeout", type=int, default=180)
    parser.add_argument("--gate-simplify", action="store_true", help="ABC-simplify the combinational miter before SAT")
    parser.add_argument("--output", type=Path, default=Path("out/lsq_selector_equivalence"))
    args = parser.parse_args()
    if args.loads < 2 or args.timeout < 1:
        parser.error("Invalid loads/timeout")
    root = Path(os.path.abspath(__file__)).parent.parent
    yosys = shutil.which(args.yosys)
    if not yosys:
        raise SystemExit("Yosys required")
    commit = subprocess.check_output(["git","rev-parse","--verify",args.reference+"^{commit}"],cwd=root,text=True).strip()
    reference = subprocess.check_output(["git","show",commit+":rtl/backend/rv_lsq.sv"],cwd=root,text=True,encoding="utf-8").replace("\r\n","\n")
    actual_path = args.rtl.absolute() if args.rtl else root/"rtl/backend/rv_lsq.sv"
    actual = actual_path.read_text(encoding="utf-8")
    miter = """module lsq_selector_miter #(parameter int LQ_ENTRIES=24,SEQ_WIDTH=8,
 localparam int LQ_INDEX_WIDTH=$clog2(LQ_ENTRIES))(
 input logic [LQ_ENTRIES-1:0] eligible_i,
 input logic [LQ_ENTRIES-1:0][SEQ_WIDTH-1:0] sequence_i,output logic equal_o);
 logic [1:0] a_valid,b_valid;
 logic [1:0][LQ_INDEX_WIDTH-1:0] a_index,b_index;
 logic [1:0][SEQ_WIDTH-1:0] a_sequence,b_sequence;
 lsq_selector_actual #(.LQ_ENTRIES(LQ_ENTRIES),.SEQ_WIDTH(SEQ_WIDTH)) a(eligible_i,sequence_i,a_valid,a_index,a_sequence);
 lsq_selector_reference #(.LQ_ENTRIES(LQ_ENTRIES),.SEQ_WIDTH(SEQ_WIDTH)) b(eligible_i,sequence_i,b_valid,b_index,b_sequence);
 assign equal_o=(a_valid==b_valid) &&
   (!a_valid[0] || (a_index[0]==b_index[0] && a_sequence[0]==b_sequence[0])) &&
   (!a_valid[1] || (a_index[1]==b_index[1] && a_sequence[1]==b_sequence[1]));
endmodule
"""
    cached = "function automatic logic lq_mask_before(" in actual
    copies = {"actual.sv":model(actual,"lsq_selector_actual",cached),"reference.sv":model(reference,"lsq_selector_reference",False),"miter.sv":miter}
    output = args.output.absolute()
    if os.name=="nt" and not str(output).isascii():
        raise SystemExit("ASCII subst/output path required on Windows")
    output.mkdir(parents=True,exist_ok=True)
    for name,contents in copies.items():
        (output/name).write_text(contents,encoding="utf-8")
    command=f"read_slang --single-unit --top lsq_selector_miter -G LQ_ENTRIES={args.loads} actual.sv reference.sv miter.sv; prep -top lsq_selector_miter -flatten; "
    if args.gate_simplify:
        abc_path=Path(yosys).absolute().parent/("yosys-abc.exe" if os.name=="nt" else "yosys-abc")
        if not abc_path.is_file():
            raise SystemExit("Sibling yosys-abc required for --gate-simplify")
        command+=f'techmap; opt; abc -exe "{abc_path.as_posix()}" -g simple; opt; '
    command+="sat -prove equal_o 1 -verify -show-inputs"
    report=dict(passed=False,status="running",loads=args.loads,reference_commit=commit,rtl_sha256=hashlib.sha256(actual_path.read_bytes()).hexdigest(),
                command=command,fixture_sha256={name:hashlib.sha256(contents.encode()).hexdigest() for name,contents in copies.items()},scope=__doc__)
    report_path=output/"report.json"
    report_path.write_text(json.dumps(report,indent=2)+"\n",encoding="utf-8")
    env=os.environ.copy()
    env["PATH"]=str(Path(yosys).parent.parent/"lib")+os.pathsep+env.get("PATH","")
    temp_path=output/"tmp"
    temp_path.mkdir(exist_ok=True)
    env["TEMP"]=str(temp_path)
    env["TMP"]=str(temp_path)
    try:
        with (output/"proof.log").open("w",encoding="utf-8") as log:
            result=subprocess.Popen([yosys,"-Q","-T","-p",command],cwd=output,env=env,stdout=log,stderr=subprocess.STDOUT,
                                    start_new_session=os.name!="nt")
            try:
                result.wait(timeout=args.timeout)
            except subprocess.TimeoutExpired:
                if os.name=="nt":
                    subprocess.run(["taskkill","/PID",str(result.pid),"/T","/F"],stdout=log,stderr=subprocess.STDOUT,check=False)
                else:
                    os.killpg(result.pid,9)
                if result.poll() is None:
                    result.kill()
                result.wait()
                raise
    except subprocess.TimeoutExpired:
        report.update(status="timeout")
        report_path.write_text(json.dumps(report,indent=2)+"\n",encoding="utf-8")
        raise SystemExit("SAT timed out, NOT a pass")
    passed=result.returncode==0 and "SAT proof finished - no model found: SUCCESS!" in (output/"proof.log").read_text(encoding="utf-8")
    report.update(passed=passed,status="passed" if passed else "failed",exit_code=result.returncode)
    report_path.write_text(json.dumps(report,indent=2)+"\n",encoding="utf-8")
    if not passed:
        raise SystemExit("SAT did not prove equivalence; inspect proof.log")
    print(f"PASS LSQ selector SAT loads={args.loads}, arbitrary eligibility/sequence, valid identities")


if __name__=="__main__":
    main()
