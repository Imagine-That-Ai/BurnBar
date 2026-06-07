#!/usr/bin/env python3
"""Validate native libsignal runtime evidence packets."""

from __future__ import annotations

import argparse
from datetime import UTC, datetime, timedelta
import json
import sys
from pathlib import Path
from typing import Any


PRIVACY_MARKER = "proof_only_no_plaintext_keys_or_user_data"
MAX_EVIDENCE_AGE = timedelta(hours=24)
REQUIRED_PLATFORMS = ("swift", "kotlin")
GATE_REQUIRED_PLATFORMS = {
    "rust_core_bridge": ("rust",),
    "swift_round_trips": ("swift",),
    "kotlin_round_trips": ("kotlin",),
}
REQUIRED_PLATFORM_ASSERTIONS = {
    "rust": (
        "official_libsignal_rust_bridge_builds",
        "ffi_contracts_exported",
        "swift_ffi_surface_present",
        "kotlin_jni_surface_present",
        "node_napi_surface_present",
        "no_plaintext_keys_or_user_data",
    ),
    "swift": (
        "official_libsignal_session_round_trip",
        "persistence_reload_round_trip",
        "replay_or_skipped_key_negative",
        "identity_or_safety_number_change_negative",
        "no_plaintext_keys_or_user_data",
    ),
    "kotlin": (
        "official_libsignal_session_round_trip",
        "swift_interop_kat_open",
        "replay_or_skipped_key_negative",
        "identity_key_store_negative",
        "no_plaintext_keys_or_user_data",
    ),
}
FORBIDDEN_EVIDENCE_KEYS = {
    "plaintext",
    "privateKey",
    "secretKey",
    "rawKey",
    "ciphertext",
    "userData",
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


def _missing_assertions(evidence: dict[str, Any], platform: str) -> list[str]:
    assertions = evidence.get("assertions")
    if not isinstance(assertions, list):
        return list(REQUIRED_PLATFORM_ASSERTIONS.get(platform, ()))
    present = {item for item in assertions if isinstance(item, str)}
    return [item for item in REQUIRED_PLATFORM_ASSERTIONS.get(platform, ()) if item not in present]


def validate_native_signal_runtime_evidence(data: dict[str, Any], *, gate: str | None = None) -> list[str]:
    errors: list[str] = []
    if data.get("schemaVersion") != 1:
        errors.append("schemaVersion must be 1")
    _validate_generated_at(data.get("generatedAt"), errors)
    if not data.get("generatedBy"):
        errors.append("generatedBy is required")
    if data.get("privacy") != PRIVACY_MARKER:
        errors.append("privacy marker must be proof_only_no_plaintext_keys_or_user_data")
    leaked_keys = sorted({key for key in _iter_keys(data) if key in FORBIDDEN_EVIDENCE_KEYS})
    if leaked_keys:
        errors.append("evidence must not contain raw user data or key material fields: " + ", ".join(leaked_keys))
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
        missing_assertions = _missing_assertions(evidence, platform)
        if missing_assertions:
            errors.append(
                f"{platform} runtime evidence is missing assertions: " + ", ".join(missing_assertions)
            )
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
