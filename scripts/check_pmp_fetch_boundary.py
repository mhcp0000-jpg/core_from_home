#!/usr/bin/env python3
"""Check the exact TOR/fetch-block boundary directed commit trace."""

import argparse
import csv
from pathlib import Path


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("trace", type=Path)
    args = parser.parse_args()

    with args.trace.open(newline="", encoding="utf-8") as stream:
        rows = list(csv.DictReader(stream))

    def csr_write(name: str, value: int) -> bool:
        return any(
            row.get("csr_name") == name
            and int(row.get("csr_we", "0")) == 1
            and int(row.get("csr_wdata", "0"), 16) == value
            for row in rows
        )

    assert csr_write("pmpaddr0", 0x2000023F), "pmpaddr0 TOR top was not committed"
    assert csr_write("pmpcfg0", 0x0000000F), "pmpcfg0 TOR/RWX was not committed"

    boundary = [row for row in rows if int(row["pc"], 16) == 0x800008FC]
    assert boundary, "0x800008fc did not retire"
    assert any(
        int(row["instruction"], 16) == 0x80000B37
        and int(row["trap"]) == 0
        for row in boundary
    ), "boundary_entry did not retire as a legal LUI"

    post_entry_traps = [
        row for row in rows
        if int(row["pc"], 16) >= 0x800008FC and int(row["trap"]) != 0
    ]
    assert not post_entry_traps, f"unexpected post-entry traps: {post_entry_traps[:2]}"
    print(
        "PASS: TOR top=0x800008fc, 16-byte block=0x800008f0, "
        "M-mode instruction at 0x800008fc retired without fault"
    )


if __name__ == "__main__":
    main()
