#!/usr/bin/env python3
"""Remove stale MagicNumbers prefixes and fix broken replacements."""

from __future__ import annotations

import re
from pathlib import Path

ROOTS = [
    Path(__file__).resolve().parents[1] / "app/src/main/java/com/openburnbar/data",
    Path(__file__).resolve().parents[1] / "app/src/test/java/com/openburnbar/data",
]

def process(content: str) -> str:
    content = content.replace("MagicNumbers.", "")
    # Remove stray ')' left when `(1_000_000.0)` became `VAL_1000000_0)`.
    content = re.sub(r"(/ VAL_[0-9_]+_0)\)([\s*+\-])", r"\1\2", content)
    content = re.sub(r"(/ VAL_[0-9_]+_0)\)\.", r"\1.", content)
    return content


def main() -> None:
    changed = 0
    for root in ROOTS:
        for path in root.rglob("*.kt"):
            original = path.read_text(encoding="utf-8")
            updated = process(original)
            if updated != original:
                path.write_text(updated, encoding="utf-8")
                changed += 1
    print(f"Cleaned {changed} files")


if __name__ == "__main__":
    main()
