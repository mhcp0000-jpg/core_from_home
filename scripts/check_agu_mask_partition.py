"""Exact AGU byte-mask/alignment math, with unchanged remaining RTL guard.

Arbitrary binary address/data/size INCLUDING unsupported sizes and misalignment.
Power-of-two beat fixtures cover32/64-bit XLEN and32..1024-bit memory beats.
Not full ISA/IEEE-X/physical STA certification.
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
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('--rtl',type=Path,required=True)
    p.add_argument('--reference-rtl',type=Path,required=True)
    p.add_argument('--output',type=Path,required=True)
    p.add_argument('--yosys',required=True)
    a=p.parse_args()
    root=Path(__file__).absolute().parent.parent
    source=a.rtl.read_text(encoding='utf-8')
    reference=a.reference_rtl.read_text(encoding='utf-8')
    pattern=r'  always_comb begin\n    byte_offset =.*?  end(?=\n\n  typedef struct packed)'
    cur=re.search(pattern,source,re.S);gold=re.search(pattern,reference,re.S)
    if not cur or not gold: raise ValueError('Missing exact arithmetic blocks')
    if source[:cur.start()]+source[cur.end():]!=reference[:gold.start()]+reference[gold.end():]:
        raise ValueError('Remaining interface/adder/FF/hold/reset/flush/checks changed')
    output=a.output.absolute()
    if not output.is_relative_to(root): raise ValueError('Output must stay inside workspace')
    output.mkdir(parents=True,exist_ok=True)
    yosys=shutil.which(a.yosys)
    if not yosys: raise ValueError('Missing Yosys')
    env=os.environ.copy();env['PATH']=str(Path(yosys).parent.parent/'lib')+os.pathsep+env.get('PATH','')
    record=dict(passed=False,source_sha256=hashlib.sha256(a.rtl.read_bytes()).hexdigest(),
                reference_sha256=hashlib.sha256(a.reference_rtl.read_bytes()).hexdigest(),remaining_rtl_identical=True,
                scope='Exact AGU math, arbitrary binary address/data/size including invalid; NOT ISA/IEEE-X/STA',cases=[])
    for width,mem,negative in ((32,32,False),(32,64,False),(64,64,False),(64,128,False),(64,256,False),(32,1024,False),(32,64,True)):
        name=f'x{width}_m{mem}'+('_negative' if negative else '')
        modules=[]
        for module,block in [('agu_reference',gold.group()),('agu_candidate',cur.group())]:
            modules.append(f'''module {module}(input logic [{width-1}:0] effective_address,
input logic [{mem-1}:0] store_data_extended,input logic [2:0] memory_size_i,
output logic [{mem//8+width+2+mem+32+32+(mem//8).bit_length()-2}:0] result);
localparam int XLEN={width},MEM_DATA_WIDTH={mem},MEM_BYTES=MEM_DATA_WIDTH/8,BYTE_OFFSET_WIDTH=$clog2(MEM_BYTES);
logic [BYTE_OFFSET_WIDTH-1:0] byte_offset;
integer unsigned byte_offset_integer,access_bytes;
logic [XLEN-1:0] alignment_mask;
logic unsupported_size,misaligned;
logic [MEM_BYTES-1:0] generated_mask;
logic [MEM_DATA_WIDTH-1:0] generated_store_data;
{block}
assign result={{byte_offset,byte_offset_integer,access_bytes,alignment_mask,unsupported_size,misaligned,generated_mask,generated_store_data}};
endmodule''')
        result_width=mem//8+width+2+mem+64+(mem//8).bit_length()-1
        corruption=f" ^ {result_width}'(1)" if negative else ''
        # Corrupt the byte-mask bit, not an unrelated data output, for control.
        if negative: corruption=f" ^ ({result_width}'(1) << {mem})"
        fixture='\n'.join(modules)+f'''
module agu_miter(input logic [{width-1}:0] address,input logic [{mem-1}:0] data,
input logic [2:0] size,output logic equal_o);
logic [{result_width-1}:0] expected,actual;
agu_reference gold(address,data,size,expected);
agu_candidate candidate(address,data,size,actual);
assign equal_o=expected==(actual{corruption});
endmodule
'''
        (output/f'{name}.sv').write_text(fixture,encoding='utf-8')
        command=f'read_slang --top agu_miter {name}.sv; prep -top agu_miter -flatten; opt; sat -verify -prove equal_o 1 -show-inputs'
        try:
            with (output/f'{name}.log').open('w',encoding='utf-8') as log:
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
