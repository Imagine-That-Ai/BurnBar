#!/usr/bin/env python3
"""Validate CloudVault at-rest runtime evidence for Signal-backed private data.

The validator intentionally recomputes product enablement from the checked-out
data-domain registry when run from CI/release tooling. A packet that merely
claims Signal at-rest writes are enabled is not release evidence.
"""

from __future__ import annotations

import argparse
from datetime import UTC, datetime, timedelta
import hashlib
import json
import re
import shlex
import subprocess
import sys
from pathlib import Path
from typing import Any, Callable


PRIVACY_MARKER = "proof_only_no_plaintext_keys_ciphertext_or_document_identifiers"
SIGNAL_AT_REST_SCHEME = "signal-hpke-identity-seal-v1"
MAX_EVIDENCE_AGE = timedelta(hours=24)
REQUIRED_COMMAND_FRAGMENTS = (
    "npm run build --prefix functions",
    "scripts/ci/check_functions_cloudvault_runtime.js",
    "tests/test_signal_envelope_contracts_cjs_exports.py",
)
APPROVED_REPLAY_COMMANDS = (
    ("npm", "run", "build", "--prefix", "functions"),
    ("node", "scripts/ci/check_functions_cloudvault_runtime.js"),
    ("python3", "-m", "pytest", "tests/test_signal_envelope_contracts_cjs_exports.py", "-q"),
)
REQUIRED_ASSERTIONS = (
    "compiled_functions_imports_signal_at_rest_write",
    "admin_write_validator_accepts_strict_cloudvault_envelope",
    "admin_write_validator_derives_canonical_aad",
    "admin_write_validator_rejects_wrong_binding",
    "admin_write_validator_rejects_plaintext",
    "contract_sanitizer_rejects_gateway_transport_as_cloudvault",
    "sanitized_envelope_drops_plaintext_siblings",
    "signal_at_rest_policy_mirrors_registry",
    "cjs_runtime_import_validates_signal_at_rest_write",
)
REQUIRED_ASSERTIONS_WHEN_SIGNAL_ENABLED = ("signal_at_rest_policy_requires_enabled_collection",)
REQUIRED_ASSERTIONS_WHEN_SIGNAL_DISABLED = ("signal_at_rest_policy_evaluates_future_required_collection",)
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
SHA256_RE = re.compile(r"^[0-9a-f]{64}$")
CommandRunner = Callable[[list[str], Path], tuple[int, str, str]]


def _sha256_text(value: str) -> str:
    return hashlib.sha256(value.encode("utf-8", errors="replace")).hexdigest()


def _sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


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


def _run_command(argv: list[str], repo_root: Path) -> tuple[int, str, str]:
    result = subprocess.run(
        argv,
        cwd=repo_root,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=False,
    )
    return result.returncode, result.stdout, result.stderr


def _command_argv(command: str) -> list[str] | None:
    try:
        return shlex.split(command)
    except ValueError:
        return None


def _approved_replay_command(argv: list[str]) -> bool:
    return tuple(argv) in APPROVED_REPLAY_COMMANDS


def _replay_command_evidence(
    data: dict[str, Any],
    errors: list[str],
    *,
    repo_root: Path | None,
    command_runner: CommandRunner,
) -> None:
    if repo_root is None:
        errors.append("repo_root is required when replaying CloudVault command evidence")
        return
    for entry in _passed_commands(data):
        command = entry.get("command")
        if not isinstance(command, str):
            continue
        argv = _command_argv(command)
        if argv is None:
            errors.append(f"command evidence is not shell-safe for replay: {command}")
            continue
        if not _approved_replay_command(argv):
            errors.append(f"command evidence command is not approved for replay: {command}")
            continue
        exit_code, stdout, stderr = command_runner(argv, repo_root)
        if exit_code != entry.get("exitCode"):
            errors.append(
                f"replayed command exitCode mismatch for {command}: {exit_code} != {entry.get('exitCode')}"
            )
        stdout_sha = _sha256_text(stdout)
        if stdout_sha != entry.get("stdoutSha256"):
            errors.append(
                f"replayed command stdoutSha256 mismatch for {command}: {stdout_sha} != {entry.get('stdoutSha256')}"
            )
        stderr_sha = _sha256_text(stderr)
        if stderr_sha != entry.get("stderrSha256"):
            errors.append(
                f"replayed command stderrSha256 mismatch for {command}: {stderr_sha} != {entry.get('stderrSha256')}"
            )


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


def _assertions(data: dict[str, Any]) -> set[str]:
    present: set[str] = set()
    for entry in _passed_commands(data):
        entry_assertions = entry.get("assertions")
        if isinstance(entry_assertions, list):
            present.update(item for item in entry_assertions if isinstance(item, str))
    return present


def _registry_signal_at_rest_enablement(repo_root: Path) -> dict[str, Any]:
    registry_path = repo_root / "packages" / "data-domains" / "registry.json"
    registry = json.loads(registry_path.read_text(encoding="utf-8"))
    domains = registry.get("domains", [])
    signal_domains = [
        domain
        for domain in domains
        if isinstance(domain, dict) and domain.get("sealingScheme") == SIGNAL_AT_REST_SCHEME
    ]
    enabled = [domain.get("id") for domain in signal_domains]
    enabled_domains = sorted(domain_id for domain_id in enabled if isinstance(domain_id, str))
    required_collections = sorted(
        {
            collection
            for domain in signal_domains
            for collection in domain.get("signalSealedCollections", [])
            if isinstance(collection, str)
        }
    )
    return {
        "scheme": SIGNAL_AT_REST_SCHEME,
        "enabledDomainCount": len(enabled_domains),
        "enabledDomains": enabled_domains,
        "requiredCollectionCount": len(required_collections),
        "requiredCollections": required_collections,
        "source": "packages/data-domains/registry.json sealingScheme + signalSealedCollections",
        "sourceSha256": _sha256_file(registry_path),
    }


def _validate_enablement(data: dict[str, Any], errors: list[str], *, repo_root: Path | None) -> None:
    enablement = data.get("signalAtRestEnablement")
    if not isinstance(enablement, dict):
        errors.append("signalAtRestEnablement is required")
        return
    if enablement.get("scheme") != SIGNAL_AT_REST_SCHEME:
        errors.append(f"signalAtRestEnablement.scheme must be {SIGNAL_AT_REST_SCHEME}")
    enabled_count = enablement.get("enabledDomainCount")
    enabled_domains = enablement.get("enabledDomains")
    required_count = enablement.get("requiredCollectionCount")
    required_collections = enablement.get("requiredCollections")
    if not isinstance(enabled_count, int) or enabled_count < 0:
        errors.append("signalAtRestEnablement.enabledDomainCount must be a non-negative integer")
    if not isinstance(enabled_domains, list) or not all(isinstance(item, str) for item in enabled_domains):
        errors.append("signalAtRestEnablement.enabledDomains must be a list of domain ids")
    elif isinstance(enabled_count, int) and enabled_count != len(enabled_domains):
        errors.append("signalAtRestEnablement.enabledDomainCount must match enabledDomains length")
    if not isinstance(required_count, int) or required_count < 0:
        errors.append("signalAtRestEnablement.requiredCollectionCount must be a non-negative integer")
    if not isinstance(required_collections, list) or not all(isinstance(item, str) for item in required_collections):
        errors.append("signalAtRestEnablement.requiredCollections must be a list of collection ids")
    elif isinstance(required_count, int) and required_count != len(required_collections):
        errors.append("signalAtRestEnablement.requiredCollectionCount must match requiredCollections length")
    if isinstance(enabled_count, int) and enabled_count > 0 and isinstance(required_count, int) and required_count <= 0:
        errors.append("Signal at-rest enabled domains must declare requiredCollections")
    if enablement.get("source") != "packages/data-domains/registry.json sealingScheme + signalSealedCollections":
        errors.append("signalAtRestEnablement.source must name the data-domain registry sealingScheme and signalSealedCollections")
    source_sha = enablement.get("sourceSha256")
    if not isinstance(source_sha, str) or not SHA256_RE.fullmatch(source_sha):
        errors.append("signalAtRestEnablement.sourceSha256 must be a lowercase SHA-256 hex digest")
    if data.get("signalAtRestWritesEnabled") != (isinstance(enabled_count, int) and enabled_count > 0):
        errors.append("signalAtRestWritesEnabled must match signalAtRestEnablement.enabledDomainCount > 0")

    if repo_root is not None:
        try:
            actual = _registry_signal_at_rest_enablement(repo_root)
        except (OSError, json.JSONDecodeError) as exc:
            errors.append(f"unable to recompute Signal at-rest enablement from registry: {exc}")
            return
        comparable_keys = (
            "scheme",
            "enabledDomainCount",
            "enabledDomains",
            "requiredCollectionCount",
            "requiredCollections",
            "source",
            "sourceSha256",
        )
        expected = {key: actual[key] for key in comparable_keys}
        observed = {key: enablement.get(key) for key in comparable_keys}
        if observed != expected:
            errors.append("signalAtRestEnablement must match packages/data-domains/registry.json")


def validate_cloudvault_at_rest_evidence(
    data: dict[str, Any],
    *,
    repo_root: Path | None = None,
    replay_commands: bool = False,
    command_runner: CommandRunner = _run_command,
) -> list[str]:
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
    raw_commands = data.get("commandEvidence", [])
    if not isinstance(raw_commands, list):
        errors.append("commandEvidence must be a list")
        raw_commands = []
    for entry in raw_commands:
        if isinstance(entry, dict):
            _validate_command_entry(entry, errors)
        else:
            errors.append("commandEvidence entries must be objects")
    commands = [entry.get("command", "") for entry in _passed_commands(data)]
    for fragment in REQUIRED_COMMAND_FRAGMENTS:
        if not any(fragment in command for command in commands):
            errors.append(f"missing passing command evidence for {fragment}")
    if replay_commands:
        _replay_command_evidence(data, errors, repo_root=repo_root, command_runner=command_runner)
    present_assertions = _assertions(data)
    for assertion in REQUIRED_ASSERTIONS:
        if assertion not in present_assertions:
            errors.append(f"missing proof assertion: {assertion}")
    _validate_enablement(data, errors, repo_root=repo_root)
    enablement = data.get("signalAtRestEnablement")
    required_count = enablement.get("requiredCollectionCount") if isinstance(enablement, dict) else None
    if isinstance(required_count, int) and required_count > 0:
        for assertion in REQUIRED_ASSERTIONS_WHEN_SIGNAL_ENABLED:
            if assertion not in present_assertions:
                errors.append(f"missing proof assertion: {assertion}")
    elif isinstance(required_count, int):
        for assertion in REQUIRED_ASSERTIONS_WHEN_SIGNAL_DISABLED:
            if assertion not in present_assertions:
                errors.append(f"missing proof assertion: {assertion}")
    if data.get("signalAtRestWritesEnabled") is not True:
        errors.append("signalAtRestWritesEnabled must be true for release-ready evidence")
    return errors


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("evidence", type=Path)
    parser.add_argument("--repo-root", type=Path, default=Path.cwd())
    parser.add_argument(
        "--replay-commands",
        action="store_true",
        help="Re-run the allowlisted commandEvidence entries and compare their exit codes and stdout/stderr hashes.",
    )
    args = parser.parse_args(argv)
    try:
        data = json.loads(args.evidence.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        print(f"FAIL: unreadable CloudVault evidence: {exc}", file=sys.stderr)
        return 1
    errors = validate_cloudvault_at_rest_evidence(
        data,
        repo_root=args.repo_root,
        replay_commands=args.replay_commands,
    )
    if errors:
        print("FAIL: CloudVault at-rest runtime evidence is not release-ready", file=sys.stderr)
        for error in errors:
            print(f"- {error}", file=sys.stderr)
        return 1
    print("PASS: CloudVault at-rest runtime evidence is release-ready")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
