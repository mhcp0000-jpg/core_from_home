"""Full-array structural diagnostic without Yosys's large flatten peak.

Streams a fine_hierarchy.il through an exact hierarchy/port expansion and
explicit synchronous-reset/enable FF logic. No memories or unknown cells may
be omitted. This is NOT physical STA, ns, or the post-flatten/ABC cost model:
cross-module constant folding is not performed. Use matched inputs/model.
"""
import argparse
import contextlib
import hashlib
import json
import re
from pathlib import Path

from trace_full_array_path import Graph, TOKENS


FF = re.compile(r"\$_SDFF(?P<enable>E)?_(?P<clock>[PN])(?P<reset>[PN])(?P<value>[01])(?P<epol>[PN])?_\Z")


class Hierarchy:
    def __init__(self, path, top):
        self.path = path
        self.top = "\\" + top.lstrip("\\")
        self.modules = {}
        self.instances = []
        digest = hashlib.sha256()
        info = None
        cell = None
        offset = 0
        with path.open("rb") as stream:
            for raw in stream:
                digest.update(raw)
                line = raw.decode("utf-8").strip()
                if line.startswith("module "):
                    name = line[7:]
                    if name in self.modules:
                        raise ValueError("Duplicate module")
                    info = {"start": offset + len(raw), "ports": {}, "cells": []}
                    self.modules[name] = info
                elif line.startswith("memory "):
                    raise ValueError("Memory object: full-array model required")
                elif line.startswith("wire ") and info is not None:
                    fields = line.split()
                    for direction in ("input", "output", "inout"):
                        if direction in fields:
                            info["ports"][fields[-1]] = direction
                elif line.startswith("cell "):
                    _, kind, name = line.split(None, 2)
                    cell = {"kind": kind, "name": name, "ports": {}}
                elif line.startswith("connect ") and cell is not None:
                    _, pin, value = line.split(None, 2)
                    cell["ports"][pin] = value
                elif line == "end":
                    if cell is not None:
                        # Primitive cells are streamed, not stored in Python.
                        if cell["kind"].startswith("\\") and cell["kind"] != "\\DFF_X1":
                            info["cells"].append(cell)
                        cell = None
                    elif info is not None:
                        info["stop"] = offset
                        info = None
                offset += len(raw)
        if info is not None or cell is not None:
            raise ValueError("Unterminated module/cell")
        self.source_sha256 = digest.hexdigest()
        if self.top not in self.modules:
            raise ValueError("Top module missing")
        self._expand(self.top, "", ())

    def _expand(self, kind, prefix, parents):
        if kind in parents:
            raise ValueError("Recursive hierarchy")
        info = self.modules[kind]
        self.instances.append((kind, prefix))
        for cell in info["cells"]:
            child = cell["kind"]
            if child not in self.modules:
                raise ValueError(f"Unknown/black-box module: {child}")
            ports = self.modules[child]["ports"]
            if set(cell["ports"]) - set(ports):
                raise ValueError("Unknown child port")
            required = {name for name, direction in ports.items() if direction in ("input", "inout")}
            if required - set(cell["ports"]):
                raise ValueError("Unconnected child input")
            name = cell["name"].lstrip("\\")
            stem = prefix + name + "."
            self._expand(child, stem, parents + (kind,))

    @staticmethod
    def wire(name, prefix):
        if name.startswith("\\"):
            return "\\" + prefix + name[1:]
        if name.startswith("$"):
            return "$hier$" + prefix + name
        raise ValueError("Unsupported wire identifier")

    @classmethod
    def value(cls, value, prefix):
        return " ".join(cls.wire(token, prefix) if token.startswith(("\\", "$")) else token
                        for token in TOKENS.findall(value))

    @staticmethod
    def logic(kind, name, pins):
        yield f"  cell {kind} {name}\n"
        for pin, value in pins.items():
            yield f"    connect \\{pin} {value}\n"
        yield "  end\n"

    def stream(self):
        yield f"module {self.top}\n"
        serial = 0
        with self.path.open("rb") as file:
            for kind, prefix in self.instances:
                info = self.modules[kind]
                file.seek(info["start"])
                cell = None
                while file.tell() < info["stop"]:
                    line = file.readline().decode("utf-8").strip()
                    if line.startswith("wire "):
                        fields = line.split()
                        fields[-1] = self.wire(fields[-1], prefix)
                        if prefix:
                            for direction in ("input", "output", "inout"):
                                if direction in fields:
                                    index = fields.index(direction)
                                    del fields[index:index+2]
                        yield "  " + " ".join(fields) + "\n"
                    elif line.startswith("cell "):
                        _, ctype, name = line.split(None, 2)
                        cell = {"kind": ctype, "name": self.wire(name, prefix), "ports": {}}
                    elif line.startswith("connect "):
                        if cell is None:
                            yield "  connect " + self.value(line[8:], prefix) + "\n"
                        else:
                            _, pin, value = line.split(None, 2)
                            cell["ports"][pin[1:]] = self.value(value, prefix)
                    elif line == "end" and cell is not None:
                        ctype = cell["kind"]
                        pins = cell["ports"]
                        match = FF.fullmatch(ctype)
                        if ctype in self.modules or ctype == "$scopeinfo":
                            pass  # Hierarchy connects below; scopeinfo is metadata.
                        elif match:
                            if bool(match["enable"]) != bool(match["epol"]):
                                raise ValueError("Invalid FF encoding")
                            expected = {"C", "D", "Q", "R"} | ({"E"} if match["enable"] else set())
                            if set(pins) != expected:
                                raise ValueError("Unexpected FF ports")
                            serial += 1
                            base = f"$hier_ff${serial}"
                            data = pins["D"]
                            if match["enable"]:
                                enabled = base + "$enable"
                                yield f"  wire {enabled}\n"
                                a, b = (pins["Q"], data) if match["epol"] == "P" else (data, pins["Q"])
                                yield from self.logic("$_MUX_", base + "$mux", {"A": a, "B": b, "S": pins["E"], "Y": enabled})
                                data = enabled
                            result = base + "$reset"
                            yield f"  wire {result}\n"
                            reset_kind = {("N", "0"): "$_AND_", ("P", "0"): "$_ANDNOT_",
                                          ("N", "1"): "$_ORNOT_", ("P", "1"): "$_OR_"}[(match["reset"], match["value"])]
                            yield from self.logic(reset_kind, base + "$rgate", {"A": data, "B": pins["R"], "Y": result})
                            yield from self.logic("$_DFF_" + match["clock"] + "_", base + "$ff",
                                                  {"C": pins["C"], "D": result, "Q": pins["Q"]})
                        else:
                            yield from self.logic(ctype, cell["name"], pins)
                        cell = None
        # All wires have been declared before resolving inter-module aliases.
        for kind, prefix in self.instances:
            for cell in self.modules[kind]["cells"]:
                child_prefix = prefix + cell["name"].lstrip("\\") + "."
                for pin, value in cell["ports"].items():
                    yield "  connect " + self.wire(pin, child_prefix) + " " + self.value(value, prefix) + "\n"
        yield "end\n"

    @contextlib.contextmanager
    def open(self, mode="r", encoding=None):
        # Graph consumes a read-only iterable. No enormous intermediate flat
        # file or duplicated Yosys design is constructed.
        yield (line.encode("utf-8") for line in self.stream()) if "b" in mode else self.stream()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("netlist", type=Path)
    parser.add_argument("--top-module", default="rv_ooo_core")
    parser.add_argument("--src", required=True)
    parser.add_argument("--to", required=True)
    parser.add_argument("--json", type=Path, required=True)
    args = parser.parse_args()
    if args.json.exists():
        parser.error("Refusing to overwrite report")
    model = Hierarchy(args.netlist, args.top_module)
    graph = Graph()
    graph.first_pass(model)
    graph.second_pass(model)
    paths = graph.trace(args.src, args.to, 3, details=True)
    args.json.parent.mkdir(parents=True, exist_ok=True)
    args.json.write_text(json.dumps({
        "scope": "Unfolded full-array hierarchy; explicit reset/enable, no cross-module constant folding; NOT STA/ns",
        "input_sha256": model.source_sha256, "normalized_model_sha256": graph.sha256,
        "instances": len(model.instances), "cells_checked": graph.cell_count,
        "bits": len(graph.parent), "source_regex": args.src, "endpoint_regex": args.to,
        "paths": paths}, indent=2) + "\n", encoding="utf-8")


if __name__ == "__main__":
    main()
