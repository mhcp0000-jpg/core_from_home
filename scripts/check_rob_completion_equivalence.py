#!/usr/bin/env python3
"""Cycle-compare ROB storage/completions with immutable native RTL.

Builds generated fixtures only below out/. Checks all original public outputs
and every ROB state bit, not an independent ISA or unbounded formal proof.
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
    header = source.split(") (", 1)[1].split(");", 1)[0]
    header = re.sub(r"//[^\n]*", "", header)
    result = []
    for item in header.split(","):
        match = re.fullmatch(r"\s*(input|output)\s+(.+?)\s+(\w+)\s*", item, re.S)
        if not match:
            raise ValueError(f"Unsupported port declaration: {item}")
        result.append((match[1], " ".join(match[2].split()), match[3]))
    return result


def fixture(current, reference, width, entries, cycles):
    current_ports, reference_ports = ports(current), ports(reference)
    originals = {name for _, _, name in reference_ports}
    extras = {name for _, _, name in current_ports} - originals
    masked = extras == {"complete_entry_mask_i", "live_query_entry_o"}
    if extras and not masked:
        raise ValueError(f"Unexpected ROB interface delta: {extras}")
    declarations, stimulus, checks = [], [], []
    for direction, kind, name in current_ports:
        declarations.append(f"typedef {kind} type_{name};")
        if direction == "input":
            declarations.append(f"type_{name} {name};")
            if name not in ("clk_i", "rst_ni", "complete_entry_mask_i"):
                stimulus.append(f"{name}=type_{name}'({{8{{$urandom}}}});")
        else:
            declarations.append(f"type_{name} dut_{name};")
            if name in originals:
                declarations.append(f"type_{name} ref_{name};")
                checks.append(f'if (dut_{name} !== ref_{name}) $fatal(1,"{name} cycle=%0d",cycle);')
    def instance(module, prefix, masked, port_list):
        parameters = ".XLEN(XLEN),.ROB_ENTRIES(ROB_ENTRIES),.SEQ_WIDTH(SEQ_WIDTH),.COMPLETE_PORTS(COMPLETE_PORTS),.LIVE_QUERY_PORTS(LIVE_QUERY_PORTS)"
        if masked:
            parameters += ",.COMPLETE_ENTRY_MASK(1)"
        connections = [f".{name}({name if direction=='input' else prefix+'_'+name})"
                       for direction, _, name in port_list]
        return f"{module} #({parameters}) {prefix}_i({','.join(connections)});"
    mask_connections = """
  for (genvar port=0; port<COMPLETE_PORTS; port++) begin
    assign complete_entry_mask_i[port]=dut_live_query_entry_o[port];
  end
""" if masked else ""
    return f"""
module rob_completion_equiv_tb;
  import rv_ooo_pkg::*;
  localparam int XLEN={width}, ROB_ENTRIES={entries}, SEQ_WIDTH=8;
  localparam int PHYS_TAG_WIDTH=7, LQ_INDEX_WIDTH=5, SQ_INDEX_WIDTH=4;
  localparam int COMPLETE_PORTS=4, LIVE_QUERY_PORTS=8;
  localparam int ROB_INDEX_WIDTH=$clog2(ROB_ENTRIES), ROB_COUNT_WIDTH=$clog2(ROB_ENTRIES+1);
  {chr(10).join(declarations)}
  {instance('rv_rob', 'dut', masked, current_ports)}
  {instance('rv_rob_reference', 'ref', False, reference_ports)}
  {mask_connections}
  always #5 clk_i=~clk_i;
  int cycle, seed, allocation_cycles, completion_cycles, selective_flushes, resets, wraps;
  logic [SEQ_WIDTH-1:0] last_sequence;
  task automatic compare;
    {chr(10).join(checks)}
    if (dut_i.head_q !== ref_i.head_q || dut_i.tail_q !== ref_i.tail_q ||
        dut_i.count_q !== ref_i.count_q || dut_i.next_sequence_q !== ref_i.next_sequence_q)
      $fatal(1,"ROB cursor/generation state differs cycle=%0d",cycle);
    for (int entry=0; entry<ROB_ENTRIES; entry++)
      if (dut_i.entries_q[entry] !== ref_i.entries_q[entry])
        $fatal(1,"ROB entry %0d state differs cycle=%0d",entry,cycle);
  endtask
  initial begin
    clk_i=0; rst_ni=0; seed=32'h4513a201; void'($urandom(seed));
    allocation_cycles=0; completion_cycles=0; selective_flushes=0; resets=0; wraps=0;
    last_sequence='0;
    // Both models start with synchronous reset, including every payload FF.
    {chr(10).join(stimulus)}
    alloc_valid_i=0; complete_valid_i=0; flush_younger_i=0; flush_all_i=0; trap_ready_i=0;
    live_query_sequence_i='0;
    repeat (2) @(posedge clk_i);
    #1; compare();
    for (cycle=0; cycle<{cycles}; cycle++) begin
      @(negedge clk_i);
      {chr(10).join(stimulus)}
      rst_ni=(cycle%997)!=0;
      if (!rst_ni) resets++;
      alloc_valid_i=($urandom_range(0,3)==0)?2'b00:
        (($urandom_range(0,1)==0)?2'b01:2'b11);
      alloc_complete_i &= type_alloc_complete_i'($urandom_range(0,3)==0 ? 3 : 0);
      alloc_exception_valid_i &= type_alloc_exception_valid_i'($urandom_range(0,23)==0 ? 3 : 0);
      flush_all_i=($urandom_range(0,181)==0);
      flush_younger_i=0;
      trap_ready_i=ref_trap_valid_o && ($urandom_range(0,3)==0);
      if (trap_ready_i) flush_all_i=1;
      if (!flush_all_i && ($urandom_range(0,7)==0)) begin
        int start;
        start=$urandom_range(0,ROB_ENTRIES-1);
        for (int step=0; step<ROB_ENTRIES; step++) begin
          int entry;
          entry=(start+step)%ROB_ENTRIES;
          if (!flush_younger_i && ref_i.entries_q[entry].valid) begin
            flush_younger_i=1; flush_sequence_i=ref_i.entries_q[entry].sequence_id;
          end
        end
      end
      // Complete live, stale or duplicated generations out of program order.
      for (int port=0; port<COMPLETE_PORTS; port++) begin
        int entry;
        entry=$urandom_range(0,ROB_ENTRIES-1);
        if (ref_i.entries_q[entry].valid && ($urandom_range(0,3)!=0))
          complete_sequence_i[port]=ref_i.entries_q[entry].sequence_id;
        if (port>0 && $urandom_range(0,7)==0)
          complete_sequence_i[port]=complete_sequence_i[0];
        complete_exception_valid_i[port] &= ($urandom_range(0,19)==0);
        live_query_sequence_i[port]=complete_sequence_i[port];
      end
      #1; compare();
      if (alloc_valid_i!=0 && dut_alloc_ready_o) allocation_cycles++;
      if (complete_valid_i!=0) completion_cycles++;
      if (flush_younger_i) selective_flushes++;
      if (dut_alloc_sequence_o[0]<last_sequence && rst_ni) wraps++;
      last_sequence=dut_alloc_sequence_o[0];
      @(posedge clk_i); #1; compare();
    end
    if (allocation_cycles<1000 || completion_cycles<1000 || selective_flushes<100 || wraps<10)
      $fatal(1,"Insufficient stimulus coverage");
    $display("ROB full-output/state equality PASS XLEN=%0d ENTRIES=%0d cycles=%0d alloc=%0d completion=%0d selective=%0d resets=%0d wraps=%0d",
      XLEN,ROB_ENTRIES,cycle,allocation_cycles,completion_cycles,selective_flushes,resets,wraps);
    $finish;
  end
endmodule
"""


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--reference", default="081e714")
    parser.add_argument("--rtl", type=Path, help="Saved same-interface or entry-mask ROB candidate; default is working-tree RTL")
    parser.add_argument("--width", type=int, choices=(32, 64), default=32)
    parser.add_argument("--entries", type=int, choices=(4, 7, 48), default=48)
    parser.add_argument("--cycles", type=int, default=60000)
    parser.add_argument("--jobs", type=int, default=4)
    parser.add_argument("--resume", action="store_true", help="Reuse matching generated C++ after an interrupted build")
    parser.add_argument("--verilator-root", type=Path,
                        default=Path("C:/rv_toolchains/verilator-5.050") if os.name=="nt" else None)
    parser.add_argument("--verilator", default="verilator")
    parser.add_argument("--make", default="C:/rv_toolchains/w64devkit-2.9.1/w64devkit/bin/make.exe" if os.name=="nt" else "make")
    parser.add_argument("--output", type=Path, default=Path("out/rob_completion_equivalence"))
    args = parser.parse_args()
    if args.cycles<10000 or args.jobs<1:
        parser.error("cycles>=10000 and jobs>=1 required")
    root = Path(os.path.abspath(__file__)).parent.parent
    commit = subprocess.check_output(["git", "rev-parse", "--verify", args.reference+"^{commit}"], cwd=root, text=True).strip()
    reference = subprocess.check_output(["git", "show", commit+":rtl/backend/rv_rob.sv"], cwd=root, text=True, encoding="utf-8")
    reference = re.sub(r"\bmodule\s+rv_rob\b", "module rv_rob_reference", reference, count=1)
    current_path = args.rtl.absolute() if args.rtl else root/"rtl/backend/rv_rob.sv"
    current = current_path.read_text(encoding="utf-8")
    output = args.output.absolute()
    output.mkdir(parents=True, exist_ok=True)
    testbench = fixture(current, reference, args.width, args.entries, args.cycles)
    report = dict(passed=False, status="running", reference_commit=commit, width=args.width,
                  entries=args.entries, cycles=args.cycles,
                  rtl_sha256=hashlib.sha256(current_path.read_bytes()).hexdigest(),
                  rtl_path=str(current_path),
                  package_sha256=hashlib.sha256((root/"rtl/rv_ooo_pkg.sv").read_bytes()).hexdigest(),
                  tb_sha256=hashlib.sha256(testbench.encode()).hexdigest(),
                  scope="All original outputs and internal state; finite cycle equivalence, not ISA/formal proof")
    reuse = False
    if args.resume and (output/"report.json").exists():
        previous = json.loads((output/"report.json").read_text(encoding="utf-8"))
        reuse = all(previous.get(key)==report[key] for key in
                    ("reference_commit", "width", "entries", "cycles", "rtl_sha256", "rtl_path", "package_sha256", "tb_sha256"))
        reuse = reuse and (output/"reference.sv").is_file() and (output/"miter.sv").is_file()
        reuse = reuse and (output/"reference.sv").read_text(encoding="utf-8")==reference
        reuse = reuse and (output/"miter.sv").read_text(encoding="utf-8")==testbench
        reuse = reuse and (output/"obj/Vrob_completion_equiv_tb.mk").exists()
    if not reuse:
        (output/"reference.sv").write_text(reference, encoding="utf-8")
        (output/"miter.sv").write_text(testbench, encoding="utf-8")
    def command(argv, name):
        with (output/name).open("w", encoding="utf-8") as log:
            subprocess.run(argv, cwd=output, env=environment, stdout=log, stderr=subprocess.STDOUT, check=True)
    environment = os.environ.copy()
    if args.verilator_root:
        environment["VERILATOR_ROOT"] = str(args.verilator_root.absolute())
        verilator = args.verilator_root/("bin/verilator_bin.exe" if os.name=="nt" else "bin/verilator")
    else:
        verilator = shutil.which(args.verilator)
    make = shutil.which(args.make)
    if not verilator or not Path(verilator).is_file() or not make:
        raise SystemExit("Verilator/make not found; pass --verilator-root or --verilator/--make")
    environment["PATH"] = str(Path(make).absolute().parent)+os.pathsep+environment.get("PATH", "")
    try:
        (output/"report.json").write_text(json.dumps(report, indent=2)+"\n", encoding="utf-8")
        if not reuse:
            command([str(verilator), "--cc", "--exe", "--main", "--timing", "--assert", "-Wno-fatal", "-Werror-UNOPTFLAT",
                     "--top-module", "rob_completion_equiv_tb", "--Mdir", "obj", str(root/"rtl/rv_ooo_pkg.sv").replace("\\","/"),
                     str(current_path).replace("\\","/"), "reference.sv", "miter.sv"], "build.log")
        command([make, "-j"+str(args.jobs), "-C", "obj", "-f", "Vrob_completion_equiv_tb.mk",
                 "CXX=g++", "CC=gcc", "LINK=g++", "VM_PARALLEL_BUILDS=1"], "make.log")
        command([str(output/("obj/Vrob_completion_equiv_tb.exe" if os.name=="nt" else "obj/Vrob_completion_equiv_tb"))], "result.log")
        result = (output/"result.log").read_text(encoding="utf-8")
        if "ROB full-output/state equality PASS" not in result:
            raise RuntimeError("Missing successful comparison marker")
        report.update(passed=True, status="passed")
        print(result.splitlines()[0])
    finally:
        if not report["passed"]:
            report["status"]="failed"
        (output/"report.json").write_text(json.dumps(report, indent=2)+"\n", encoding="utf-8")


if __name__ == "__main__":
    main()
