#!/usr/bin/env python3
"""Prove the actual target-selection fragment against an immutable Git baseline.

Inputs to the fragment are arbitrary (even mutually inconsistent branch
classifications). This does not prove instruction decode, history/RAS training,
or the whole predictor/core. The generated fixture is also usable with Icarus.
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
import time


def fragment(text):
    end = '      prediction_meta_o[lane].taken = prediction_taken_o[lane];'
    stop = text.index(end)
    priority = '      prediction_target_o[lane] = query_sequential_pc[lane];'
    onehot = "      choose_sequential = 1'b1;"
    starts = [text.find(marker, 0, stop) for marker in (priority, onehot)]
    starts = [value for value in starts if value >= 0]
    if len(starts) != 1 or text.count(end) != 1:
        raise ValueError('Expected one recognized target-selection fragment')
    return text[starts[0]:stop]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--baseline', default='081e714')
    parser.add_argument('--rtl', type=Path)
    parser.add_argument('--xlen', type=int, choices=(32, 64), default=32)
    parser.add_argument('--ras-depth', type=int, choices=(2, 4, 8, 16), default=16)
    parser.add_argument('--yosys', type=Path)
    parser.add_argument('--timeout', type=int, default=120)
    parser.add_argument('--out', type=Path, required=True)
    args = parser.parse_args()
    repo = Path(__file__).resolve().parent.parent
    candidate_bytes = (args.rtl or repo / 'rtl/frontend/rv_branch_predictor.sv').read_bytes()
    reference_bytes = subprocess.check_output(
        ['git', 'show', f'{args.baseline}:rtl/frontend/rv_branch_predictor.sv'], cwd=repo)
    commit = subprocess.check_output(['git', 'rev-parse', args.baseline], cwd=repo,
                                     text=True).strip()
    candidate = fragment(candidate_bytes.decode('utf-8-sig'))
    reference = fragment(reference_bytes.decode('utf-8-sig'))
    reference = re.sub(r'\bprediction_(taken|target)_o\b',
                       lambda match: match.group(0) + '_ref', reference)
    fixture = f'''module predictor_target_miter #(
  parameter int XLEN={args.xlen}, RAS_DEPTH={args.ras_depth},
  localparam int RAS_PTR_BITS=$clog2(RAS_DEPTH)
)(
  input logic [1:0] query_valid_i, query_conditional, query_direct_jump,
                     query_indirect_jump, query_return, query_use_global,
                     query_global_taken, query_bimodal_taken, query_btb_hit,
  input logic [1:0][XLEN-1:0] query_sequential_pc, query_direct_target, query_btb_target,
  input logic [RAS_DEPTH-1:0][XLEN-1:0] ras_i,
  input logic [RAS_PTR_BITS-1:0] ras_pointer_work,
  input logic [RAS_PTR_BITS:0] ras_count_work,
  output logic [1:0] prediction_taken_o, prediction_taken_o_ref,
  output logic [1:0][XLEN-1:0] prediction_target_o, prediction_target_o_ref,
  output logic equal_o
);
logic [XLEN-1:0] speculative_ras_q [0:RAS_DEPTH-1];
for(genvar entry=0; entry<RAS_DEPTH; entry++) begin : g_ras
  assign speculative_ras_q[entry]=ras_i[entry];
end
always_comb begin
  prediction_taken_o='0; prediction_target_o='0;
  for(integer lane=0; lane<2; lane++) begin
    logic choose_sequential, choose_direct, choose_ras, choose_btb;
    logic [XLEN-1:0] ras_target;
{candidate}
  end
end
always_comb begin
  prediction_taken_o_ref='0; prediction_target_o_ref='0;
  for(integer lane=0; lane<2; lane++) begin
{reference}
  end
end
assign equal_o=({{prediction_taken_o,prediction_target_o}}==
                {{prediction_taken_o_ref,prediction_target_o_ref}});
endmodule
'''
    out = args.out.absolute()
    if os.name == 'nt' and not str(out).isascii():
        parser.error('Windows Yosys output requires an ASCII path, e.g. subst drive')
    if args.timeout <= 0:
        parser.error('timeout must be positive')
    out.mkdir(parents=True, exist_ok=True)
    yosys = args.yosys or shutil.which('yosys')
    if not yosys and os.name == 'nt':
        yosys = Path('C:/rv_toolchains/oss-cad-suite/bin/yosys.exe')
    if not yosys or not Path(yosys).is_file():
        raise FileNotFoundError('Pass --yosys to an existing executable')
    (out / 'miter.sv').write_text(fixture, encoding='utf-8')
    commands = ('read_slang --std 1800-2017 --top predictor_target_miter miter.sv\n'
                'prep -top predictor_target_miter\nflatten\nmemory_map\nopt\ntechmap\nopt\n'
                f'sat -verify -prove equal_o 1 -timeout {args.timeout}\n')
    (out / 'proof.ys').write_text(commands, encoding='utf-8')
    sha = lambda data: hashlib.sha256(data).hexdigest()
    report = dict(status='running', reference_commit=commit, xlen=args.xlen,
                  ras_depth=args.ras_depth, candidate_sha256=sha(candidate_bytes),
                  reference_sha256=sha(reference_bytes), fixture_sha256=sha(fixture.encode()),
                  scope='Actual target-selection fragments; all two-state input combinations; '
                        'not instruction decode, state transitions, pipeline or core proof')
    report_path = out / 'report.json'
    report_path.write_text(json.dumps(report, indent=2), encoding='utf-8')
    env = os.environ.copy()
    tool_dir = Path(yosys).absolute().parent
    env['PATH'] = str(tool_dir) + os.pathsep + str(tool_dir.parent / 'lib') + \
                  os.pathsep + env.get('PATH', '')
    started = time.monotonic()
    with (out / 'proof.log').open('w', encoding='utf-8') as log:
        process = subprocess.Popen([str(yosys), '-s', 'proof.ys'], cwd=out,
                                   stdout=log, stderr=subprocess.STDOUT, env=env,
                                   start_new_session=(os.name != 'nt'))
        try:
            report['exit_code'] = process.wait(timeout=args.timeout + 60)
            report['status'] = 'failed'
        except subprocess.TimeoutExpired:
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
    print(f"{report['status'].upper()} predictor target XLEN={args.xlen} "
          f"RAS={args.ras_depth}; report={report_path}")
    return 0 if report['status'] == 'pass' else 1


if __name__ == '__main__':
    raise SystemExit(main())
