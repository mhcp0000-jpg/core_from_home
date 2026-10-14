#!/usr/bin/env python3
"""Prove actual BTB selection/reset/write transitions, excluding unchanged PHT/RAS.

All BTB contents, PCs and controls are arbitrary binary values. This does not
prove whole predictor/ISA/IEEE-X behavior or physical timing.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess


def one(pattern, source):
    matches = re.findall(pattern, source, re.S)
    if len(matches) != 1:
        raise ValueError('Expected exactly one actual RTL excerpt: ' + pattern)
    return matches[0]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--reference', type=Path, required=True)
    parser.add_argument('--candidate', type=Path, required=True)
    parser.add_argument('--out', type=Path, required=True)
    args = parser.parse_args()
    reference_bytes = args.reference.read_bytes()
    candidate_bytes = args.candidate.read_bytes()
    reference = reference_bytes.decode('utf-8-sig').replace('\r\n', '\n')
    candidate = candidate_bytes.decode('utf-8-sig').replace('\r\n', '\n')
    entry = one(r'(typedef\s+struct\s+packed\s*\{[^}]*\}\s*btb_entry_t\s*;)', reference)
    if re.sub(r'\s+', '', entry) != re.sub(r'\s+', '', one(
        r'(typedef\s+struct\s+packed\s*\{[^}]*\}\s*btb_entry_t\s*;)', candidate)):
        raise ValueError('Entry type changed')
    old_select = one(r'(        resolve_set =.*?update_way = \$clog2\(BTB_WAYS\)\x27\(way\);)', reference)
    old_write = one(r'        if \(resolve_taken_i\) begin\s*(btb_q\[resolve_set\]\[update_way\].*?)\s*end', reference)
    new_set = one(r'(  assign training_set =.*?;)', candidate)
    new_tag = one(r'(  assign training_tag =.*?;)', candidate)
    new_select = one(r'(  always_comb begin\s*training_way =.*?\n  end)', candidate)
    new_enable = one(r'wire set_write = (.*?);', candidate)
    new_way_enable = one(r'else if \(set_write && (\(training_way ==.*?\))\) begin', candidate)
    new_fields = '\n'.join(one(r'(          btb_q\[set_index\]\[way\]\.' + field + r' <= .*?;)', candidate)
                           for field in ('valid', 'tag', 'target'))
    new_replace = one(r'(        btb_replace_q\[set_index\] <= training_way \+ 1\x27b1;)', candidate)
    # Restore the exact original BTB storage/selection into the candidate.
    # This proves that query/PHT/RAS/commit/recovery code is text-unchanged;
    # the word-transition proof below covers precisely the moved hardware.
    added = one(r'(  // Resolve trains the same entry.*?\n)(?=  always_ff @\(posedge clk_i\) begin)', candidate)
    reset = one(r"(      for \(integer set_index = 0; set_index < BTB_SETS; set_index\+\+\) begin.*?      end\n)", reference)
    declarations = one(r'(        logic \[BTB_SET_BITS-1:0\] resolve_set;\n.*?        logic \[\$clog2\(BTB_WAYS\)-1:0\] update_way;\n)', reference)
    global_assignment = one(r'(        resolve_global_pht_index =.*?;)', reference)
    write_block = one(r'(        if \(resolve_taken_i\) begin\n.*?        end\n)(?=        if \(resolve_mispredict_i\))', reference)
    restored = candidate.replace(added, '', 1)
    restored = restored.replace("      committed_ras_count_q <= '0;\n",
                                "      committed_ras_count_q <= '0;\n" + reset, 1)
    restored = restored.replace('        logic [PHT_BITS-1:0] resolve_global_pht_index;\n',
                                '        logic [PHT_BITS-1:0] resolve_global_pht_index;\n' + declarations, 1)
    restored = restored.replace(global_assignment, global_assignment + '\n' + old_select, 1)
    restored = restored.replace('        if (resolve_mispredict_i) begin\n',
                                write_block + '        if (resolve_mispredict_i) begin\n', 1)
    if re.sub(r'\s+', '', restored) != re.sub(r'\s+', '', reference):
        raise ValueError('Unexpected change outside proved BTB rewrite')
    # This runner is deliberately bound to the current reset semantics.
    for source in (reference, candidate):
        if not re.search(r"btb_q\[set_index\]\[way\] <= '0;", source) or not re.search(
                r"btb_replace_q\[set_index\] <= '0;", source):
            raise ValueError('Reset contract changed; update proof binding')
    out = args.out.absolute()
    if not str(out).isascii():
        raise ValueError('Use an ASCII Windows alias for native output')
    out.mkdir(parents=True, exist_ok=True)
    env = os.environ.copy()
    env['PATH'] = 'C:/rv_toolchains/oss-cad-suite/bin;C:/rv_toolchains/oss-cad-suite/lib;' + env.get('PATH', '')
    cases = []
    for width, sets, ways, negative in ((32, 64, 4, False), (64, 64, 4, False),
                                       (32, 2, 2, False), (32, 2, 2, True)):
        name = f'x{width}_s{sets}_w{ways}' + ('_negative' if negative else '')
        case = out / name
        case.mkdir(exist_ok=True)
        # A freely selected watched word proves every memory word's next
        # value without constructing thousands of temporary array versions.
        # Variable-write semantics update exactly the addressed word; static
        # enables select that same word. Set/way widths cover their full
        # power-of-two ranges, so no watch-address assumptions are required.
        writes = new_fields.replace('btb_q[set_index][way]', 'new_word').replace('<=', '=')
        if negative:
            writes = writes.replace('target = resolve_target_i;', "target = resolve_target_i ^ XLEN'(1);")
        old_fields = '\n'.join(line for line in old_write.splitlines() if 'btb_q[' in line)
        old_fields = old_fields.replace('btb_q[resolve_set][update_way]', 'old_word').replace('<=', '=')
        old_replace = one(r'(          btb_replace_q\[resolve_set\] <= update_way \+ 1\x27b1;)', reference)
        fixture = f'''module training_miter #(
  parameter int XLEN={width}, BTB_SETS={sets}, BTB_WAYS={ways},
  localparam int BTB_SET_BITS=$clog2(BTB_SETS), BTB_TAG_BITS=XLEN-BTB_SET_BITS-1,
  localparam int WAY_BITS=$clog2(BTB_WAYS), ENTRY_WIDTH=1+BTB_TAG_BITS+XLEN
) (
  input logic rst_ni, resolve_valid_i, resolve_taken_i,
  input logic [XLEN-1:0] resolve_pc_i, resolve_target_i,
  input logic [BTB_SETS-1:0][BTB_WAYS-1:0][ENTRY_WIDTH-1:0] state_i,
  input logic [BTB_SETS-1:0][WAY_BITS-1:0] replacement_i,
  input logic [BTB_SET_BITS-1:0] watch_set_i,
  input logic [WAY_BITS-1:0] watch_way_i,
  output logic equal_o
);
{entry}
btb_entry_t btb_q [0:BTB_SETS-1][0:BTB_WAYS-1];
btb_entry_t old_word, new_word;
logic [WAY_BITS-1:0] btb_replace_q [0:BTB_SETS-1];
logic [WAY_BITS-1:0] old_replace_word, new_replace_word;
logic [BTB_SET_BITS-1:0] resolve_set, training_set;
logic [BTB_TAG_BITS-1:0] resolve_tag, training_tag;
logic [WAY_BITS-1:0] update_way, training_way;
for (genvar s=0;s<BTB_SETS;s++) begin : g_input
  assign btb_replace_q[s]=replacement_i[s];
  for (genvar w=0;w<BTB_WAYS;w++) assign btb_q[s][w]=state_i[s][w];
end
always_comb begin
{old_select}
end
{new_set}
{new_tag}
{new_select}
always_comb begin
  old_word=state_i[watch_set_i][watch_way_i];
  old_replace_word=replacement_i[watch_set_i];
  if (!rst_ni) begin old_word='0; old_replace_word='0; end
  else if (resolve_valid_i && resolve_taken_i && resolve_set==watch_set_i) begin
{old_replace.replace('btb_replace_q[resolve_set]', 'old_replace_word').replace('<=', '=')}
    if (update_way==watch_way_i) begin
{old_fields}
    end
  end
end
always_comb begin
    logic [BTB_SET_BITS-1:0] set_index;
    logic [WAY_BITS-1:0] way;
    logic set_write;
    set_index=watch_set_i;
    way=watch_way_i;
    set_write={new_enable};
    new_word=state_i[watch_set_i][watch_way_i];
    new_replace_word=replacement_i[watch_set_i];
    if (!rst_ni) begin new_word='0; new_replace_word='0; end
    else if (set_write) begin
{new_replace.replace('btb_replace_q[set_index]', 'new_replace_word').replace('<=', '=')}
      if ({new_way_enable}) begin
{writes}
      end
    end
end
assign equal_o=(old_word==new_word)&&(old_replace_word==new_replace_word);
endmodule
'''
        (case / 'miter.sv').write_text(fixture, encoding='utf-8')
        (case / 'proof.ys').write_text('read_slang --std 1800-2017 --top training_miter miter.sv\n'
                                     'prep -top training_miter\nflatten\nopt\ntechmap\nopt\n'
                                     'sat -verify -prove equal_o 1 -timeout 120\n', encoding='ascii')
        with (case / 'proof.log').open('w', encoding='utf-8') as log:
            native = subprocess.run(['C:/rv_toolchains/oss-cad-suite/bin/yosys.exe', '-s', 'proof.ys'],
                                    cwd=case, env=env, stdout=log, stderr=subprocess.STDOUT, timeout=180)
        log_text = (case / 'proof.log').read_text(encoding='utf-8', errors='replace')
        passed = (native.returncode == 1 and 'proof did fail' in log_text) if negative else (
            native.returncode == 0 and 'no model found: SUCCESS!' in log_text)
        cases.append(dict(name=name, negative=negative, exit_code=native.returncode, passed=passed,
                          fixture_sha256=hashlib.sha256(fixture.encode()).hexdigest()))
        report = dict(passed=all(item['passed'] for item in cases), cases=cases, unchanged_rest=True,
                      reference_sha256=hashlib.sha256(reference_bytes).hexdigest(),
                      candidate_sha256=hashlib.sha256(candidate_bytes).hexdigest(),
                      scope='Actual extracted BTB selection/reset/write transition for a freely chosen word (therefore every word); arbitrary binary contents/PC/control including duplicate hits/replacement wrap; not unchanged PHT/RAS/full predictor/ISA/IEEE-X/STA')
        (out / 'report.json').write_text(json.dumps(report, indent=2), encoding='utf-8')
        if not passed:
            raise RuntimeError('Native BTB transition proof failed/incomplete: ' + name)
    print(json.dumps(report, indent=2))


if __name__ == '__main__':
    main()
