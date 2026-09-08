"""Check locked-PMP denial after an optional earlier execution of victim.

The diagnostic handler intentionally exits HTIF with code 1. Only exact trap
and commit counts establish success; a simulator failure alone never does.
"""
import argparse
import csv

p = argparse.ArgumentParser()
p.add_argument('trace')
p.add_argument('--warm', type=int, choices=[0, 1], required=True)
args = p.parse_args()
with open(args.trace, newline='') as f:
    rows = list(csv.DictReader(f))
victim = [r for r in rows if int(r['pc'],16) == 0x80000800]
successful = [r for r in victim if r['trap'] == '0']
faults = [r for r in rows if r['trap'] == '1' and int(r['pc'],16) >= 0x80000000]
assert len(successful) == args.warm, ('unauthorized or missing execution', successful)
assert len(faults) == 1, faults
fault = faults[0]
assert int(fault['pc'],16) == 0x80000800 and int(fault['cause']) == 1, fault
assert int(fault['tval'],16) == 0x80000800, fault
assert len(victim) == args.warm + 1, victim
for r in successful:
    assert int(r['instruction'],16) == 0x00140413 and int(r['wdata'],16) == 1, r
handler = [r for r in rows if int(r['pc'],16) == 0x80000200 and r['trap'] == '0']
assert len(handler) == 1 and int(handler[0]['wdata'],16) == 1, handler
print(f'PASS: warm={args.warm}, victim executions={len(successful)}, locked instruction fault=1, handler mcause=1')
