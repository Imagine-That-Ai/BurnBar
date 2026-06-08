#!/usr/bin/env python3
"""Validate native libsignal runtime evidence packets."""

from __future__ import annotations

import argparse
from datetime import UTC, datetime, timedelta
import json
import re
import shlex
import subprocess
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
REQUIRED_PLATFORM_COMMAND_FRAGMENTS = {
    "rust": (
        (
            "cargo",
            "test",
            "--manifest-path",
            "Vendor/libsignal/Cargo.toml",
            "--locked",
            "-p libsignal-ffi",
            "-p libsignal-ffi-native_swift",
            "-p libsignal-jni-impl",
            "-p libsignal-jni-native_kt",
            "-p libsignal-node",
            "-p libsignal-node-native_ts",
            "--features",
            "libsignal-ffi/metadata",
        ),
    ),
    "swift": (
        ("swift", "test", "--package-path", "OpenBurnBarCore"),
        ("scripts/test-openburnbar-swift.sh", "OPENBURNBAR_CORE_SWIFT_FILTER"),
    ),
    "kotlin": (("scripts/ci/run_android_signal_runtime_tests.py",),),
}
FORBIDDEN_EVIDENCE_KEYS = {
    "plaintext",
    "privateKey",
    "secretKey",
    "rawKey",
    "ciphertext",
    "userData",
}
SHA256_RE = re.compile(r"^[0-9a-f]{64}$")


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
    present = _assertions_from_passing_commands(evidence)
    return [item for item in REQUIRED_PLATFORM_ASSERTIONS.get(platform, ()) if item not in present]


def _command_evidence_entries(evidence: dict[str, Any]) -> list[dict[str, Any]]:
    entries = evidence.get("commandEvidence")
    if not isinstance(entries, list):
        return []
    return [entry for entry in entries if isinstance(entry, dict)]


def _validate_command_entry(platform: str, entry: dict[str, Any], errors: list[str]) -> None:
    status = entry.get("status")
    if status not in {"pass", "fail"}:
        errors.append(f"{platform} command evidence status must be pass or fail")
    if not isinstance(entry.get("command"), str) or not entry.get("command"):
        errors.append(f"{platform} command evidence is missing command")
    if not isinstance(entry.get("exitCode"), int):
        errors.append(f"{platform} command evidence is missing numeric exitCode")
    duration_ms = entry.get("durationMs")
    if not isinstance(duration_ms, int) or duration_ms < 0:
        errors.append(f"{platform} command evidence is missing non-negative durationMs")
    for field in ("stdoutSha256", "stderrSha256"):
        value = entry.get(field)
        if not isinstance(value, str) or not SHA256_RE.fullmatch(value):
            errors.append(f"{platform} command evidence {field} must be a lowercase SHA-256 hex digest")


def _passing_commands(evidence: dict[str, Any]) -> list[dict[str, Any]]:
    return [
        entry
        for entry in _command_evidence_entries(evidence)
        if entry.get("status") == "pass"
        and entry.get("exitCode") == 0
        and isinstance(entry.get("command"), str)
    ]


def _assertions_from_passing_commands(evidence: dict[str, Any]) -> set[str]:
    assertions: set[str] = set()
    for entry in _passing_commands(evidence):
        entry_assertions = entry.get("assertions")
        if isinstance(entry_assertions, list):
            assertions.update(item for item in entry_assertions if isinstance(item, str))
    return assertions


def _has_required_command(platform: str, evidence: dict[str, Any]) -> bool:
    alternatives = REQUIRED_PLATFORM_COMMAND_FRAGMENTS.get(platform, ())
    if not alternatives:
        return True
    for entry in _passing_commands(evidence):
        command = entry.get("command") or ""
        for fragments in alternatives:
            if all(fragment in command for fragment in fragments):
                return True
    return False


def _required_command_description(platform: str) -> str:
    alternatives = REQUIRED_PLATFORM_COMMAND_FRAGMENTS.get(platform, ())
    return " or ".join(" ".join(fragments) for fragments in alternatives)


def _replay_command(command: str, *, repo_root: Path) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        shlex.split(command),
        cwd=repo_root,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=False,
    )


def validate_native_signal_runtime_evidence(
    data: dict[str, Any],
    *,
    gate: str | None = None,
    replay_commands: bool = False,
    repo_root: Path | None = None,
) -> list[str]:
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
        entries = _command_evidence_entries(evidence)
        if not entries:
            errors.append(f"{platform} runtime evidence is missing commandEvidence")
        for entry in entries:
            _validate_command_entry(platform, entry, errors)
        if not _passing_commands(evidence):
            errors.append(f"missing passing command evidence for {platform} runtime")
        if entries and not _has_required_command(platform, evidence):
            required = _required_command_description(platform)
            errors.append(f"missing passing command evidence for {platform} approved runtime command: {required}")
        missing_assertions = _missing_assertions(evidence, platform)
        if missing_assertions:
            errors.append(
                f"{platform} runtime evidence is missing assertions: " + ", ".join(missing_assertions)
            )
        if replay_commands:
            root = repo_root or Path.cwd()
            for entry in _passing_commands(evidence):
                command = entry.get("command") or ""
                try:
                    result = _replay_command(command, repo_root=root)
                except ValueError as exc:
                    errors.append(f"{platform} command evidence cannot be replayed safely: {exc}")
                    continue
                except OSError as exc:
                    errors.append(f"{platform} command evidence replay failed to start: {exc}")
                    continue
                if result.returncode != 0:
                    errors.append(
                        f"{platform} command evidence replay failed with {result.returncode}: "
                        f"{(result.stderr or result.stdout).strip()}"
                    )
    return errors


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("evidence", type=Path)
    parser.add_argument("--gate", choices=tuple(GATE_REQUIRED_PLATFORMS), default=None)
    parser.add_argument(
        "--replay-commands",
        action="store_true",
        help="Re-run passing commandEvidence entries from the packet before accepting it",
    )
    parser.add_argument("--repo-root", type=Path, default=Path.cwd())
    args = parser.parse_args(argv)
    try:
        data = json.loads(args.evidence.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        print(f"FAIL: unreadable native runtime evidence: {exc}", file=sys.stderr)
        return 1
    errors = validate_native_signal_runtime_evidence(
        data,
        gate=args.gate,
        replay_commands=args.replay_commands,
        repo_root=args.repo_root,
    )
    if errors:
        print("FAIL: native Signal runtime evidence is not release-ready", file=sys.stderr)
        for error in errors:
            print(f"- {error}", file=sys.stderr)
        return 1
    print("PASS: native Signal runtime evidence is release-ready")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
