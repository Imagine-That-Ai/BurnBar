#!/usr/bin/env python3
"""Create an append-only operational rollback receipt for one authority generation."""

from __future__ import annotations

import argparse
import importlib.util
import sys
from datetime import UTC, datetime
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
GATE_PATH = ROOT / "scripts/ci/verify-domain-core-legacy-deletion.py"
SPEC = importlib.util.spec_from_file_location("domain_core_legacy_deletion_gate", GATE_PATH)
if SPEC is None or SPEC.loader is None:
    raise RuntimeError(f"cannot load {GATE_PATH}")
GATE = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = GATE
SPEC.loader.exec_module(GATE)
WRITER_PATH = ROOT / "scripts/ops/create-domain-core-promotion-receipt.py"
WRITER_SPEC = importlib.util.spec_from_file_location("domain_core_promotion_writer", WRITER_PATH)
if WRITER_SPEC is None or WRITER_SPEC.loader is None:
    raise RuntimeError(f"cannot load {WRITER_PATH}")
WRITER = importlib.util.module_from_spec(WRITER_SPEC)
sys.modules[WRITER_SPEC.name] = WRITER
WRITER_SPEC.loader.exec_module(WRITER)


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repo-root", type=Path, default=ROOT)
    parser.add_argument("--row-id", required=True)
    parser.add_argument("--authority-generation", type=int, required=True)
    parser.add_argument("--rollback-commit", required=True)
    parser.add_argument("--issue-uri", required=True)
    parser.add_argument("--activated-at", required=True)
    parser.add_argument("--approved-by", required=True)
    parser.add_argument("--approved-at", required=True)
    args = parser.parse_args(argv)
    repo_root = args.repo_root.resolve(strict=True)
    try:
        if args.row_id not in GATE.ROW_IDS:
            raise GATE.GateError(f"unknown row id: {args.row_id}")
        GATE.positive_integer(args.authority_generation, "authority generation")
        rollback_commit = GATE.require_commit(repo_root, args.rollback_commit, "rollback commit")
        issue_uri = GATE.validate_https_uri(args.issue_uri, "rollback issue URI")
        activated = GATE.parse_rfc3339_utc(args.activated_at, "activatedAt")
        approved = GATE.parse_rfc3339_utc(args.approved_at, "approvedAt")
        if approved > datetime.now(UTC):
            raise GATE.GateError("approvedAt cannot be in the future")
        if activated > approved:
            raise GATE.GateError("rollback activation cannot follow rollback approval")
        if not GATE.RECEIPT_ACTOR_RE.fullmatch(args.approved_by):
            raise GATE.GateError("approvedBy must be a GitHub handle")
        stable_relative = f"{GATE.RECEIPT_ROOT}/{args.row_id}/{args.authority_generation}/stable_release.json"
        stable_path = GATE.secure_path(repo_root, stable_relative, "stable receipt", must_exist=True)
        stable = GATE.require_object(GATE.load_json(stable_path, "stable receipt"), "stable receipt")
        if (
            stable.get("rowId") != args.row_id
            or stable.get("authorityGeneration") != args.authority_generation
            or stable.get("transition") != "stable_release"
            or stable.get("status") != "active"
        ):
            raise GATE.GateError("stable receipt does not match the requested active authority generation")
        stable_approved = GATE.parse_rfc3339_utc(stable.get("approvedAt"), "stable receipt approvedAt")
        if activated < stable_approved:
            raise GATE.GateError("rollback activation cannot precede stable-release approval")
        release = GATE.require_object(stable.get("release"), "stable receipt release")
        activation = GATE.require_object(release.get("activation"), "stable receipt activation")
        activation_commit = GATE.require_commit(
            repo_root,
            activation.get("activationCommit"),
            "stable activation commit",
        )
        GATE.require_ancestor(repo_root, activation_commit, rollback_commit, "rollback commit")
        modes, _ = GATE.public_production_profile(repo_root)
        if modes[GATE.profile_domain_for_row(args.row_id)] != "legacy":
            raise GATE.GateError("operational rollback requires the public-production profile restored to legacy")
        receipt = {
            "schemaVersion": 2,
            "rowId": args.row_id,
            "authorityGeneration": args.authority_generation,
            "transition": "rollback",
            "status": "active",
            "evidence": [issue_uri],
            "approvedBy": args.approved_by,
            "approvedAt": args.approved_at,
            "commit": rollback_commit,
            "rollback": {
                "stableReceiptSha256": GATE.sha256_path(stable_path),
                "issueUri": issue_uri,
                "activatedAt": args.activated_at,
            },
        }
        output = repo_root / GATE.RECEIPT_ROOT / args.row_id / str(args.authority_generation) / "rollback.json"
        WRITER.append_only(output, WRITER.serialized(receipt))
    except (GATE.GateError, OSError, KeyError, TypeError, ValueError) as error:
        print(f"ERROR: cannot create rollback receipt: {error}", file=sys.stderr)
        return 1
    print(output.relative_to(repo_root).as_posix())
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
