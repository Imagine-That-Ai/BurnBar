#!/usr/bin/env python3
"""Create a predicate for exact final release bytes after legacy source removal."""

from __future__ import annotations

import argparse
import hashlib
import importlib.util
import json
import sys
from pathlib import Path
from typing import Any


ROOT = Path(__file__).resolve().parents[2]
GATE_PATH = ROOT / "scripts/ci/verify-domain-core-legacy-deletion.py"
SPEC = importlib.util.spec_from_file_location("domain_core_legacy_deletion_gate", GATE_PATH)
if SPEC is None or SPEC.loader is None:
    raise RuntimeError(f"cannot load {GATE_PATH}")
GATE = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = GATE
SPEC.loader.exec_module(GATE)

CONSUMERS = {
    "apple": ("macos-dmg", "macos-arm64"),
    "ios": ("ios-ipa", "ios-universal"),
    "android": ("android-aab", "android-universal"),
    "windows": ("windows-release-bundle", "windows-x64-arm64"),
    "linux": ("linux-release-bundle", "linux-x64-arm64"),
    "console": ("console-deployment-receipt", "firebase-hosting-production"),
    "functions": ("functions-deployment-receipt", "firebase-functions-production"),
}
CANDIDATE_FIELDS = ("candidateCommit", "coreVersion", "abiVersion", "sourceSha256")


def load(path: Path, label: str) -> dict[str, Any]:
    value = json.loads(path.read_text())
    if not isinstance(value, dict):
        raise ValueError(f"{label} must be a JSON object")
    return value


def observed_candidate(value: dict[str, Any]) -> dict[str, Any]:
    for candidate in (
        value,
        value.get("observed"),
        value.get("candidate"),
        value.get("candidateIdentity"),
        value.get("identity"),
    ):
        if isinstance(candidate, dict):
            projected = {key: candidate.get(key) for key in CANDIDATE_FIELDS}
            if all(projected.values()) and isinstance(projected["abiVersion"], int):
                return projected
    raise ValueError("loaded identity does not contain a complete candidate identity")


def absent_rows(repo_root: Path, manifest: dict[str, Any], consumer: str) -> list[str]:
    roots = GATE.require_object(manifest.get("sourceRoots"), "manifest.sourceRoots")
    result: list[str] = []
    for raw_row in GATE.require_array(manifest.get("rows"), "manifest.rows"):
        row = GATE.require_object(raw_row, "manifest row")
        row_id = row.get("id")
        if consumer not in GATE.ROW_RELEASE_CONSUMERS.get(row_id, set()):
            continue
        implementations = [
            GATE.parse_target(raw, f"row {row_id} target", roots)
            for raw in GATE.require_array(row.get("targets"), f"row {row_id}.targets")
            if isinstance(raw, dict) and raw.get("role") == "legacy_implementation"
        ]
        if implementations and all(
            not GATE.target_present(repo_root, target, f"row {row_id} target")
            for target in implementations
        ):
            result.append(row_id)
    if not result:
        raise ValueError(f"no inventoried legacy implementation is absent for {consumer}")
    return sorted(result)


def create(
    repo_root: Path,
    manifest_path: Path,
    consumer: str,
    artifact: Path,
    identity_path: Path,
    candidate_path: Path,
    activation_path: Path,
    *,
    version: str,
    tag: str,
    commit: str,
) -> dict[str, Any]:
    if consumer not in CONSUMERS:
        raise ValueError("unknown final release consumer")
    if not artifact.is_file() or artifact.is_symlink() or artifact.stat().st_size < 1:
        raise ValueError("final artifact must be a nonempty regular file")
    candidate = load(candidate_path, "candidate")
    candidate = {key: candidate.get(key) for key in CANDIDATE_FIELDS}
    activation = load(activation_path, "activation")
    activation_commit = activation.get("activationCommit")
    if any(activation.get(key) != candidate.get(key) for key in CANDIDATE_FIELDS):
        raise ValueError("final artifact activation does not bind the unchanged candidate tuple")
    if activation_commit == commit:
        raise ValueError("release B must be built from deletion D, not activation P")
    try:
        GATE.require_ancestor(repo_root, activation_commit, commit, "release-A activation P to release-B deletion D")
    except GATE.GateError as error:
        raise ValueError(str(error)) from error
    identity = load(identity_path, "loaded final-artifact identity")
    if observed_candidate(identity) != candidate:
        raise ValueError("loaded final-artifact identity differs from the candidate")
    manifest = load(manifest_path, "deletion inventory")
    deleted = absent_rows(repo_root, manifest, consumer)
    artifact_kind, target = CONSUMERS[consumer]
    return {
        "schemaVersion": 1,
        "predicateType": "https://openburnbar.dev/attestations/domain-core-final-legacy-absence/v1",
        "consumer": consumer,
        "artifactKind": artifact_kind,
        "target": target,
        "artifact": {
            "fileName": artifact.name,
            "sha256": hashlib.sha256(artifact.read_bytes()).hexdigest(),
            "size": artifact.stat().st_size,
        },
        "release": {"version": version, "tag": tag, "commit": commit},
        "candidate": candidate,
        "activation": activation,
        "deletionInventorySha256": hashlib.sha256(manifest_path.read_bytes()).hexdigest(),
        "absentRows": deleted,
        "loadedIdentity": identity,
    }


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repo-root", type=Path, default=ROOT)
    parser.add_argument("--manifest", type=Path, default=Path("config/domain-core-legacy-deletion.json"))
    parser.add_argument("--consumer", required=True)
    parser.add_argument("--artifact", required=True, type=Path)
    parser.add_argument("--identity", required=True, type=Path)
    parser.add_argument("--candidate", required=True, type=Path)
    parser.add_argument("--activation", required=True, type=Path)
    parser.add_argument("--version", required=True)
    parser.add_argument("--tag", required=True)
    parser.add_argument("--commit", required=True)
    parser.add_argument("--output", required=True, type=Path)
    args = parser.parse_args()
    try:
        manifest = args.manifest if args.manifest.is_absolute() else args.repo_root / args.manifest
        result = create(
            args.repo_root.resolve(), manifest, args.consumer, args.artifact, args.identity,
            args.candidate, args.activation, version=args.version, tag=args.tag, commit=args.commit,
        )
        args.output.write_text(json.dumps(result, indent=2, sort_keys=True) + "\n")
    except (OSError, ValueError, GATE.GateError, json.JSONDecodeError) as error:
        parser.error(str(error))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
