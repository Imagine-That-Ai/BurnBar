#!/usr/bin/env python3
"""Validate CloudVault at-rest runtime evidence for Signal-backed private data."""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path
from typing import Any


PRIVACY_MARKER = "proof_only_no_plaintext_keys_ciphertext_or_document_identifiers"
REQUIRED_COMMAND_FRAGMENTS = (
    "scripts/ci/check_functions_cloudvault_runtime.js",
    "tests/test_signal_envelope_contracts_cjs_exports.py",
)


def validate_cloudvault_at_rest_evidence(data: dict[str, Any]) -> list[str]:
    errors: list[str] = []
    if data.get("privacy") != PRIVACY_MARKER:
        errors.append("privacy marker must be proof_only_no_plaintext_keys_ciphertext_or_document_identifiers")
    commands = [entry.get("command", "") for entry in data.get("commandEvidence", []) if isinstance(entry, dict)]
    for fragment in REQUIRED_COMMAND_FRAGMENTS:
        if not any(fragment in command for command in commands):
            errors.append(f"missing command evidence for {fragment}")
    if data.get("signalAtRestWritesEnabled") is not True:
        errors.append("signalAtRestWritesEnabled must be true for release-ready evidence")
    return errors


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("evidence", type=Path)
    args = parser.parse_args(argv)
    try:
        data = json.loads(args.evidence.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        print(f"FAIL: unreadable CloudVault evidence: {exc}", file=sys.stderr)
        return 1
    errors = validate_cloudvault_at_rest_evidence(data)
    if errors:
        print("FAIL: CloudVault at-rest runtime evidence is not release-ready", file=sys.stderr)
        for error in errors:
            print(f"- {error}", file=sys.stderr)
        return 1
    print("PASS: CloudVault at-rest runtime evidence is release-ready")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
