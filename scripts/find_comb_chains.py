#!/usr/bin/env python3
"""Find register-to-register paths that cross module boundaries without a
register in between.

Block-level timing screening synthesizes each module alone, so a path that
enters one module combinationally, leaves it, and continues into the next is
invisible there.  This tool works on the RTL hierarchy instead:

  1. For every module (bottom-up) it computes which input bits reach which
     output bits combinationally, whether an output is fed by an internal
     register, and whether an input reaches an internal register.
  2. At the top module it walks those arcs through the glue logic and lists
     the register-to-register chains that touch the most modules.

Dependencies are conservative (word-level cells may over-approximate), so it
never misses a real combinational arc.  Module-hop count is not delay; use it
to locate unregistered boundaries, then confirm with whole-top synthesis.

Usage (from the repository root, oss-cad-suite on PATH):

  yosys -p "read_slang --std 1800-2017 --single-unit --ignore-assertions \
            --ignore-initial --top rv_backend --keep-hierarchy \
            -f sim/xcelium/sources_core.f; hierarchy -check -top rv_backend; \
            proc; opt_clean; opt_expr; opt_clean; memory_collect; opt_clean; \
            write_json build/rv_backend_hier.json"
  python3 scripts/find_comb_chains.py build/rv_backend_hier.json rv_backend
"""

import json, sys, collections

sys.setrecursionlimit(1_000_000)

FF_TYPES = {'$dff', '$dffe', '$adff', '$adffe', '$sdff', '$sdffe', '$sdffce',
            '$dffsr', '$dffsre', '$aldff', '$aldffe', '$dlatch', '$adlatch',
            '$dlatchsr', '$ff', '$_DFF_P_', '$_DFF_N_'}
FF_OUT = {'Q'}
BITWISE2 = {'$and', '$or', '$xor', '$xnor', '$bweqx'}
BITWISE1 = {'$not', '$pos', '$buf'}
CARRY = {'$add', '$sub', '$neg'}   # Y[i] <- inputs[0..i]


def load(path):
    return json.load(open(path))['modules']


class Mod:
    def __init__(self, name, m):
        self.name = name
        self.m = m
        self.in_bits = []      # ordered list of (port, idx, bit)
        self.out_bits = []
        self.in_index = {}     # bit -> index into in_bits
        for p, d in m['ports'].items():
            for i, b in enumerate(d['bits']):
                if isinstance(b, str):
                    continue
                if d['direction'] == 'input':
                    self.in_index.setdefault(b, len(self.in_bits))
                    self.in_bits.append((p, i, b))
                elif d['direction'] == 'output':
                    self.out_bits.append((p, i, b))
        self.arcs = {}         # out (port, idx) -> mask over in_bits
        self.reg_out = {}      # out (port, idx) -> bool
        self.reg_in = {}       # in  (port, idx) -> bool


def analyze(mods_json, order, done):
    for name in order:
        m = mods_json[name]
        M = Mod(name, m)
        cells = m.get('cells', {})
        # driver map: bit -> (cellname, portname, index)
        driver = {}
        for cn, c in cells.items():
            pdir = c.get('port_directions', {})
            for p, bits in c['connections'].items():
                if pdir.get(p) == 'output':
                    for i, b in enumerate(bits):
                        if not isinstance(b, str):
                            driver[b] = (cn, p, i)

        memo = {}

        def deps(bit):
            """return (mask_of_module_inputs, reg_flag)."""
            if isinstance(bit, str):
                return (0, False)
            r = memo.get(bit)
            if r is not None:
                return r
            memo[bit] = (0, False)          # cycle guard
            if bit in M.in_index and bit not in driver:
                r = (1 << M.in_index[bit], False)
                memo[bit] = r
                return r
            drv = driver.get(bit)
            if drv is None:
                memo[bit] = (0, False)
                return memo[bit]
            cn, p, i = drv
            c = cells[cn]
            t = c['type']
            conn = c['connections']
            mask, reg = 0, False

            def add(bits):
                nonlocal mask, reg
                for b in bits:
                    mk, rg = deps(b)
                    mask |= mk
                    reg = reg or rg

            if t in FF_TYPES:
                reg = True
            elif t == '$mem_v2' or t == '$mem':
                # read port data: sync -> register, async -> addr comb + contents
                rd_clk_en = c['parameters'].get('RD_CLK_ENABLE', '0')
                nports = int(c['parameters'].get('RD_PORTS', '1'), 2) if isinstance(
                    c['parameters'].get('RD_PORTS'), str) else int(c['parameters'].get('RD_PORTS', 1))
                reg = True           # memory contents are state
                width = int(c['parameters'].get('WIDTH', '1'), 2) if isinstance(
                    c['parameters'].get('WIDTH'), str) else int(c['parameters'].get('WIDTH', 1))
                port_no = i // max(width, 1)
                abits = len(conn.get('RD_ADDR', [])) // max(nports, 1)
                en_str = rd_clk_en if isinstance(rd_clk_en, str) else format(rd_clk_en, 'b')
                en_str = en_str[::-1]  # LSB first
                sync = port_no < len(en_str) and en_str[port_no] == '1'
                if not sync:
                    add(conn.get('RD_ADDR', [])[port_no*abits:(port_no+1)*abits])
            elif t in BITWISE2:
                for q in ('A', 'B'):
                    v = conn.get(q, [])
                    if i < len(v):
                        add([v[i]])
                    elif v:
                        add([v[-1]])
            elif t in BITWISE1:
                v = conn.get('A', [])
                if i < len(v):
                    add([v[i]])
                elif v:
                    add([v[-1]])
            elif t == '$mux':
                for q in ('A', 'B'):
                    v = conn[q]
                    if i < len(v):
                        add([v[i]])
                add(conn['S'])
            elif t == '$bwmux':
                for q in ('A', 'B', 'S'):
                    v = conn[q]
                    if i < len(v):
                        add([v[i]])
            elif t == '$pmux':
                w = len(conn['A'])
                add([conn['A'][i]])
                bb = conn['B']
                for k in range(len(bb) // w):
                    add([bb[k*w + i]])
                add(conn['S'])
            elif t in CARRY:
                for q in ('A', 'B'):
                    v = conn.get(q, [])
                    add(v[:i+1])
            elif not t.startswith('$'):
                child = done.get(t)
                if child is None:
                    add([b for pp, bb in conn.items() for b in bb
                         if c['port_directions'].get(pp) == 'input'])
                else:
                    key = (p, i)
                    reg = child.reg_out.get(key, False)
                    cm = child.arcs.get(key, 0)
                    idx = 0
                    while cm:
                        if cm & 1:
                            ip, ii, _ = child.in_bits[idx]
                            add([conn[ip][ii]])
                        cm >>= 1
                        idx += 1
            else:
                # everything else: every output bit depends on every input bit
                for pp, bb in conn.items():
                    if c['port_directions'].get(pp) == 'input':
                        add(bb)
            r = (mask, reg)
            memo[bit] = r
            return r

        for (p, i, b) in M.out_bits:
            mk, rg = deps(b)
            M.arcs[(p, i)] = mk
            M.reg_out[(p, i)] = rg

        # sinks: FF data/control inputs, memory write ports, child reg_in
        sink_mask = 0
        for cn, c in cells.items():
            t = c['type']
            conn = c['connections']
            pdir = c.get('port_directions', {})
            bits = []
            if t in FF_TYPES:
                bits = [b for pp, bb in conn.items() if pdir.get(pp) == 'input' for b in bb]
            elif t in ('$mem_v2', '$mem'):
                for pp in ('WR_ADDR', 'WR_DATA', 'WR_EN', 'RD_ADDR', 'RD_EN', 'RD_SRST', 'RD_ARST'):
                    bits += conn.get(pp, [])
            elif not t.startswith('$') and t in done:
                child = done[t]
                for pp, bb in conn.items():
                    if pdir.get(pp) == 'input':
                        for ii, b in enumerate(bb):
                            if child.reg_in.get((pp, ii), False):
                                bits.append(b)
            for b in bits:
                sink_mask |= deps(b)[0]
        for idx, (p, i, b) in enumerate(M.in_bits):
            M.reg_in[(p, i)] = bool((sink_mask >> idx) & 1)
        M.cells = cells
        M.driver = driver
        done[name] = M
    return done


def topo_order(mods_json, top):
    order, seen = [], set()

    def visit(n):
        if n in seen:
            return
        seen.add(n)
        for c in mods_json[n].get('cells', {}).values():
            if not c['type'].startswith('$') and c['type'] in mods_json:
                visit(c['type'])
        order.append(n)
    visit(top)
    return order


def short(n):
    return n.split('$', 1)[-1].replace('rv_backend.', '') if '$' in n else n


def summarize(done, order, top):
    out = []
    for n in order:
        if n == top:
            continue
        M = done[n]
        ports_in = collections.defaultdict(int)
        # port-level arc table
        table = collections.defaultdict(set)
        for (p, i), mk in M.arcs.items():
            idx = 0
            while mk:
                if mk & 1:
                    table[p].add(M.in_bits[idx][0])
                mk >>= 1
                idx += 1
        comb_outs = {p for p, s in table.items() if s}
        out.append((short(n), M, table, comb_outs))
    return out


def chain_search(done, top):
    """Longest (in module crossings) reg->reg paths through the top module."""
    T = done[top]
    cells = T.cells
    driver = T.driver
    memo = {}

    def hop(bit):
        """(crossings, path) of the longest chain ending at net `bit`."""
        if isinstance(bit, str):
            return (-1, ())
        if bit in memo:
            return memo[bit]
        memo[bit] = (-1, ())
        if bit in T.in_index and bit not in driver:
            r = (0, ('<rv_backend input>',))
            memo[bit] = r
            return r
        drv = driver.get(bit)
        if drv is None:
            return memo[bit]
        cn, p, i = drv
        c = cells[cn]
        t = c['type']
        conn = c['connections']
        best = (-1, ())
        if t in FF_TYPES or t in ('$mem_v2', '$mem'):
            best = (0, (f'<rv_backend reg {cn[:40]}>',))
        elif not t.startswith('$') and t in done:
            child = done[t]
            key = (p, i)
            label = f'{short(t)}.{p}'
            if child.reg_out.get(key, False):
                best = (1, (f'[{short(t)} reg] -> {label}',))
            cm = child.arcs.get(key, 0)
            idx = 0
            while cm:
                if cm & 1:
                    ip, ii, _ = child.in_bits[idx]
                    h, path = hop(conn[ip][ii])
                    if h >= 0 and h + 1 > best[0]:
                        best = (h + 1, path + (f'{short(t)}.{ip} -> {short(t)}.{p}',))
                cm >>= 1
                idx += 1
        else:
            for pp, bb in conn.items():
                if c.get('port_directions', {}).get(pp) == 'input':
                    for b in bb:
                        h, path = hop(b)
                        if h > best[0]:
                            best = (h, path)
        memo[bit] = best
        return best

    results = []
    for cn, c in cells.items():
        t = c['type']
        if t.startswith('$') or t not in done:
            continue
        child = done[t]
        pdir = c.get('port_directions', {})
        for p, bb in c['connections'].items():
            if pdir.get(p) != 'input':
                continue
            for ii, b in enumerate(bb):
                if child.reg_in.get((p, ii), False):
                    h, path = hop(b)
                    if h >= 0:
                        results.append((h + 1, path + (f'{short(t)}.{p} -> [{short(t)} reg]',)))
    return results


if __name__ == '__main__':
    path = sys.argv[1]
    top = sys.argv[2] if len(sys.argv) > 2 else 'rv_backend'
    mj = load(path)
    order = topo_order(mj, top)
    done = analyze(mj, order, {})
    summ = summarize(done, order, top)
    print('=' * 100)
    print('PER-MODULE COMBINATIONAL INPUT->OUTPUT ARCS (port level)')
    print('=' * 100)
    for name, M, table, comb_outs in summ:
        nff = sum(1 for c in M.cells.values() if c['type'] in FF_TYPES)
        n_out_ports = len({p for p, _, _ in M.out_bits})
        print(f'\n## {name}   (ff cells={nff}, output ports={n_out_ports}, '
              f'comb-driven output ports={len(comb_outs)})')
        for p in sorted(table):
            if table[p]:
                ins = sorted(table[p])
                s = ', '.join(ins[:10]) + (f' ... (+{len(ins)-10})' if len(ins) > 10 else '')
                print(f'   {p:36s} <= {s}')
    res = chain_search(done, top)
    res.sort(key=lambda x: -x[0])
    print('\n' + '=' * 100)
    print('LONGEST REGISTER-TO-REGISTER CHAINS BY MODULE CROSSINGS (top %d unique)' % 40)
    print('=' * 100)
    seen = set()
    shown = 0
    for h, path in res:
        key = tuple(x.split(' -> ')[0].split('.')[0] for x in path)
        if key in seen:
            continue
        seen.add(key)
        print(f'\n[{h} modules]')
        for step in path:
            print('    ' + step)
        shown += 1
        if shown >= 40:
            break
    hist = collections.Counter(h for h, _ in res)
    print('\nhistogram (modules touched : number of sink bits):', dict(sorted(hist.items())))
