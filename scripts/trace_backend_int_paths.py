"""Trace the reported ALU0 path and both sides of an INT issue boundary.

Loads the complete, flattened, reset-retained pre-ABC core once. Results are
structural heuristic costs, NOT nanoseconds, sensitization proof, or STA.
No RTL elaboration, hardware overrides, or netlist modification is performed.
"""
import argparse
import hashlib
import json
from pathlib import Path

from trace_full_array_path import Graph


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("netlist", type=Path)
    parser.add_argument("--json", type=Path, required=True)
    args = parser.parse_args()
    if args.json.exists():
        parser.error("Refusing to overwrite an existing path report")
    graph = Graph()
    graph.first_pass(args.netlist)
    graph.second_pass(args.netlist)
    probes = [
        ("reported_lsu_to_alu0_buffer", r"u_lsu_cluster\.forward_valid_q",
         r"g_fast\[0\]\.u_buffer.*slots_q"),
        ("lsu_to_int_issue", r"u_lsu_cluster\.forward_valid_q",
         r"int_issue_(?:valid_)?q"),
        ("int_issue_to_alu0_buffer", r"int_issue_(?:valid_)?q",
         r"g_fast\[0\]\.u_buffer.*slots_q"),
        ("lsu_to_branch_stage", r"u_lsu_cluster\.forward_valid_q",
         r"branch_issue_(?:valid_)?q"),
    ]
    results = []
    for name, source, endpoint in probes:
        print(f"PROBE {name}", flush=True)
        item = {"name": name, "source_regex": source,
                "endpoint_regex": endpoint}
        # Distinguish absent FFs (e.g. INT pipeline disabled) from an actual
        # disconnected cone; neither is a numerical zero-delay STA result.
        try:
            item["paths"] = graph.trace(source, endpoint, 3, details=True)
            item["status"] = "path_present"
        except ValueError as exc:
            message = str(exc)
            if message.startswith("No matching FFs:"):
                item["status"] = "ff_set_absent"
            elif message == "No combinational source-to-endpoint path in the full model":
                item["status"] = "no_combinational_path"
            else:
                raise  # Unknown cells/cycles/driver errors invalidate analysis.
            item["reason"] = message
            item["paths"] = []
            print(f"{item['status']}: {message}", flush=True)
        results.append(item)
    report = {
        "scope": "Full-array structural heuristic; NOT STA/ns or sensitization proof",
        "netlist_sha256": graph.sha256,
        "cells_checked": graph.cell_count,
        "bits": len(graph.parent),
        "tracer_sha256": hashlib.sha256(Path(__file__).with_name("trace_full_array_path.py").read_bytes()).hexdigest(),
        "ff_output_model": "Register regex includes physical Q/QN peers; exact source pin remains exact; heuristic, not STA",
        "probes": results,
    }
    args.json.parent.mkdir(parents=True, exist_ok=True)
    args.json.write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")


if __name__ == "__main__":
    main()
