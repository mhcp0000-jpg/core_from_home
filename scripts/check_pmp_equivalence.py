#!/usr/bin/env python3
"""Prove combinational PMP outputs against an immutable Git RTL reference.

This is a two-state equivalence check, not an independent PMP specification
proof. Directed boundary/permission tests must still be run separately.
Generated sources and proof logs stay below out/ by default.
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
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--yosys', default='yosys')
    parser.add_argument('--reference', default='bd11890')
    parser.add_argument('--width', type=int, choices=(4, 8, 16, 32, 64), default=32)
    parser.add_argument('--entries', type=int, default=1)
    parser.add_argument('--priority-only', action='store_true',
                        help='Prove extracted priority block for arbitrary overlap/deny vectors')
    parser.add_argument('--isolate-last-entry', action='store_true',
                        help='Disable earlier cfg entries, retain all address inputs (TOR previous bound)')
    parser.add_argument('--timeout', type=int, default=600)
    parser.add_argument('--output', type=Path, default=Path('out/pmp_equivalence'))
    args = parser.parse_args()
    if args.entries < 1 or args.timeout < 1:
        parser.error('entries and timeout must be positive')
    root = Path(os.path.abspath(__file__)).parent.parent
    executable = shutil.which(args.yosys)
    if not executable:
        raise SystemExit(f'Yosys not found: {args.yosys}')
    executable = str(Path(executable).absolute())
    reference_commit = subprocess.check_output(
        ['git', 'rev-parse', '--verify', args.reference + '^{commit}'],
        cwd=root, text=True).strip()
    reference = subprocess.check_output(
        ['git', 'show', reference_commit + ':rtl/backend/rv_pmp.sv'],
        cwd=root, text=True)
    source = (root / 'rtl/backend/rv_pmp.sv').read_text(encoding='utf-8')
    output = args.output.absolute()
    output.mkdir(parents=True, exist_ok=True)
    width, entries = args.width, args.entries
    # Supply the actual package so the privilege encoding/type is preserved.
    (output / 'package.sv').write_text(
        (root / 'rtl/rv_ooo_pkg.sv').read_text(encoding='utf-8'), encoding='utf-8')
    (output / 'current.sv').write_text(source, encoding='utf-8')
    (output / 'reference.sv').write_text(
        reference.replace('module rv_pmp #(', 'module rv_pmp_reference #(', 1),
        encoding='utf-8')
    (output / 'miter.sv').write_text(f'''
module pmp_miter(
  input logic [{entries*8-1}:0] cfg_i,
  input logic [{entries*(width-2)-1}:0] addr_i,
  input logic valid_i,
  input logic [{width-1}:0] address_i,
  input logic [2:0] size_i, access_i,
  input logic [1:0] privilege_i,
  output logic equal_o
);
  rv_ooo_pkg::privilege_e [0:0] priv;
  assign priv[0] = rv_ooo_pkg::privilege_e'(privilege_i);
  logic allow_dut, allow_ref, match_dut, match_ref;
  logic [{width-1}:0] fault_dut, fault_ref;
  rv_pmp #(.PADDR_WIDTH({width}), .PMP_ENTRIES({entries}), .CHECK_PORTS(1)) dut(
    .pmpcfg_i(cfg_i), .pmpaddr_i(addr_i), .check_valid_i(valid_i),
    .check_address_i(address_i), .check_size_i(size_i),
    .check_access_i(access_i), .check_privilege_i(priv),
    .allow_o(allow_dut), .matched_o(match_dut), .fault_address_o(fault_dut));
  rv_pmp_reference #(.PADDR_WIDTH({width}), .PMP_ENTRIES({entries}), .CHECK_PORTS(1)) ref_i(
    .pmpcfg_i(cfg_i), .pmpaddr_i(addr_i), .check_valid_i(valid_i),
    .check_address_i(address_i), .check_size_i(size_i),
    .check_access_i(access_i), .check_privilege_i(priv),
    .allow_o(allow_ref), .matched_o(match_ref), .fault_address_o(fault_ref));
  assign equal_o = (allow_dut == allow_ref) && (match_dut == match_ref) &&
                   (fault_dut == fault_ref);
endmodule
''', encoding='utf-8')
    if args.priority_only:
        selection = re.search(
            r'for \(int unsigned entry = 0; entry < PMP_ENTRIES; entry\+\+\) begin\n'
            r'        logic earlier_overlap;[\s\S]+?'
            r'if \(!check_valid_i\[port\]\) begin[\s\S]+?\n      end', source)
        if not selection:
            raise SystemExit('Cannot extract actual PMP priority block')
        (output / 'miter.sv').write_text(f'''
module pmp_miter(
  input logic [{entries-1}:0] overlap_i, deny_i,
  input logic valid_i, default_allow_i,
  output logic equal_o
);
  localparam int PMP_ENTRIES={entries};
  localparam int port=0;
  logic [PMP_ENTRIES-1:0] overlap_vector, deny_vector, first_match_vector;
  logic [0:0] check_valid_i, allow_o, matched_o;
  logic reference_allow, reference_match, selected;
  always_comb begin
    overlap_vector=overlap_i;
    deny_vector=deny_i;
    first_match_vector='0;
    check_valid_i=valid_i;
    allow_o=default_allow_i;
    matched_o='0;
    {selection.group(0)}
    // Independent lowest-index first-match oracle.
    selected=0;
    reference_allow=default_allow_i;
    reference_match=0;
    for (int entry=0; entry<PMP_ENTRIES; entry++)
      if (valid_i && !selected && overlap_i[entry]) begin
        selected=1;
        reference_match=1;
        reference_allow=!deny_i[entry];
      end
    if (!valid_i) begin reference_allow=1; reference_match=0; end
  end
  assign equal_o=(allow_o[0]==reference_allow) && (matched_o[0]==reference_match);
endmodule
''', encoding='utf-8')
    report = {
        'passed': False, 'status': 'running', 'paddr_width': width,
        'entries': entries, 'reference_commit': reference_commit,
        'rtl_sha256': hashlib.sha256(source.encode()).hexdigest(),
        'scope': 'all unconstrained two-state combinational inputs; one check port; not a spec proof',
        'earlier_entries_disabled': args.isolate_last_entry,
    }
    if args.priority_only:
        report['scope'] = 'extracted priority block only; arbitrary overlap/deny vectors; not full PMP'
    report_path = output / 'report.json'
    report_path.write_text(json.dumps(report, indent=2) + '\n', encoding='utf-8')
    (output / 'proof.log').write_text('', encoding='utf-8')
    env = os.environ.copy()
    runtime = Path(executable).parent.parent / 'lib'
    if os.name == 'nt' and runtime.is_dir():
        env['PATH'] = str(runtime) + os.pathsep + env.get('PATH', '')
    # Exhaustive disjoint size partitions simplify carry proofs while still
    # covering every value of the three-bit architectural size input.
    isolation = ''.join(
        f' -set cfg_i[{entry*8+7}:{entry*8}] 0'
        for entry in range(entries-1)) if args.isolate_last_entry else ''
    command = (
        'read_slang --top pmp_miter package.sv current.sv reference.sv miter.sv; '
        'prep -top pmp_miter -flatten; opt; '
    ) + '; '.join(
        f'sat -set size_i {size}{isolation} -prove equal_o 1 -verify -show-inputs'
        for size in range(8))
    if args.priority_only:
        command = ('read_slang --top pmp_miter miter.sv; '
                   'prep -top pmp_miter; opt; '
                   'sat -prove equal_o 1 -verify -show-inputs')
    try:
        with (output / 'console.log').open('w', encoding='utf-8') as log:
            result = subprocess.run(
                [executable, '-Q', '-T', '-l', 'proof.log', '-p', command],
                cwd=output, env=env, stdout=log, stderr=subprocess.STDOUT,
                timeout=args.timeout)
        proof = (output / 'proof.log').read_text(encoding='utf-8')
        report['proven_size_partitions'] = proof.count('no model found: SUCCESS!')
        report['passed'] = result.returncode == 0 and report['proven_size_partitions'] == (
            1 if args.priority_only else 8)
        report['yosys_exit_code'] = result.returncode
        report['status'] = 'passed' if report['passed'] else 'failed'
    except subprocess.TimeoutExpired:
        report['status'] = 'timeout'
    report_path.write_text(json.dumps(report, indent=2) + '\n', encoding='utf-8')
    if not report['passed']:
        raise SystemExit(f'FAIL: see {output / "console.log"} and {report_path}')
    print(f'PASS: PMP {"priority-only" if args.priority_only else "all unconstrained-input"} '
          f'equivalence, PADDR_WIDTH={width}, entries={entries}')
    print(f'Report: {report_path}')


if __name__ == '__main__':
    main()
