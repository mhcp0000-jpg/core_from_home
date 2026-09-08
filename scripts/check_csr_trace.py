"""Compare CSR trace smoke against architectural mscratch RMW results."""
import argparse
import csv
from pathlib import Path

p = argparse.ArgumentParser()
p.add_argument('directory', type=Path)
args = p.parse_args()
symbols = {}
for line in (args.directory / 'symbols.txt').read_text().splitlines():
    fields = line.split()
    if len(fields) == 3:
        symbols[fields[2]] = int(fields[0], 16)
with (args.directory / 'commit_trace.csv').open(newline='') as f:
    rows = list(csv.DictReader(f))
expected = {
    'check_rw': (10, 0, 1, 0x12, 'CSRRW'),
    'check_rs': (11, 0x12, 1, 0x13, 'CSRRS'),
    'check_rc': (12, 0x13, 1, 0x12, 'CSRRC'),
    'check_rwi': (13, 0x12, 1, 5, 'CSRRWI'),
    'check_rsi': (14, 5, 1, 7, 'CSRRSI'),
    'check_rci': (15, 7, 1, 6, 'CSRRCI'),
    'check_read': (16, 6, 0, 0, 'CSRRS'),
    'check_nord': (0, 0, 1, 0, 'CSRRW'),
    'check_readi': (17, 0, 0, 0, 'CSRRSI'),
}
for name, (rd, old, we, new, mnemonic) in expected.items():
    matches = [r for r in rows if int(r['pc'],16) == symbols[name]]
    assert len(matches) == 1, (name, matches)
    r = matches[0]
    assert int(r['rd']) == rd and int(r['gpr_we']) == int(rd != 0), (name,r)
    assert r['csr_valid'] == '1' and int(r['csr_we']) == we, (name,r)
    assert int(r['csr_addr'],16) == 0x340 and int(r['csr_wdata'],16) == new, (name,r)
    assert r['mnemonic'] == mnemonic, (name,r)
    assert r['fpr_we'] == '0' and r['trap'] == '0', (name,r)
    if rd:
        assert int(r['wdata'],16) == old, (name,r)
faults = [r for r in rows if r['trap'] == '1' and int(r['pc'],16) >= 0x80000000]
assert len(faults) == 1 and int(faults[0]['pc'],16) == symbols['check_illegal'], faults
assert faults[0]['cause'] == '2' and faults[0]['gpr_we'] == '0' and faults[0]['csr_we'] == '0', faults
assert faults[0]['csr_valid'] == '0', faults
assert faults[0]['mnemonic'] == 'CSRRW', faults
assert all(r['csr_we'] == '0' for r in rows if r['lane'] == '1'), 'CSR misattributed to lane 1'
print('PASS: 6 CSR forms, read-only register/immediate, rd=x0, illegal write; GPR/CSR fields and mnemonics match')
