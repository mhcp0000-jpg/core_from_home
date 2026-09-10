#!/usr/bin/env python3
"""Reproduce extended FP result/fflags checks with Icarus on Linux or Windows."""
import argparse
import os
from pathlib import Path
import shutil
import subprocess
import sys


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--iverilog", default="iverilog")
    parser.add_argument("--vvp", default="vvp")
    parser.add_argument("--output", type=Path, default=Path("out/fpu_corners"))
    parser.add_argument("--seed", default="0x20260910")
    parser.add_argument("--random-per-op-rm", type=int, default=1024)
    args = parser.parse_args()
    root = Path(__file__).resolve().parent.parent
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=True)
    vectors = output / "vectors.hex"
    executable = output / "fpu.vvp"
    # Icarus on Windows can mishandle Unicode in absolute $fopen paths.
    # Relative paths also make the logged commands portable within the checkout.
    vector_arg = Path(os.path.relpath(vectors, root)).as_posix()
    executable_arg = Path(os.path.relpath(executable, root)).as_posix()

    def run(name, command):
        print(f"{name}: {' '.join(map(str, command))}", flush=True)
        with (output / f"{name}.log").open("w", encoding="utf-8") as log:
            result = subprocess.run(list(map(str, command)), cwd=root,
                                    stdout=log, stderr=subprocess.STDOUT)
        if result.returncode:
            raise SystemExit(f"FAIL: inspect {output / (name + '.log')}")
        print(f"PASS: {name}", flush=True)

    for tool in (args.iverilog, args.vvp):
        if not shutil.which(tool):
            raise SystemExit(f"Tool not found: {tool}; specify its full path")
    run("generate", [sys.executable, root / "scripts/gen_fpu_diff_vectors.py",
                     "--corners", "--seed", args.seed, "--random-per-op-rm",
                     args.random_per_op_rm, "--output", vectors])
    run("compile", [args.iverilog, "-g2012", "-s", "rv_fpu_diff_tb", "-o",
                    executable_arg, "rtl/rv_ooo_pkg.sv", "rtl/backend/rv_fpu.sv",
                    "tb/unit/backend/rv_fpu_diff_tb.sv"])
    for mode in ("static", "dynamic"):
        command = [args.vvp, executable_arg, f"+fpu_vectors={vector_arg}"]
        if mode == "dynamic":
            command.append("+fpu_dynamic_rm")
        run(mode, command)
    print(f"FP CORNER REGRESSION PASS; vectors and logs: {output}")


if __name__ == "__main__":
    main()
