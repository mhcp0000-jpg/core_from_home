#!/usr/bin/env python3
"""Named critical-path tracer for a flattened pre-ABC Yosys RTLIL netlist
(scripts/trace_named_path.py).

ABC reports only gate ids, so this walks the gate-level netlist (after
techmap, before abc) with a simple delay model and prints the longest
register-to-register paths through *named* RTL signals.

Delay model (unit ~ one 2-input gate): NOT 0.3, AND/OR 1.0, XOR/XNOR 1.6,
MUX 1.4, plus 0.2*log2(fanout).  Async-read $mem_v2 ports are traversed
from RD_ADDR to RD_DATA with ceil(log2(SIZE))*1.4 (a mux tree).  It is a
structure finder, not signoff: compare its ranking with ABC's worst path.

usage:
  trace_named_path.py netlist.il --top 5                      # worst endpoints
  trace_named_path.py netlist.il --src 'dmem_rsp_replay_i'    # from matching sources
  trace_named_path.py netlist.il --srcbit 'u_x.count_q[3]' --tonode 'u_x.byte_d[203]'
The netlist is the pre-ABC RTLIL written by the whole-top flow (after
techmap/dfflibmap, before abc).  Unit delays over-count serial loops that
ABC rebalances (e.g. FPU LZC, one-hot OR chains); use it to name the stages
of a path ABC reported, not to rank paths.
"""
import sys, re, math, argparse, collections, array

ap = argparse.ArgumentParser()
ap.add_argument('il')
ap.add_argument('--top', type=int, default=5)
ap.add_argument('--to', default=None, help='regex on endpoint name')
ap.add_argument('--frm', default=None, help='regex on startpoint name')
ap.add_argument('--src', default=None, help='only sources whose name matches')
ap.add_argument('--exclude', default=None, help='regex of endpoints to skip')
ap.add_argument('--srcbit', default=None, help='exact wire[idx] start (any alias)')
ap.add_argument('--tonode', default=None, help='exact wire[idx] internal node to report')
ap.add_argument('--tobit', default=None, help='exact wire[idx] of the endpoint FF Q (any alias)')
args = ap.parse_args()

GATE_DELAY = {'$_NOT_': 0.3, '$_AND_': 1.0, '$_OR_': 1.0, '$_XOR_': 1.6,
              '$_XNOR_': 1.6, '$_MUX_': 1.4, '$_NAND_': 0.8, '$_NOR_': 0.8,
              '$_ANDNOT_': 1.0, '$_ORNOT_': 1.0, '$_BUF_': 0.0,
              '$_AOI3_': 1.2, '$_OAI3_': 1.2, '$_AOI4_': 1.4, '$_OAI4_': 1.4}
GATE_OUT = 'Y'

wire_base = {}      # name -> base id
wire_width = {}
wire_names = []
bit_wire = array.array('l')
nbits = 0
parent = array.array('l')

def new_wire(name, width):
    global nbits
    wire_base[name] = nbits
    wire_width[name] = width
    wi = len(wire_names); wire_names.append(name)
    bit_wire.extend([wi] * width)
    parent.extend(range(nbits, nbits + width))
    nbits += width

CONST0, CONST1, CONSTX = -1, -2, -3
tok_re = re.compile(r"\{|\}|\[[0-9:]+\]|[0-9]+'[01xzm-]*|-?[0-9]+|\\\S+|\$\S+")

def _parse_one(toks, i):
    """Parse one sigspec starting at toks[i]; return (bits LSB-first, next i)."""
    t = toks[i]
    if t == '{':
        parts = []; i += 1
        while toks[i] != '}':
            bits, i = _parse_one(toks, i); parts.append(bits)
        out = []
        for p in reversed(parts): out.extend(p)
        return out, i + 1
    if t[0].isdigit() or t[0] == '-':
        if "'" not in t:
            v = int(t) & 0xffffffff
            return [CONST1 if (v >> k) & 1 else CONST0 for k in range(32)], i + 1
        v = t.split("'")[1]
        return [CONST1 if ch == '1' else CONST0 if ch == '0' else CONSTX
                for ch in reversed(v)], i + 1
    base = wire_base[t]; width = wire_width[t]
    if i + 1 < len(toks) and toks[i+1].startswith('['):
        sel = toks[i+1][1:-1]; i += 1
        if ':' in sel:
            hi, lo = map(int, sel.split(':'))
            return [base + k for k in range(lo, hi+1)], i + 1
        return [base + int(sel)], i + 1
    return [base + k for k in range(width)], i + 1

def parse_sig(s):
    toks = tok_re.findall(s)
    bits, _ = _parse_one(toks, 0)
    return bits

def parse_pair(s):
    toks = tok_re.findall(s)
    a, i = _parse_one(toks, 0)
    b, _ = _parse_one(toks, i)
    return a, b

def find(x):
    while parent[x] != x:
        parent[x] = parent[parent[x]]
        x = parent[x]
    return x

def union(a, b):
    if a < 0 or b < 0: return
    ra, rb = find(a), find(b)
    if ra != rb: parent[ra] = rb

cells = []   # (type, {port: sig string}, params)
connects = []
sys.stderr.write('parsing...\n')
with open(args.il) as f:
    cur = None
    for line in f:
        s = line.strip()
        if s.startswith('wire '):
            parts = s.split()
            width = 1
            if 'width' in parts:
                width = int(parts[parts.index('width')+1])
            new_wire(parts[-1], width)
        elif s.startswith('cell '):
            _, ctype, cname = s.split(None, 2)
            cur = [ctype, {}, {}, cname]
        elif s.startswith('parameter ') and cur is not None:
            p = s.split(None, 2)
            cur[2][p[1]] = p[2] if len(p) > 2 else ''
        elif s.startswith('connect '):
            if cur is not None:
                _, port, sig = s.split(None, 2)
                cur[1][port.lstrip(chr(92))] = sig
            else:
                connects.append(s[8:])
        elif s == 'end':
            if cur is not None:
                cells.append(tuple(cur)); cur = None
sys.stderr.write(f'{nbits} bits, {len(cells)} cells\n')

for c in connects:
    a, b = parse_pair(c)
    for x, y in zip(a, b):
        if x >= 0 and y >= 0: union(x, y)

rep_name = {}
def score(b):
    n = wire_names[bit_wire[b]]
    return (0 if n.startswith(chr(92)) else 1, len(n))
def resolve_names(roots):
    need = set(roots) - set(rep_name)
    if not need: return
    for b in range(nbits):
        rt = find(b)
        if rt in need:
            c = rep_name.get(rt)
            if c is None or score(b) < score(c): rep_name[rt] = b
def nm(bit):
    if bit is None or bit < 0: return 'const'
    rt = find(bit)
    if rt not in rep_name: resolve_names([rt])
    b = rep_name[rt]
    n = wire_names[bit_wire[b]]; i = b - wire_base[n]
    if n.startswith(chr(92)): n = n[1:]
    return n + (f'[{i}]' if wire_width[wire_names[bit_wire[b]]] > 1 else '')

# Build graph: node = set root. preds[node] = list of (pred, delay)
fanin = collections.defaultdict(list)
fanout_cnt = collections.Counter()
sources = set(); sinks = {}
def r(b): return find(b) if b >= 0 else None

for ctype, conn, params, cname in cells:
    if ctype in GATE_DELAY:
        y = parse_sig(conn['Y'])[0]
        ins = []
        for p in ('A', 'B', 'C', 'D', 'S'):
            if p in conn:
                ins.extend(parse_sig(conn[p]))
        ry = r(y)
        for x in ins:
            if x >= 0:
                fanin[ry].append((r(x), GATE_DELAY[ctype]))
                fanout_cnt[r(x)] += 1
    elif ctype == '\\DFF_X1' or ctype.startswith('$_DFF') or ctype.startswith('$_SDFF'):
        q = conn.get('Q'); d = conn.get('D')
        qb = parse_sig(q)[0] if q else -1
        if q:
            for b in parse_sig(q): sources.add(r(b))
        if 'QN' in conn:
            for b in parse_sig(conn['QN']):
                if b >= 0: sources.add(r(b))
        if d:
            for b in parse_sig(d):
                if b >= 0: sinks[r(b)] = ('FF', qb)
    elif ctype == '$mem_v2':
        size = int(params.get('\\SIZE', '1'))
        width = int(params.get('\\WIDTH', '1'))
        nrd = int(params.get('\\RD_PORTS', '0'))
        abits = int(params.get('\\ABITS', '1'))
        clkv = params.get('\\RD_CLK_ENABLE', "0")
        clkbits = clkv.split("'")[1] if "'" in clkv else bin(int(clkv))[2:].zfill(max(nrd,1))
        clkbits = clkbits[::-1]
        raddr = parse_sig(conn['RD_ADDR']) if 'RD_ADDR' in conn else []
        rdata = parse_sig(conn['RD_DATA']) if 'RD_DATA' in conn else []
        mdel = math.ceil(math.log2(max(size, 2))) * 1.4
        for p in range(nrd):
            a = raddr[p*abits:(p+1)*abits]; dd = rdata[p*width:(p+1)*width]
            sync = p < len(clkbits) and clkbits[p] == '1'
            for db in dd:
                if db < 0: continue
                rd = r(db)
                sources.add(rd)            # contents act as registers
                if not sync:
                    for ab in a:
                        if ab >= 0:
                            fanin[rd].append((r(ab), mdel))
                            fanout_cnt[r(ab)] += 1
        for port in ('WR_ADDR', 'WR_DATA', 'WR_EN'):
            if port in conn:
                for b in parse_sig(conn[port]):
                    if b >= 0: sinks[r(b)] = ('MEMW', cname)
    # other cell types ignored

# ports
for name, base in wire_base.items():
    pass
sys.stderr.write(f'graph nodes {len(fanin)}, sources {len(sources)}, sinks {len(sinks)}\n')

# names for every root (one pass)
sys.stderr.write('naming...\n')
for b in range(nbits):
    rt = find(b)
    c = rep_name.get(rt)
    if c is None or score(b) < score(c): rep_name[rt] = b
def exact_root(spec):
    m = re.match(r'(.*)\[(\d+)\]$', spec)
    name, idx = (m.group(1), int(m.group(2))) if m else (spec, 0)
    # RTLIL has escaped user identifiers (\name) and unescaped internal $ids.
    # ABC endpoints may be either; also accept an explicitly escaped CLI name.
    key = name if name in wire_base else chr(92) + name
    if key not in wire_base:
        raise SystemExit(f'Wire not found: {name}')
    if idx >= wire_width[key]:
        raise SystemExit(f'Bit index out of range: {spec}; width={wire_width[key]}')
    return find(wire_base[key] + idx)
src_ok = None
if args.srcbit:
    src_ok = {exact_root(args.srcbit)}
if args.src:
    rxs = re.compile(args.src)
    src_ok = set(n for n in rep_name if (n in sources or n not in fanin) and rxs.search(nm(n)))
    # primary inputs (no fanin, not FF) count as sources when named
    sys.stderr.write(f'{len(src_ok)} selected sources\n')
# arrival times via iterative DFS (memoized)
arr = {}
pred = {}
def arrival(n0):
    stack = [(n0, 0)]
    while stack:
        n, st = stack.pop()
        if n in arr: continue
        if n in sources or n not in fanin:
            arr[n] = 0.0 if (src_ok is None or n in src_ok) else -1e9
            pred[n] = None; continue
        if st == 0:
            stack.append((n, 1))
            for p, _ in fanin[n]:
                if p not in arr: stack.append((p, 0))
        else:
            best = -2e9; bp = None
            for p, dl in fanin[n]:
                a = arr.get(p, 0.0) + dl + 0.2 * math.log2(max(1, fanout_cnt[p]))
                if a > best: best, bp = a, p
            arr[n] = best; pred[n] = bp
for s in list(sinks):
    arrival(s)

def path_of(n):
    out = []
    while n is not None:
        out.append(n); n = pred.get(n)
    return out[::-1]

if args.tonode:
    tn = exact_root(args.tonode)
    arrival(tn)
    p = path_of(tn)
    print(f'=== {arr[tn]:.1f} units  start {nm(p[0])}  ->  node {args.tonode}  gates={len(p)-1}')
    last = None
    for n in p:
        name = nm(n)
        if not name.startswith('$') and name != last:
            print(f'    {arr[n]:6.1f}  {name}')
            last = name
    sys.exit(0)
def sink_name(e):
    k, v = sinks[e]
    return nm(v) if k == 'FF' else 'MEMW ' + v
ends = sorted(sinks, key=lambda s: -arr.get(s, 0))
rxt = re.compile(args.to) if args.to else None
rxx = re.compile(args.exclude) if args.exclude else None
to_root = exact_root(args.tobit) if args.tobit else None
shown = 0
for e in ends:
    if arr.get(e, -1) < 0: break
    sn = sink_name(e)
    if to_root is not None and not (sinks[e][0] == 'FF' and find(sinks[e][1]) == to_root) and e != to_root: continue
    if rxt and not rxt.search(sn): continue
    if rxx and rxx.search(sn): continue
    p = path_of(e)
    print(f'=== {arr[e]:.1f} units  start {nm(p[0])}  ->  end {sn}  gates={len(p)-1}')
    last = None
    for n in p:
        name = nm(n)
        if not name.startswith('$') and name != last:
            print(f'    {arr[n]:6.1f}  {name}')
            last = name
    shown += 1
    if shown >= args.top: break
