#!/usr/bin/env python3
"""Validate CloudVault at-rest runtime evidence for Signal-backed private data."""

from __future__ import annotations

import argparse
from datetime import UTC, datetime, timedelta
import json
import sys
from pathlib import Path
from typing import Any


PRIVACY_MARKER = "proof_only_no_plaintext_keys_ciphertext_or_document_identifiers"
MAX_EVIDENCE_AGE = timedelta(hours=24)
REQUIRED_COMMAND_FRAGMENTS = (
    "scripts/ci/check_functions_cloudvault_runtime.js",
    "tests/test_signal_envelope_contracts_cjs_exports.py",
)
REQUIRED_ASSERTIONS = (
    "compiled_functions_imports_signal_at_rest_write",
    "admin_write_validator_accepts_strict_cloudvault_envelope",
    "admin_write_validator_derives_canonical_aad",
    "admin_write_validator_rejects_wrong_binding",
    "admin_write_validator_rejects_plaintext",
    "contract_sanitizer_rejects_gateway_transport_as_cloudvault",
    "sanitized_envelope_drops_plaintext_siblings",
    "cjs_runtime_import_validates_signal_at_rest_write",
)
FORBIDDEN_EVIDENCE_KEYS = {
    "plaintext",
    "ciphertext",
    "privateKey",
    "secretKey",
    "rawKey",
    "documentId",
    "docId",
    "uid",
    "userId",
}


def _iter_keys(value: Any):
    if isinstance(value, dict):
        for key, nested in value.items():
            yield str(key)
            yield from _iter_keys(nested)
    elif isinstance(value, list):
        for item in value:
            yield from _iter_keys(item)


def _validate_generated_at(value: Any, errors: list[str]) -> None:
    if not isinstance(value, str) or not value:
        errors.append("generatedAt is required")
        return
    try:
        generated_at = datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError:
        errors.append("generatedAt must be an ISO timestamp")
        return
    if generated_at.tzinfo is None:
        generated_at = generated_at.replace(tzinfo=UTC)
    if datetime.now(UTC) - generated_at.astimezone(UTC) > MAX_EVIDENCE_AGE:
        errors.append("generatedAt must be within the last 24 hours")


def _passed_commands(data: dict[str, Any]) -> list[dict[str, Any]]:
    commands = data.get("commandEvidence", [])
    if not isinstance(commands, list):
        return []
    return [
        entry
        for entry in commands
        if isinstance(entry, dict)
        and entry.get("status") == "pass"
        and entry.get("exitCode") == 0
        and isinstance(entry.get("command"), str)
    ]


def _assertions(data: dict[str, Any]) -> set[str]:
    present: set[str] = set()
    top_level = data.get("assertions")
    if isinstance(top_level, list):
        present.update(item for item in top_level if isinstance(item, str))
    for entry in data.get("commandEvidence", []):
        if not isinstance(entry, dict):
            continue
        entry_assertions = entry.get("assertions")
        if isinstance(entry_assertions, list):
            present.update(item for item in entry_assertions if isinstance(item, str))
    return present


def validate_cloudvault_at_rest_evidence(data: dict[str, Any]) -> list[str]:
    errors: list[str] = []
    if data.get("schemaVersion") != 1:
        errors.append("schemaVersion must be 1")
    _validate_generated_at(data.get("generatedAt"), errors)
    if not data.get("generatedBy"):
        errors.append("generatedBy is required")
    if data.get("privacy") != PRIVACY_MARKER:
        errors.append("privacy marker must be proof_only_no_plaintext_keys_ciphertext_or_document_identifiers")
    leaked_keys = sorted({key for key in _iter_keys(data) if key in FORBIDDEN_EVIDENCE_KEYS})
    if leaked_keys:
        errors.append(
            "evidence must not contain plaintext, ciphertext, keys, or document identifiers: "
            + ", ".join(leaked_keys)
        )
    commands = [entry.get("command", "") for entry in _passed_commands(data)]
    for fragment in REQUIRED_COMMAND_FRAGMENTS:
        if not any(fragment in command for command in commands):
            errors.append(f"missing passing command evidence for {fragment}")
    present_assertions = _assertions(data)
    for assertion in REQUIRED_ASSERTIONS:
        if assertion not in present_assertions:
            errors.append(f"missing proof assertion: {assertion}")
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
