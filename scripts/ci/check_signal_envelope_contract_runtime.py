#!/usr/bin/env python3
"""Validate Node Signal-envelope contract runtime evidence."""

from __future__ import annotations

import argparse
from datetime import UTC, datetime, timedelta
import json
import re
import sys
from pathlib import Path
from typing import Any


PRIVACY_MARKER = "proof_only_no_plaintext_keys_ciphertext_or_user_data"
MAX_EVIDENCE_AGE = timedelta(hours=24)
SHA256_RE = re.compile(r"^[0-9a-f]{64}$")
FORBIDDEN_EVIDENCE_KEYS = {
    "plaintext",
    "ciphertext",
    "privateKey",
    "secretKey",
    "rawKey",
    "userData",
    "stdoutText",
    "stderrText",
}
REQUIRED_COMMAND_FRAGMENTS = (
    "npm ci --prefix packages/signal-envelope-contracts",
    "npm test --prefix packages/signal-envelope-contracts",
    "npm ci --prefix functions",
    "npm run build --prefix functions",
    "src/__tests__/hermesGatewaySignalEnvelope.test.ts",
    "src/__tests__/dataExport.test.ts",
    "src/__tests__/hermesGatewaySealedEvent.test.ts",
    "npm run test:hermes-gateway --prefix functions",
    "npm ci --prefix services/hosted-mcp",
    "npm test --prefix services/hosted-mcp",
    "npm ci --prefix services/hermes-realtime-relay",
    "npm test --prefix services/hermes-realtime-relay",
)
REQUIRED_ASSERTIONS = (
    "signal_envelope_contracts_package_tests_pass",
    "transport_and_at_rest_envelope_sanitizers",
    "export_sanitizer_fails_closed",
    "deterministic_binding_aad_vectors",
    "aad_delimiter_and_control_guard",
    "unicode_normalization_fixture",
    "functions_typescript_builds_with_contracts",
    "functions_gateway_signal_envelope_tests",
    "functions_export_sanitization_tests",
    "functions_sealed_event_contract_tests",
    "functions_hermes_gateway_script_tests",
    "hosted_mcp_signal_contract_tests",
    "hermes_realtime_relay_signal_contract_tests",
)


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


def _command_entries(data: dict[str, Any]) -> list[dict[str, Any]]:
    entries = data.get("commandEvidence")
    if not isinstance(entries, list):
        return []
    return [entry for entry in entries if isinstance(entry, dict)]


def _validate_command_entry(entry: dict[str, Any], errors: list[str]) -> None:
    status = entry.get("status")
    if status not in {"pass", "fail"}:
        errors.append("command evidence status must be pass or fail")
    if not isinstance(entry.get("command"), str) or not entry.get("command"):
        errors.append("command evidence is missing command")
    if not isinstance(entry.get("exitCode"), int):
        errors.append("command evidence is missing numeric exitCode")
    duration_ms = entry.get("durationMs")
    if not isinstance(duration_ms, int) or duration_ms < 0:
        errors.append("command evidence is missing non-negative durationMs")
    for field in ("stdoutSha256", "stderrSha256"):
        value = entry.get(field)
        if not isinstance(value, str) or not SHA256_RE.fullmatch(value):
            errors.append(f"command evidence {field} must be a lowercase SHA-256 hex digest")


def _passing_commands(data: dict[str, Any]) -> list[dict[str, Any]]:
    return [
        entry
        for entry in _command_entries(data)
        if entry.get("status") == "pass"
        and entry.get("exitCode") == 0
        and isinstance(entry.get("command"), str)
    ]


def _assertions(data: dict[str, Any]) -> set[str]:
    present: set[str] = set()
    for entry in _passing_commands(data):
        assertions = entry.get("assertions")
        if isinstance(assertions, list):
            present.update(assertion for assertion in assertions if isinstance(assertion, str))
    return present


def validate_signal_envelope_contract_runtime_evidence(data: dict[str, Any]) -> list[str]:
    errors: list[str] = []
    if data.get("schemaVersion") != 1:
        errors.append("schemaVersion must be 1")
    _validate_generated_at(data.get("generatedAt"), errors)
    if data.get("generatedBy") != "scripts/ci/write_signal_envelope_contract_runtime_evidence.py":
        errors.append("generatedBy must be scripts/ci/write_signal_envelope_contract_runtime_evidence.py")
    if data.get("privacy") != PRIVACY_MARKER:
        errors.append("privacy marker must be proof_only_no_plaintext_keys_ciphertext_or_user_data")

    leaked_keys = sorted({key for key in _iter_keys(data) if key in FORBIDDEN_EVIDENCE_KEYS})
    if leaked_keys:
        errors.append("evidence must not contain raw output, user data, ciphertext, or key material: " + ", ".join(leaked_keys))

    entries = _command_entries(data)
    if not entries:
        errors.append("commandEvidence is required")
    for entry in entries:
        _validate_command_entry(entry, errors)

    commands = [entry.get("command", "") for entry in _passing_commands(data)]
    for fragment in REQUIRED_COMMAND_FRAGMENTS:
        if not any(fragment in command for command in commands):
            errors.append(f"missing passing command evidence for {fragment}")

    present_assertions = _assertions(data)
    for assertion in REQUIRED_ASSERTIONS:
        if assertion not in present_assertions:
            errors.append(f"missing proof assertion: {assertion}")
    return errors


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("evidence", type=Path)
    args = parser.parse_args(argv)
    try:
        data = json.loads(args.evidence.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        print(f"FAIL: unreadable Node Signal-envelope contract evidence: {exc}", file=sys.stderr)
        return 1
    errors = validate_signal_envelope_contract_runtime_evidence(data)
    if errors:
        print("FAIL: Node Signal-envelope contract evidence is not release-ready", file=sys.stderr)
        for error in errors:
            print(f"- {error}", file=sys.stderr)
        return 1
    print("PASS: Node Signal-envelope contract evidence is release-ready")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
