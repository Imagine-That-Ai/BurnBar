#!/usr/bin/env python3
"""Repair MagicNumber remediation artifacts in OpenBurnBar Android data/ layer."""

from __future__ import annotations

import re
from pathlib import Path

ANDROID_ROOT = Path(__file__).resolve().parents[1]
DATA_GLOBS = [
    ANDROID_ROOT / "app/src/main/java/com/openburnbar/data",
    ANDROID_ROOT / "app/src/test/java/com/openburnbar/data",
]

INVALID_CONST_RE = re.compile(
    r"private const val (VAL_[0-9]+(?:\.[0-9_]+)+)\s*=\s*([^\n]+)"
)


def sanitize_name(name: str) -> str:
    return name.replace(".", "_").replace("-", "_")


def unwrap_magic_numbers_object(source: str) -> str:
    pattern = re.compile(
        r"private object MagicNumbers \{\n((?:    private const val .+\n)+)\}\n\n",
        re.MULTILINE,
    )

    def repl(match: re.Match[str]) -> str:
        block = match.group(1)
        lines = []
        for line in block.splitlines():
            line = line.replace("    private const val ", "private const val ")
            lines.append(line)
        return "\n".join(lines) + "\n\n"

    return pattern.sub(repl, source)


def fix_invalid_const_names(source: str) -> str:
    def repl(match: re.Match[str]) -> str:
        bad_name = match.group(1)
        value = match.group(2).strip()
        good_name = sanitize_name(bad_name)
        # Double/float values cannot be const val in some cases - use val for non-primitive-looking
        if re.search(r"[eE]", value) or "." in value and not value.endswith(".0"):
            return f"private val {good_name} = {value}"
        if "." in value:
            return f"private const val {good_name} = {value}"
        return f"private const val {good_name} = {value}"

    new_source = INVALID_CONST_RE.sub(repl, source)
    # rename usages
    for match in INVALID_CONST_RE.finditer(source):
        bad = match.group(1)
        good = sanitize_name(bad)
        new_source = re.sub(rf"\b{re.escape(bad)}\b", good, new_source)
    return new_source


def fix_double_const_in_objects(source: str) -> str:
    # const val with float/double is allowed in Kotlin but names were broken; also fix member private const in objects
    return source


def process_file(path: Path) -> bool:
    original = path.read_text(encoding="utf-8")
    updated = original
    updated = unwrap_magic_numbers_object(updated)
    updated = fix_invalid_const_names(updated)
    if updated != original:
        path.write_text(updated, encoding="utf-8")
        return True
    return False


def main() -> None:
    changed = 0
    for root in DATA_GLOBS:
        if not root.exists():
            continue
        for path in sorted(root.rglob("*.kt")):
            if process_file(path):
                changed += 1
                print(f"repaired {path.relative_to(ANDROID_ROOT)}")
    print(f"Repaired {changed} files")


if __name__ == "__main__":
    main()
