#!/usr/bin/env python3
"""Prove the actual SB query cone against a head-relative FIFO scan.

No simulator/tool timing assumptions: all valid bits, addresses, byte masks,
data, head positions and both queries are unconstrained. Empty-query data and
index are don't-care. This is a combinational proof, not a FIFO state-machine
or AXI ordering proof. Generated proof inputs/logs stay below out/.
"""
import argparse
import hashlib
import json
from pathlib import Path
import shutil
import subprocess


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--yosys', default='yosys')
    parser.add_argument('--entries', type=int, choices=(2, 4, 8, 16), default=16)
    parser.add_argument('--output', type=Path, default=Path('out/sb_forwarding_proof'))
    parser.add_argument('--timeout', type=int, default=300)
    parser.add_argument('--partition-head', action='store_true',
                        help='Prove every fixed head position separately (same full input space)')
    args = parser.parse_args()
    executable = shutil.which(args.yosys)
    if not executable:
        raise SystemExit(f'Yosys not found: {args.yosys}')
    root = Path(__file__).resolve().parent.parent
    source = (root / 'rtl/backend/rv_store_buffer.sv').read_text(encoding='utf-8')
    # Copy the real reduction and result logic, not a reimplementation.
    cone = source[source.index('  localparam int unsigned QTREE_LEVELS'):
                  source.index('  assign drain_rsp_ready_o')]
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=True)
    count = args.entries
    width = (count - 1).bit_length()
    report_path = output / 'report.json'
    report = {
        'passed': False, 'status': 'running', 'entries': count,
        'head_partitions_completed': 0,
        'head_partitions_required': count if args.partition_head else 1,
        'rtl_sha256': hashlib.sha256(source.encode()).hexdigest(),
        'scope': 'Actual two-query cone vs independent FIFO scan; unconstrained inputs',
        'log': str(output / 'proof.log'),
    }
    # A killed rerun must not leave a previous PASS report looking current.
    report_path.write_text(json.dumps(report, indent=2) + '\n', encoding='utf-8')
    miter = f'''module sb_query_miter #(parameter int FIXED_HEAD=-1)(
  input logic [{count-1}:0] valid_q,
  input logic [{width-1}:0] head_i,
  input logic [{count-1}:0][31:0] addresses_i,
  input logic [{count-1}:0][63:0] data_i,
  input logic [{count-1}:0][7:0] masks_i,
  input logic [1:0] query_valid_i,
  input logic [1:0][31:0] query_address_i,
  input logic [1:0][7:0] query_mask_i,
  output logic equal_o
);
  localparam int ENTRIES={count}, INDEX_WIDTH={width};
  localparam int PADDR_WIDTH=32, DATA_WIDTH=64, DATA_BYTES=8, BANK_BIT=3;
  logic [INDEX_WIDTH-1:0] head_q;
  assign head_q=(FIXED_HEAD<0) ? head_i : INDEX_WIDTH'(FIXED_HEAD);
  logic [31:0] address_q [0:ENTRIES-1];
  logic [63:0] data_q [0:ENTRIES-1];
  logic [7:0] mask_q [0:ENTRIES-1];
  logic [1:0] query_full_cover_o, query_partial_o;
  logic [1:0][63:0] query_data_o;
  logic [1:0][INDEX_WIDTH-1:0] query_index_o;
  for (genvar i=0; i<ENTRIES; i++) begin
    assign address_q[i]=addresses_i[i];
    assign data_q[i]=data_i[i];
    assign mask_q[i]=masks_i[i];
  end
{cone}
  always_comb begin
    equal_o=1'b1;
    for (int lane=0; lane<2; lane++) begin
      logic hit;
      logic [7:0] overlap;
      logic [63:0] value;
      logic [INDEX_WIDTH-1:0] chosen;
      hit=0; overlap=0; value=0; chosen=0;
      // Independent algorithm: walk oldest to youngest around the ring;
      // every later overlapping valid entry overwrites the previous match.
      for (int age=0; age<ENTRIES; age++) begin
        logic [INDEX_WIDTH-1:0] index;
        index=INDEX_WIDTH'(int'(head_q)+age);
        if (query_valid_i[lane] && valid_q[index] &&
            addresses_i[index][31:3]==query_address_i[lane][31:3] &&
            (masks_i[index] & query_mask_i[lane])!=0) begin
          hit=1; overlap=masks_i[index] & query_mask_i[lane];
          value=data_i[index]; chosen=index;
        end
      end
      equal_o &= query_full_cover_o[lane]==(hit && overlap==query_mask_i[lane]);
      equal_o &= query_partial_o[lane]==(hit && overlap!=query_mask_i[lane]);
      if (hit) equal_o &= query_data_o[lane]==value && query_index_o[lane]==chosen;
    end
  end
endmodule
'''
    (output / 'miter.sv').write_text(miter, encoding='utf-8')
    # A relative input under cwd avoids Windows slang's non-ASCII/quoted
    # absolute-path limitations; subprocess itself can select a Unicode cwd.
    heads = range(count) if args.partition_head else (None,)
    commands = [('read_slang --top sb_query_miter ' +
                 (f'-G FIXED_HEAD={head} ' if head is not None else '') +
                 'miter.sv; prep -top sb_query_miter -flatten; '
                 'sat -verify -prove equal_o 1 -show-inputs') for head in heads]
    log = output / 'proof.log'
    passed = True
    status = 'passed'
    completed = 0
    with log.open('w', encoding='utf-8') as stream:
        for partition, command in enumerate(commands):
            stream.write(f'\nHEAD PARTITION {partition}\n')
            stream.flush()
            try:
                result = subprocess.run([executable, '-p', command], cwd=output,
                                        stdout=stream, stderr=subprocess.STDOUT,
                                        timeout=args.timeout, check=False)
            except subprocess.TimeoutExpired:
                passed = False
                status = 'incomplete_timeout'
                break
            if result.returncode:
                passed = False
                status = 'failed'
                break
            completed += 1
    passed &= log.read_text(encoding='utf-8').count('SUCCESS!') == len(commands)
    if not passed and status == 'passed':
        status = 'failed'
    report.update(passed=passed, status=status, head_partitions_completed=completed)
    report_path.write_text(json.dumps(report, indent=2) + '\n', encoding='utf-8')
    print(f'{"PASS" if passed else "FAIL"}: SB FIFO forwarding, entries={count}; {log}')
    raise SystemExit(0 if passed else 1)


if __name__ == '__main__':
    main()
