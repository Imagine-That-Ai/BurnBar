#!/usr/bin/env python3
"""Shared error-debt counters for CI gates and TECH_DEBT_METRICS.md."""

from __future__ import annotations

import argparse
import json
import pathlib
import re
import sys


EXCLUDED_PATH_SEGMENTS = {
    ".build",
    ".build-codex",
    ".derived-data",
    ".git",
    ".swiftpm",
    "Carthage",
    "DerivedData",
    "Pods",
    "build",
    "checkouts",
}


def is_excluded_path(path: pathlib.Path) -> bool:
    return any(part in EXCLUDED_PATH_SEGMENTS for part in path.parts)


def count_empty_catches(repo_root: pathlib.Path) -> dict[str, int]:
    """Count empty catch blocks in AgentLens and OpenBurnBarDaemon."""
    count = 0
    agent_lens = 0
    daemon = 0
    pattern = re.compile(r"catch\s*\{([^}]*)\}")

    for label, base in (("agent_lens", repo_root / "AgentLens"), ("daemon", repo_root / "OpenBurnBarDaemon")):
        subtotal = 0
        if not base.exists():
            continue
        for path in base.rglob("*.swift"):
            if is_excluded_path(path.relative_to(repo_root)):
                continue
            try:
                text = path.read_text(encoding="utf-8")
            except OSError:
                continue
            for match in pattern.finditer(text):
                body = match.group(1)
                stripped = re.sub(r"//[^\n]*", "", body).strip()
                if not stripped:
                    subtotal += 1
        if label == "agent_lens":
            agent_lens = subtotal
        else:
            daemon = subtotal
        count += subtotal

    return {"total": count, "agent_lens": agent_lens, "daemon": daemon}


# A `try?` occurrence, excluding the `try?-ok` justification token itself so a
# tag comment can never inflate the count (negative lookahead on `-ok`).
TRY_OPTIONAL_OCCURRENCE = re.compile(r"try\?(?!-ok)")
# The justification token that marks an intentional, reviewed best-effort
# optionality. Written as `// try?-ok(<reason>)` on the same source line as the
# `try?` (preferred) or on the line immediately above it.
TRY_OPTIONAL_TAG = "try?-ok("


def count_untagged_try_optional_in_text(text: str) -> tuple[int, int]:
    """Return (untagged, tagged) `try?` counts for one Swift source string.

    A `try?` is *tagged* when a ``try?-ok(<reason>)`` token appears on its own
    line or on the line immediately above it. Tagged sites are intentional
    best-effort reads that have been reviewed and justified; only untagged
    sites are counted as debt, which lets the ratchet drive the untagged total
    to zero without forcing genuinely-optional reads into `do/catch`.
    """
    untagged = 0
    tagged = 0
    lines = text.split("\n")
    for index, line in enumerate(lines):
        hits = len(TRY_OPTIONAL_OCCURRENCE.findall(line))
        if hits == 0:
            continue
        previous = lines[index - 1] if index > 0 else ""
        if TRY_OPTIONAL_TAG in line or TRY_OPTIONAL_TAG in previous:
            tagged += hits
        else:
            untagged += hits
    return untagged, tagged


def count_try_optional_services(repo_root: pathlib.Path) -> dict[str, int]:
    """Count untagged `try?` occurrences under AgentLens/Services.

    Only untagged sites count toward the debt budget; sites carrying a
    ``try?-ok(<reason>)`` justification are reported separately as ``tagged``.
    """
    services = repo_root / "AgentLens" / "Services"
    if not services.exists():
        return {"total": 0, "tagged": 0}

    untagged_total = 0
    tagged_total = 0
    for path in services.rglob("*.swift"):
        if is_excluded_path(path.relative_to(repo_root)):
            continue
        try:
            text = path.read_text(encoding="utf-8")
        except OSError:
            continue
        untagged, tagged = count_untagged_try_optional_in_text(text)
        untagged_total += untagged
        tagged_total += tagged

    return {"total": untagged_total, "tagged": tagged_total}


def main() -> int:
    parser = argparse.ArgumentParser(description="OpenBurnBar error-debt counters")
    parser.add_argument("--repo-root", type=pathlib.Path, default=pathlib.Path.cwd())
    parser.add_argument(
        "--metric",
        choices=("empty-catch", "try-optional", "all"),
        default="all",
    )
    parser.add_argument("--format", choices=("json", "text"), default="json")
    args = parser.parse_args()
    repo_root = args.repo_root.resolve()

    payload: dict[str, object] = {}
    if args.metric in ("empty-catch", "all"):
        payload["emptyCatch"] = count_empty_catches(repo_root)
    if args.metric in ("try-optional", "all"):
        payload["tryOptional"] = count_try_optional_services(repo_root)

    if args.format == "text":
        if "emptyCatch" in payload:
            ec = payload["emptyCatch"]
            assert isinstance(ec, dict)
            print(f"empty_catch total={ec['total']} agent_lens={ec['agent_lens']} daemon={ec['daemon']}")
        if "tryOptional" in payload:
            to = payload["tryOptional"]
            assert isinstance(to, dict)
            print(f"try_optional total={to['total']} tagged={to.get('tagged', 0)}")
    else:
        json.dump(payload, sys.stdout, indent=2)
        sys.stdout.write("\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
