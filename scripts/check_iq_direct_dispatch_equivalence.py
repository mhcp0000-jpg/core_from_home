#!/usr/bin/env python3
"""Prove static one-hot IQ dispatch writes match the original binary decoder.

Extract the actual allocator and handshake RTL. All registered-valid bitmap
bits, dispatch lanes and flush inputs are arbitrary binary. Prove the write
predicate of every lane/row, and check that every payload expression, priority,
reset, flush, issue and wakeup operation outside the rewrite is unchanged.
This compositional write-selection proof is NOT full sequential/IEEE-X/ISA/STA.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess


def digest(data):
    return hashlib.sha256(data).hexdigest()


def dispatch_block(text):
    start = text.index("      if (dispatch_fire) begin")
    end = text.index("\n    end\n  end\n\n  always_comb begin\n    // PROTOTYPE: balanced popcount", start)
    return start, end, text[start:end]


def expected_rewrite(original):
    lines = original.splitlines()
    if lines[2].strip() != "if (dispatch_valid_i[lane]) begin" or [x.strip() for x in lines[-3:]] != ["end"] * 3:
        raise ValueError("Unexpected original dispatch block")
    source_start = original.index("            for (int unsigned source = 0; source < 3; source++) begin")
    source_end = original.index("            destination_valid_q", source_start)
    ready = original[source_start:source_end].rstrip()
    payload = "\n".join(lines[3:-3]).replace(ready, "            src_ready_q[dispatch_index_o[lane]] <= dispatch_ready_for_write[lane];")
    body = ["  " + line.replace("[dispatch_index_o[lane]]", "[entry]") for line in payload.splitlines()]
    return "\n".join([
        lines[0],
        "        // Keep the allocator's one-hot winner through every payload write.",
        "        // Binary dispatch_index_o remains an unchanged interface output.",
        lines[1],
        "          for (int unsigned entry = 0; entry < ENTRIES; entry++) begin",
        "            if (allocation_hot[lane][entry]) begin",
        *body, "            end", "          end", lines[-2], lines[-1],
    ])


def readiness_helper(original):
    start = original.index("            for (int unsigned source = 0; source < 3; source++) begin")
    end = original.index("            destination_valid_q", start)
    ready = original[start:end].rstrip()
    return "\n".join([
        "  // Compute the identical lane wakeup once, not once per potential slot.",
        "  always_comb begin",
        "    for (int unsigned lane = 0; lane < 2; lane++) begin",
        *[line[6:].replace("src_ready_q[dispatch_index_o[lane]][source] <=", "dispatch_ready_for_write[lane][source] =") for line in ready.splitlines()],
        "    end", "  end", "", "",
    ])


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--rtl", type=Path, required=True)
    parser.add_argument("--reference", type=Path, required=True)
    parser.add_argument("--out", type=Path, required=True)
    parser.add_argument("--yosys", type=Path, required=True)
    args = parser.parse_args()
    candidate_bytes, reference_bytes = args.rtl.read_bytes(), args.reference.read_bytes()
    candidate = candidate_bytes.decode("utf-8-sig").replace("\r\n", "\n")
    reference = reference_bytes.decode("utf-8-sig").replace("\r\n", "\n")
    c_start, c_end, actual_block = dispatch_block(candidate)
    _, _, original_block = dispatch_block(reference)
    if actual_block != expected_rewrite(original_block):
        raise ValueError("Actual per-lane/row data or priority differs from the exact rewrite")
    restored = candidate[:c_start] + original_block + candidate[c_end:]
    helper = readiness_helper(original_block)
    if restored.count(helper) != 1:
        raise ValueError("Lane wakeup precompute differs from the exact original data expression")
    restored = restored.replace(helper, "", 1)
    declaration = "  logic [1:0][2:0] dispatch_ready_for_write;\n"
    if restored.count(declaration) != 1:
        raise ValueError("Unexpected wakeup wire declaration")
    restored = restored.replace(declaration, "", 1)
    restored = restored.replace(
        "  // binary indices are only an interface representation, not a write decoder.",
        "  // binary indices are only an interface/payload-write representation.",
    )
    if restored != reference:
        raise ValueError("Unproved changes outside dispatch write selection")
    start = candidate.index("  for (genvar leaf = 0; leaf < CNT_LEAVES; leaf++) begin : g_alloc_leaf")
    end = candidate.index("\n  always_ff @(posedge clk_i)", start)
    allocator = candidate[start:end]
    out = args.out.absolute()
    if os.name == "nt" and not str(out).isascii():
        parser.error("Use an owned ASCII output alias")
    out.mkdir(parents=True, exist_ok=True)
    env = os.environ.copy()
    env["PATH"] = str(args.yosys.parent) + os.pathsep + str(args.yosys.parent.parent / "lib") + os.pathsep + env.get("PATH", "")
    report = dict(passed=False, candidate_sha256=digest(candidate_bytes), reference_sha256=digest(reference_bytes),
                  unchanged_remaining_rtl=True, identical_payload_and_priority=True,
                  readiness_precompute_exact_expression=True,
                  allocator_sha256=digest(allocator.encode()), cases=[],
                  scope="Exact actual allocator/handshake binary per-lane/per-row write selection, unchanged remaining RTL/data/priority; NOT full sequential/IEEE-X/core/ISA/STA")
    for entries, negative in [(2, False), (4, False), (7, False), (56, False), (64, False), (97, False), (56, True)]:
        run = out / f"entries{entries}_negative{int(negative)}"
        run.mkdir(exist_ok=True)
        candidate_lane = "0" if negative else "lane"
        fixture = f"""module iq_write_miter #(
parameter int ENTRIES={entries}, INDEX_WIDTH=$clog2(ENTRIES),
CNT_LEVELS=$clog2(ENTRIES), CNT_LEAVES=1<<CNT_LEVELS
)(input logic [ENTRIES-1:0] valid_q, input logic [1:0] dispatch_valid_i,
input logic flush_all_i, flush_younger_i, output logic equal_o);
logic [ENTRIES-1:0] available_slots, alloc_first_hot, alloc_second_hot;
logic [1:0][ENTRIES-1:0] allocation_hot;
logic [2*CNT_LEAVES-1:1] alloc_any, alloc_ge2, alloc_prefix_none, alloc_prefix_one;
logic [1:0] allocation_found;
logic [1:0][INDEX_WIDTH-1:0] dispatch_index_o;
logic [2:0] requested_dispatch_count;
logic dispatch_ready_o, dispatch_fire;
logic [1:0][ENTRIES-1:0] original_writes, candidate_writes;
{allocator}
for (genvar lane=0; lane<2; lane++) begin
  for (genvar entry=0; entry<ENTRIES; entry++) begin
    assign original_writes[lane][entry] = dispatch_fire && dispatch_valid_i[lane] &&
      (dispatch_index_o[lane] == INDEX_WIDTH'(entry));
    assign candidate_writes[lane][entry] = dispatch_fire && allocation_hot[{candidate_lane}][entry];
  end
end
assign equal_o=(original_writes == candidate_writes);
endmodule
"""
        (run / "miter.sv").write_text(fixture, encoding="utf-8")
        (run / "proof.ys").write_text(
            "read_slang --top iq_write_miter miter.sv\nprep -top iq_write_miter\n"
            "flatten\ntechmap\nopt\nsat -verify -prove equal_o 1 -timeout 90\n", encoding="utf-8")
        with (run / "proof.log").open("w", encoding="utf-8") as log:
            result = subprocess.run([str(args.yosys), "-Q", "-T", "-s", "proof.ys"],
                                    cwd=run, env=env, stdout=log, stderr=subprocess.STDOUT, timeout=120)
        transcript = (run / "proof.log").read_text(encoding="utf-8", errors="replace")
        passed = (result.returncode != 0 and "proof did fail" in transcript) if negative else (
            result.returncode == 0 and "no model found: SUCCESS!" in transcript)
        report["cases"].append(dict(entries=entries, negative=negative, passed=passed,
                                  native_exit=result.returncode, fixture_sha256=digest(fixture.encode())))
        (out / "report.json").write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
        if not passed:
            raise RuntimeError(f"Unexpected IQ write-selection proof result: {run}")
        print(f"PASS IQ row write predicate ENTRIES={entries} negative={negative}", flush=True)
    report["passed"] = True
    (out / "report.json").write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")


if __name__ == "__main__":
    main()
