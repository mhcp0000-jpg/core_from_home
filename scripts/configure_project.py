#!/usr/bin/env python3
"""Create a configured, portable copy of the RV OoO SoC project.

The generator is intentionally standard-library only so it can run on both
Windows and Linux before any RTL toolchain has been installed.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import shutil
import sys
from pathlib import Path
from typing import Any, Optional, Union


if os.name == "nt":
    # PowerShell 7 and the Codex terminal consume UTF-8 native-process output.
    # Keep Korean prompts and paths readable regardless of the legacy codepage.
    sys.stdout.reconfigure(encoding="utf-8")
    sys.stderr.reconfigure(encoding="utf-8")


REGIONS = ("bootrom", "clint", "plic", "hostif", "itim", "dtim")
DEFAULTS: dict[str, Any] = {
    "project_name": "my_rv_core",
    "memory_map": {
        "bootrom": {"base": "0x00001000", "size_kb": 4},
        "clint": {"base": "0x00200000", "size_kb": 64},
        "plic": {"base": "0x0c000000", "size_kb": 4096},
        "hostif": {"base": "0x10000000", "size_kb": 4},
        "itim": {"base": "0x80000000", "size_kb": 128},
        "dtim": {"base": "0x80020000", "size_kb": 128},
    },
    "boot": {
        "mtvec": "0x80000000",
        "bootrom_image": "auto",
    },
    "host": {
        "default_elf": "",
        "payload_dir": "host/payload",
        "artifact_root": "out/dpi_elf",
        "timeout_cycles": 2_000_000,
    },
}


def write_text_lf(path: Path, content: str, encoding: str = "utf-8") -> None:
    with path.open("w", encoding=encoding, newline="\n") as stream:
        stream.write(content)


def parse_number(value: Union[str, int]) -> int:
    if isinstance(value, int):
        return value
    text = str(value).strip().replace("_", "")
    return int(text, 0)


def hex32(value: int) -> str:
    return f"0x{value:08x}"


def sv_hex32(value: int) -> str:
    digits = f"{value:08x}"
    return f"32'h{digits[:4]}_{digits[4:]}"


def deep_merge(base: dict[str, Any], update: dict[str, Any]) -> dict[str, Any]:
    result = json.loads(json.dumps(base))
    for key, value in update.items():
        if isinstance(value, dict) and isinstance(result.get(key), dict):
            result[key] = deep_merge(result[key], value)
        else:
            result[key] = value
    return result


def prompt_text(label: str, default: str) -> str:
    answer = input(f"{label} [{default}]: ").strip()
    return answer or default


def prompt_number(label: str, default: int, *, address: bool = False) -> int:
    shown = hex32(default) if address else str(default)
    while True:
        answer = input(f"{label} [{shown}]: ").strip()
        try:
            return parse_number(answer) if answer else default
        except ValueError:
            print("  숫자는 0x80000000 또는 128 형식으로 입력해 주세요.")


def collect_interactive(config: dict[str, Any], source_root: Path) -> dict[str, Any]:
    print("\nRV OoO SoC 새 프로젝트 생성기")
    print("Enter를 누르면 대괄호 안의 기본값을 사용합니다.\n")
    config["project_name"] = prompt_text("프로젝트 이름", config["project_name"])
    for region in REGIONS:
        title = region.upper()
        entry = config["memory_map"][region]
        entry["base"] = hex32(prompt_number(
            f"{title} 시작 주소", parse_number(entry["base"]), address=True
        ))
        entry["size_kb"] = prompt_number(
            f"{title} 크기(KiB)", parse_number(entry["size_kb"])
        )

    config["boot"]["mtvec"] = hex32(prompt_number(
        "Boot mtvec 주소", parse_number(config["boot"]["mtvec"]), address=True
    ))
    config["boot"]["bootrom_image"] = prompt_text(
        "BootROM HEX 파일('auto'면 mtvec에 맞춰 자동 생성)",
        str(config["boot"]["bootrom_image"]),
    )
    config["host"]["payload_dir"] = prompt_text(
        "Host ELF를 복사할 새 프로젝트 내부 폴더",
        config["host"]["payload_dir"],
    )
    config["host"]["default_elf"] = prompt_text(
        "기본 DPI ELF 파일 경로(지금 지정하지 않으면 '-' 입력)",
        config["host"]["default_elf"] or "-",
    )
    config["host"]["artifact_root"] = prompt_text(
        "DPI 빌드/로그 출력 폴더(새 프로젝트 기준)",
        config["host"]["artifact_root"],
    )
    config["host"]["timeout_cycles"] = prompt_number(
        "DPI simulation timeout cycle", config["host"]["timeout_cycles"]
    )
    return config


def normalize(config: dict[str, Any]) -> dict[str, Any]:
    for region in REGIONS:
        entry = config["memory_map"][region]
        entry["base"] = hex32(parse_number(entry["base"]))
        entry["size_kb"] = parse_number(entry["size_kb"])
    config["boot"]["mtvec"] = hex32(parse_number(config["boot"]["mtvec"]))
    config["host"]["timeout_cycles"] = parse_number(
        config["host"]["timeout_cycles"]
    )
    if config["host"].get("default_elf") == "-":
        config["host"]["default_elf"] = ""
    return config


def validate(config: dict[str, Any]) -> None:
    errors: list[str] = []
    intervals: list[tuple[str, int, int]] = []
    for region in REGIONS:
        entry = config["memory_map"][region]
        base = parse_number(entry["base"])
        size_kb = parse_number(entry["size_kb"])
        size_bytes = size_kb * 1024
        if not 0 <= base <= 0xFFFFFFFF:
            errors.append(f"{region}: base가 RV32 주소 범위를 벗어납니다")
        if base & 0xFFF:
            errors.append(f"{region}: base는 4 KiB 정렬이어야 합니다")
        if size_kb <= 0:
            errors.append(f"{region}: size_kb는 1 이상이어야 합니다")
        if base + size_bytes > 0x1_0000_0000:
            errors.append(f"{region}: 영역 끝이 RV32 주소 범위를 벗어납니다")
        intervals.append((region, base, base + size_bytes))

    for index, (name_a, start_a, end_a) in enumerate(intervals):
        for name_b, start_b, end_b in intervals[index + 1 :]:
            if start_a < end_b and start_b < end_a:
                errors.append(f"주소 영역 중복: {name_a}와 {name_b}")

    mtvec = parse_number(config["boot"]["mtvec"])
    itim = config["memory_map"]["itim"]
    itim_start = parse_number(itim["base"])
    itim_end = itim_start + parse_number(itim["size_kb"]) * 1024
    if mtvec & 0x3 or not itim_start <= mtvec < itim_end:
        errors.append("boot.mtvec은 4-byte 정렬되고 ITIM 내부에 있어야 합니다")
    for tim in ("itim", "dtim"):
        if parse_number(config["memory_map"][tim]["size_kb"]) * 1024 % 16:
            errors.append(f"{tim}: 2-bank 64-bit 구조를 위해 크기가 16-byte 배수여야 합니다")
    if parse_number(config["memory_map"]["clint"]["size_kb"]) * 1024 < 0xC000:
        errors.append("CLINT 크기는 mtime register를 포함하도록 최소 48 KiB여야 합니다")
    if parse_number(config["memory_map"]["plic"]["size_kb"]) * 1024 < 0x201008:
        errors.append("PLIC 크기는 M/S context register를 포함하도록 최소 2053 KiB여야 합니다")
    if config["host"]["timeout_cycles"] <= 0:
        errors.append("host.timeout_cycles는 1 이상이어야 합니다")
    if errors:
        raise ValueError("설정 오류:\n  - " + "\n  - ".join(errors))


def replace_exact(path: Path, pattern: str, replacement: str) -> None:
    text = path.read_text(encoding="utf-8")
    changed, count = re.subn(pattern, replacement, text, flags=re.MULTILINE)
    if count != 1:
        raise RuntimeError(f"{path}: expected one replacement, found {count}")
    write_text_lf(path, changed)


def update_soc_package(project_root: Path, config: dict[str, Any]) -> None:
    package_path = project_root / "rtl/soc/rv_soc_pkg.sv"
    for region in REGIONS:
        symbol = region.upper()
        entry = config["memory_map"][region]
        replace_exact(
            package_path,
            rf"(parameter logic \[SOC_ADDR_WIDTH-1:0\]\s+{symbol}_BASE_ADDR\s*=\s*)32'h[0-9a-fA-F_]+;",
            rf"\g<1>{sv_hex32(parse_number(entry['base']))};",
        )
        replace_exact(
            package_path,
            rf"(parameter int unsigned\s+{symbol}_SIZE_KB\s*=\s*)\d+;",
            rf"\g<1>{entry['size_kb']};",
        )
    replace_exact(
        package_path,
        r"(parameter logic \[SOC_ADDR_WIDTH-1:0\]\s+BOOT_MTVEC_ADDR\s*=\s*)[^;]+;",
        rf"\g<1>{sv_hex32(parse_number(config['boot']['mtvec']))};",
    )


def update_software_map(project_root: Path, config: dict[str, Any]) -> None:
    mmap = config["memory_map"]
    linker = project_root / "sw/tests/rv32_c_loop/rv32_tim.ld"
    replace_exact(
        linker,
        r"(ITIM \(rx\)\s+: ORIGIN = )0x[0-9a-fA-F]+(, LENGTH = )\d+K",
        rf"\g<1>{hex32(parse_number(mmap['itim']['base']))}\g<2>{mmap['itim']['size_kb']}K",
    )
    replace_exact(
        linker,
        r"(DTIM \(rwx\) : ORIGIN = )0x[0-9a-fA-F]+(, LENGTH = )\d+K",
        rf"\g<1>{hex32(parse_number(mmap['dtim']['base']))}\g<2>{mmap['dtim']['size_kb']}K",
    )

    c_source = project_root / "sw/tests/rv32_c_loop/rv32_loop_smoke.c"
    replace_exact(
        c_source,
        r"#define HOSTIF_BASE_ADDR 0x[0-9a-fA-F]+u",
        f"#define HOSTIF_BASE_ADDR {hex32(parse_number(mmap['hostif']['base']))}u",
    )
    start = project_root / "sw/tests/rv32_c_loop/rv32_start.S"
    start_text = start.read_text(encoding="utf-8")
    start_text, clint_count = re.subn(
        r"\s+(?:lui|li)\s+t0,\s*0x[0-9a-fA-F]+\s*\n\s+sw\s+zero,\s*0\(t0\)",
        f"\n  li    t0, {hex32(parse_number(mmap['clint']['base']))}\n"
        "  sw    zero, 0(t0)",
        start_text,
        count=1,
    )
    start_text, host_count = re.subn(
        r"\s+(?:lui|li)\s+t0,\s*0x[0-9a-fA-F]+\s*\n\s+sw\s+a0,\s*0x14\(t0\)",
        f"\n  li    t0, {hex32(parse_number(mmap['hostif']['base']))}\n"
        "  sw    a0, 0x14(t0)",
        start_text,
        count=1,
    )
    if clint_count != 1 or host_count != 1:
        raise RuntimeError("rv32_start.S address replacement failed")
    write_text_lf(start, start_text)

    run_c = project_root / "scripts/run_c_loop_test.ps1"
    replace_exact(
        run_c,
        r'\$itimBase = \[Convert\]::ToUInt32\("[0-9a-fA-F]+", 16\)',
        f'$itimBase = [Convert]::ToUInt32("{parse_number(mmap["itim"]["base"]):08x}", 16)',
    )


def copy_runtime_assets(
    project_root: Path, source_root: Path, config: dict[str, Any]
) -> None:
    boot_dest = project_root / "config/assets/bootrom.hex"
    boot_dest.parent.mkdir(parents=True, exist_ok=True)
    boot_choice = str(config["boot"]["bootrom_image"]).strip()
    if boot_choice.lower() == "auto":
        write_bootrom_wait_hex(boot_dest, parse_number(config["boot"]["mtvec"]))
        config["boot"]["bootrom_source"] = "auto-generated WFI image"
    else:
        boot_source = Path(boot_choice).expanduser()
        if not boot_source.is_absolute():
            boot_source = source_root / boot_source
        if not boot_source.is_file():
            raise FileNotFoundError(f"BootROM HEX 파일을 찾을 수 없습니다: {boot_source}")
        shutil.copy2(boot_source, boot_dest)
        config["boot"]["bootrom_source"] = str(boot_source.resolve())
    config["boot"]["bootrom_image"] = "config/assets/bootrom.hex"

    for testbench in (
        "tb/e2e/dpi/rv_soc_dpi_tb.sv",
        "tb/integration/soc/rv_soc_top_tb.sv",
    ):
        replace_exact(
            project_root / testbench,
            r'(\.BOOTROM_INIT_FILE\s*\(")[^"]+("\))',
            r'\g<1>config/assets/bootrom.hex\g<2>',
        )
    first_bootrom_beat = boot_dest.read_text(encoding="ascii").splitlines()[0].strip()
    if not re.fullmatch(r"[0-9a-fA-F]{16}", first_bootrom_beat):
        raise ValueError("BootROM HEX 첫 줄은 64-bit hexadecimal word여야 합니다")
    boot_tb = project_root / "tb/integration/soc/rv_soc_top_tb.sv"
    replace_exact(
        boot_tb,
        r"(axi_read\(4'h1, BOOTROM_BASE_ADDR,[\s\S]*?read_data != 64'h)"
        r"[0-9a-fA-F_]+(\)\))",
        rf"\g<1>{first_bootrom_beat}\g<2>",
    )

    elf_value = str(config["host"].get("default_elf", "")).strip()
    if elf_value:
        elf_source = Path(elf_value).expanduser()
        if not elf_source.is_absolute():
            elf_source = source_root / elf_source
        if not elf_source.is_file():
            raise FileNotFoundError(f"기본 ELF 파일을 찾을 수 없습니다: {elf_source}")
        payload_dir = Path(config["host"]["payload_dir"])
        if payload_dir.is_absolute() or ".." in payload_dir.parts:
            raise ValueError("host.payload_dir은 새 프로젝트 내부 상대 경로여야 합니다")
        elf_dest = project_root / payload_dir / elf_source.name
        elf_dest.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(elf_source, elf_dest)
        config["host"]["default_elf"] = elf_dest.relative_to(project_root).as_posix()
    else:
        config["host"]["default_elf"] = ""


def write_bootrom_wait_hex(path: Path, mtvec: int) -> None:
    """Write a tiny M-mode ROM: set mtvec/MSIE/MIE, then WFI forever."""
    upper = (mtvec + 0x800) >> 12
    lower = mtvec - (upper << 12)

    def u_type(imm20: int, rd: int, opcode: int = 0x37) -> int:
        return ((imm20 & 0xFFFFF) << 12) | ((rd & 0x1F) << 7) | opcode

    def i_type(imm: int, rs1: int, funct3: int, rd: int, opcode: int) -> int:
        return (
            ((imm & 0xFFF) << 20)
            | ((rs1 & 0x1F) << 15)
            | ((funct3 & 7) << 12)
            | ((rd & 0x1F) << 7)
            | opcode
        )

    def csr_type(csr: int, rs1: int, funct3: int, rd: int = 0) -> int:
        return (
            ((csr & 0xFFF) << 20)
            | ((rs1 & 0x1F) << 15)
            | ((funct3 & 7) << 12)
            | ((rd & 0x1F) << 7)
            | 0x73
        )

    words = [
        u_type(upper, 5),                    # lui  t0,%hi(mtvec)
        i_type(lower, 5, 0, 5, 0x13),       # addi t0,t0,%lo(mtvec)
        csr_type(0x305, 5, 1),               # csrw mtvec,t0
        i_type(8, 0, 0, 5, 0x13),           # li   t0,MIE.MSIE
        csr_type(0x304, 5, 1),               # csrw mie,t0
        csr_type(0x300, 5, 2),               # csrs mstatus,t0 (MIE bit)
        0x10500073,                          # wfi
        0x0000006F,                          # jal zero,0
    ]
    lines = [f"{words[index + 1]:08x}{words[index]:08x}" for index in range(0, 8, 2)]
    write_text_lf(path, "\n".join(lines) + "\n", encoding="ascii")


def write_generated_files(project_root: Path, config: dict[str, Any]) -> None:
    config_dir = project_root / "config"
    config_dir.mkdir(parents=True, exist_ok=True)
    config_path = config_dir / "soc_project.json"
    write_text_lf(config_path, json.dumps(config, indent=2, ensure_ascii=False) + "\n")

    mmap = config["memory_map"]
    header_lines = [
        "/* Auto-generated by scripts/configure_project.py. */",
        "#ifndef RV_SOC_MEMORY_MAP_H",
        "#define RV_SOC_MEMORY_MAP_H",
    ]
    asm_lines = ["/* Auto-generated by scripts/configure_project.py. */"]
    for region in REGIONS:
        symbol = region.upper()
        base = parse_number(mmap[region]["base"])
        size_kb = parse_number(mmap[region]["size_kb"])
        header_lines.extend([
            f"#define {symbol}_BASE_ADDR {hex32(base)}u",
            f"#define {symbol}_SIZE_KB {size_kb}u",
        ])
        asm_lines.extend([
            f".equ {symbol}_BASE_ADDR, {hex32(base)}",
            f".equ {symbol}_SIZE_KB, {size_kb}",
        ])
    header_lines.extend([
        f"#define BOOT_MTVEC_ADDR {config['boot']['mtvec']}u",
        "#endif",
        "",
    ])
    asm_lines.extend([f".equ BOOT_MTVEC_ADDR, {config['boot']['mtvec']}", ""])
    write_text_lf(config_dir / "soc_memory_map.h", "\n".join(header_lines))
    write_text_lf(config_dir / "soc_memory_map.inc", "\n".join(asm_lines))

    def shell_quote(value: str) -> str:
        return "'" + value.replace("'", "'\"'\"'") + "'"

    env_lines = [
        "# Auto-generated. Source this file only from this repository.",
        f"SOC_DEFAULT_ELF={shell_quote(config['host']['default_elf'])}",
        f"SOC_ARTIFACT_ROOT={shell_quote(config['host']['artifact_root'])}",
        f"SOC_TIMEOUT_CYCLES={config['host']['timeout_cycles']}",
        "",
    ]
    write_text_lf(config_dir / "soc_project.env", "\n".join(env_lines))

    readme = f"""# Generated SoC configuration

Project: `{config['project_name']}`

- RTL memory map: `rtl/soc/rv_soc_pkg.sv`
- Machine-readable configuration: `config/soc_project.json`
- C/assembly constants: `config/soc_memory_map.h`, `config/soc_memory_map.inc`
- BootROM image used by DPI testbench: `{config['boot']['bootrom_image']}`
- Default Host ELF: `{config['host']['default_elf'] or '(not set; pass an ELF path when running)'}`

Windows:

```powershell
scripts/run_configured_elf.ps1
# or: scripts/run_configured_elf.ps1 -ElfPath C:\\path\\program.elf
```

Linux:

```bash
./scripts/run_configured_elf.sh
# or: ./scripts/run_configured_elf.sh /path/program.elf
```
"""
    write_text_lf(config_dir / "README.md", readme)


def copy_project(source_root: Path, output_root: Path) -> None:
    source_resolved = source_root.resolve()
    output_resolved = output_root.resolve()
    if output_resolved == source_resolved or source_resolved in output_resolved.parents:
        raise ValueError("출력 폴더는 원본 프로젝트 밖에 지정해야 합니다")
    if output_root.exists():
        raise FileExistsError(
            f"출력 폴더가 이미 존재합니다: {output_root}\n"
            "안전을 위해 덮어쓰지 않습니다. 새 폴더명을 사용해 주세요."
        )

    ignored_names = {
        ".git", ".pytest_cache", "__pycache__", "build", "out", "obj_dir"
    }

    def ignore(_directory: str, names: list[str]) -> set[str]:
        return {name for name in names if name in ignored_names or name.endswith(".pyc")}

    shutil.copytree(source_root, output_root, ignore=ignore)


def load_config(path: Optional[Path]) -> dict[str, Any]:
    config = json.loads(json.dumps(DEFAULTS))
    if path:
        loaded = json.loads(path.read_text(encoding="utf-8"))
        config = deep_merge(config, loaded)
    return config


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description="대화형 질문 또는 JSON으로 설정된 새 SoC 프로젝트 복사본을 만듭니다."
    )
    parser.add_argument("--output", help="새 프로젝트 폴더(기본: 원본의 형제 폴더)")
    parser.add_argument("--config", type=Path, help="질문 기본값/비대화형 입력 JSON")
    parser.add_argument("--non-interactive", action="store_true", help="질문 없이 설정값 사용")
    parser.add_argument("--project-name")
    parser.add_argument("--default-elf", help="새 프로젝트에 복사할 기본 DPI ELF")
    parser.add_argument("--bootrom-image", help="새 프로젝트에 복사할 BootROM HEX")
    parser.add_argument("--boot-mtvec", help="Boot mtvec 주소(기본: ITIM base)")
    for region in REGIONS:
        parser.add_argument(f"--{region}-base")
        parser.add_argument(f"--{region}-size-kb", type=int)
    return parser


def main() -> int:
    args = build_parser().parse_args()
    source_root = Path(__file__).resolve().parents[1]
    config = load_config(args.config)
    if args.project_name:
        config["project_name"] = args.project_name
    if args.default_elf is not None:
        config["host"]["default_elf"] = args.default_elf
    if args.bootrom_image is not None:
        config["boot"]["bootrom_image"] = args.bootrom_image
    if args.boot_mtvec is not None:
        config["boot"]["mtvec"] = args.boot_mtvec
    for region in REGIONS:
        base_arg = getattr(args, f"{region}_base")
        size_arg = getattr(args, f"{region}_size_kb")
        if base_arg is not None:
            config["memory_map"][region]["base"] = base_arg
        if size_arg is not None:
            config["memory_map"][region]["size_kb"] = size_arg
    if args.itim_base is not None and args.boot_mtvec is None and args.config is None:
        config["boot"]["mtvec"] = args.itim_base

    if not args.non_interactive:
        config = collect_interactive(config, source_root)
    config = normalize(config)
    validate(config)

    default_output = source_root.parent / f"{config['project_name']}_configured"
    output_value = args.output
    if not args.non_interactive and not output_value:
        output_value = prompt_text("새 프로젝트를 만들 폴더", str(default_output))
    output = Path(output_value).expanduser() if output_value else default_output
    if not output.is_absolute():
        output = Path.cwd() / output
    copy_project(source_root, output)
    try:
        update_soc_package(output, config)
        update_software_map(output, config)
        copy_runtime_assets(output, source_root, config)
        write_generated_files(output, config)
    except Exception:
        shutil.rmtree(output, ignore_errors=True)
        raise

    print("\n생성 완료")
    print(f"  새 프로젝트 : {output.resolve()}")
    print(f"  설정 파일    : {(output / 'config/soc_project.json').resolve()}")
    print(f"  BootROM      : {config['boot']['bootrom_image']}")
    print(f"  기본 ELF     : {config['host']['default_elf'] or '(실행할 때 지정)'}")
    print("  Windows 실행 : scripts\\run_configured_elf.ps1")
    print("  Linux 실행   : ./scripts/run_configured_elf.sh")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (ValueError, FileNotFoundError, FileExistsError, RuntimeError) as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        raise SystemExit(2)
