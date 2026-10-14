#!/usr/bin/env python3
"""Prove the actual banked PHT direction helper, not the complete predictor.

Inputs are arbitrary binary index/table bits. A restoration guard binds every
changed callsite and verifies that the remainder of the predictor is identical
to the supplied frozen reference. Includes a required wrong-result negative.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess


def sha(data):
    return hashlib.sha256(data).hexdigest()


def normalized(text):
    return re.sub(r"\s+", "", text)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--rtl', type=Path, required=True)
    parser.add_argument('--reference', type=Path, required=True)
    parser.add_argument('--out', type=Path, required=True)
    parser.add_argument('--yosys', type=Path, default=Path('C:/rv_toolchains/oss-cad-suite/bin/yosys.exe'))
    args = parser.parse_args()
    actual_bytes, reference_bytes = args.rtl.read_bytes(), args.reference.read_bytes()
    actual, reference = actual_bytes.decode('utf-8-sig'), reference_bytes.decode('utf-8-sig')
    block_match = re.search(r'  // Two-level, shared decoded direction read\..*?endfunction\r?\n', actual, re.S)
    if not block_match:
        raise ValueError('Missing actual implementation block')
    helper = re.search(r'function automatic logic lookup_direction\(.*?endfunction', block_match[0], re.S)[0]
    restored = actual[:block_match.start()] + actual[block_match.end():]
    replacements = {
        'lookup_direction(bimodal_direction,query_pht_index[lane])': 'pht_q[query_pht_index[lane]][1]',
        'lookup_direction(global_direction,query_global_pht_index[lane])': 'global_pht_q[query_global_pht_index[lane]][1]',
        'lookup_direction(global_direction,unshifted_index)': 'global_pht_q[unshifted_index][1]',
        'lookup_direction(global_direction,shifted_zero_index)': 'global_pht_q[shifted_zero_index][1]',
        'lookup_direction(global_direction,shifted_one_index)': 'global_pht_q[shifted_one_index][1]',
        'lookup_direction(chooser_direction,query_pht_index[lane])': 'chooser_q[query_pht_index[lane]][1]',
    }
    for candidate, old in replacements.items():
        if restored.count(candidate) != 1:
            raise ValueError('Actual read-site binding changed: ' + candidate)
        restored = restored.replace(candidate, old)
    if normalized(restored) != normalized(reference):
        raise ValueError('Unproved predictor changes outside the bound implementation')
    for destination, source in [('bimodal_direction', 'pht_q'), ('global_direction', 'global_pht_q'), ('chooser_direction', 'chooser_q')]:
        if f'assign {destination}[entry] = {source}[entry][1];' not in block_match[0]:
            raise ValueError('Direction bits not bound to original table MSBs')
    out = args.out.absolute()
    if os.name == 'nt' and not str(out).isascii():
        parser.error('Use an ASCII output path (owned subst drive on Windows)')
    out.mkdir(parents=True, exist_ok=True)
    report = dict(candidate_sha256=sha(actual_bytes), reference_sha256=sha(reference_bytes),
                  helper_sha256=sha(helper.encode()), unchanged_rest=True, cases=[], passed=False,
                  scope='Actual binary direction-read helper and callsite/restoration binding; '
                        'not four-state equivalence, full predictor state, ISA or physical STA')
    env = os.environ.copy()
    env['PATH'] = str(args.yosys.parent) + os.pathsep + str(args.yosys.parent.parent / 'lib') + os.pathsep + env['PATH']
    for entries, negative in [(2, False), (16, False), (32, False), (64, False), (2048, False), (32, True)]:
        run = out / f'pht{entries}_negative{int(negative)}'
        run.mkdir(exist_ok=True)
        implementation = helper.replace('return |bank_taken;', 'return !(|bank_taken);') if negative else helper
        fixture = f'''module direction_miter #(
parameter int PHT_ENTRIES={entries}, PHT_BITS=$clog2(PHT_ENTRIES),
PHT_ROW_BITS=(PHT_BITS<5)?PHT_BITS:5, PHT_ROWS=1<<PHT_ROW_BITS,
PHT_BANKS=PHT_ENTRIES/PHT_ROWS
)(input logic [PHT_ENTRIES-1:0] directions_i,
input logic [PHT_BITS-1:0] index_i, output logic equal_o);
{implementation}
assign equal_o=lookup_direction(directions_i,index_i)==directions_i[index_i];
endmodule
'''
        (run / 'miter.sv').write_text(fixture, encoding='utf-8')
        (run / 'proof.ys').write_text('read_slang --top direction_miter miter.sv\n'
            'prep -top direction_miter\nflatten\ntechmap\nopt\n'
            'sat -verify -prove equal_o 1 -timeout 120\n', encoding='utf-8')
        with (run / 'proof.log').open('w', encoding='utf-8') as log:
            process = subprocess.run([str(args.yosys), '-Q', '-T', '-s', 'proof.ys'], cwd=run,
                                     env=env, stdout=log, stderr=subprocess.STDOUT, timeout=180)
        transcript = (run / 'proof.log').read_text(encoding='utf-8', errors='replace')
        passed = (process.returncode != 0 and 'proof did fail' in transcript) if negative else (
            process.returncode == 0 and 'SUCCESS' in transcript)
        report['cases'].append(dict(entries=entries, negative=negative, native_exit=process.returncode,
                                    passed=passed, fixture_sha256=sha(fixture.encode())))
        (out / 'report.json').write_text(json.dumps(report, indent=2), encoding='utf-8')
        if not passed:
            raise RuntimeError(f'Unexpected proof result: {run}')
    report['passed'] = True
    (out / 'report.json').write_text(json.dumps(report, indent=2), encoding='utf-8')
    print(json.dumps(report, indent=2))


if __name__ == '__main__':
    main()
