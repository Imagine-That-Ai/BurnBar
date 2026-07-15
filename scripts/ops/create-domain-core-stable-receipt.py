#!/usr/bin/env python3
"""Create an append-only stable-release receipt binding candidate C and activation P."""

from __future__ import annotations

import argparse
import importlib.util
import json
import sys
from datetime import UTC, datetime
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

PROMOTION_WRITER = ROOT / "scripts/ops/create-domain-core-promotion-receipt.py"
PROMOTION_SPEC = importlib.util.spec_from_file_location("domain_core_promotion_writer", PROMOTION_WRITER)
if PROMOTION_SPEC is None or PROMOTION_SPEC.loader is None:
    raise RuntimeError(f"cannot load {PROMOTION_WRITER}")
WRITER = importlib.util.module_from_spec(PROMOTION_SPEC)
sys.modules[PROMOTION_SPEC.name] = WRITER
PROMOTION_SPEC.loader.exec_module(WRITER)


def load(path: Path, label: str) -> dict[str, Any]:
    return GATE.require_object(GATE.load_json(path, label), label)


def create_receipt(
    repo_root: Path,
    *,
    row_id: str,
    generation: int,
    activation_commit: str,
    release_paths: list[Path],
    rollback_path: Path,
    approved_by: str,
    approved_at: str,
) -> dict[str, Any]:
    if row_id not in GATE.ROW_IDS:
        raise GATE.GateError(f"unknown row id: {row_id}")
    GATE.positive_integer(generation, "authority generation")
    if not isinstance(approved_by, str) or not GATE.RECEIPT_ACTOR_RE.fullmatch(approved_by):
        raise GATE.GateError("approvedBy must be a GitHub handle")
    approved = GATE.parse_rfc3339_utc(approved_at, "approvedAt")
    if approved > datetime.now(UTC):
        raise GATE.GateError("approvedAt cannot be in the future")
    promotion_relative = f"{GATE.RECEIPT_ROOT}/{row_id}/{generation}/promotion.json"
    promotion_path = GATE.secure_path(repo_root, promotion_relative, "promotion receipt", must_exist=True)
    promotion = load(promotion_path, "promotion receipt")
    pointer = GATE.require_object(promotion.get("promotionAttestation"), "promotion attestation pointer")
    attestation_path = GATE.secure_path(repo_root, pointer["path"], "promotion attestation", must_exist=True)
    candidate = load(attestation_path, "promotion attestation")["candidate"]
    candidate_commit = candidate["candidateCommit"]
    activation = GATE.validate_activation_closure(repo_root, candidate_commit, activation_commit)
    releases = [load(path, f"consumer release {path}") for path in release_paths]
    if not releases:
        raise GATE.GateError("at least one consumer release descriptor is required")
    consumers = {item.get("consumer") for item in releases}
    if consumers != GATE.release_consumers_for_row(row_id):
        raise GATE.GateError("consumer release descriptors do not cover the exact row consumer set")
    for item in releases:
        if item.get("candidate") != candidate or item.get("activation") != activation:
            raise GATE.GateError(f"{item.get('consumer')}: release descriptor does not bind candidate C and activation P")
        if item.get("commit") != activation_commit:
            raise GATE.GateError(f"{item.get('consumer')}: release descriptor commit must equal activation P")
    rollback = load(rollback_path, "rollback artifact descriptor")
    if rollback.get("candidate") != candidate or rollback.get("activation") != activation:
        raise GATE.GateError("rollback artifact descriptor does not bind candidate C and activation P")
    if rollback.get("commit") != activation_commit:
        raise GATE.GateError("rollback artifact descriptor commit must equal activation P")
    profile_domain = GATE.profile_domain_for_row(row_id)
    modes, digests = GATE.public_production_profile(repo_root)
    if modes[profile_domain] != "rust":
        raise GATE.GateError(f"public-production.{profile_domain} must be rust at activation P")
    evidence = sorted({item["artifactUri"] for item in releases} | {rollback["artifactUri"]})
    return {
        "schemaVersion": 2,
        "rowId": row_id,
        "authorityGeneration": generation,
        "transition": "stable_release",
        "status": "active",
        "evidence": evidence,
        "approvedBy": approved_by,
        "approvedAt": approved_at,
        "commit": activation_commit,
        "release": {
            "promotionReceiptSha256": GATE.sha256_path(promotion_path),
            "publicProfileSha256": digests[profile_domain],
            "candidate": candidate,
            "activation": activation,
            "consumerReleases": sorted(releases, key=lambda item: item["consumer"]),
            "rollbackArtifact": rollback,
        },
    }


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repo-root", type=Path, default=ROOT)
    parser.add_argument("--row-id", required=True)
    parser.add_argument("--authority-generation", required=True, type=int)
    parser.add_argument("--activation-commit", required=True)
    parser.add_argument("--consumer-release", action="append", default=[], type=Path)
    parser.add_argument("--rollback-artifact", required=True, type=Path)
    parser.add_argument("--approved-by", required=True)
    parser.add_argument("--approved-at", required=True)
    args = parser.parse_args(argv)
    repo_root = args.repo_root.resolve(strict=True)
    try:
        receipt = create_receipt(
            repo_root,
            row_id=args.row_id,
            generation=args.authority_generation,
            activation_commit=args.activation_commit,
            release_paths=[path.resolve(strict=True) for path in args.consumer_release],
            rollback_path=args.rollback_artifact.resolve(strict=True),
            approved_by=args.approved_by,
            approved_at=args.approved_at,
        )
        output = repo_root / GATE.RECEIPT_ROOT / args.row_id / str(args.authority_generation) / "stable_release.json"
        WRITER.append_only(output, WRITER.serialized(receipt))
    except (GATE.GateError, OSError, KeyError, TypeError, ValueError) as error:
        print(f"ERROR: cannot create stable-release receipt: {error}", file=sys.stderr)
        return 1
    print(output.relative_to(repo_root).as_posix())
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
