#!/usr/bin/env python3
"""Prove early INT/FP query-tag gating preserves selected ready observations.

Actual backend address assignments and class selection are extracted. Prove
selected namespace tag identity and ready outputs for arbitrary tags/classes
and arbitrary consistent per-namespace tag-to-ready functions. Restore the six
assignments to check every other backend line is identical. Not whole backend,
IEEE-X, ISA or timing signoff; unconsumed query outputs intentionally change.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess


def digest(data):
    return hashlib.sha256(data).hexdigest()


def query_logic(text, allocation=False):
    start = text.index("      int_query_addr[lane*3]")
    end = text.index("\n    end\n  end\n\n  rv_phys_regfile #", start) if allocation else text.index("      int_alloc_valid[lane]", start)
    return text[start:end].rstrip()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--rtl", type=Path, required=True)
    parser.add_argument("--reference", type=Path, required=True)
    parser.add_argument("--package", type=Path, required=True)
    parser.add_argument("--out", type=Path, required=True)
    parser.add_argument("--yosys", type=Path, required=True)
    parser.add_argument("--allocation", action="store_true", help="Also prove class-gated allocation requests and their readiness effect")
    args = parser.parse_args()
    c_bytes, r_bytes = args.rtl.read_bytes(), args.reference.read_bytes()
    candidate = c_bytes.decode("utf-8-sig").replace("\r\n", "\n")
    reference = r_bytes.decode("utf-8-sig").replace("\r\n", "\n")
    for text in (candidate, reference):
        for name, count in [("int_query_ready", 3), ("fp_query_ready", 3),
                            ("int_query_addr", 5), ("fp_query_addr", 5)]:
            if len(re.findall(r"\b" + name + r"\b", text)) != count:
                raise ValueError("Unexpected query consumer; expand the proof scope: " + name)
    restored = candidate
    comment = (
        "      // Only the matching namespace's readiness is consumed below. Gate the\n"
        "      // unused query before its large PRF selector, not after the selector.\n"
        "      // The selected namespace sees exactly the original physical tag.\n"
    )
    if restored.count(comment) != 1:
        raise ValueError("Unexpected query-gating rewrite")
    restored = restored.replace(comment, "", 1)
    for namespace, reg_class in [("int", "REG_INT"), ("fp", "REG_FP")]:
        for source, suffix in [(0, ""), (1, "+1"), (2, "+2")]:
            old = f"      {namespace}_query_addr[lane*3{suffix}] = src{source}_phys[lane];"
            new = (f"      {namespace}_query_addr[lane*3{suffix}] = src{source}_phys[lane] &\n"
                   f"        {{PHYS_TAG_WIDTH{{dec_src_class[lane][{source}] == {reg_class}}}}};")
            if restored.count(new) != 1 or reference.count(old) != 1:
                raise ValueError("Unexpected selected-tag expression")
            restored = restored.replace(new, old, 1)
    if args.allocation:
        allocation_comment = (
            "      // Inactive allocation addresses cannot affect PRF state/readiness.\n"
            "      // Class-only masks avoid adding the late dispatch_fire to the tag path.\n"
        )
        declaration = "  logic [1:0][PHYS_TAG_WIDTH-1:0] int_alloc_addr, fp_alloc_addr;\n"
        if restored.count(allocation_comment) != 1 or restored.count(declaration) != 1:
            raise ValueError("Unexpected allocation namespace rewrite")
        restored = restored.replace(allocation_comment, "", 1).replace(declaration, "", 1)
        for namespace, reg_class in [("int", "REG_INT"), ("fp", "REG_FP")]:
            expression = (f"      {namespace}_alloc_addr[lane] = renamed_dst_phys[lane] &\n"
                          f"        {{PHYS_TAG_WIDTH{{dec_dst_class[lane] == {reg_class}}}}};\n")
            if restored.count(expression) != 1:
                raise ValueError("Unexpected allocation address expression")
            restored = restored.replace(expression, "", 1)
            connection = f".allocate_valid_i({namespace}_alloc_valid), .allocate_addr_i({namespace}_alloc_addr),"
            if restored.count(connection) != 1:
                raise ValueError("Unexpected PRF allocation connection")
            restored = restored.replace(connection, f".allocate_valid_i({namespace}_alloc_valid), .allocate_addr_i(renamed_dst_phys),", 1)
    if restored != reference:
        raise ValueError("Unproved changes outside the six address assignments")
    actual, original = query_logic(candidate, args.allocation), query_logic(reference, args.allocation)
    out = args.out.absolute()
    if os.name == "nt" and not str(out).isascii():
        parser.error("Use an owned ASCII output alias")
    out.mkdir(parents=True, exist_ok=True)
    env = os.environ.copy()
    env["PATH"] = str(args.yosys.parent) + os.pathsep + str(args.yosys.parent.parent / "lib") + os.pathsep + env.get("PATH", "")
    report = dict(passed=False, candidate_sha256=digest(c_bytes), reference_sha256=digest(r_bytes),
                  package_sha256=digest(args.package.read_bytes()), unchanged_remaining_rtl=True, cases=[],
                  allocation_requests_checked=args.allocation,
                  scope="Actual backend binary selected-tag/readiness observation; optional active per-lane allocation identity/ready-hit masks, arbitrary base tag-to-ready functions; NOT full backend/IEEE-X/ISA/STA; unconsumed query values may change")
    cases = [(5, None), (7, None), (8, None), (7, "query")]
    if args.allocation:
        cases.append((7, "allocation"))
    for width, negative in cases:
        run = out / f"tag{width}_negative{negative or 'none'}"
        run.mkdir(exist_ok=True)
        current = actual
        if negative:
            needle = "{PHYS_TAG_WIDTH{dec_dst_class[lane] == REG_FP}};" if negative == "allocation" else "{PHYS_TAG_WIDTH{dec_src_class[lane][0] == REG_FP}};"
            if current.count(needle) != 1:
                raise ValueError("Missing actual wrong-namespace negative target")
            current = current.replace(needle, needle.replace("REG_FP", "REG_INT"), 1)
        ref = original
        for name in ["int_query_addr", "fp_query_addr", "int_query_ready", "fp_query_ready", "dispatch_src_ready", "int_alloc_valid", "fp_alloc_valid"]:
            ref = re.sub(r"\b" + name + r"\b", name + "_ref", ref)
        allocation_model = """
assign int_alloc_addr_ref=renamed_dst_phys;
assign fp_alloc_addr_ref=renamed_dst_phys;
for (genvar tag=0; tag<(1<<PHYS_TAG_WIDTH); tag++) begin
  assign int_alloc_mask[tag]=(int_alloc_valid[0] && int_alloc_addr[0]==PHYS_TAG_WIDTH'(tag)) ||
                            (int_alloc_valid[1] && int_alloc_addr[1]==PHYS_TAG_WIDTH'(tag));
  assign fp_alloc_mask[tag]=(fp_alloc_valid[0] && fp_alloc_addr[0]==PHYS_TAG_WIDTH'(tag)) ||
                           (fp_alloc_valid[1] && fp_alloc_addr[1]==PHYS_TAG_WIDTH'(tag));
  assign int_alloc_mask_ref[tag]=(int_alloc_valid_ref[0] && int_alloc_addr_ref[0]==PHYS_TAG_WIDTH'(tag)) ||
                                (int_alloc_valid_ref[1] && int_alloc_addr_ref[1]==PHYS_TAG_WIDTH'(tag));
  assign fp_alloc_mask_ref[tag]=(fp_alloc_valid_ref[0] && fp_alloc_addr_ref[0]==PHYS_TAG_WIDTH'(tag)) ||
                               (fp_alloc_valid_ref[1] && fp_alloc_addr_ref[1]==PHYS_TAG_WIDTH'(tag));
end
for (genvar lane=0; lane<2; lane++) begin
  assign allocation_equal[lane]=(int_alloc_valid[lane]==int_alloc_valid_ref[lane]) &&
    (fp_alloc_valid[lane]==fp_alloc_valid_ref[lane]) &&
    (!int_alloc_valid[lane] || int_alloc_addr[lane]==int_alloc_addr_ref[lane]) &&
    (!fp_alloc_valid[lane] || fp_alloc_addr[lane]==fp_alloc_addr_ref[lane]);
end
""" if args.allocation else "assign int_alloc_mask='0, fp_alloc_mask='0, int_alloc_mask_ref='0, fp_alloc_mask_ref='0, allocation_equal='1;"
        fixture = f"""module namespace_query_miter #(parameter int PHYS_TAG_WIDTH={width})(
input rv_ooo_pkg::reg_class_e [1:0][2:0] dec_src_class,
input logic [1:0][PHYS_TAG_WIDTH-1:0] src0_phys, src1_phys, src2_phys,
input logic dispatch_fire, input logic [1:0] dec_valid, renamed_writes_dst,
input rv_ooo_pkg::reg_class_e [1:0] dec_dst_class,
input logic [1:0][PHYS_TAG_WIDTH-1:0] renamed_dst_phys,
input logic [(1<<PHYS_TAG_WIDTH)-1:0] int_ready_function, fp_ready_function,
output logic equal_o);
import rv_ooo_pkg::*;
logic [5:0][PHYS_TAG_WIDTH-1:0] int_query_addr, fp_query_addr, int_query_addr_ref, fp_query_addr_ref;
logic [5:0] int_query_ready, fp_query_ready, int_query_ready_ref, fp_query_ready_ref;
logic [1:0][2:0] dispatch_src_ready, dispatch_src_ready_ref, selected_tag_equal;
logic [1:0] int_alloc_valid, fp_alloc_valid, int_alloc_valid_ref, fp_alloc_valid_ref, allocation_equal;
logic [1:0][PHYS_TAG_WIDTH-1:0] int_alloc_addr, fp_alloc_addr, int_alloc_addr_ref, fp_alloc_addr_ref;
logic [(1<<PHYS_TAG_WIDTH)-1:0] int_alloc_mask, fp_alloc_mask, int_alloc_mask_ref, fp_alloc_mask_ref;
always_comb begin
  for (int unsigned lane=0; lane<2; lane++) begin
{current}
  end
end
always_comb begin
  for (int unsigned lane=0; lane<2; lane++) begin
{ref}
  end
end
{allocation_model}
for (genvar port=0; port<6; port++) begin
  assign int_query_ready[port]=(int_query_addr[port]=='0) || (int_ready_function[int_query_addr[port]] && !int_alloc_mask[int_query_addr[port]]);
  assign fp_query_ready[port]=fp_ready_function[fp_query_addr[port]] && !fp_alloc_mask[fp_query_addr[port]];
  assign int_query_ready_ref[port]=(int_query_addr_ref[port]=='0) || (int_ready_function[int_query_addr_ref[port]] && !int_alloc_mask_ref[int_query_addr_ref[port]]);
  assign fp_query_ready_ref[port]=fp_ready_function[fp_query_addr_ref[port]] && !fp_alloc_mask_ref[fp_query_addr_ref[port]];
end
for (genvar lane=0; lane<2; lane++) begin
  for (genvar source=0; source<3; source++) begin
    assign selected_tag_equal[lane][source]=
      (dec_src_class[lane][source]==REG_INT) ?
        (int_query_addr[lane*3+source]==int_query_addr_ref[lane*3+source]) :
      (dec_src_class[lane][source]==REG_FP) ?
        (fp_query_addr[lane*3+source]==fp_query_addr_ref[lane*3+source]) : 1'b1;
  end
end
assign equal_o=(dispatch_src_ready==dispatch_src_ready_ref) && (&selected_tag_equal) &&
  (&allocation_equal) && (int_alloc_mask==int_alloc_mask_ref) && (fp_alloc_mask==fp_alloc_mask_ref);
endmodule
"""
        (run / "package.sv").write_bytes(args.package.read_bytes())
        (run / "miter.sv").write_text(fixture, encoding="utf-8")
        (run / "proof.ys").write_text(
            "read_slang --top namespace_query_miter package.sv miter.sv\n"
            "prep -top namespace_query_miter\nflatten\ntechmap\nopt\n"
            "sat -verify -prove equal_o 1 -timeout 90\n", encoding="utf-8")
        with (run / "proof.log").open("w", encoding="utf-8") as log:
            result = subprocess.run([str(args.yosys), "-Q", "-T", "-s", "proof.ys"],
                                    cwd=run, env=env, stdout=log, stderr=subprocess.STDOUT, timeout=120)
        transcript = (run / "proof.log").read_text(encoding="utf-8", errors="replace")
        passed = (result.returncode != 0 and "proof did fail" in transcript) if negative else (
            result.returncode == 0 and "no model found: SUCCESS!" in transcript)
        report["cases"].append(dict(tag_width=width, negative=negative, passed=passed,
                                  native_exit=result.returncode, fixture_sha256=digest(fixture.encode())))
        (out / "report.json").write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
        if not passed:
            raise RuntimeError(f"Unexpected namespace-query proof result: {run}")
        print(f"PASS namespace selected-tag/readiness TAG={width} negative={negative}", flush=True)
    report["passed"] = True
    (out / "report.json").write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")


if __name__ == "__main__":
    main()
