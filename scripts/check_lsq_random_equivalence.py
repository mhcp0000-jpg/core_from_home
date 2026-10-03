#!/usr/bin/env python3
"""Randomized LSQ cycle/state differential test against immutable reference RTL.

A seeded two-state stress test, not an independent ISA/protocol/formal proof.
Stimulus intentionally includes stale generations and arbitrary backpressure;
protocol SVA is disabled, but cache equality is explicitly checked every step.
Use check_lsq_directed_equivalence.py / SoC tests for assertion-enabled traffic.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess

from check_lsq_directed_equivalence import ports


def fixture(actual, reference, args):
    interface = ports(actual)
    if interface != ports(reference):
        raise ValueError("Interface changed; update test explicitly")
    declarations, assignments, checks = [], [], []
    for direction, kind, name in interface:
        declarations.append(f"typedef {kind} type_{name};")
        if direction == "input":
            declarations.append(f"type_{name} {name};")
            if name not in ("clk_i", "rst_ni"):
                assignments.append(f"{name}=type_{name}'({{8{{$urandom}}}});")
        else:
            declarations.append(f"type_{name} dut_{name},ref_{name};")
            if getattr(args, "qualified_commit_ready", False) and name in (
                "load_commit_ready_o", "store_commit_ready_o"
            ):
                valid = name.replace("ready_o", "valid_i")
                checks.append(
                    f'if((dut_{name} & {valid}) !== (ref_{name} & {valid})) '
                    f'$fatal(1,"qualified {name} differs cycle=%0d",cycle);'
                )
            else:
                checks.append(f'if(dut_{name} !== ref_{name}) $fatal(1,"{name} differs cycle=%0d",cycle);')
    def instance(module, prefix):
        connections = ",".join(f".{name}({name if direction == 'input' else prefix+'_'+name})" for direction, _, name in interface)
        return f"{module} #(.EARLY_LOAD_SELECT({args.early}),.AGU_LOAD_BYPASS({args.bypass}),.LQ_ENTRIES(LQ_ENTRIES),.SQ_ENTRIES(SQ_ENTRIES),.PADDR_WIDTH(PADDR_WIDTH)) {prefix}_i({connections});"
    scalars = ("lq_valid_q lq_killed_q lq_address_valid_q lq_issued_q lq_completed_q lq_exception_q "
               "lq_destination_valid_q lq_unsigned_q lq_device_q sq_valid_q sq_address_valid_q "
               "sq_data_valid_q sq_exception_q sq_device_q candidate_found candidate_index "
               "candidate_sequence candidate_blocked_q").split()
    scalar_checks = "\n".join(f'if(dut_i.{name} !== ref_i.{name}) $fatal(1,"{name} state cycle=%0d",cycle);' for name in scalars)
    def row_checks(queue, fields):
        return f"for(int entry=0;entry<{queue.upper()}_ENTRIES;entry++) begin\n" + "\n".join(
            f'if(dut_i.{queue}_{field}_q[entry] !== ref_i.{queue}_{field}_q[entry]) $fatal(1,"{queue}_{field} row=%0d cycle=%0d",entry,cycle);'
            for field in fields.split()) + "\nend"
    cache_check = ""
    if re.search(r"logic\s+\[LQ_ENTRIES-1:0\].*\blq_order_q\b", actual):
        cache_check = """for(int row=0;row<LQ_ENTRIES;row++)
      for(int col=0;col<LQ_ENTRIES;col++)
        if(dut_i.lq_order_q[row][col] !==
          ((dut_i.lq_sequence_q[row]==dut_i.lq_sequence_q[col]) ? (row<col) :
           ref_i.sequence_after(dut_i.lq_sequence_q[col],dut_i.lq_sequence_q[row])))
          $fatal(1,"cached order row=%0d col=%0d cycle=%0d",row,col,cycle);"""
    return f"""module lsq_random_equiv_tb;
  import rv_ooo_pkg::*;
  localparam int LQ_ENTRIES={args.loads},SQ_ENTRIES={args.stores},PADDR_WIDTH={args.width};
  localparam int DATA_WIDTH=64,DATA_BYTES=8,SEQ_WIDTH=8,PHYS_TAG_WIDTH=7;
  localparam int LQ_INDEX_WIDTH=$clog2(LQ_ENTRIES),SQ_INDEX_WIDTH=$clog2(SQ_ENTRIES);
  localparam int LQ_COUNT_WIDTH=$clog2(LQ_ENTRIES+1),SQ_COUNT_WIDTH=$clog2(SQ_ENTRIES+1);
  {chr(10).join(declarations)}
  {instance('rv_lsq', 'dut')}
  {instance('rv_lsq_reference', 'ref')}
  always #5 clk_i=~clk_i;
  int cycle,seed,allocations,stores,agu_updates,flushes,resets,wraps,dual_loads,stalls;
  logic [SEQ_WIDTH-1:0] next_sequence;
  task automatic compare;
    {chr(10).join(checks)}
    {scalar_checks}
    {row_checks('lq','sequence destination_phys size address mask exception_cause')}
    {row_checks('sq','sequence address data mask size exception_cause')}
    {cache_check}
    if(dut_i.selected_candidate_found !== ref_i.selected_candidate_found)
      $fatal(1,"selected candidate valid cycle=%0d",cycle);
    for(int lane=0;lane<2;lane++)
      if(dut_i.selected_candidate_found[lane] &&
        (dut_i.selected_candidate_index[lane] !== ref_i.selected_candidate_index[lane] ||
         dut_i.selected_candidate_sequence[lane] !== ref_i.selected_candidate_sequence[lane]))
        $fatal(1,"selected candidate identity cycle=%0d",cycle);
  endtask
  initial begin
    clk_i=0;rst_ni=0;seed=32'h61758921;void'($urandom(seed));next_sequence=0;
    allocations=0;stores=0;agu_updates=0;flushes=0;resets=0;wraps=0;dual_loads=0;stalls=0;
    {chr(10).join(assignments)}
    dispatch_valid_i=0;agu_valid_i=0;agu_preview_valid_i=0;
    flush_valid_i=0;load_response_valid_i=0;load_commit_valid_i=0;store_commit_valid_i=0;
    repeat(2) @(posedge clk_i);
    #1;compare();
    for(cycle=0;cycle<{args.cycles};cycle++) begin
      @(negedge clk_i);
      {chr(10).join(assignments)}
      rst_ni=(cycle%997)!=0;
      if(!rst_ni) resets++;
      dispatch_valid_i=($urandom_range(0,3)==0)?0:2'($urandom_range(1,3));
      dispatch_accept_i=($urandom_range(0,3)!=0);
      dispatch_is_load_i=2'($urandom);
      dispatch_is_store_i=~dispatch_is_load_i;
      dispatch_sequence_i[0]=next_sequence;
      dispatch_sequence_i[1]=next_sequence+1'b1;
      dispatch_device_i=0;
      flush_valid_i=($urandom_range(0,29)==0);
      flush_all_i=($urandom_range(0,7)==0);
      flush_sequence_i=next_sequence-SEQ_WIDTH'($urandom_range(1,80));
      if(flush_valid_i) flushes++;
      load_candidate_ready_i=2'($urandom);
      agu_valid_i=0;agu_preview_valid_i=0;agu_lq_valid_i=0;agu_sq_valid_i=0;
      load_response_valid_i=0;load_commit_valid_i=0;store_commit_valid_i=0;
      for(int lane=0;lane<2;lane++) begin
        int li,si;
        li=$urandom_range(0,LQ_ENTRIES-1);si=$urandom_range(0,SQ_ENTRIES-1);
        dispatch_size_i[lane]=3'($urandom_range(0,3));
        agu_lq_index_i[lane]=LQ_INDEX_WIDTH'(li);
        agu_sq_index_i[lane]=SQ_INDEX_WIDTH'(si);
        agu_address_i[lane]=PADDR_WIDTH'(32'h80020000+8*$urandom_range(0,7));
        agu_device_i[lane]=($urandom_range(0,31)==0);
        agu_exception_valid_i[lane]=($urandom_range(0,31)==0);
        agu_exception_cause_i[lane]=EXC_LOAD_ACCESS_FAULT;
        if($urandom_range(0,1)==0 && ref_i.lq_valid_q[li]) begin
          agu_sequence_i[lane]=ref_i.lq_sequence_q[li];
          agu_lq_valid_i[lane]=1;
        end else if(ref_i.sq_valid_q[si]) begin
          agu_sequence_i[lane]=ref_i.sq_sequence_q[si];
          agu_sq_valid_i[lane]=1;
          agu_exception_cause_i[lane]=EXC_STORE_ACCESS_FAULT;
        end
        // Include stale generations: they must be rejected identically.
        if($urandom_range(0,15)==0) agu_sequence_i[lane]++;
        agu_preview_valid_i[lane]=($urandom_range(0,3)!=0);
        agu_valid_i[lane]=agu_preview_valid_i[lane] && ($urandom_range(0,3)!=0);
        agu_address_valid_i[lane]=($urandom_range(0,3)!=0);
        agu_store_data_valid_i[lane]=($urandom_range(0,3)!=0);
        load_response_index_i[lane]=LQ_INDEX_WIDTH'(li);
        load_response_valid_i[lane]=ref_i.lq_valid_q[li] && ref_i.lq_issued_q[li] && ($urandom_range(0,1)==0);
        load_response_replay_i[lane]=($urandom_range(0,7)==0);
        load_commit_index_i[lane]=LQ_INDEX_WIDTH'(li);
        load_commit_sequence_i[lane]=ref_i.lq_sequence_q[li];
        load_commit_valid_i[lane]=($urandom_range(0,1)==0);
        store_commit_index_i[lane]=SQ_INDEX_WIDTH'(si);
        store_commit_sequence_i[lane]=ref_i.sq_sequence_q[si];
        store_commit_valid_i[lane]=($urandom_range(0,1)==0);
        sb_query_full_cover_i[lane]=($urandom_range(0,7)==0);
        sb_query_partial_i[lane]=!sb_query_full_cover_i[lane] && ($urandom_range(0,15)==0);
      end
      #1;compare();
      if(&ref_load_candidate_valid_o) dual_loads++;
      if(|ref_load_candidate_present_o && !(&ref_load_candidate_valid_o)) stalls++;
      agu_updates+=$countones(agu_valid_i & ref_agu_ready_o);
      allocations+=$countones(ref_dispatch_lq_valid_o);
      stores+=$countones(ref_dispatch_sq_valid_o);
      begin
        logic [SEQ_WIDTH-1:0] previous_sequence;
        previous_sequence=next_sequence;
        next_sequence+=SEQ_WIDTH'($countones(ref_dispatch_lq_valid_o | ref_dispatch_sq_valid_o)+$urandom_range(0,3));
        if(next_sequence<previous_sequence) wraps++;
      end
      @(posedge clk_i);#1;compare();
    end
    if(allocations<100 || stores<100 || agu_updates<100 || wraps<10 || dual_loads<1)
      $fatal(1,"insufficient stress coverage");
    $display("LSQ randomized reference equality PASS cycles={args.cycles} LQ={args.loads} SQ={args.stores} width={args.width} early={args.early} bypass={args.bypass}");
    $display("coverage allocations=%0d stores=%0d agu_updates=%0d flushes=%0d resets=%0d wraps=%0d dual_loads=%0d stalls=%0d",allocations,stores,agu_updates,flushes,resets,wraps,dual_loads,stalls);
    $finish;
  end
endmodule
"""


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--reference", default="081e714")
    parser.add_argument("--rtl", type=Path, help="Optional saved candidate RTL")
    parser.add_argument("--loads", type=int, default=24)
    parser.add_argument("--stores", type=int, default=16)
    parser.add_argument("--width", type=int, choices=(32, 64), default=32)
    parser.add_argument("--early", type=int, choices=(0, 1), default=1)
    parser.add_argument("--bypass", type=int, choices=(0, 1), default=1)
    parser.add_argument("--cycles", type=int, default=60000)
    parser.add_argument(
        "--qualified-commit-ready", action="store_true",
        help="Compare only valid-qualified commit-ready; compare every other output/state exactly. "
             "Use only for an intentional idle-ready availability contract change.",
    )
    parser.add_argument("--jobs", type=int, default=2)
    parser.add_argument("--verilator", default="verilator_bin.exe" if os.name == "nt" else "verilator")
    parser.add_argument("--make", default="make")
    parser.add_argument("--output", type=Path, default=Path("out/lsq_random_equivalence"))
    args = parser.parse_args()
    if args.loads < 2 or args.stores < 2 or args.cycles < 1000 or args.jobs < 1:
        parser.error("Invalid geometry/cycles/jobs")
    root = Path(os.path.abspath(__file__)).parent.parent
    verilator, make = shutil.which(args.verilator), shutil.which(args.make)
    if not verilator or not make:
        raise SystemExit("Verilator and GNU make required")
    commit = subprocess.check_output(["git", "rev-parse", "--verify", args.reference+"^{commit}"], cwd=root, text=True).strip()
    reference = subprocess.check_output(["git", "show", commit+":rtl/backend/rv_lsq.sv"], cwd=root, text=True, encoding="utf-8")
    actual_path = args.rtl.absolute() if args.rtl else root/"rtl/backend/rv_lsq.sv"
    actual = actual_path.read_text(encoding="utf-8")
    copies = {"pkg.sv": (root/"rtl/rv_ooo_pkg.sv").read_text(encoding="utf-8"), "candidate.sv": actual,
              "reference.sv": re.sub(r"\bmodule\s+rv_lsq\b", "module rv_lsq_reference", reference, count=1),
              "equiv_tb.sv": fixture(actual, reference, args)}
    output = args.output.absolute()
    if os.name == "nt" and not str(output).isascii():
        raise SystemExit("ASCII subst/output path required on Windows")
    output.mkdir(parents=True, exist_ok=True)
    for name, contents in copies.items():
        (output/name).write_text(contents, encoding="utf-8")
    report = dict(passed=False, status="running", reference_commit=commit,
                  parameters=dict(loads=args.loads, stores=args.stores, width=args.width, early=args.early, bypass=args.bypass, cycles=args.cycles),
                  rtl_sha256=hashlib.sha256(actual_path.read_bytes()).hexdigest(),
                  fixture_sha256={name: hashlib.sha256(contents.encode()).hexdigest() for name, contents in copies.items()},
                  qualified_commit_ready=args.qualified_commit_ready,
                  scope=("Seeded two-state random differential test; "
                         + ("commit-ready observed only while valid, all other outputs/original state exact; "
                            if args.qualified_commit_ready else "all-output/original-state exact; ")
                         + "protocol SVA disabled; not formal/ISA proof"))
    report_path = output/"report.json"
    report_path.write_text(json.dumps(report, indent=2)+"\n", encoding="utf-8")
    commands = [[verilator,"--cc","--exe","--main","--timing","-DSYNTHESIS","-Wno-fatal","-Werror-UNOPTFLAT","--top-module","lsq_random_equiv_tb","--Mdir","build",*copies],
                [make,"-j",str(args.jobs),"-C","build","-f","Vlsq_random_equiv_tb.mk","CXX=g++","CC=gcc","LINK=g++","VM_PARALLEL_BUILDS=1"],
                [str(output/"build"/("Vlsq_random_equiv_tb.exe" if os.name == "nt" else "Vlsq_random_equiv_tb"))]]
    for index, command in enumerate(commands):
        with (output/("result.log" if index==2 else f"build{index}.log")).open("w", encoding="utf-8") as log:
            result = subprocess.run(command, cwd=output, stdout=log, stderr=subprocess.STDOUT)
        if result.returncode:
            report.update(status="failed", failed_step=index, exit_code=result.returncode)
            report_path.write_text(json.dumps(report, indent=2)+"\n", encoding="utf-8")
            raise SystemExit(result.returncode)
    result_text = (output/"result.log").read_text(encoding="utf-8")
    if "LSQ randomized reference equality PASS" not in result_text:
        raise SystemExit("Missing completion marker")
    report.update(passed=True, status="passed", result=result_text)
    report_path.write_text(json.dumps(report, indent=2)+"\n", encoding="utf-8")
    print(result_text.split("- S i m")[0].strip())


if __name__ == "__main__":
    main()
