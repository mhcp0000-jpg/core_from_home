#!/usr/bin/env python3
"""Prove actual frontend successor rewrites against a frozen predecessor.

Extracts actual RTL assignments, checks every other RTL line unchanged, then
proves the next-request-address state transition for arbitrary binary inputs.
Not full frontend/ISA/IEEE-X equivalence or STA.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess


def digest(data):
    return hashlib.sha256(data).hexdigest()


def assignment(text, signal):
    matches = re.findall(r'  assign ' + re.escape(signal) + r'\s*=.*?;', text, re.S)
    if len(matches) != 1:
        raise ValueError('Expected one actual assignment: ' + signal)
    return matches[0]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--reference', type=Path, required=True)
    parser.add_argument('--candidate', type=Path, required=True)
    parser.add_argument('--out', type=Path, required=True)
    parser.add_argument('--yosys', type=Path, default=Path('C:/rv_toolchains/oss-cad-suite/bin/yosys.exe'))
    args = parser.parse_args()
    reference_bytes = args.reference.read_bytes()
    candidate_bytes = args.candidate.read_bytes()
    reference = reference_bytes.decode('utf-8-sig').replace('\r\n', '\n')
    candidate = candidate_bytes.decode('utf-8-sig').replace('\r\n', '\n')
    declarations = ('  logic [PADDR_WIDTH-1:0] redirect_block_successor;\n'
                    '  logic [PADDR_WIDTH-1:0] request_successor;\n')
    added = re.search(r'  // Constant-block successors.*?\n(?=  assign response_id_matches)', candidate, re.S)
    shadow = re.search(r'  assert property.*?\n(?=  // Independent shadow contract)',
                       candidate.split('`ifndef SYNTHESIS', 1)[1], re.S)
    if added is None or shadow is None:
        raise ValueError('Missing expected actual rewrite/shadow assertions')
    normal_old = 'next_request_addr_q <= imem_req_addr_o + FETCH_BYTES_VALUE;'
    normal_new = 'next_request_addr_q <= request_successor;'
    redirect_old = ('next_request_addr_q <= redirect_block_addr +\n'
                    "            (redirect_uses_target_buffer ? FETCH_BYTES_VALUE : '0);")
    redirect_new = ('next_request_addr_q <= redirect_uses_target_buffer ?\n'
                    '            redirect_block_successor : redirect_block_addr;')
    for original, revised in ((normal_old, normal_new), (redirect_old, redirect_new)):
        if reference.count(original) != 1 or candidate.count(revised) != 1:
            raise ValueError('Unexpected state-update rewrite')
    restored = candidate.replace(declarations, '', 1).replace(added[0], '', 1)
    restored = restored.replace(shadow[0], '', 1).replace(normal_new, normal_old, 1)
    restored = restored.replace(redirect_new, redirect_old, 1)
    if restored != reference:
        raise ValueError('Unexpected change outside proved rewrite')
    old_addr = assignment(reference, 'imem_req_addr_o')
    if assignment(candidate, 'imem_req_addr_o') != old_addr:
        raise ValueError('Request-address output changed')
    actual = '\n'.join(assignment(candidate, signal) for signal in
                       ('redirect_block_successor', 'request_successor'))
    out = args.out.absolute()
    if not str(out).isascii():
        raise ValueError('Use an ASCII Windows alias for native proof output')
    out.mkdir(parents=True, exist_ok=True)
    env = os.environ.copy()
    env['PATH'] = str(args.yosys.parent) + os.pathsep + str(args.yosys.parent.parent / 'lib') + os.pathsep + env.get('PATH', '')
    cases = []
    for width, fetch in ((32, 8), (32, 16), (32, 32), (56, 16), (64, 16), (64, 32)):
        for negative in (False, True):
            if negative and (width, fetch) != (32, 16):
                continue
            name = f'p{width}_f{fetch}' + ('_negative' if negative else '')
            case = out / name
            case.mkdir(exist_ok=True)
            altered = actual.replace('redirect_block_addr + FETCH_BYTES_VALUE',
                                     'redirect_block_addr + FETCH_BYTES_VALUE + 1') if negative else actual
            source = f'''module successor_miter #(
  parameter int PADDR_WIDTH={width}, FETCH_BYTES={fetch},
  localparam logic [PADDR_WIDTH-1:0] FETCH_BYTES_VALUE=FETCH_BYTES
) (
  input logic rst_ni, request_fire, request_hold_q, frontend_redirect_valid,
  input logic redirect_uses_target_buffer,
  input logic [PADDR_WIDTH-1:0] request_hold_addr_q, next_request_addr_q,
  input logic [PADDR_WIDTH-1:0] redirect_block_addr, reset_addr_i,
  output logic equal_o
);
logic [PADDR_WIDTH-1:0] imem_req_addr_o, redirect_block_successor, request_successor;
logic [PADDR_WIDTH-1:0] original_d, revised_d;
{old_addr}
{altered}
always_comb begin
  original_d=next_request_addr_q;
  revised_d=next_request_addr_q;
  if (request_fire) begin
    {normal_old.replace('next_request_addr_q <=', 'original_d=')}
    {normal_new.replace('next_request_addr_q <=', 'revised_d=')}
  end
  if (frontend_redirect_valid && !request_fire) begin
    {redirect_old.replace('next_request_addr_q <=', 'original_d=')}
    {redirect_new.replace('next_request_addr_q <=', 'revised_d=')}
  end
  if (!rst_ni) begin
    original_d=reset_addr_i;
    revised_d=reset_addr_i;
  end
end
assign equal_o=(original_d==revised_d);
endmodule
'''
            (case / 'miter.sv').write_text(source, encoding='utf-8')
            script = ('read_slang --std 1800-2017 --top successor_miter miter.sv\n'
                      'prep -top successor_miter\nflatten\nopt\ntechmap\nopt\n'
                      'sat -verify -prove equal_o 1 -timeout 120\n')
            (case / 'proof.ys').write_text(script, encoding='ascii')
            with (case / 'proof.log').open('w', encoding='utf-8') as log:
                proc = subprocess.run([str(args.yosys), '-s', 'proof.ys'], cwd=case,
                                      env=env, stdout=log, stderr=subprocess.STDOUT, timeout=180)
            log_text = (case / 'proof.log').read_text(encoding='utf-8', errors='replace')
            passed = (proc.returncode == 1 and 'proof did fail' in log_text) if negative else (
                proc.returncode == 0 and 'no model found: SUCCESS!' in log_text)
            cases.append(dict(name=name, exit_code=proc.returncode, negative=negative,
                              passed=passed, fixture_sha256=digest(source.encode())))
            if not passed:
                raise RuntimeError('Unexpected native proof outcome: ' + name)
    report = dict(passed=True, reference_sha256=digest(reference_bytes),
                  candidate_sha256=digest(candidate_bytes), unchanged_rest=True,
                  cases=cases, scope='Actual changed next-address assignment/state-transition; '
                  'arbitrary binary addresses/control including wrap/hold/reset/redirect/handshake; '
                  'not full frontend/IEEE-X/ISA/STA')
    (out / 'report.json').write_text(json.dumps(report, indent=2), encoding='utf-8')
    print(json.dumps(report, indent=2))


if __name__ == '__main__':
    main()
