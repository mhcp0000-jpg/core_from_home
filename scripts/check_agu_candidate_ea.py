#!/usr/bin/env python3
"""Prove actual candidate-parallel EA routing preserves modulo-XLEN address.

All two-candidate operands and both LSU-port choices are arbitrary binary.
Check copied carry-select helper identity, on/off routing and exact restoration
of every other backend line. Not IEEE-X/fullcore/ISA/STA signoff.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess


def sha(data): return hashlib.sha256(data).hexdigest()


def main():
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('--source',type=Path,required=True)
    p.add_argument('--reference',type=Path,required=True)
    p.add_argument('--out',type=Path,required=True)
    p.add_argument('--yosys',type=Path,required=True)
    a=p.parse_args()
    cpath=a.source/'rtl/backend/rv_backend.sv';rpath=a.reference/'rtl/backend/rv_backend.sv'
    raw,oldraw=cpath.read_bytes(),rpath.read_bytes()
    c=raw.decode('utf-8-sig').replace('\r\n','\n');r=oldraw.decode('utf-8-sig').replace('\r\n','\n')
    pipe=(a.source/'rtl/backend/rv_lsu_pipe.sv').read_text(encoding='utf-8-sig').replace('\r\n','\n')
    helper=re.search(r'  function automatic logic \[XLEN-1:0\] lsu_candidate_address_add\(.*?  endfunction',c,re.S)[0]
    original_helper=re.search(r'  function automatic logic \[XLEN-1:0\] address_add\(.*?  endfunction',pipe,re.S)[0]
    if helper.replace('lsu_candidate_address_add','address_add')!=original_helper:
        raise ValueError('Precomputed arithmetic differs from original AGU helper')
    gen=re.search(r'  for \(genvar candidate=0; candidate<2; candidate\+\+\) begin : g_lsu_candidate_ea.*?\n  end\n',c,re.S)[0]
    begin=c.index('      if (AGU_EA_PRECOMPUTE) begin');end=c.index('      lsu_issue_store_data[lane]',begin)
    route=c[begin:end]
    old_route=('      lsu_issue_base[lane] = cand_operand0[port_candidate[2+lane]];\n'
               '      lsu_issue_immediate[lane] = cand_immediate[port_candidate[2+lane]];\n')
    begin=r.index(old_route);assert begin>=0
    restored=c.replace(route,old_route,1)
    removed=("  logic [1:0][XLEN-1:0] lsu_candidate_ea;\n"
      "  // Same modulo-XLEN grouped carry-select helper as the original AGU.\n"+helper+'\n'+gen+'\n')
    if restored.count(removed)!=1: raise ValueError('Unexpected candidate sum block')
    restored=restored.replace(removed,'',1)
    param='  parameter bit AGU_EA_PRECOMPUTE = rv_ooo_pkg::CORE_CFG_AGU_EA_PRECOMPUTE,\n'
    if restored.count(param)!=1: raise ValueError('Unexpected early-EA parameter')
    restored=restored.replace(param,'',1)
    new_sva=('        (lsu_candidate_address_add(lsu_issue_base[lane], lsu_issue_immediate[lane]) ==\n'
             '         lsu_candidate_address_add(port_operand0[2+lane], port_immediate[2+lane])));')
    old_sva=('        (lsu_issue_base[lane] == port_operand0[2+lane]) &&\n'
             '        (lsu_issue_immediate[lane] == port_immediate[2+lane]));')
    if restored.count(new_sva)!=1: raise ValueError('Changed route assertion not recognized')
    restored=restored.replace(new_sva,old_sva,1)
    if restored!=r: raise ValueError('Unproved unrelated backend change')
    for filename in ['rtl/rv_ooo_pkg.sv','rtl/rv_ooo_core.sv']:
        current=(a.source/filename).read_text(encoding='utf-8-sig').replace('\r\n','\n')
        before=(a.reference/filename).read_text(encoding='utf-8-sig').replace('\r\n','\n')
        if filename.endswith('pkg.sv'):
            addition=("  // Compute each IQ candidate's EA before selecting its LSU port. No extra\n"
              "  // cycle; the unchanged AGU receives {base=selected EA, immediate=0}.\n"
              "  localparam bit CORE_CFG_AGU_EA_PRECOMPUTE = 1'b1;\n")
            if current.count(addition)!=1: raise ValueError('Unreported PKG change')
            current=current.replace(addition,'',1)
        else:
            current=current.replace(param,'',1).replace('    .AGU_EA_PRECOMPUTE(AGU_EA_PRECOMPUTE),\n','',1)
        if current!=before: raise ValueError('Unrelated top/package change')
    out=a.out.absolute();out.mkdir(parents=True,exist_ok=True)
    if os.name=='nt' and not str(out).isascii(): p.error('Use owned ASCII alias')
    env=os.environ.copy();env['PATH']=str(a.yosys.parent)+os.pathsep+str(a.yosys.parent.parent/'lib')+os.pathsep+env.get('PATH','')
    report=dict(passed=False,backend_sha256=sha(raw),reference_sha256=sha(oldraw),helper_identity=True,
      remaining_backend_restored=True,top_package_only_explicit_option=True,cases=[],
      scope='Actual modulo-XLEN two-candidate sum+LSU routing, arbitrary binary operands/port choices, on/off, restoration; NOT IEEE-X/fullcore/ISA/STA')
    for width,enabled,negative in [(32,False,False),(32,True,False),(64,False,False),(64,True,False),(32,True,True)]:
        run=out/f'x{width}_e{int(enabled)}_negative{int(negative)}';run.mkdir(exist_ok=True)
        actual=route
        if negative:
            needle='lsu_candidate_ea[port_candidate[2+lane]];'
            if actual.count(needle)!=1: raise ValueError('Missing actual port-select corruption target')
            actual=actual.replace(needle,'lsu_candidate_ea[!port_candidate[2+lane]];',1)
        fixture=f"""module candidate_ea_miter #(parameter int XLEN={width}, AGU_EA_PRECOMPUTE={int(enabled)})(
input logic [1:0][XLEN-1:0] cand_operand0,cand_immediate,
input logic [4:0] port_candidate,output logic equal_o);
logic [1:0][XLEN-1:0] lsu_candidate_ea,lsu_issue_base,lsu_issue_immediate;
logic [1:0] same;
{helper}
{gen}
always_comb begin
  for(int unsigned lane=0;lane<2;lane++) begin
{actual}
    same[lane]=(lsu_candidate_address_add(lsu_issue_base[lane],lsu_issue_immediate[lane])==
      (cand_operand0[port_candidate[2+lane]]+cand_immediate[port_candidate[2+lane]]));
  end
end
assign equal_o=&same;
endmodule
"""
        (run/'miter.sv').write_text(fixture,encoding='utf-8')
        (run/'proof.ys').write_text('read_slang --top candidate_ea_miter miter.sv\nprep -top candidate_ea_miter\nflatten\ntechmap\nopt\nsat -verify -prove equal_o 1 -timeout 90\n',encoding='utf-8')
        with (run/'proof.log').open('w',encoding='utf-8') as log:
            result=subprocess.run([str(a.yosys),'-Q','-T','-s','proof.ys'],cwd=run,env=env,stdout=log,stderr=subprocess.STDOUT,timeout=120)
        transcript=(run/'proof.log').read_text(encoding='utf-8',errors='replace')
        passed=(result.returncode!=0 and 'proof did fail' in transcript) if negative else (
          result.returncode==0 and 'no model found: SUCCESS!' in transcript)
        report['cases'].append(dict(xlen=width,enabled=enabled,negative=negative,passed=passed,native_exit=result.returncode,fixture_sha256=sha(fixture.encode())))
        (out/'report.json').write_text(json.dumps(report,indent=2)+'\n',encoding='utf-8')
        if not passed: raise RuntimeError(f'Unexpected candidate-EA proof: {run}')
        print(f'PASS candidate EA XLEN={width} ENABLE={enabled} negative={negative}',flush=True)
    report['passed']=True;(out/'report.json').write_text(json.dumps(report,indent=2)+'\n',encoding='utf-8')


if __name__=='__main__': main()
