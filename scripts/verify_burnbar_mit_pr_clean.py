#!/usr/bin/env python3
"""Verify a Nous/Hermes MIT PR does not carry BurnBar product-only materials."""

from __future__ import annotations

import argparse
import subprocess
import sys
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
FORBIDDEN = (
    "official libsignal npm dependency",
    "post-quantum recovery claim",
    "AGPL_RELEASE_REVIEW_PACKET.md",
    "Vendor/libsignal/",
)


def git_lines(args: list[str]) -> list[str]:
    result = subprocess.run(["git", *args], cwd=ROOT, text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=True)
    return [line for line in result.stdout.splitlines() if line]


def changed_paths(base: str, include_working_tree: bool) -> list[str]:
    paths = set(git_lines(["diff", "--name-only", f"{base}...HEAD"]))
    if include_working_tree:
        paths.update(git_lines(["ls-files", "--modified", "--others", "--exclude-standard"]))
    return sorted(paths)


def scan_path(rel_path: str) -> list[str]:
    path = ROOT / rel_path
    if not path.is_file():
        return []
    try:
        text = path.read_text(encoding="utf-8")
    except UnicodeDecodeError:
        return []
    violations = []
    for token in FORBIDDEN:
        if token in text or token in rel_path:
            violations.append(f"{rel_path}: {token}")
    return violations


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="BurnBar MIT PR cleanliness scan")
    parser.add_argument("--base", required=True)
    parser.add_argument("--include-working-tree", action="store_true")
    args = parser.parse_args(argv)
    violations = []
    for rel_path in changed_paths(args.base, args.include_working_tree):
        violations.extend(scan_path(rel_path))
    if violations:
        print("FAIL: BurnBar MIT PR cleanliness scan found product-lane material", file=sys.stderr)
        for violation in violations:
            print(f"- {violation}", file=sys.stderr)
        return 1
    print("PASS: BurnBar MIT PR cleanliness scan checked changed path(s)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
