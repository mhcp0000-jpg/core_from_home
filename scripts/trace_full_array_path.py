#!/usr/bin/env python3
"""Memory-bounded register-cone tracer for a FULL, flattened pre-ABC RTLIL.

Two streaming passes and compact numeric arrays avoid holding millions of cell
dicts/strings simultaneously. Refuses inferred memories, unknown cells, multiple
modules/drivers and combinational cycles. Reports STRUCTURAL unit costs, NOT ns
or STA. Cost model matches trace_named_path.py's primitive/fanout heuristics.
"""
import argparse
import array
import hashlib
import json
import math
import re
import sys
import time
from pathlib import Path

COSTS = {"$_NOT_": 0.3, "$_AND_": 1.0, "$_OR_": 1.0, "$_XOR_": 1.6,
         "$_XNOR_": 1.6, "$_MUX_": 1.4, "$_NAND_": 0.8, "$_NOR_": 0.8,
         "$_ANDNOT_": 1.0, "$_ORNOT_": 1.0, "$_BUF_": 0.0,
         "$_AOI3_": 1.2, "$_OAI3_": 1.2, "$_AOI4_": 1.4, "$_OAI4_": 1.4}
TOKENS = re.compile(r"\{|\}|\[[0-9:]+\]|[0-9]+'[01xzm-]*|-?[0-9]+|\\\S+|\$\S+")


class Graph:
    def __init__(self):
        self.wires = {}  # identifier -> (base, width); no bit-name dictionary
        self.public = []
        self.input_ranges = []
        self.parent = array.array("i")
        self.modules = []
        self.cell_count = 0
        self.started = time.monotonic()

    def root(self, n):
        if n < 0:
            return -1
        while self.parent[n] != n:
            self.parent[n] = self.parent[self.parent[n]]
            n = self.parent[n]
        return n

    def bits(self, text):
        toks = TOKENS.findall(text)

        def take(i):
            token = toks[i]
            if token == "{":
                parts = []
                i += 1
                while toks[i] != "}":
                    part, i = take(i)
                    parts.append(part)
                return [bit for part in reversed(parts) for bit in part], i + 1
            if token[0].isdigit() or token[0] == "-":
                width = int(token.split("'")[0]) if "'" in token else 32
                return [-1] * width, i + 1  # constants are not source paths
            base, width = self.wires[token]
            if i + 1 < len(toks) and toks[i+1].startswith("["):
                sel = toks[i+1][1:-1]
                if ":" in sel:
                    hi, lo = map(int, sel.split(":"))
                else:
                    hi = lo = int(sel)
                return list(range(base+lo, base+hi+1)), i + 2
            return list(range(base, base+width)), i + 1

        bits, end = take(0)
        if end != len(toks):
            raise ValueError(f"Trailing sigspec tokens: {text[:160]}")
        return bits

    def aliases(self, text):
        # Split two top-level sigspecs, respecting concatenation and bit ranges.
        toks = TOKENS.findall(text)
        depth = 0
        end = 1
        if toks[0] == "{":
            for i, tok in enumerate(toks):
                depth += (tok == "{") - (tok == "}")
                if depth == 0:
                    end = i + 1
                    break
        elif len(toks) > 1 and toks[1].startswith("["):
            end = 2
        lhs = self.bits(" ".join(toks[:end]))
        rhs = self.bits(" ".join(toks[end:]))
        if len(lhs) != len(rhs):
            raise ValueError("Alias width mismatch")
        for a, b in zip(lhs, rhs):
            if a >= 0 and b >= 0:
                ra, rb = self.root(a), self.root(b)
                if ra != rb:
                    self.parent[ra] = rb

    def first_pass(self, path):
        in_cell = False
        digest = hashlib.sha256()
        with path.open("rb") as stream:
            for raw in stream:
                digest.update(raw)
                text = raw.decode("utf-8").strip()
                if text.startswith("module "):
                    self.modules.append(text[7:])
                elif text.startswith("wire "):
                    fields = text.split()
                    width = int(fields[fields.index("width")+1]) if "width" in fields else 1
                    name = fields[-1]
                    if name in self.wires:
                        raise ValueError(f"Duplicate wire: {name}")
                    base = len(self.parent)
                    self.wires[name] = (base, width)
                    self.parent.extend(range(base, base+width))
                    if "input" in fields:
                        self.input_ranges.append((base, width))
                    if name.startswith("\\"):
                        self.public.append((name, base, width))
                elif text.startswith("memory "):
                    raise ValueError("Memory object found; this is NOT a full-array netlist")
                elif text.startswith("cell "):
                    in_cell = True
                    self.cell_count += 1
                elif text == "end":
                    in_cell = False
                elif text.startswith("connect ") and not in_cell:
                    self.aliases(text[8:])
        if len(self.modules) != 1:
            raise ValueError("Requires exactly one flattened module")
        self.sha256 = digest.hexdigest()
        self.progress(f"aliases: {len(self.parent)} bits / {self.cell_count} cells")

    def progress(self, text):
        print(f"[{time.monotonic()-self.started:.1f}s] {text}", file=sys.stderr, flush=True)

    def second_pass(self, path):
        size = len(self.parent)
        self.pred = [array.array("i", [-1]) * size for _ in range(3)]
        self.kind = bytearray(size)
        self.register = bytearray(size)
        self.fanout = array.array("I", [0]) * size
        self.ff_d = array.array("i")
        self.ff_q = array.array("i")
        self.kinds = {name: i+1 for i, name in enumerate(COSTS)}
        self.delays = [0.0] + list(COSTS.values())
        ctype = None
        ports = {}

        def finish():
            if ctype == "$scopeinfo":
                return
            if ctype in self.kinds:
                output = self.bits(ports["Y"])
                if len(output) != 1:
                    raise ValueError("Primitive output is not scalar")
                y = self.root(output[0])
                if y < 0:
                    return
                if self.kind[y] or self.register[y]:
                    raise ValueError(f"Multiple drivers: {y}")
                ins = []
                for pin in ("A", "B", "C", "D", "S"):
                    if pin in ports:
                        ins.extend(self.bits(ports[pin]))
                if len(ins) > 3:
                    # AOI4/OAI4 use four inputs; rejected rather than silently cut.
                    raise ValueError("Four-input primitive requires an extended tracer")
                self.kind[y] = self.kinds[ctype]
                for i, bit in enumerate(ins):
                    x = self.root(bit)
                    self.pred[i][y] = x
                    if x >= 0:
                        self.fanout[x] += 1
            elif ctype in ("\\DFF_X1", "$_DFF_P_", "$_DFF_N_"):
                qs = self.bits(ports["Q"])
                ds = self.bits(ports["D"])
                if len(qs) != len(ds):
                    raise ValueError("FF width mismatch")
                for q, d in zip(qs, ds):
                    q, d = self.root(q), self.root(d)
                    if q >= 0:
                        if self.kind[q] or self.register[q]:
                            raise ValueError(f"Multiple FF/logic drivers: {q}")
                        self.register[q] = 1
                    if q >= 0 and d >= 0:
                        self.ff_q.append(q)
                        self.ff_d.append(d)
            else:
                raise ValueError(f"Unsupported cell type; refusing omitted path: {ctype}")

        with path.open(encoding="utf-8") as stream:
            for line in stream:
                text = line.strip()
                if text.startswith("cell "):
                    _, ctype, _ = text.split(None, 2)
                    ports = {}
                elif text.startswith("connect ") and ctype is not None:
                    _, pin, value = text.split(None, 2)
                    ports[pin.lstrip("\\")] = value
                elif text == "end" and ctype is not None:
                    finish()
                    ctype = None
        self.progress(f"graph: {len(self.ff_q)} FF boundaries; all cells recognized")

    def matched(self, pattern):
        if pattern is None:
            return set()
        regex = re.compile(pattern)
        roots = set()
        for name, base, width in self.public:
            if regex.search(name[1:]):
                roots.update(self.root(base+i) for i in range(width))
        return roots

    def exact(self, spec):
        match = re.fullmatch(r"(.*)\[([0-9]+)\]", spec)
        name, index = (match[1], int(match[2])) if match else (spec, 0)
        key = name if name in self.wires else "\\"+name
        if key not in self.wires:
            raise ValueError(f"Wire not found: {spec}")
        base, width = self.wires[key]
        if index >= width:
            raise ValueError(f"Bit outside wire width: {spec}")
        return self.root(base+index)

    def trace(self, source_pattern, end_pattern, top, source_bit=None,
              target_node=None, source_kind="ff", target_bit=None):
        qualified = {self.exact(source_bit)} if source_bit else self.matched(source_pattern)
        inputs = {self.root(base+i) for base, width in self.input_ranges for i in range(width)}
        qualified = {n for n in qualified if
          (source_kind in ("ff", "ff_or_input") and self.register[n]) or
          (source_kind in ("input", "ff_or_input") and n in inputs)}
        endpoints = {self.exact(target_bit)} if target_bit else self.matched(end_pattern)
        targets = [(d, q) for d, q in zip(self.ff_d, self.ff_q) if q in endpoints]
        if target_node:
            node = self.exact(target_node)
            targets = [(d, q) for d, q in zip(self.ff_d, self.ff_q) if d == node]
            if not targets:
                targets = [(node, node)]  # explicitly requested internal signal, NOT FF timing
        if not qualified or not targets:
            raise ValueError(f"No matching FFs: sources={len(qualified)} endpoints={len(targets)}")
        self.progress(f"selected {len(qualified)} source FF bits / {len(targets)} endpoint FF bits")
        size = len(self.parent)
        color = bytearray(size)
        arrival = array.array("f", [float("-inf")]) * size
        previous = array.array("i", [-1]) * size

        def evaluate(start):
            stack = [[start, 0]]
            while stack:
                n, edge = stack[-1]
                if color[n] == 2:
                    stack.pop()
                    continue
                if not self.kind[n] or self.register[n]:
                    arrival[n] = 0.0 if n in qualified else float("-inf")
                    color[n] = 2
                    stack.pop()
                    continue
                color[n] = 1
                if edge < 3:
                    stack[-1][1] += 1
                    p = self.pred[edge][n]
                    if p >= 0 and color[p] != 2:
                        if color[p] == 1:
                            raise ValueError("Combinational cycle in selected cone")
                        stack.append([p, 0])
                else:
                    best, bp = float("-inf"), -1
                    for pred in self.pred:
                        p = pred[n]
                        if p >= 0:
                            value = arrival[p] + self.delays[self.kind[n]] + 0.2*math.log2(max(1, self.fanout[p]))
                            if value > best:
                                best, bp = value, p
                    arrival[n], previous[n] = best, bp
                    color[n] = 2
                    stack.pop()

        ranked = []
        for d, q in targets:
            evaluate(d)
            if math.isfinite(arrival[d]):
                ranked.append((arrival[d], d, q))
        ranked.sort(reverse=True)
        if not ranked:
            raise ValueError("No combinational source-to-endpoint path in the full model")
        paths, needed = [], set()
        for value, d, q in ranked[:top]:
            path = []
            n = d
            while n >= 0:
                path.append(n)
                n = previous[n]
            path.reverse()
            needed.update(path)
            needed.add(q)
            paths.append((value, path, q))
        names = {}
        for name, base, width in self.public:
            for i in range(width):
                root = self.root(base+i)
                if root in needed:
                    label = name[1:] + (f"[{i}]" if width > 1 else "")
                    if root not in names or len(label) < len(names[root]):
                        names[root] = label
        if target_node:
            names.setdefault(self.exact(target_node), target_node)
        result = []
        for value, path, q in paths:
            item = {"units": value, "gates": len(path)-1,
                    "source": names.get(path[0], f"internal#{path[0]}"),
                    "endpoint": names.get(q, f"internal#{q}"),
                    "named_steps": [{"units": arrival[n], "signal": names[n]}
                                    for n in path if n in names]}
            print(f"=== {value:.2f} STRUCTURAL units: {item['source']} -> {item['endpoint']} ({item['gates']} gates)")
            for step in item["named_steps"]:
                print(f"  {step['units']:8.2f}  {step['signal']}")
            result.append(item)
        return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("netlist", type=Path)
    start = parser.add_mutually_exclusive_group(required=True)
    start.add_argument("--src", help="regex of source public aliases")
    start.add_argument("--srcbit", help="exact source alias and optional bit index")
    end = parser.add_mutually_exclusive_group(required=True)
    end.add_argument("--to", help="regex of ENDPOINT FF public aliases")
    end.add_argument("--tobit", help="exact endpoint FF Q alias and optional bit index")
    end.add_argument("--tonode", help="exact endpoint D/internal signal alias from ABC")
    parser.add_argument("--source-kind", choices=("ff", "input", "ff_or_input"), default="ff",
                        help="Require FF sources by default; inputs must be explicitly enabled")
    parser.add_argument("--top", type=int, default=3)
    parser.add_argument("--json", type=Path)
    args = parser.parse_args()
    if args.top < 1:
        parser.error("--top must be positive")
    if args.json and args.json.exists():
        parser.error("Refusing to overwrite an existing report")
    graph = Graph()
    graph.first_pass(args.netlist)
    graph.second_pass(args.netlist)
    paths = graph.trace(args.src, args.to, args.top, args.srcbit, args.tonode, args.source_kind, args.tobit)
    if args.json:
        args.json.parent.mkdir(parents=True, exist_ok=True)
        args.json.write_text(json.dumps({"netlist_sha256": graph.sha256,
          "scope": "Full-array structural path; heuristic units, NOT STA/ns or sensitization proof",
          "cells_checked": graph.cell_count, "bits": len(graph.parent),
          "source_regex": args.src, "source_bit": args.srcbit, "source_kind": args.source_kind,
          "endpoint_regex": args.to, "endpoint_node": args.tonode, "endpoint_bit": args.tobit,
          "paths": paths}, indent=2)+"\n", encoding="utf-8")


if __name__ == "__main__":
    main()
