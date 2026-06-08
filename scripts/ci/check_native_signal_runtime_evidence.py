#!/usr/bin/env python3
"""Validate native libsignal runtime evidence packets."""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path
from typing import Any


PRIVACY_MARKER = "proof_only_no_plaintext_keys_or_user_data"
REQUIRED_PLATFORMS = ("swift", "kotlin")
GATE_REQUIRED_PLATFORMS = {
    "rust_core_bridge": ("rust",),
    "swift_round_trips": ("swift",),
    "kotlin_round_trips": ("kotlin",),
}


def validate_native_signal_runtime_evidence(data: dict[str, Any], *, gate: str | None = None) -> list[str]:
    errors: list[str] = []
    if data.get("privacy") != PRIVACY_MARKER:
        errors.append("privacy marker must be proof_only_no_plaintext_keys_or_user_data")
    platforms = data.get("platforms") or {}
    required_platforms = GATE_REQUIRED_PLATFORMS.get(gate, REQUIRED_PLATFORMS)
    for platform in required_platforms:
        evidence = platforms.get(platform) if isinstance(platforms, dict) else None
        if not isinstance(evidence, dict):
            errors.append(f"missing {platform} runtime evidence")
            continue
        if evidence.get("status") != "pass":
            errors.append(f"{platform} runtime evidence must be pass")
        if not evidence.get("command"):
            errors.append(f"{platform} runtime evidence is missing command")
    return errors


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("evidence", type=Path)
    parser.add_argument("--gate", choices=tuple(GATE_REQUIRED_PLATFORMS), default=None)
    args = parser.parse_args(argv)
    try:
        data = json.loads(args.evidence.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        print(f"FAIL: unreadable native runtime evidence: {exc}", file=sys.stderr)
        return 1
    errors = validate_native_signal_runtime_evidence(data, gate=args.gate)
    if errors:
        print("FAIL: native Signal runtime evidence is not release-ready", file=sys.stderr)
        for error in errors:
            print(f"- {error}", file=sys.stderr)
        return 1
    print("PASS: native Signal runtime evidence is release-ready")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
