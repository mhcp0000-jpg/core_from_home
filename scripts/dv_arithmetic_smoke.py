"""Small RV32I test using upstream riscv-dv's experimental generator.

Generate with --dv-root PATH; validate an executed commit CSV with --trace PATH.
This is not the SV/UVM generator or a complete ISS comparison.
"""
import argparse
import csv
import hashlib
import json
from pathlib import Path
import random
import sys

REGS = 'zero ra sp gp tp t0 t1 t2 s0 s1 a0 a1 a2 a3 a4 a5 a6 a7 s2 s3 s4 s5 s6 s7 s8 s9 s10 s11 t3 t4 t5 t6'.split()
MASK = 0xffffffff

def signed(v):
    return v if v < 0x80000000 else v - 0x100000000

def evaluate(asm, regs, pc):
    op, args = asm.split(None, 1)
    args = [a.strip() for a in args.split(',')]
    rd = REGS.index(args[0])
    if op in ('lui', 'auipc'):
        value = (int(args[1], 0) << 12) + (pc if op == 'auipc' else 0)
    else:
        a = regs[REGS.index(args[1])]
        b = int(args[2], 0) if op.endswith('i') or op in ('slli', 'srli', 'srai', 'sltiu') else regs[REGS.index(args[2])]
        name = {'addi':'add', 'andi':'and', 'ori':'or', 'xori':'xor', 'slti':'slt', 'sltiu':'sltu', 'slli':'sll', 'srli':'srl', 'srai':'sra'}.get(op, op)
        b &= MASK
        value = {'add':lambda:a+b, 'sub':lambda:a-b, 'and':lambda:a&b,
                 'or':lambda:a|b, 'xor':lambda:a^b, 'slt':lambda:int(signed(a)<signed(b)),
                 'sltu':lambda:int(a<b), 'sll':lambda:a<<(b&31),
                 'srl':lambda:a>>(b&31), 'sra':lambda:signed(a)>>(b&31)}[name]()
    value &= MASK
    if rd:
        regs[rd] = value
    return rd, value if rd else 0

def main():
    p = argparse.ArgumentParser()
    p.add_argument('--dv-root', type=Path)
    p.add_argument('--output', type=Path, required=True)
    p.add_argument('--seed', type=int, default=7)
    p.add_argument('--count', type=int, default=256)
    p.add_argument('--trace', type=Path)
    args = p.parse_args()
    args.output.mkdir(parents=True, exist_ok=True)
    manifest = args.output / 'expected.json'
    if args.trace:
        spec = json.loads(manifest.read_text())
        expected = spec['expected']
        seen = []
        traps = []
        boot_interrupts = 0
        elf_started = False
        entered = False
        with args.trace.open() as f:
            for row in csv.DictReader(f):
                pc = int(row['pc'], 16)
                elf_started |= pc == 0x80000000
                if int(row['trap']):
                    # This trace interface omits the interrupt bit. Recognize
                    # only the expected pre-entry Boot ROM MSIP event.
                    if not elf_started and pc == 0x101c and int(row['cause']) == 3 and int(row['tval'], 16) == 0:
                        boot_interrupts += 1
                    else:
                        traps.append(row)
                entered |= pc == 0x800008fc and int(row['instruction'], 16) == 0x80000b37 and not int(row['trap'])
                if spec['payload_start'] <= pc < spec['payload_start'] + 4*len(expected):
                    e = expected[len(seen)]
                    assert pc == e['pc'], (row, e)
                    assert int(row['rd']) == e['rd'], (row, e)
                    assert int(row['rd_write']) == int(e['rd'] != 0), (row, e)
                    if e['rd']:
                        assert int(row['wdata'], 16) == e['value'], (row, e)
                    seen.append(row)
        assert entered and len(seen) == len(expected) and not traps and boot_interrupts == 1, (entered, len(seen), traps, boot_interrupts)
        print(f'PASS: main=800008fc, {len(seen)} arithmetic commits match reference, ELF traps=0, expected boot MSIP=1')
        return
    source = args.dv_root / 'pygen/experimental'
    sys.path.insert(0, str(source.resolve()))
    from riscv_rand_instr import riscv_rand_instr
    random.seed(args.seed)
    regs = [0] + [random.getrandbits(32) for _ in range(31)]
    lines = ['.section .text.init', '.option norelax', '.option norvc', '.globl _start', '_start:',
             'j entry_jump', '.org 0x166', '.option rvc', 'entry_jump:', 'c.j main',
             '.option norvc', '.org 0x8fc', '.globl main', 'main:', 'lui s6,0x80000']
    for i in range(1,32):
        # Two real instructions per register: payload PC does not depend on li relaxation.
        v = regs[i]
        lo = (v & 0xfff) - (0x1000 if v & 0x800 else 0)
        hi = ((v - lo) >> 12) & 0xfffff
        lines += [f'lui {REGS[i]}, {hi}', f'addi {REGS[i]}, {REGS[i]}, {lo}']
    start = 0x80000900 + 31*8
    expected = []
    allowed = ['ADD','SUB','ADDI','AND','OR','XOR','ANDI','ORI','XORI','SLT','SLTU','SLTI','SLTIU','SLL','SRL','SRA','SLLI','SRLI','SRAI','LUI','AUIPC']
    for i in range(args.count):
        instr = riscv_rand_instr()
        instr.problem_definition(no_branch=1, no_load_store=1)
        instr.problem.addConstraint(lambda name: name in allowed, [instr.instr_name])
        instr.randomize()
        asm = instr.convert2asm().strip()
        pc = start + i*4
        rd, value = evaluate(asm, regs, pc)
        expected.append(dict(pc=pc, asm=asm, rd=rd, value=value))
        lines.append(asm)
    lines += ['lui t0,0x80020', 'addi t1,zero,1', 'sw zero,4(t0)', 'sw t1,0(t0)',
              'done: j done', '.section .htif,"aw",@progbits', '.balign 8',
              '.globl tohost', 'tohost: .dword 0', '.globl fromhost', 'fromhost: .dword 0']
    (args.output / 'test.S').write_text('\n'.join(lines)+'\n')
    manifest.write_text(json.dumps(dict(seed=args.seed, generator='riscv-dv pygen/experimental',
        upstream_sha256={f.name:hashlib.sha256(f.read_bytes()).hexdigest() for f in source.glob('*.py')},
        payload_start=start, expected=expected), indent=2)+'\n')
    print(f'Generated {len(expected)} instructions, seed={args.seed}')

if __name__ == '__main__':
    main()
