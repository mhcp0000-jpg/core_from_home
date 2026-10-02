#!/usr/bin/env python3
"""Prove the actual BTB lookup helper against an immutable Git reference.

All two-state query PCs and BTB contents are unconstrained, including multiple
matching ways and invalid entries with arbitrary target bits. This is a helper
proof, not a proof of predictor training/recovery or the complete core.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import signal
import subprocess
import sys
import time


def sha(data):
    return hashlib.sha256(data).hexdigest()


def lookup(text):
    hits = re.findall(r"function\s+automatic\s+btb_lookup_t\s+lookup_btb\b.*?endfunction",
                      text, re.S)
    if len(hits) != 1:
        raise ValueError("Expected exactly one actual lookup_btb function")
    return hits[0]


def typedef(text, name):
    hits = re.findall(r"typedef\s+struct\s+packed\s*\{[^}]*\}\s*" + name + r"\s*;",
                      text, re.S)
    if len(hits) != 1:
        raise ValueError("Expected actual packed type " + name)
    return hits[0]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--baseline', default='081e714')
    parser.add_argument('--rtl', type=Path)
    parser.add_argument('--xlen', type=int, choices=(32, 64), default=32)
    parser.add_argument('--sets', type=int, default=64)
    parser.add_argument('--ways', type=int, default=4)
    parser.add_argument('--yosys', type=Path)
    parser.add_argument('--timeout', type=int, default=180)
    parser.add_argument('--out', type=Path, required=True)
    args = parser.parse_args()
    if any(v < 2 or v & (v - 1) for v in (args.sets, args.ways)):
        parser.error('sets/ways must be powers of two and at least two')
    if args.sets.bit_length() >= args.xlen or args.timeout <= 0:
        parser.error('invalid geometry/timeout')
    repo = Path(__file__).resolve().parent.parent
    rtl = args.rtl or repo / 'rtl/frontend/rv_branch_predictor.sv'
    candidate_bytes = rtl.read_bytes()
    candidate = candidate_bytes.decode('utf-8-sig')
    reference_bytes = subprocess.check_output(
        ['git', 'show', f'{args.baseline}:rtl/frontend/rv_branch_predictor.sv'], cwd=repo)
    reference = reference_bytes.decode('utf-8-sig')
    commit = subprocess.check_output(['git', 'rev-parse', args.baseline], cwd=repo,
                                     text=True).strip()
    types = []
    for name in ('btb_entry_t', 'btb_lookup_t'):
        actual = typedef(candidate, name)
        if re.sub(r'\s+', '', actual) != re.sub(r'\s+', '', typedef(reference, name)):
            raise ValueError('Changed entry/result type requires a new proof binding')
        types.append(actual)
    candidate_lookup = lookup(candidate)
    reference_lookup = re.sub(r'\blookup_btb\b', 'lookup_btb_ref', lookup(reference))
    out = args.out.absolute()
    if os.name == 'nt' and not str(out).isascii():
        parser.error('Windows Yosys output must use an ASCII path (e.g. a subst drive)')
    out.mkdir(parents=True, exist_ok=True)
    yosys = args.yosys or shutil.which('yosys')
    if not yosys and os.name == 'nt':
        yosys = Path('C:/rv_toolchains/oss-cad-suite/bin/yosys.exe')
    if not yosys or not Path(yosys).is_file():
        raise FileNotFoundError('Pass --yosys to an existing executable')
    fixture = f'''module btb_lookup_miter #(
  parameter int XLEN={args.xlen}, BTB_SETS={args.sets}, BTB_WAYS={args.ways},
  localparam int BTB_SET_BITS=$clog2(BTB_SETS),
  localparam int BTB_TAG_BITS=XLEN-BTB_SET_BITS-1,
  localparam int ENTRY_WIDTH=1+BTB_TAG_BITS+XLEN
) (
  input logic [XLEN-1:0] pc_i,
  input logic [BTB_SETS-1:0][BTB_WAYS-1:0][ENTRY_WIDTH-1:0] entries_i,
  output logic equal_o
);
{types[0]}
{types[1]}
btb_entry_t btb_q [0:BTB_SETS-1][0:BTB_WAYS-1];
for (genvar s=0; s<BTB_SETS; s++) begin : g_set
  for (genvar w=0; w<BTB_WAYS; w++) begin : g_way
    assign btb_q[s][w]=entries_i[s][w];
  end
end
{candidate_lookup}
{reference_lookup}
assign equal_o=(lookup_btb(pc_i)==lookup_btb_ref(pc_i));
endmodule
'''
    fixture_path = out / 'miter.sv'
    script_path = out / 'proof.ys'
    fixture_path.write_text(fixture, encoding='utf-8')
    # read_slang has its own filename parser; quoted Yosys script arguments
    # may be treated as literal quote characters. Run in the fixture folder
    # and use a fixed relative name, also supporting spaces in the folder.
    commands = ('read_slang --std 1800-2017 --top btb_lookup_miter miter.sv\n' +
                'prep -top btb_lookup_miter\nflatten\nmemory_map\nopt\ntechmap\nopt\n' +
                f'sat -verify -prove equal_o 1 -timeout {args.timeout}\n')
    script_path.write_text(commands, encoding='utf-8')
    report = dict(status='running', reference_commit=commit,
                  candidate_sha256=sha(candidate_bytes), reference_sha256=sha(reference_bytes),
                  fixture_sha256=sha(fixture.encode()), xlen=args.xlen,
                  sets=args.sets, ways=args.ways,
                  scope='Actual lookup helper; all two-state PCs/BTB entries including multi-hit; '
                        'not training/recovery/pipeline/core equivalence')
    report_path = out / 'report.json'
    report_path.write_text(json.dumps(report, indent=2), encoding='utf-8')
    env = os.environ.copy()
    tool_dir = Path(yosys).absolute().parent
    env['PATH'] = str(tool_dir) + os.pathsep + str(tool_dir.parent / 'lib') + \
                  os.pathsep + env.get('PATH', '')
    started = time.monotonic()
    with (out / 'proof.log').open('w', encoding='utf-8') as log:
        process = subprocess.Popen([str(yosys), '-s', str(script_path)], cwd=out,
                                   stdout=log, stderr=subprocess.STDOUT, env=env,
                                   start_new_session=(os.name != 'nt'))
        try:
            code = process.wait(timeout=args.timeout + 60)
            report['status'] = 'failed'
            report['exit_code'] = code
        except subprocess.TimeoutExpired:
            # Kill only this owned process tree before reaping the parent.
            if os.name == 'nt':
                subprocess.run(['taskkill', '/PID', str(process.pid), '/T', '/F'],
                               stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=False)
            else:
                os.killpg(process.pid, signal.SIGKILL)
            process.wait()
            report['status'] = 'timeout'
    log_text = (out / 'proof.log').read_text(encoding='utf-8', errors='replace')
    if report.get('exit_code') == 0 and 'no model found: SUCCESS!' in log_text:
        report['status'] = 'pass'
    report['elapsed_seconds'] = round(time.monotonic() - started, 3)
    report_path.write_text(json.dumps(report, indent=2), encoding='utf-8')
    print(f"{report['status'].upper()} BTB lookup XLEN={args.xlen} SETS={args.sets} "
          f"WAYS={args.ways}; report={report_path}")
    return 0 if report['status'] == 'pass' else 1


if __name__ == '__main__':
    sys.exit(main())
