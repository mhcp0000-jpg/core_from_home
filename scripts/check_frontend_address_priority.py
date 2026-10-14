#!/usr/bin/env python3
"""Bind and prove the actual single-writer frontend address transition.

The restoration guard checks every other RTL line. SAT covers arbitrary binary
state/control/address; the optional Icarus check covers all256 four-state control
combinations with binary/X/Z address samples. Neither is a full frontend proof.
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
    parser.add_argument('--reference', type=Path, required=True)
    parser.add_argument('--rtl', type=Path, required=True)
    parser.add_argument('--out', type=Path, required=True)
    parser.add_argument('--tools', type=Path, default=Path('C:/rv_toolchains/oss-cad-suite'))
    args = parser.parse_args()
    before_bytes, after_bytes = args.reference.read_bytes(), args.rtl.read_bytes()
    before, after = [value.decode('utf-8-sig').replace('\r\n', '\n') for value in (before_bytes, after_bytes)]
    added = re.search(r'  // One writer for the address word\..*?\n  end\n\n', after, re.S)
    if not added:
        raise ValueError('Missing actual single-writer implementation')
    old_reset = re.search(r'      next_request_addr_q <=\n.*?;', before, re.S)[0]
    old_normal = '        next_request_addr_q <= request_successor;'
    old_redirect = re.search(r'        if \(!request_fire\)\n          next_request_addr_q <=.*?;', before, re.S)[0]
    if before.count(old_normal) != 1 or len(re.findall(r'next_request_addr_q\s*<=', before)) != 3 or len(re.findall(r'next_request_addr_q\s*<=', after)) != 3:
        raise ValueError('Unexpected additional/missing address writer')
    restored = after.replace(added[0], '', 1)
    reset_marker = "      epoch_q <= '0;"
    normal_marker = '        outstanding_addr_q <= imem_req_addr_o;'
    redirect_marker = "        epoch_q <= epoch_q + 1'b1;"
    for marker, inserted in [(reset_marker, old_reset + '\n' + reset_marker),
                             (normal_marker, normal_marker + '\n' + old_normal),
                             (redirect_marker, redirect_marker + '\n' + old_redirect)]:
        if restored.count(marker) != 1:
            raise ValueError('Unexpected binding marker')
        restored = restored.replace(marker, inserted, 1)
    if restored != before:
        raise ValueError('Unproved RTL changes outside the address update')
    new_body = added[0].split('begin : p_request_address\n', 1)[1].rsplit('  end', 1)[0]
    new_body = re.sub(r'next_request_addr_q\s*<=', 'revised_d =', new_body)
    old_body = ('if (!rst_ni) begin\n' + old_reset.replace('next_request_addr_q <=', 'original_d =') +
                '\nend else begin\nif (request_fire) begin\n' + old_normal.replace('next_request_addr_q <=', 'original_d =') +
                '\nend\nif (frontend_redirect_valid) begin\n' + old_redirect.replace('next_request_addr_q <=', 'original_d =') + '\nend\nend')
    out = args.out.absolute()
    if not str(out).isascii():
        parser.error('Use an ASCII output path')
    out.mkdir(parents=True, exist_ok=True)
    env = os.environ.copy()
    env['PATH'] = str(args.tools / 'bin') + os.pathsep + str(args.tools / 'lib') + os.pathsep + env['PATH']
    report = dict(passed=False, unchanged_rest=True, cases=[],
                  candidate_sha256=hashlib.sha256(after_bytes).hexdigest(),
                  reference_sha256=hashlib.sha256(before_bytes).hexdigest(),
                  scope='Actual address priority/restoration binding; binary transition SAT plus finite four-state control/address simulation; not full frontend/ISA/STA')
    for width, fetch, negative in [(32, 8, False), (32, 16, False), (32, 32, False), (56, 16, False), (64, 16, False), (64, 32, False), (32, 16, True)]:
        run = out / f'p{width}_f{fetch}_negative{int(negative)}'
        run.mkdir(exist_ok=True)
        body = new_body.replace('frontend_redirect_valid && !request_fire', 'frontend_redirect_valid') if negative else new_body
        fixture = f'''module address_miter #(
parameter int PADDR_WIDTH={width}, FETCH_BYTES={fetch}, FETCH_ADDR_LSB=$clog2(FETCH_BYTES)
)(input logic rst_ni, request_fire, frontend_redirect_valid, redirect_uses_target_buffer,
input logic [PADDR_WIDTH-1:0] next_request_addr_q, request_successor,
redirect_block_successor, redirect_block_addr, reset_vector_paddr,
output logic [PADDR_WIDTH-1:0] original_d,revised_d, output logic equal_o);
always_comb begin
original_d=next_request_addr_q;
{old_body}
end
always_comb begin
revised_d=next_request_addr_q;
{body}
end
assign equal_o=original_d==revised_d;
endmodule
'''
        (run / 'miter.sv').write_text(fixture, encoding='utf-8')
        (run / 'proof.ys').write_text('read_slang --top address_miter miter.sv\n'
            'prep -top address_miter\nflatten\ntechmap\nopt\n'
            'sat -verify -prove equal_o 1 -timeout 30\n', encoding='utf-8')
        with (run / 'proof.log').open('w', encoding='utf-8') as log:
            native = subprocess.run([str(args.tools / 'bin/yosys.exe'), '-Q', '-T', '-s', 'proof.ys'],
                                    cwd=run, env=env, stdout=log, stderr=subprocess.STDOUT, timeout=60)
        transcript = (run / 'proof.log').read_text(errors='replace')
        passed = (native.returncode == 1 and 'proof did fail' in transcript) if negative else (native.returncode == 0 and 'SUCCESS' in transcript)
        case = dict(width=width, fetch=fetch, negative=negative, native_exit=native.returncode, passed=passed)
        report['cases'].append(case)
        (out / 'report.json').write_text(json.dumps(report, indent=2))
        if not passed:
            raise RuntimeError('Unexpected SAT outcome: ' + str(run))
        if not negative:
            tb = f'''module address_priority_tb;
localparam int PADDR_WIDTH={width};
logic rst_ni,request_fire,frontend_redirect_valid,redirect_uses_target_buffer;
logic [PADDR_WIDTH-1:0] next_request_addr_q,request_successor,redirect_block_successor,
redirect_block_addr,reset_vector_paddr,original_d,revised_d;
logic equal_o;
address_miter dut(.*);
function automatic logic symbol(input integer value);
case(value) 0:symbol=0;1:symbol=1;2:symbol=1'bx;3:symbol=1'bz;endcase
endfunction
initial begin
for(integer sample=0;sample<16;sample++) begin
next_request_addr_q='h87654321;request_successor='h81234567;
redirect_block_successor='hfedcba98;redirect_block_addr='h12345678;reset_vector_paddr='h80000007;
next_request_addr_q[sample]=symbol(sample%4);
request_successor[sample]=symbol((sample+1)%4);
redirect_block_addr[sample]=symbol((sample+2)%4);
redirect_block_successor[sample]=symbol((sample+3)%4);
reset_vector_paddr[sample]=symbol((sample+1)%4);
for(integer control=0;control<256;control++) begin
rst_ni=symbol(control%4);request_fire=symbol((control/4)%4);
frontend_redirect_valid=symbol((control/16)%4);
redirect_uses_target_buffer=symbol((control/64)%4);
#1;if(original_d !== revised_d) $fatal(1,"four-state address mismatch sample=%0d control=%0d",sample,control);
end
end
$display("PASS address priority four-state4096 width={width} fetch={fetch}");$finish;
end
endmodule
'''
            (run / 'tb.sv').write_text(tb, encoding='utf-8')
            with (run / 'four_state.log').open('w', encoding='utf-8') as log:
                compile_run = subprocess.run([str(args.tools / 'bin/iverilog.exe'), '-g2012', '-s', 'address_priority_tb', '-o', 'sim.vvp', 'miter.sv', 'tb.sv'], cwd=run, env=env, stdout=log, stderr=subprocess.STDOUT, timeout=30)
                if compile_run.returncode:
                    raise RuntimeError('Icarus compilation failed')
                sim_run = subprocess.run([str(args.tools / 'bin/vvp.exe'), 'sim.vvp'], cwd=run, env=env, stdout=log, stderr=subprocess.STDOUT, timeout=30)
            case['four_state_native_exit'] = sim_run.returncode
            case['four_state_vectors'] = 4096
            if sim_run.returncode or 'PASS address priority' not in (run / 'four_state.log').read_text():
                raise RuntimeError('Four-state transition comparison failed')
    report['passed'] = True
    (out / 'report.json').write_text(json.dumps(report, indent=2))
    print(json.dumps(report, indent=2))


if __name__ == '__main__':
    main()
