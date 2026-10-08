#!/usr/bin/env python3
"""Partition proof of IQ store-phase FF update, with unchanged-RTL guard.

Checks binary next-state equivalence, including arbitrary/OOB indices. The
candidate's actual constant-row update block is extracted, not reimplemented.
Not an independent ISA, four-state, or timing proof. Generated files: out/ only.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--rtl', type=Path, required=True)
    parser.add_argument('--reference', default='e9d135b')
    parser.add_argument('--yosys', default='C:/rv_toolchains/oss-cad-suite/bin/yosys.exe')
    parser.add_argument('--output', type=Path, default=Path('out/iq_store_phase_formal'))
    args = parser.parse_args()
    root = Path(__file__).absolute().parent.parent
    reference = subprocess.check_output(
        ['git', 'show', args.reference+':rtl/backend/rv_issue_queue.sv'],
        cwd=root, text=True, encoding='utf-8')
    candidate = args.rtl.read_text(encoding='utf-8')
    start = candidate.index('  // Each phase bit has a constant write address.')
    end = candidate.index('  always_comb begin\n    // PROTOTYPE: balanced popcount tree.', start)
    block = candidate[start:end]
    original = reference.replace("        store_address_issued_q[entry] <= 1'b0;\n", '')
    original = original.replace("          else\n            store_address_issued_q[candidate_index_o[slot]] <= 1'b1;\n", '')
    original = original.replace("            store_address_issued_q[dispatch_index_o[lane]] <= 1'b0;\n", '')
    if original != candidate[:start]+candidate[end:]:
        raise ValueError('Other IQ RTL changed: partition proof is not sufficient')
    if len(re.findall(r'store_address_issued_q\[[^\n]+<=', reference)) != 3:
        raise ValueError('Reference phase write layout changed')
    gate_body = block[block.index('  for (genvar'):]
    gate_body = gate_body.replace('always_ff @(posedge clk_i) begin',
        'always_comb begin\n      phase_next_o[entry] = phase_i[entry];')
    gate_body = gate_body.replace('store_address_issued_q[entry]', 'phase_next_o[entry]').replace(' <= ', ' = ')
    output = args.output.absolute()
    output.mkdir(parents=True, exist_ok=True)
    environment = os.environ.copy()
    tool = Path(args.yosys).absolute()
    environment['PATH'] = str(tool.parent)+os.pathsep+str(tool.parent.parent/'lib')+os.pathsep+environment.get('PATH', '')
    cases = []
    for entries, slots, negative in [(4,1,False),(7,2,False),(56,2,False),(64,2,False),(7,2,True)]:
        name = f'e{entries}_s{slots}'+('_negative' if negative else '')
        idx = (entries-1).bit_length()
        header = f'''#(parameter ENTRIES={entries}, SELECT_WIDTH={slots}, INDEX_WIDTH={idx}) (
          input logic [ENTRIES-1:0] phase_i,
          input logic rst_ni,flush_all_i,flush_younger_i,dispatch_fire,
          input logic [SELECT_WIDTH-1:0] candidate_valid_o,candidate_accept_i,candidate_final_phase,
          input logic [SELECT_WIDTH-1:0][INDEX_WIDTH-1:0] candidate_index_o,
          input logic [1:0] dispatch_valid_i,
          input logic [1:0][INDEX_WIDTH-1:0] dispatch_index_o,
          output logic [ENTRIES-1:0] phase_next_o);'''
        gold = f'''module gold {header}
          logic store_address_issued_q [0:ENTRIES-1];
          always_comb begin
            for(int entry=0;entry<ENTRIES;entry++) store_address_issued_q[entry]=phase_i[entry];
            if(!rst_ni || flush_all_i) begin
              for(int entry=0;entry<ENTRIES;entry++) store_address_issued_q[entry]=1'b0;
            end else if(flush_younger_i) begin end else begin
              for(int slot=0;slot<SELECT_WIDTH;slot++)
                if(candidate_valid_o[slot] && candidate_accept_i[slot]) begin
                  if(!candidate_final_phase[slot]) store_address_issued_q[candidate_index_o[slot]]=1'b1;
                end
              if(dispatch_fire)
                for(int lane=0;lane<2;lane++)
                  if(dispatch_valid_i[lane]) store_address_issued_q[dispatch_index_o[lane]]=1'b0;
            end
            for(int entry=0;entry<ENTRIES;entry++) phase_next_o[entry]=store_address_issued_q[entry];
          end
        endmodule'''
        gate = f'module gate {header}\n{gate_body}\nendmodule'
        if negative:
            gate = gate.replace("phase_next_o[entry] = 1'b1;", "phase_next_o[entry] = 1'b0;")
        miter_header = header.replace('output logic [ENTRIES-1:0] phase_next_o', 'output logic equal_o')
        connections = '.phase_i(phase_i),.rst_ni(rst_ni),.flush_all_i(flush_all_i),.flush_younger_i(flush_younger_i),.dispatch_fire(dispatch_fire),.candidate_valid_o(candidate_valid_o),.candidate_accept_i(candidate_accept_i),.candidate_final_phase(candidate_final_phase),.candidate_index_o(candidate_index_o),.dispatch_valid_i(dispatch_valid_i),.dispatch_index_o(dispatch_index_o)'
        fixture = gold+'\n'+gate+f'''\nmodule miter {miter_header}
          logic [ENTRIES-1:0] a,b;
          gold g({connections},.phase_next_o(a)); gate c({connections},.phase_next_o(b));
          assign equal_o=(a==b);
        endmodule'''
        (output/(name+'.sv')).write_text(fixture, encoding='utf-8')
        command = f'read_slang --top miter {name}.sv; prep -top miter -flatten; sat -prove equal_o 1 -verify -show-inputs'
        with (output/(name+'.log')).open('w', encoding='utf-8') as log:
            result = subprocess.run([str(tool),'-Q','-T','-p',command],cwd=output,env=environment,
                                    stdout=log,stderr=subprocess.STDOUT,timeout=120)
        content = (output/(name+'.log')).read_text(encoding='utf-8')
        passed = (result.returncode != 0 and 'proof did fail' in content) if negative else (
            result.returncode == 0 and 'SUCCESS!' in content)
        cases.append(dict(name=name,passed=passed,actualExitCode=result.returncode,negative=negative))
        print(name, 'PASS' if passed else 'FAILED', flush=True)
    report = dict(passed=all(case['passed'] for case in cases),cases=cases,
                  candidateSha256=hashlib.sha256(args.rtl.read_bytes()).hexdigest(),
                  reference=args.reference,unchangedRemainingRtl=True,
                  scope='Actual row-update binary next-state partition + remaining RTL text identity; NOT 4-state/ISA/STA')
    (output/'report.json').write_text(json.dumps(report,indent=2)+'\n',encoding='utf-8')
    if not report['passed']:
        raise SystemExit(1)


if __name__ == '__main__':
    main()
