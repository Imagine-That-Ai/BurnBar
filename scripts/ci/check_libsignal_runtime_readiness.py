#!/usr/bin/env python3
"""Validate BurnBar's libsignal runtime-readiness manifest.

The manifest is allowed to be ``not_ready`` while launch gates remain open. A
``ready`` manifest is accepted only when every required gate is complete and the
completed evidence is artifact-backed, hash-checked, and tied to an explicit
validator command. This prevents a self-consistent JSON file from becoming a
release-readiness proof.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import re
import shlex
import subprocess
import sys
from pathlib import Path
from typing import Any


ROOT = Path(__file__).resolve().parents[2]
DEFAULT_MANIFEST = Path("third_party/libsignal/runtime-readiness.json")

REQUIRED_GATE_IDS: tuple[str, ...] = (
    "rust_core_bridge",
    "swift_round_trips",
    "kotlin_round_trips",
    "node_contracts",
    "hermes_gateway_writes",
    "hermes_attachment_writes",
    "cloudvault_private_domains",
    "migration_telemetry",
    "store_and_counsel_approval",
)

EXPECTED_PIN = {
    "tag": "v0.94.4",
    "tagObject": "03c449017b57eccbda715b8b018dce5dff603ac6",
    "commit": "46d867c986f66201e34e7ae20ce423eec742bf3f",
}

READY_EVIDENCE_FIELDS = (
    "artifactPath",
    "artifactType",
    "sha256",
    "validatorCommand",
    "validatorResult",
)

GATE_VALIDATOR_FRAGMENTS: dict[str, tuple[str, ...]] = {
    "rust_core_bridge": ("check_native_signal_runtime_evidence.py",),
    "swift_round_trips": ("check_native_signal_runtime_evidence.py",),
    "kotlin_round_trips": ("check_native_signal_runtime_evidence.py",),
    "node_contracts": ("npm test --prefix packages/signal-envelope-contracts",),
    "hermes_gateway_writes": ("check_hermes_gateway_migration_drain.py",),
    "hermes_attachment_writes": ("check_hermes_gateway_migration_drain.py",),
    "cloudvault_private_domains": ("check_cloudvault_at_rest_runtime.py",),
    "migration_telemetry": ("check_hermes_gateway_migration_drain.py",),
    "store_and_counsel_approval": ("check_agpl_legal_release_review.py",),
}

GATE_VALIDATOR_REQUIRED_ARGS: dict[str, tuple[str, ...]] = {
    "rust_core_bridge": ("--gate", "rust_core_bridge"),
    "swift_round_trips": ("--gate", "swift_round_trips"),
    "kotlin_round_trips": ("--gate", "kotlin_round_trips"),
}

GATE_ARTIFACT_PATH_PREFIXES: dict[str, tuple[str, ...]] = {
    "rust_core_bridge": ("launch-evidence/", "artifacts/libsignal/"),
    "swift_round_trips": ("launch-evidence/", "artifacts/libsignal/"),
    "kotlin_round_trips": ("launch-evidence/", "artifacts/libsignal/"),
    "node_contracts": ("launch-evidence/", "artifacts/libsignal/", "packages/signal-envelope-contracts/"),
    "hermes_gateway_writes": ("launch-evidence/",),
    "hermes_attachment_writes": ("launch-evidence/",),
    "cloudvault_private_domains": ("launch-evidence/",),
    "migration_telemetry": ("launch-evidence/",),
    "store_and_counsel_approval": ("launch-evidence/",),
}

SHA256_RE = re.compile(r"^[0-9a-f]{64}$")


def _resolve(path: Path | str, repo_root: Path | str | None = None) -> Path:
    candidate = Path(path)
    if not candidate.is_absolute():
        candidate = Path(repo_root or ROOT) / candidate
    return candidate


def _sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def load_manifest(manifest: Path | str, repo_root: Path | str | None = None) -> dict[str, Any]:
    """Load and normalize ``requiredGates`` into a ``gates`` mapping."""

    path = _resolve(manifest, repo_root)
    data: dict[str, Any] = json.loads(path.read_text(encoding="utf-8"))
    gates: dict[str, Any] = {}
    for gate in data.get("requiredGates", []):
        if isinstance(gate, dict) and isinstance(gate.get("id"), str):
            gates[gate["id"]] = gate
    data["gates"] = gates
    return data


def _validator_result_passed(value: Any) -> bool:
    if value == "pass":
        return True
    if isinstance(value, dict):
        return value.get("status") == "pass" or value.get("ok") is True
    return False


def _command_names_approved_validator(command: list[str], approved_fragments: tuple[str, ...]) -> bool:
    if not approved_fragments:
        return False
    for fragment in approved_fragments:
        fragment_parts = shlex.split(fragment)
        if fragment_parts and command[: len(fragment_parts)] == fragment_parts:
            return True
        if any(token == fragment or token.endswith(f"/{fragment}") for token in command):
            return True
    return False


def _command_references_artifact(command: list[str], artifact_path: str) -> bool:
    variants = {artifact_path, artifact_path.rstrip("/")}
    for token in command:
        normalized = token.strip("'\"")
        if normalized in variants:
            return True
        if any(normalized.endswith(f"={variant}") for variant in variants):
            return True
    return False


def _command_has_required_args(command: list[str], required: tuple[str, ...]) -> bool:
    if not required:
        return True
    for index in range(0, len(required), 2):
        option = required[index]
        value = required[index + 1]
        for position, token in enumerate(command):
            if token == option and position + 1 < len(command) and command[position + 1] == value:
                return True
            if token == f"{option}={value}":
                return True
    return False


def _validate_ready_evidence(
    gate_id: str,
    evidence: dict[str, Any] | None,
    *,
    repo_root: Path,
    run_validators: bool,
) -> list[str]:
    errors: list[str] = []
    if evidence is None:
        return [f"ready gate {gate_id} is missing completedEvidence"]

    for field in READY_EVIDENCE_FIELDS:
        if not evidence.get(field):
            errors.append(f"ready gate {gate_id} evidence is missing {field}")

    artifact_path = evidence.get("artifactPath")
    if isinstance(artifact_path, str):
        allowed_prefixes = GATE_ARTIFACT_PATH_PREFIXES.get(gate_id, ())
        if allowed_prefixes and not any(artifact_path.startswith(prefix) for prefix in allowed_prefixes):
            errors.append(
                f"ready gate {gate_id} artifactPath must live under one of: {', '.join(allowed_prefixes)}"
            )
        resolved_artifact = _resolve(artifact_path, repo_root)
        if not resolved_artifact.is_file():
            errors.append(f"ready gate {gate_id} artifactPath does not exist: {artifact_path}")
        else:
            expected_hash = evidence.get("sha256")
            if not isinstance(expected_hash, str) or not SHA256_RE.fullmatch(expected_hash):
                errors.append(f"ready gate {gate_id} sha256 must be a lowercase SHA-256 hex digest")
            else:
                actual_hash = _sha256(resolved_artifact)
                if actual_hash != expected_hash:
                    errors.append(
                        f"ready gate {gate_id} artifact hash mismatch for {artifact_path}: "
                        f"{actual_hash} != {expected_hash}"
                    )

    validator_command = evidence.get("validatorCommand")
    if isinstance(validator_command, str):
        try:
            command = shlex.split(validator_command)
        except ValueError as exc:
            errors.append(f"ready gate {gate_id} validatorCommand is not shell-safe: {exc}")
            command = []
        allowed = GATE_VALIDATOR_FRAGMENTS.get(gate_id, ())
        if command and allowed and not _command_names_approved_validator(command, allowed):
            errors.append(
                f"ready gate {gate_id} validatorCommand does not name an approved validator "
                f"({', '.join(allowed)})"
            )
        if gate_id == "store_and_counsel_approval" and "--allow-pending" in command:
            errors.append("ready gate store_and_counsel_approval validatorCommand must not use --allow-pending")
        required_args = GATE_VALIDATOR_REQUIRED_ARGS.get(gate_id, ())
        if required_args and not _command_has_required_args(command, required_args):
            errors.append(
                f"ready gate {gate_id} validatorCommand must include {' '.join(required_args)}"
            )
        if isinstance(artifact_path, str) and command and not _command_references_artifact(command, artifact_path):
            errors.append(
                f"ready gate {gate_id} validatorCommand must validate its artifactPath ({artifact_path})"
            )
        if run_validators and command:
            result = subprocess.run(
                command,
                cwd=repo_root,
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                check=False,
            )
            if result.returncode != 0:
                errors.append(
                    f"ready gate {gate_id} validatorCommand failed with {result.returncode}: "
                    f"{(result.stderr or result.stdout).strip()}"
                )

    if not _validator_result_passed(evidence.get("validatorResult")):
        errors.append(f"ready gate {gate_id} validatorResult must record a passing validator")

    return errors


def check_manifest(
    manifest: Path | str,
    *,
    repo_root: Path | str | None = None,
    run_validators: bool = False,
) -> list[str]:
    root = Path(repo_root or ROOT)
    path = _resolve(manifest, root)
    if not path.is_file():
        return [f"missing libsignal runtime-readiness manifest: {path}"]

    try:
        data = load_manifest(path, repo_root=root)
    except json.JSONDecodeError as exc:
        return [f"unreadable libsignal runtime-readiness manifest JSON: {exc}"]

    errors: list[str] = []
    status = data.get("status")
    if status not in {"ready", "not_ready"}:
        errors.append(f"invalid libsignal runtime status: {status!r}")

    pin = data.get("officialLibsignalPin") or {}
    for key, expected in EXPECTED_PIN.items():
        actual = pin.get(key)
        if actual != expected:
            errors.append(f"libsignal runtime manifest pin {key} drifted: {actual!r} != {expected!r}")

    gates: dict[str, Any] = data.get("gates", {})
    missing = [gate_id for gate_id in REQUIRED_GATE_IDS if gate_id not in gates]
    if missing:
        errors.append("missing libsignal runtime gates: " + ", ".join(missing))

    for gate_id in REQUIRED_GATE_IDS:
        gate = gates.get(gate_id) or {}
        gate_status = gate.get("status")
        if gate_status not in {"pending", "complete"}:
            errors.append(f"gate {gate_id} has invalid status {gate_status!r}")
        if not gate.get("proof"):
            errors.append(f"gate {gate_id} is missing its proof description")

    evidence_by_id = {
        evidence.get("id"): evidence
        for evidence in data.get("completedEvidence", [])
        if isinstance(evidence, dict) and evidence.get("status") == "complete"
    }
    unevidenced = [
        gate_id
        for gate_id in REQUIRED_GATE_IDS
        if gates.get(gate_id, {}).get("status") == "complete" and gate_id not in evidence_by_id
    ]
    if unevidenced:
        errors.append("complete gates missing completed evidence: " + ", ".join(unevidenced))

    incomplete = [gate_id for gate_id in REQUIRED_GATE_IDS if gates.get(gate_id, {}).get("status") != "complete"]
    if status == "ready":
        if incomplete:
            errors.append("manifest says ready but gates are incomplete: " + ", ".join(incomplete))
        for gate_id in REQUIRED_GATE_IDS:
            if gates.get(gate_id, {}).get("status") == "complete":
                errors.extend(
                    _validate_ready_evidence(
                        gate_id,
                        evidence_by_id.get(gate_id),
                        repo_root=root,
                        run_validators=True,
                    )
                )

    return errors


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--manifest", type=Path, default=DEFAULT_MANIFEST)
    parser.add_argument("--repo-root", type=Path, default=ROOT)
    parser.add_argument("--run-validators", action="store_true")
    parser.add_argument("--launch-gate", action="store_true", help="Also fail while status is not_ready")
    args = parser.parse_args(argv)

    errors = check_manifest(args.manifest, repo_root=args.repo_root, run_validators=args.run_validators)
    if errors:
        print("FAIL: libsignal runtime-readiness manifest is invalid", file=sys.stderr)
        for error in errors:
            print(f"- {error}", file=sys.stderr)
        return 1

    data = load_manifest(args.manifest, repo_root=args.repo_root)
    complete = sum(1 for gate in data["gates"].values() if gate.get("status") == "complete")
    total = len(data["gates"])
    status = data.get("status")
    if args.launch_gate and status != "ready":
        print("HOLD: official libsignal is not yet the OpenBurnBar runtime crypto core.", file=sys.stderr)
        print(f"Current runtime core: {data.get('runtimeCryptoCore')}", file=sys.stderr)
        print(f"Blocking reason: {data.get('blockingReason')}", file=sys.stderr)
        incomplete = [gate_id for gate_id, gate in data["gates"].items() if gate.get("status") != "complete"]
        print("Incomplete gates:", file=sys.stderr)
        for gate_id in incomplete:
            print(f"- {gate_id}: {data['gates'][gate_id].get('proof')}", file=sys.stderr)
        return 1

    if status == "ready":
        print(f"PASS: libsignal runtime readiness gate is READY ({complete}/{total} gates complete)")
    else:
        print(
            "PASS: libsignal runtime readiness manifest is consistent and fail-closed "
            f"(status=not_ready, {complete}/{total} gates complete)"
        )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
