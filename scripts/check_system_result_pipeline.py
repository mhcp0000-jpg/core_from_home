#!/usr/bin/env python3
"""Test actual extracted system-result glue with the actual result FIFO.

Checks capture-once, volatile read retention, stalls, reset, payload fields,
sequence wrap and flush survival/drop. Synthetic head/CSR inputs are used;
full CSR, precise traps/IRQ and CoreMark remain separate regressions.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess


def sha(data):
    return hashlib.sha256(data).hexdigest()


def fixture(text, width, pipeline, negative):
    begin = text.index("  logic system_result_request_ready, system_result_valid;")
    end = text.index("  logic [XLEN-1:0] architectural_next_pc_q;", begin)
    declarations = text[begin:end]
    begin = text.index("  assign head_special_request =")
    end = text.index("\n\n  always_comb begin", begin)
    head_gate = text[begin:end]
    begin = text.index("  if (SYSTEM_RESULT_PIPELINE) begin : g_system_result_pipeline")
    end = text.index("\n  always_comb begin\n    source_valid='0", begin)
    block = text[begin:end]
    offer = "".join(line for line in text.splitlines() if "source_valid[10]=" in line)
    if not offer or "!flush_valid" not in offer:
        raise ValueError("Missing actual flush-qualified WB offer")
    offer = offer.replace("source_valid[10]", "wb_offer")
    if negative:
        needle = ".request_exception_tval_i(system_completion_tval)"
        if block.count(needle) != 1:
            raise ValueError("Missing actual tval corruption target")
        block = block.replace(needle, ".request_exception_tval_i(system_completion_tval ^ XLEN'(1))")
    return f"""module system_stage_tb;
timeunit 1ns; timeprecision 1ps;
import rv_ooo_pkg::*;
localparam int XLEN={width}, ROB_SEQ_WIDTH=8, PHYS_TAG_WIDTH=7;
localparam bit SYSTEM_RESULT_PIPELINE={int(pipeline)};
localparam int PACK_BITS=ROB_SEQ_WIDTH+1+$bits(reg_class_e)+PHYS_TAG_WIDTH+2*XLEN+1+$bits(exception_code_e);
logic clk_i=0, rst_ni=0;
always #5 clk_i=~clk_i;
logic head_special_request, head_is_special_instruction, rob_head_complete, rob_head_valid;
logic system_redirect_pending_q=0;
logic head_is_csr_instruction, head_is_fence, head_is_fence_i, fence_ready;
logic [ROB_SEQ_WIDTH-1:0] rob_head_sequence, fence_completion_sequence;
logic rob_head_writes_dst, csr_illegal;
reg_class_e rob_head_dst_class;
logic [PHYS_TAG_WIDTH-1:0] rob_head_dst_phys;
logic [XLEN-1:0] csr_rdata;
logic [10:0] source_ready;
logic flush_valid, flush_all;
logic [ROB_SEQ_WIDTH-1:0] flush_sequence;
logic system_completion_valid, system_completion_fire, system_completion_exception, csr_execute, wb_offer;
exception_code_e system_completion_cause;
logic [XLEN-1:0] system_completion_tval;
{declarations}
{head_gate}
assign head_is_special_instruction=rob_head_valid;
assign fence_completion_sequence=rob_head_sequence;
assign system_completion_valid=head_special_request &&
  (!(head_is_fence || head_is_fence_i) || fence_ready);
assign system_completion_fire=system_completion_valid && system_result_request_ready;
assign csr_execute=system_completion_fire && head_is_csr_instruction && !csr_illegal;
always_comb begin
{offer}
end
{block}
wire [PACK_BITS-1:0] observed={{system_result_sequence,system_result_dst_valid,
  system_result_dst_class,system_result_dst_phys,system_result_data,
  system_result_exception,system_result_cause,system_result_tval}};
wire [PACK_BITS-1:0] raw_packet={{rob_head_sequence,
  (head_is_csr_instruction && !csr_illegal && rob_head_writes_dst),
  (head_is_csr_instruction ? rob_head_dst_class : REG_NONE),rob_head_dst_phys,
  csr_rdata,system_completion_exception,system_completion_cause,system_completion_tval}};
logic expected_valid=0;
logic [PACK_BITS-1:0] expected_packet='0;
bit failed=0, new_head=1;
int execute_count=0, captures=0, deliveries=0, stalls=0, keeps=0, kills=0;
initial begin
  rob_head_sequence=0; rob_head_complete=0;rob_head_valid=0;
  head_is_csr_instruction=1;head_is_fence=0;head_is_fence_i=0;
  fence_ready=0;rob_head_writes_dst=0;csr_illegal=0;rob_head_dst_class=REG_INT;
  rob_head_dst_phys=0;csr_rdata=0;source_ready=0;flush_valid=0;flush_all=0;flush_sequence=0;
  system_completion_exception=0;system_completion_cause=EXC_ILLEGAL_INSTRUCTION;
  system_completion_tval=0;
  for(int cycle=0;cycle<4000;cycle++) begin
    bit push, pop, killed;
    logic [PACK_BITS-1:0] captured;
    @(negedge clk_i);
    rst_ni=(cycle>=3 && cycle%211!=0);
    if(new_head && rst_ni) begin
      rob_head_sequence=rob_head_sequence+1'b1;
      execute_count=0;new_head=0;
    end
    rob_head_valid=rst_ni;rob_head_complete=0;
    head_is_csr_instruction=(cycle%4==0);head_is_fence=(cycle%4==1);
    head_is_fence_i=(cycle%4==2);fence_ready=(cycle%7!=0);
    rob_head_writes_dst=$urandom;csr_illegal=$urandom;
    rob_head_dst_class=reg_class_e'($urandom);rob_head_dst_phys=$urandom;
    csr_rdata=XLEN'({{$urandom,$urandom}}); // Changes while WB is stalled.
    system_completion_exception=$urandom;
    system_completion_cause=exception_code_e'($urandom);
    system_completion_tval=XLEN'({{$urandom,$urandom}});
    source_ready='0;source_ready[10]=(cycle%13>=5);
    flush_valid=(cycle%47==17 || cycle%101==39);
    flush_all=(cycle%101==39);
    flush_sequence=rob_head_sequence+ROB_SEQ_WIDTH'((cycle%2) ? 2 : -2);
    if(flush_valid) source_ready[10]=1; // Must not pop/offer on this edge.
    #1;
    if(rst_ni) begin
      if(SYSTEM_RESULT_PIPELINE && (system_result_valid!==expected_valid ||
         (expected_valid && observed!==expected_packet))) begin
        $display("FAIL system stage payload/valid cycle=%0d",cycle);failed=1;break;
      end
      if(!SYSTEM_RESULT_PIPELINE && (system_result_valid!==system_completion_valid || observed!==raw_packet)) begin
        $display("FAIL system direct fallback cycle=%0d",cycle);failed=1;break;
      end
      if(flush_valid && (wb_offer || system_completion_fire || csr_execute)) begin
        $display("FAIL system flush transfer cycle=%0d",cycle);failed=1;break;
      end
      if(csr_execute) begin
        execute_count++;
        if(execute_count>1) begin $display("FAIL repeated CSR execute cycle=%0d",cycle);failed=1;break;end
      end
      if(expected_valid && !source_ready[10] && !flush_valid) stalls++;
    end
    push=rst_ni && system_completion_fire;
    pop=rst_ni && wb_offer && source_ready[10];
    captured=raw_packet;
    killed=flush_valid && (flush_all ||
      (!((rob_head_sequence-flush_sequence)&8'h80) && rob_head_sequence!=flush_sequence));
    @(posedge clk_i);#1;
    if(!rst_ni) begin
      expected_valid=0;expected_packet=0;new_head=1;execute_count=0;
      if(SYSTEM_RESULT_PIPELINE && (system_result_valid || observed!='0)) begin
        $display("FAIL system reset payload cycle=%0d",cycle);failed=1;break;
      end
    end else if(SYSTEM_RESULT_PIPELINE) begin
      if(flush_valid) begin
        if(killed) begin if(expected_valid) kills++;expected_valid=0;new_head=1;end
        else if(expected_valid) keeps++;
      end else begin
        if(pop) begin expected_valid=0;new_head=1;deliveries++;end
        if(push) begin
          if(expected_valid) begin $display("FAIL duplicate system ingress");failed=1;break;end
          expected_valid=1;expected_packet=captured;captures++;
        end
      end
    end else if(pop || killed) begin new_head=1;deliveries+=int'(pop);end
  end
  if(!failed && SYSTEM_RESULT_PIPELINE && (captures<100 || deliveries<100 || stalls==0 || keeps==0 || kills==0)) begin
    $display("FAIL system stimulus coverage");failed=1;
  end
  if(!failed) $display("PASS system stage XLEN=%0d PIPE=%0d captures=%0d deliveries=%0d stalls=%0d keeps=%0d kills=%0d",
    XLEN,SYSTEM_RESULT_PIPELINE,captures,deliveries,stalls,keeps,kills);
  $finish;
end
endmodule
"""


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source",type=Path,required=True)
    parser.add_argument("--out",type=Path,required=True)
    parser.add_argument("--verilator",type=Path,required=True)
    parser.add_argument("--devkit",type=Path,required=True)
    args=parser.parse_args()
    out=args.out.absolute();out.mkdir(parents=True,exist_ok=True)
    if os.name=="nt" and not str(out).isascii(): parser.error("Use an owned ASCII alias")
    backend=args.source/"rtl/backend/rv_backend.sv"
    buffer=args.source/"rtl/backend/rv_exec_result_buffer.sv"
    package=args.source/"rtl/rv_ooo_pkg.sv"
    raw=backend.read_bytes();text=raw.decode("utf-8-sig").replace("\r\n","\n")
    report=dict(passed=False,backend_sha256=sha(raw),buffer_sha256=sha(buffer.read_bytes()),
      package_sha256=sha(package.read_bytes()),cases=[],
      scope="Actual extracted system glue + actual FIFO with synthetic head/CSR inputs; reset/payload/stall/capture-once/flush/wrap; NOT full CSR/backend/ISA/IEEE-X/STA")
    env=os.environ.copy();env["VERILATOR_ROOT"]=str(args.verilator.parent.parent)
    env["PATH"]=str(args.devkit/"bin")+os.pathsep+env.get("PATH","")
    for width,pipeline,negative in [(32,False,False),(32,True,False),(64,False,False),(64,True,False),(32,True,True)]:
        run=out/f"x{width}_p{int(pipeline)}_negative{int(negative)}";run.mkdir(exist_ok=True)
        emitted=fixture(text,width,pipeline,negative)
        (run/"tb.sv").write_text(emitted,encoding="utf-8")
        steps=[([str(args.verilator),"--cc","--exe","--main","--timing","--assert","-Wno-fatal",
          "--top-module","system_stage_tb","--Mdir",str(run/"build"),str(package),str(buffer),str(run/"tb.sv")],"compile.log"),
          ([str(args.devkit/"bin/make.exe"),"-j","1","-C",str(run/"build"),"-f","Vsystem_stage_tb.mk","CXX=g++","CC=gcc","LINK=g++","VM_PARALLEL_BUILDS=1"],"build.log")]
        for command,logname in steps:
            with (run/logname).open("w",encoding="utf-8") as log:
                result=subprocess.run(command,env=env,stdout=log,stderr=subprocess.STDOUT,timeout=180)
            if result.returncode: raise RuntimeError(f"Unit build failed: {run/logname}")
        with (run/"result.log").open("w",encoding="utf-8") as log:
            result=subprocess.run([str(run/"build/Vsystem_stage_tb.exe")],env=env,stdout=log,stderr=subprocess.STDOUT,timeout=30)
        transcript=(run/"result.log").read_text(encoding="utf-8",errors="replace")
        passed=(result.returncode==0 and "FAIL system stage payload" in transcript and "PASS system stage" not in transcript) if negative else (
          result.returncode==0 and "PASS system stage" in transcript and "FAIL " not in transcript)
        report["cases"].append(dict(xlen=width,pipeline=pipeline,negative=negative,passed=passed,native_exit=result.returncode,
          fixture_sha256=sha(emitted.encode()),negative_detection="mismatch marker with clean native0, NOT native1" if negative else None))
        (out/"report.json").write_text(json.dumps(report,indent=2)+"\n",encoding="utf-8")
        if not passed: raise RuntimeError(f"Unexpected system-stage result: {run}")
        print(f"PASS actual system glue XLEN={width} PIPE={pipeline} negative={negative}",flush=True)
    report["passed"]=True;(out/"report.json").write_text(json.dumps(report,indent=2)+"\n",encoding="utf-8")


if __name__=="__main__": main()
