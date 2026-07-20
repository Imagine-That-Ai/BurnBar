#!/usr/bin/env python3
"""Return the legacy-absence block a final release predicate must sign."""

from __future__ import annotations

import argparse
import hashlib
import importlib.util
import json
import sys
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
GATE_PATH = ROOT / "scripts/ci/verify-domain-core-legacy-deletion.py"
SPEC = importlib.util.spec_from_file_location("domain_core_legacy_deletion_gate", GATE_PATH)
if SPEC is None or SPEC.loader is None:
    raise RuntimeError(f"cannot load {GATE_PATH}")
GATE = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = GATE
SPEC.loader.exec_module(GATE)


def inspect(
    repo_root: Path,
    manifest_path: Path,
    consumer: str,
    domain: str,
    commit: str,
    expected_candidate: dict | None = None,
):
    manifest = GATE.require_object(GATE.load_json(manifest_path, "deletion inventory"), "deletion inventory")
    roots = GATE.require_object(manifest.get("sourceRoots"), "manifest.sourceRoots")
    absent: list[str] = []
    authorities: dict[str, tuple[dict, dict]] = {}
    for raw_row in GATE.require_array(manifest.get("rows"), "manifest.rows"):
        row = GATE.require_object(raw_row, "manifest row")
        row_id = row.get("id")
        if (
            row.get("state") != "legacy_deleted"
            or GATE.profile_domain_for_row(row_id) != domain
            or consumer not in GATE.ROW_RELEASE_CONSUMERS.get(row_id, set())
        ):
            continue
        targets = [
            GATE.parse_target(raw, f"row {row_id} target", roots)
            for raw in GATE.require_array(row.get("targets"), f"row {row_id}.targets")
            if isinstance(raw, dict) and raw.get("role") == "legacy_implementation"
        ]
        if not targets or any(GATE.target_present(repo_root, target, f"row {row_id} target") for target in targets):
            raise GATE.GateError(f"row {row_id}: release cannot attest absence while legacy source remains")
        absent.append(row_id)
        receipts = GATE.require_object(row.get("receipts"), f"row {row_id}.receipts")
        stable_relative = GATE.repository_path(receipts.get("stableRelease"), f"row {row_id}.stableRelease")
        stable = GATE.require_object(
            GATE.load_json(
                GATE.secure_path(repo_root, stable_relative, "stable receipt", must_exist=True), "stable receipt"
            ),
            "stable receipt",
        )
        release = GATE.require_object(stable.get("release"), "stable receipt.release")
        candidate = GATE.require_object(release.get("candidate"), "stable receipt.release.candidate")
        activation = GATE.require_object(release.get("activation"), "stable receipt.release.activation")
        authorities[GATE.canonical_json_sha256({"candidate": candidate, "activation": activation})] = (
            candidate,
            activation,
        )
    if not absent:
        return None
    if not GATE.COMMIT_RE.fullmatch(commit):
        raise GATE.GateError("release legacy absence requires a full lowercase release commit")
    if len(authorities) != 1:
        raise GATE.GateError("release-B deleted rows must share one stable release-A authority")
    candidate, activation = next(iter(authorities.values()))
    if expected_candidate is not None and candidate != expected_candidate:
        raise GATE.GateError("release-B candidate differs from stable release-A authority")
    activation_commit = activation.get("activationCommit")
    if activation_commit == commit:
        raise GATE.GateError("release B must be later than stable release-A activation P")
    GATE.require_ancestor(repo_root, activation_commit, commit, "release-A activation P to release-B deletion D")
    return {
        "candidate": candidate,
        "activation": activation,
        "absence": {
            "schemaVersion": 1,
            "predicateType": "https://openburnbar.dev/attestations/domain-core-final-legacy-absence/v1",
            "releaseCommit": commit,
            "authorityActivationCommit": activation_commit,
            "deletionInventorySha256": hashlib.sha256(manifest_path.read_bytes()).hexdigest(),
            "rowIds": sorted(absent),
        },
    }


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repo-root", type=Path, default=ROOT)
    parser.add_argument("--manifest", type=Path, default=Path("config/domain-core-legacy-deletion.json"))
    parser.add_argument("--consumer", required=True)
    parser.add_argument("--domain", required=True)
    parser.add_argument("--commit", required=True)
    parser.add_argument("--candidate-json")
    args = parser.parse_args()
    try:
        repo = args.repo_root.resolve()
        manifest = args.manifest if args.manifest.is_absolute() else repo / args.manifest
        candidate = json.loads(args.candidate_json) if args.candidate_json else None
        if candidate is not None and not isinstance(candidate, dict):
            raise GATE.GateError("expected candidate must be a JSON object")
        print(json.dumps(inspect(repo, manifest, args.consumer, args.domain, args.commit, candidate), sort_keys=True))
    except (OSError, json.JSONDecodeError, GATE.GateError) as error:
        parser.error(str(error))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
