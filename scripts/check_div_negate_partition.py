"""Prove the exact DIV negate helper, with unchanged remaining RTL guard.

All binary inputs at widths32/64 plus a mandatory wrong-bit negative control.
This is a compositional arithmetic proof, not ISA/IEEE-X/physical STA signoff.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--rtl',type=Path,required=True)
    parser.add_argument('--reference',default='e9d135b')
    parser.add_argument('--yosys',required=True)
    parser.add_argument('--output',type=Path,required=True)
    args=parser.parse_args()
    root=Path(__file__).absolute().parent.parent
    source=args.rtl.read_text(encoding='utf-8')
    commit=subprocess.check_output(['git','rev-parse',args.reference+'^{commit}'],cwd=root,text=True).strip()
    reference=subprocess.check_output(['git','show',commit+':rtl/backend/rv_divider.sv'],cwd=root,text=True)
    helper=re.search(r'  // -value modulo.*?  endfunction\n\n',source,re.S)
    if not helper: raise ValueError('Missing exact helper block')
    function=re.search(r'function automatic logic \[XLEN-1:0\] prefix_negate\(.*?endfunction',helper.group(),re.S).group()
    restored=source[:helper.start()]+source[helper.end():]
    for value in ('operand_a_effective','operand_b_effective','quotient_next','reduced_remainder[XLEN-1:0]'):
        target=f'prefix_negate({value})'
        if restored.count(target)!=1: raise ValueError('Unexpected helper call count')
        restored=restored.replace(target,f'(~{value} + 1\'b1)')
    if re.sub(r'\s+','',restored)!=re.sub(r'\s+','',reference):
        raise ValueError('Remaining interface/state/transport/arithmetic changed')
    output=args.output.absolute()
    if not output.is_relative_to(root): raise ValueError('Output must stay below workspace')
    output.mkdir(parents=True,exist_ok=True)
    yosys=shutil.which(args.yosys)
    if not yosys: raise ValueError('Missing Yosys')
    env=os.environ.copy()
    env['PATH']=str(Path(yosys).parent.parent/'lib')+os.pathsep+env.get('PATH','')
    record=dict(passed=False,reference=commit,source_sha256=hashlib.sha256(args.rtl.read_bytes()).hexdigest(),
                remaining_rtl_identical=True,cases=[],scope='Exact negate helper, all binary inputs32/64; NOT ISA/IEEE-X/STA')
    for width,negative in ((32,False),(64,False),(32,True)):
        name=f'w{width}'+('_negative' if negative else '')
        corruption=" ^ XLEN'(1)" if negative else ''
        fixture=f'''module negate_miter(input logic [{width-1}:0] value,output logic equal_o);
localparam int XLEN={width};
{function}
assign equal_o=(prefix_negate(value){corruption}) == XLEN'(-value);
endmodule
'''
        (output/f'{name}.sv').write_text(fixture,encoding='utf-8')
        command=f'read_slang --top negate_miter {name}.sv; prep -top negate_miter -flatten; opt; sat -verify -prove equal_o 1 -show-inputs'
        with (output/f'{name}.log').open('w',encoding='utf-8') as log:
            try:
                result=subprocess.run([yosys,'-Q','-T','-p',command],cwd=output,env=env,stdout=log,stderr=subprocess.STDOUT,timeout=120)
                contents=(output/f'{name}.log').read_text(encoding='utf-8')
                passed=(result.returncode!=0 and 'proof did fail' in contents) if negative else (result.returncode==0 and 'SUCCESS!' in contents)
                case=dict(name=name,negative=negative,passed=passed,exit_code=result.returncode)
            except subprocess.TimeoutExpired:
                case=dict(name=name,negative=negative,passed=False,status='timeout',exit_code=None)
        record['cases'].append(case)
        (output/'report.json').write_text(json.dumps(record,indent=2)+'\n',encoding='utf-8')
        if not case['passed']: raise SystemExit(f'FAIL/INCOMPLETE {name}')
        print(f'PASS {name}',flush=True)
    record['passed']=True
    (output/'report.json').write_text(json.dumps(record,indent=2)+'\n',encoding='utf-8')


if __name__=='__main__': main()
