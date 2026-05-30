#!/usr/bin/env python3
"""Shared error-debt counters for CI gates and TECH_DEBT_METRICS.md."""

from __future__ import annotations

import argparse
import json
import pathlib
import re
import sys


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


def count_try_optional_services(repo_root: pathlib.Path) -> dict[str, int]:
    """Count try? occurrences under AgentLens/Services."""
    services = repo_root / "AgentLens" / "Services"
    total = 0
    if not services.exists():
        return {"total": 0}

    for path in services.rglob("*.swift"):
        try:
            text = path.read_text(encoding="utf-8")
        except OSError:
            continue
        total += len(re.findall(r"try\?", text))

    return {"total": total}


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
            print(f"try_optional total={to['total']}")
    else:
        json.dump(payload, sys.stdout, indent=2)
        sys.stdout.write("\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
