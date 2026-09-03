"""Create a self-contained RTL/HTIF bundle for a Linux Xcelium server."""

from __future__ import annotations

import argparse
import hashlib
import json
import shutil
import stat
import subprocess
from datetime import datetime, timezone
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
CORE_LIST = ROOT / "sim" / "xcelium" / "sources_core.f"
SOC_LIST = ROOT / "sim" / "xcelium" / "sources_soc.f"
CANONICAL_RTL_LIST = ROOT / "rtl" / "filelist.f"

SUPPORT_FILES = (
    "config/soc_project.json",
    "config/soc_memory_map.h",
    "config/soc_memory_map.inc",
    "config/soc_project.env",
    "tb/fixtures/bootrom/bootrom_wait.hex",
    "tb/fixtures/bootrom/bootrom_host_jump.hex",
    "tb/e2e/dpi/rv_host_dpi.sv",
    "tb/e2e/dpi/rv_soc_htif_dpi_tb.sv",
    "tb/e2e/dpi/elf_loader.cpp",
    "sw/tests/htif_smoke/htif_smoke.S",
    "sw/tests/htif_smoke/rv32_htif.ld",
    "sim/xcelium/setup_env.sh",
    "sim/xcelium/setup_env.csh",
    "sim/xcelium/rtl.f",
    "sim/xcelium/htif_tb.f",
    "sim/xcelium/run_verilog_sub.sh",
    "sim/xcelium/build_htif_smoke.sh",
    "sim/xcelium/README.md",
)


def read_sources(filelist: Path) -> list[str]:
    sources: list[str] = []
    for raw_line in filelist.read_text(encoding="utf-8").splitlines():
        line = raw_line.strip()
        if not line or line.startswith("#"):
            continue
        normalized = Path(line).as_posix()
        if normalized in sources:
            raise ValueError(f"duplicate source in {filelist}: {normalized}")
        source = ROOT / normalized
        if not source.is_file():
            raise FileNotFoundError(f"source does not exist: {source}")
        sources.append(normalized)
    return sources


def safe_prepare_output(output: Path, force: bool) -> None:
    resolved = output.resolve()
    forbidden = {Path(resolved.anchor).resolve(), ROOT.resolve(), ROOT.parent.resolve()}
    if resolved in forbidden:
        raise ValueError(f"refusing broad output path: {resolved}")
    if resolved.exists() and any(resolved.iterdir()):
        if not force:
            raise FileExistsError(
                f"output is not empty: {resolved}; pass --force to replace it"
            )
        shutil.rmtree(resolved)
    resolved.mkdir(parents=True, exist_ok=True)


def copy_relative(relative: str, output: Path) -> None:
    source = ROOT / relative
    if not source.is_file():
        raise FileNotFoundError(f"support file does not exist: {source}")
    destination = output / relative
    destination.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(source, destination)


def write_filelist(path: Path, sources: list[str], title: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    text = f"# {title}\n" + "\n".join(sources) + "\n"
    path.write_text(text, encoding="utf-8", newline="\n")


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def git_revision() -> str:
    try:
        return subprocess.check_output(
            ["git", "rev-parse", "HEAD"], cwd=ROOT, text=True
        ).strip()
    except (OSError, subprocess.CalledProcessError):
        return "unknown"


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--output",
        type=Path,
        default=ROOT / "out" / "xcelium_bundle",
        help="bundle output directory (default: out/xcelium_bundle)",
    )
    parser.add_argument(
        "--force",
        action="store_true",
        help="replace an existing non-empty output directory",
    )
    args = parser.parse_args()

    output = args.output.resolve()
    safe_prepare_output(output, args.force)
    core_sources = read_sources(CORE_LIST)
    soc_sources = read_sources(SOC_LIST)
    canonical_sources = read_sources(CANONICAL_RTL_LIST)
    if not set(core_sources).issubset(soc_sources):
        missing = sorted(set(core_sources) - set(soc_sources))
        raise ValueError(f"SoC file list omits core sources: {missing}")
    if set(soc_sources) != set(canonical_sources):
        missing = sorted(set(canonical_sources) - set(soc_sources))
        extra = sorted(set(soc_sources) - set(canonical_sources))
        raise ValueError(
            "Xcelium source set differs from rtl/filelist.f; "
            f"missing={missing}, extra={extra}"
        )

    for relative in soc_sources:
        copy_relative(relative, output)
    for relative in SUPPORT_FILES:
        copy_relative(relative, output)

    write_filelist(
        output / "filelist" / "core_rtl.f",
        core_sources,
        "Core-only RTL; paths are relative to the verilog_sub root.",
    )
    write_filelist(
        output / "filelist" / "soc_rtl.f",
        soc_sources,
        "Complete SoC RTL; paths are relative to the verilog_sub root.",
    )
    write_filelist(
        output / "verilog_sub.f",
        soc_sources,
        "Xcelium verilog_sub entry; invoke from this directory.",
    )

    runner_source = ROOT / "sim" / "xcelium" / "run_xcelium.sh"
    runner_destination = output / "scripts" / "run_xcelium.sh"
    runner_destination.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(runner_source, runner_destination)
    runner_destination.chmod(
        runner_destination.stat().st_mode
        | stat.S_IXUSR
        | stat.S_IXGRP
        | stat.S_IXOTH
    )
    shutil.copy2(ROOT / "sim" / "xcelium" / "README.md", output / "README.md")
    for relative in (
        "sim/xcelium/setup_env.sh",
        "sim/xcelium/run_verilog_sub.sh",
        "sim/xcelium/build_htif_smoke.sh",
    ):
        script = output / relative
        script.chmod(script.stat().st_mode | stat.S_IXUSR | stat.S_IXGRP | stat.S_IXOTH)

    tracked_files = sorted(
        path for path in output.rglob("*") if path.is_file() and path.name != "manifest.json"
    )
    project_config = json.loads(
        (ROOT / "config" / "soc_project.json").read_text(encoding="utf-8")
    )
    manifest = {
        "format": "rv-ooo-xcelium-htif-bundle-v2",
        "generated_utc": datetime.now(timezone.utc).isoformat(),
        "git_revision": git_revision(),
        "rtl_top": "rv_soc_top",
        "core_top": "rv_ooo_core",
        "source_count": len(soc_sources),
        "memory_map": project_config["memory_map"],
        "boot": project_config["boot"],
        "files": {
            path.relative_to(output).as_posix(): sha256(path)
            for path in tracked_files
        },
    }
    (output / "manifest.json").write_text(
        json.dumps(manifest, indent=2) + "\n", encoding="utf-8", newline="\n"
    )

    print(f"Xcelium HTIF bundle       : {output}")
    print(f"RTL sources               : {len(soc_sources)}")
    print(f"Entry file list           : {output / 'verilog_sub.f'}")
    print(f"Linux runner              : {output / 'scripts' / 'run_xcelium.sh'}")
    print(f"Server runner             : {output / 'sim/xcelium/run_verilog_sub.sh'}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
