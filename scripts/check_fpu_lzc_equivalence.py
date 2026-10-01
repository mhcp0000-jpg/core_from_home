#!/usr/bin/env python3
"""Prove the actual RTL highest-bit helper for every magnitude (Yosys/read_slang)."""
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
    parser.add_argument('--output', type=Path, default=Path('out/fpu_lzc_equivalence'))
    args = parser.parse_args()
    # Preserve an ASCII subst path on Windows; do not resolve to a Unicode path.
    root = Path(os.path.abspath(__file__)).parent.parent
    rtl = root / 'rtl/backend/rv_fpu.sv'
    source = rtl.read_text(encoding='utf-8')
    width_match = re.search(r'localparam\s+int\s+unsigned\s+MAGW\s*=\s*(\d+)\s*;', source)
    helper_match = re.search(
        r'function\s+automatic\s+logic\s*\[6:0\]\s+highest_magnitude_bit\s*\('
        r'[\s\S]*?endfunction', source)
    if not width_match or not helper_match:
        raise SystemExit('MAGW constant / highest_magnitude_bit helper not found in RTL')
    width = int(width_match.group(1))
    if not 1 <= width <= 128:
        raise SystemExit('Seven-bit index proof requires 1 <= MAGW <= 128')
    resolved_yosys = shutil.which(args.yosys)
    if not resolved_yosys:
        raise SystemExit(f'Yosys not found: {args.yosys}')
    yosys_executable = str(Path(resolved_yosys).absolute())
    output = args.output.absolute()
    output.mkdir(parents=True, exist_ok=True)
    fixture = output / 'miter.sv'
    fixture.write_text(f'''// Helper extracted verbatim from rtl/backend/rv_fpu.sv.
module fpu_highest_bit_miter(
  input logic [{width-1}:0] magnitude_i, output logic equal_o
);
  localparam int MAGW={width};
  {helper_match.group(0)}
  logic [6:0] reference_index;
  always_comb begin
    reference_index=0;
    for (int bit_index=0;bit_index<MAGW;bit_index++)
      if (magnitude_i[bit_index]) reference_index=7'(bit_index);
  end
  assign equal_o=highest_magnitude_bit(magnitude_i)==reference_index;
endmodule
''', encoding='utf-8')
    # The independent reference scans upward, unlike the original downward
    # found/priority encoder. Both define zero magnitude's index as zero.
    relative_log = Path(os.path.relpath(output / 'proof.log', root)).as_posix()
    # read_slang does not strip Yosys command-language filename quotes on
    # every distribution. A fixed filename relative to output avoids both
    # quoting problems and space/Unicode paths in the generated command.
    yosys_command = (
        'read_slang --top fpu_highest_bit_miter miter.sv; '
        'prep -top fpu_highest_bit_miter; '
        'sat -prove equal_o 1 -verify -show-inputs'
    )
    proof_log = output / 'proof.log'
    proof_log.write_text('', encoding='utf-8')  # Never reuse an earlier SUCCESS.
    (output / 'report.json').write_text(json.dumps({
        'passed': False, 'status': 'running',
        'rtl_sha256': hashlib.sha256(rtl.read_bytes()).hexdigest(),
    }, indent=2)+'\n', encoding='utf-8')
    child_env = os.environ.copy()
    # oss-cad-suite on Windows keeps runtime DLLs beside, not inside, bin.
    # Without this PATH entry Windows may show a loader dialog and never run.
    runtime_lib = Path(yosys_executable).parent.parent / 'lib'
    if os.name == 'nt' and runtime_lib.is_dir():
        child_env['PATH'] = str(runtime_lib) + os.pathsep + child_env.get('PATH', '')
    with (output / 'console.log').open('w', encoding='utf-8') as log:
        result = subprocess.run(
            [yosys_executable, '-Q', '-T', '-l', 'proof.log', '-p', yosys_command],
            cwd=output, env=child_env, stdout=log, stderr=subprocess.STDOUT)
    proof_text = proof_log.read_text(encoding='utf-8') if proof_log.exists() else ''
    passed = result.returncode == 0 and 'no model found: SUCCESS!' in proof_text
    report = {
        'passed': passed,
        'scope': 'combinational highest-bit helper; two-state inputs; no pipeline/IEEE proof',
        'magnitude_width': width,
        'rtl_sha256': hashlib.sha256(rtl.read_bytes()).hexdigest(),
        'helper_sha256': hashlib.sha256(helper_match.group(0).encode()).hexdigest(),
        'yosys_exit_code': result.returncode,
        'proof_log': relative_log,
    }
    (output / 'report.json').write_text(json.dumps(report, indent=2)+'\n', encoding='utf-8')
    if not passed:
        raise SystemExit(f'FAIL: inspect {proof_log} and {output / "console.log"}')
    print(f'PASS: highest-bit helper equivalence for all 2^{width} two-state inputs')
    print(f'Report: {output / "report.json"}')


if __name__ == '__main__':
    main()
