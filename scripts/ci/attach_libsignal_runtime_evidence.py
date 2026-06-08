#!/usr/bin/env python3
"""Attach validated libsignal runtime evidence to the readiness manifest.

This script is intentionally conservative: it updates exactly one runtime gate,
records an artifact hash plus the validator that was executed, and then runs the
manifest checker over the resulting JSON before writing it. It never promotes a
manifest to ``ready``; final release approval remains the job of the release
preflight and counsel/legal gates.
"""

from __future__ import annotations

import argparse
from dataclasses import dataclass
from datetime import UTC, datetime
import hashlib
import json
import os
import shlex
import subprocess
import sys
import time
from pathlib import Path
from typing import Any, Callable

ROOT = Path(__file__).resolve().parents[2]
if str(ROOT) not in sys.path:
    sys.path.insert(0, str(ROOT))

from scripts.ci.check_libsignal_runtime_readiness import (  # noqa: E402
    DEFAULT_MANIFEST,
    GATE_ARTIFACT_PATH_PREFIXES,
    GATE_VALIDATOR_FRAGMENTS,
    GATE_VALIDATOR_REQUIRED_ARGS,
    REQUIRED_GATE_IDS,
    _command_has_required_args,
    _command_names_approved_validator,
    _command_references_artifact,
    check_manifest,
)


NATIVE_GATES = {"rust_core_bridge", "swift_round_trips", "kotlin_round_trips"}
HERMES_DRAIN_GATES = {"hermes_gateway_writes", "hermes_attachment_writes", "migration_telemetry"}
DEFAULT_ARTIFACT_TYPES = {
    "rust_core_bridge": "native_signal_runtime_evidence",
    "swift_round_trips": "native_signal_runtime_evidence",
    "kotlin_round_trips": "native_signal_runtime_evidence",
    "node_contracts": "signal_envelope_contract_test_report",
    "hermes_gateway_writes": "hermes_gateway_migration_drain_evidence",
    "hermes_attachment_writes": "hermes_gateway_migration_drain_evidence",
    "cloudvault_private_domains": "cloudvault_at_rest_runtime_evidence",
    "migration_telemetry": "hermes_gateway_migration_drain_evidence",
    "store_and_counsel_approval": "agpl_legal_release_review",
}
SHELL_CONTROL_TOKENS = {"&&", "||", ";", "|", "|&", ">", ">>", "<", "<<"}


class AttachError(RuntimeError):
    """Raised when evidence cannot be safely attached."""


@dataclass(frozen=True)
class ValidatorRun:
    command: list[str]
    exit_code: int
    duration_ms: int
    stdout: str
    stderr: str


ValidatorRunner = Callable[[list[str], Path], ValidatorRun]


def _sha256_bytes(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def _sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def _now_iso() -> str:
    return datetime.now(UTC).isoformat().replace("+00:00", "Z")


def _resolve_under_repo(path: Path | str, *, repo_root: Path) -> tuple[str, Path]:
    root = repo_root.resolve()
    candidate = Path(path)
    if candidate.is_absolute():
        raise AttachError(f"artifact path must be repo-relative, not absolute: {path}")
    resolved = (root / candidate).resolve()
    try:
        relative = resolved.relative_to(root)
    except ValueError as exc:
        raise AttachError(f"artifact must live under repo root: {path}") from exc
    if any(part == ".." for part in relative.parts):
        raise AttachError(f"artifact path must not traverse outside repo root: {path}")
    return relative.as_posix(), resolved


def _manifest_path(path: Path | str, *, repo_root: Path) -> Path:
    candidate = Path(path)
    if not candidate.is_absolute():
        candidate = repo_root / candidate
    return candidate


def _default_validator_command(
    gate_id: str,
    artifact_rel_path: str,
    *,
    replay_native_commands: bool,
) -> list[str]:
    if gate_id in NATIVE_GATES:
        command = [
            "python3",
            "scripts/ci/check_native_signal_runtime_evidence.py",
            artifact_rel_path,
            "--gate",
            gate_id,
            "--repo-root",
            ".",
        ]
        if replay_native_commands:
            command.append("--replay-commands")
        return command
    if gate_id in HERMES_DRAIN_GATES:
        return ["python3", "scripts/ci/check_hermes_gateway_migration_drain.py", artifact_rel_path]
    if gate_id == "cloudvault_private_domains":
        return ["python3", "scripts/ci/check_cloudvault_at_rest_runtime.py", artifact_rel_path]
    if gate_id == "store_and_counsel_approval":
        return ["python3", "scripts/ci/check_agpl_legal_release_review.py", "--evidence", artifact_rel_path]
    if gate_id == "node_contracts":
        return ["python3", "scripts/ci/check_signal_envelope_contract_runtime.py", artifact_rel_path]
    raise AttachError(f"{gate_id} cannot be attached until it has a dedicated artifact validator")


def _parse_validator_command(
    command: str | None,
    gate_id: str,
    artifact_rel_path: str,
    *,
    replay_native_commands: bool,
) -> list[str]:
    if command is None:
        return _default_validator_command(
            gate_id,
            artifact_rel_path,
            replay_native_commands=replay_native_commands,
        )
    try:
        parsed = shlex.split(command)
    except ValueError as exc:
        raise AttachError(f"validator command is not shell-safe: {exc}") from exc
    if not parsed:
        raise AttachError("validator command must not be empty")
    return parsed


def _validate_command(gate_id: str, command: list[str], artifact_rel_path: str) -> None:
    unsafe = [token for token in command if token in SHELL_CONTROL_TOKENS or "`" in token or token.startswith("$(")]
    if unsafe:
        raise AttachError("validator command must not use shell control tokens: " + ", ".join(unsafe))

    allowed = GATE_VALIDATOR_FRAGMENTS.get(gate_id, ())
    if allowed and not _command_names_approved_validator(command, allowed):
        raise AttachError(
            f"{gate_id} validator command must name an approved validator: {', '.join(allowed)}"
        )

    required_args = GATE_VALIDATOR_REQUIRED_ARGS.get(gate_id, ())
    if required_args and not _command_has_required_args(command, required_args):
        raise AttachError(f"{gate_id} validator command must include {' '.join(required_args)}")

    if not _command_references_artifact(command, artifact_rel_path):
        raise AttachError(f"{gate_id} validator command must validate its artifact path: {artifact_rel_path}")

    if gate_id == "store_and_counsel_approval" and "--allow-pending" in command:
        raise AttachError("store_and_counsel_approval evidence must not be validated with --allow-pending")


def run_validator_command(command: list[str], repo_root: Path) -> ValidatorRun:
    start = time.monotonic()
    result = subprocess.run(
        command,
        cwd=repo_root,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=False,
    )
    duration_ms = int((time.monotonic() - start) * 1000)
    return ValidatorRun(
        command=command,
        exit_code=result.returncode,
        duration_ms=duration_ms,
        stdout=result.stdout,
        stderr=result.stderr,
    )


def _validator_result(run: ValidatorRun) -> dict[str, Any]:
    return {
        "status": "pass" if run.exit_code == 0 else "fail",
        "exitCode": run.exit_code,
        "durationMs": run.duration_ms,
        "stdoutSha256": _sha256_bytes(run.stdout.encode("utf-8")),
        "stderrSha256": _sha256_bytes(run.stderr.encode("utf-8")),
        "checkedAt": _now_iso(),
    }


def _load_manifest(path: Path) -> dict[str, Any]:
    return json.loads(path.read_text(encoding="utf-8"))


def _gate_ids(data: dict[str, Any]) -> set[str]:
    gates = data.get("requiredGates")
    if not isinstance(gates, list):
        return set()
    return {gate.get("id") for gate in gates if isinstance(gate, dict) and isinstance(gate.get("id"), str)}


def _mark_gate_complete(data: dict[str, Any], gate_id: str) -> None:
    for gate in data.get("requiredGates", []):
        if isinstance(gate, dict) and gate.get("id") == gate_id:
            gate["status"] = "complete"
            return
    raise AttachError(f"manifest is missing required gate: {gate_id}")


def _replace_completed_evidence(data: dict[str, Any], evidence: dict[str, Any]) -> None:
    completed = data.get("completedEvidence")
    if not isinstance(completed, list):
        completed = []
    data["completedEvidence"] = [
        item for item in completed if not (isinstance(item, dict) and item.get("id") == evidence["id"])
    ]
    data["completedEvidence"].append(evidence)


def _validate_updated_manifest(
    data: dict[str, Any],
    *,
    manifest_path: Path,
    repo_root: Path,
    run_validators: bool,
) -> None:
    tmp_path = manifest_path.with_name(f".{manifest_path.name}.attach-check.tmp")
    try:
        tmp_path.write_text(json.dumps(data, indent=2) + "\n", encoding="utf-8")
        errors = check_manifest(tmp_path, repo_root=repo_root, run_validators=run_validators)
    finally:
        try:
            tmp_path.unlink()
        except FileNotFoundError:
            pass
    if errors:
        raise AttachError("updated runtime-readiness manifest is invalid: " + "; ".join(errors))


def write_manifest_atomic(path: Path, text: str) -> None:
    tmp_path = path.with_name(f".{path.name}.attach-write.tmp")
    try:
        with tmp_path.open("w", encoding="utf-8") as handle:
            handle.write(text)
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(tmp_path, path)
        dir_fd = os.open(str(path.parent), os.O_DIRECTORY)
        try:
            os.fsync(dir_fd)
        finally:
            os.close(dir_fd)
    except Exception:
        try:
            tmp_path.unlink()
        except FileNotFoundError:
            pass
        raise


def attach_runtime_evidence(
    *,
    gate_id: str,
    artifact: Path,
    manifest: Path = DEFAULT_MANIFEST,
    repo_root: Path = ROOT,
    artifact_type: str | None = None,
    validator_command: str | None = None,
    replay_native_commands: bool = False,
    postcheck_validators: bool = True,
    runner: ValidatorRunner = run_validator_command,
) -> dict[str, Any]:
    if gate_id not in REQUIRED_GATE_IDS:
        raise AttachError(f"unknown runtime readiness gate: {gate_id}")

    repo_root = repo_root.resolve()
    manifest_path = _manifest_path(manifest, repo_root=repo_root)
    if not manifest_path.is_file():
        raise AttachError(f"missing runtime-readiness manifest: {manifest_path}")

    artifact_rel_path, artifact_abs_path = _resolve_under_repo(artifact, repo_root=repo_root)
    if not artifact_abs_path.is_file():
        raise AttachError(f"evidence artifact does not exist: {artifact_rel_path}")

    allowed_prefixes = GATE_ARTIFACT_PATH_PREFIXES.get(gate_id, ())
    if allowed_prefixes and not any(artifact_rel_path.startswith(prefix) for prefix in allowed_prefixes):
        raise AttachError(
            f"{gate_id} artifact must live under one of: {', '.join(allowed_prefixes)}"
        )

    command = _parse_validator_command(
        validator_command,
        gate_id,
        artifact_rel_path,
        replay_native_commands=replay_native_commands,
    )
    _validate_command(gate_id, command, artifact_rel_path)

    run = runner(command, repo_root)
    if run.exit_code != 0:
        detail = (run.stderr or run.stdout).strip()
        raise AttachError(f"validator failed with exit {run.exit_code}: {detail}")

    data = _load_manifest(manifest_path)
    if gate_id not in _gate_ids(data):
        raise AttachError(f"manifest is missing required gate: {gate_id}")

    data["status"] = "not_ready"
    data["generatedAt"] = _now_iso()
    _mark_gate_complete(data, gate_id)
    _replace_completed_evidence(
        data,
        {
            "id": gate_id,
            "status": "complete",
            "artifactPath": artifact_rel_path,
            "artifactType": artifact_type or DEFAULT_ARTIFACT_TYPES[gate_id],
            "sha256": _sha256_file(artifact_abs_path),
            "validatorCommand": shlex.join(command),
            "validatorResult": _validator_result(run),
            "attachedAt": _now_iso(),
            "attachedBy": "scripts/ci/attach_libsignal_runtime_evidence.py",
        },
    )
    _validate_updated_manifest(
        data,
        manifest_path=manifest_path,
        repo_root=repo_root,
        run_validators=postcheck_validators,
    )
    return data


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--gate", required=True, choices=REQUIRED_GATE_IDS)
    parser.add_argument("--artifact", required=True, type=Path)
    parser.add_argument("--artifact-type")
    parser.add_argument("--validator-command")
    parser.add_argument("--manifest", type=Path, default=DEFAULT_MANIFEST)
    parser.add_argument("--repo-root", type=Path, default=ROOT)
    parser.add_argument(
        "--replay-native-commands",
        action="store_true",
        help="For native evidence, make the default validator replay passing commandEvidence entries.",
    )
    parser.add_argument("--dry-run", action="store_true", help="Print the updated manifest instead of writing it")
    parser.add_argument("--check", action="store_true", help="Validate and post-check without writing the manifest")
    args = parser.parse_args(argv)

    manifest_path = _manifest_path(args.manifest, repo_root=args.repo_root.resolve())
    try:
        updated = attach_runtime_evidence(
            gate_id=args.gate,
            artifact=args.artifact,
            manifest=args.manifest,
            repo_root=args.repo_root,
            artifact_type=args.artifact_type,
            validator_command=args.validator_command,
            replay_native_commands=args.replay_native_commands,
            postcheck_validators=True,
        )
    except (AttachError, OSError, json.JSONDecodeError) as exc:
        print(f"FAIL: libsignal runtime evidence was not attached: {exc}", file=sys.stderr)
        return 1

    text = json.dumps(updated, indent=2) + "\n"
    if args.dry_run:
        print(text, end="")
        return 0
    if args.check:
        print(f"PASS: validated evidence attachment for {args.gate}; manifest was not written")
        return 0
    write_manifest_atomic(manifest_path, text)
    try:
        display_path = manifest_path.relative_to(args.repo_root.resolve())
    except ValueError:
        display_path = manifest_path
    print(f"PASS: attached validated evidence for {args.gate} to {display_path}")
    print("NOTE: manifest status remains not_ready; run release preflight after every required gate is complete.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
