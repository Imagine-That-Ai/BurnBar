#!/usr/bin/env python3
"""Create the immutable plan that an independent reviewer must approve before legacy deletion."""

from __future__ import annotations

import argparse
import importlib.util
import json
import os
import sys
from pathlib import Path
from typing import Any


REPO_ROOT = Path(__file__).resolve().parents[2]
GATE_PATH = REPO_ROOT / "scripts/ci/verify-domain-core-legacy-deletion.py"
SPEC = importlib.util.spec_from_file_location("domain_core_legacy_deletion_gate", GATE_PATH)
GATE = sys.modules.get("domain_core_legacy_deletion_gate")
if GATE is None:
    if SPEC is None or SPEC.loader is None:
        raise RuntimeError(f"cannot load {GATE_PATH}")
    GATE = importlib.util.module_from_spec(SPEC)
    sys.modules[SPEC.name] = GATE
    SPEC.loader.exec_module(GATE)


def serialized(value: dict[str, Any]) -> bytes:
    return (json.dumps(value, indent=2, ensure_ascii=True) + "\n").encode("utf-8")


def write_append_only(path: Path, contents: bytes) -> None:
    if path.exists():
        if not path.is_file() or path.is_symlink():
            raise GATE.GateError(f"refusing to replace non-regular artifact: {path}")
        if path.read_bytes() != contents:
            raise GATE.GateError(f"refusing to rewrite append-only artifact: {path}")
        return
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_name(f".{path.name}.{os.getpid()}.tmp")
    try:
        temporary.write_bytes(contents)
        temporary.chmod(0o600)
        os.replace(temporary, path)
    finally:
        temporary.unlink(missing_ok=True)


def load_row(repo_root: Path, row_id: str) -> dict[str, Any]:
    manifest = GATE.require_object(
        GATE.load_json(repo_root / "config/domain-core-legacy-deletion.json", "legacy deletion ledger"),
        "legacy deletion ledger",
    )
    for index, raw in enumerate(GATE.require_array(manifest.get("rows"), "legacy deletion ledger.rows")):
        row = GATE.require_object(raw, f"legacy deletion ledger.rows[{index}]")
        if row.get("id") == row_id:
            return row
    raise GATE.GateError(f"row is missing from legacy deletion ledger: {row_id}")


def create_plan(repo_root: Path, *, row_id: str, generation: int, reviewer: str) -> tuple[Path, dict[str, Any]]:
    if row_id not in GATE.ROW_IDS:
        raise GATE.GateError(f"unknown row id: {row_id}")
    if not isinstance(generation, int) or isinstance(generation, bool) or generation < 1:
        raise GATE.GateError("authority generation must be a positive integer")
    if not isinstance(reviewer, str) or not GATE.RECEIPT_ACTOR_RE.fullmatch(reviewer):
        raise GATE.GateError("reviewer must be a GitHub handle prefixed with @")

    manifest_path = repo_root / "config/domain-core-legacy-deletion.json"
    manifest = GATE.require_object(GATE.load_json(manifest_path, "legacy deletion ledger"), "legacy deletion ledger")
    row = load_row(repo_root, row_id)
    if row.get("state") != "rust_authoritative_with_rollback" or row.get("authorityGeneration") != generation:
        raise GATE.GateError("deletion plans require the exact stable Rust authority generation")

    receipts = GATE.require_object(row.get("receipts"), f"row {row_id}.receipts")
    stable_relative = GATE.repository_path(receipts.get("stableRelease"), f"row {row_id}.stableRelease")
    stable_path = GATE.secure_path(repo_root, stable_relative, "stable release receipt", must_exist=True)
    stable = GATE.validate_receipt(
        repo_root,
        stable_relative,
        row_id,
        generation,
        "stable_release",
        set(),
    )

    roots = GATE.require_object(manifest.get("sourceRoots"), "legacy deletion ledger.sourceRoots")
    parsed_targets = [
        GATE.parse_target(raw, f"row {row_id}.targets[{index}]", roots)
        for index, raw in enumerate(GATE.require_array(row.get("targets"), f"row {row_id}.targets"))
    ]
    if not any(target.role == "legacy_implementation" for target in parsed_targets):
        raise GATE.GateError("deletion plan requires at least one legacy implementation target")
    legacy_targets_sha256 = GATE.canonical_json_sha256(
        [
            {
                "kind": target.kind,
                "role": target.role,
                "root": target.root,
                "path": target.path,
                "value": target.value,
            }
            for target in sorted(parsed_targets, key=lambda item: item.identity)
        ]
    )
    review_class = "security_crypto" if row_id in GATE.SECURITY_REVIEW_ROWS else "domain_owner"
    qualified = GATE.load_deletion_reviewers(repo_root)[review_class]
    if reviewer.casefold() not in qualified:
        raise GATE.GateError(f"reviewer is not qualified for {review_class} in the deletion reviewer catalog")
    plan = {
        "schemaVersion": 1,
        "rowId": row_id,
        "authorityGeneration": generation,
        "stableReceiptSha256": stable.digest,
        "reviewer": reviewer,
        "reviewClass": review_class,
        "legacyTargetsSha256": legacy_targets_sha256,
        "requestedAction": "approve_legacy_deletion",
    }
    output = repo_root / GATE.DELETION_PLAN_ROOT / row_id / f"{generation}.json"
    if not stable_path.is_file():
        raise GATE.GateError("stable release receipt must be a regular file")
    return output, plan


def create_deletion_receipt(
    repo_root: Path,
    *,
    row_id: str,
    generation: int,
    plan_path: Path,
    plan: dict[str, Any],
    review_uri: str,
    reviewed_commit: str,
    approved_by: str,
    approved_at: str,
) -> tuple[Path, dict[str, Any], dict[str, str]]:
    review_uri = GATE.validate_https_uri(review_uri, "review URI")
    if not isinstance(reviewed_commit, str) or not GATE.COMMIT_RE.fullmatch(reviewed_commit):
        raise GATE.GateError("reviewed commit must be a full lowercase Git SHA")
    if not isinstance(approved_by, str) or not GATE.RECEIPT_ACTOR_RE.fullmatch(approved_by):
        raise GATE.GateError("approvedBy must be a GitHub handle prefixed with @")
    GATE.parse_rfc3339_utc(approved_at, "approvedAt")
    commit = GATE.git_output(repo_root, ["rev-parse", "HEAD"], "deletion receipt commit").strip()
    GATE.require_commit(repo_root, commit, "deletion receipt commit")

    row = load_row(repo_root, row_id)
    receipts = GATE.require_object(row.get("receipts"), f"row {row_id}.receipts")
    stable_relative = receipts.get("stableRelease")
    stable_relative = GATE.repository_path(stable_relative, f"row {row_id}.stableRelease")
    stable = GATE.validate_receipt(
        repo_root, stable_relative, row_id, generation, "stable_release", set()
    )
    GATE.require_ancestor(repo_root, stable.commit, commit, "deletion receipt commit")
    plan_relative = plan_path.relative_to(repo_root).as_posix()
    plan_digest = GATE.sha256_path(plan_path)
    receipt = {
        "schemaVersion": 2,
        "rowId": row_id,
        "authorityGeneration": generation,
        "transition": "deletion_review",
        "status": "active",
        "evidence": [review_uri],
        "approvedBy": approved_by,
        "approvedAt": approved_at,
        "commit": commit,
        "deletionReview": {
            "stableReceiptSha256": stable.digest,
            "reviewUri": review_uri,
            "reviewedCommit": reviewed_commit,
            "reviewer": plan["reviewer"],
            "reviewClass": plan["reviewClass"],
            "outcome": "approved",
            "planPath": plan_relative,
            "planSha256": plan_digest,
        },
    }
    output = repo_root / GATE.RECEIPT_ROOT / row_id / str(generation) / "deletion_review.json"
    return output, receipt, {plan_relative: plan_digest, stable_relative: stable.digest}


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repo-root", type=Path, default=REPO_ROOT)
    parser.add_argument("--row-id", required=True)
    parser.add_argument("--authority-generation", required=True, type=int)
    parser.add_argument("--reviewer", required=True)
    parser.add_argument("--review-uri")
    parser.add_argument("--reviewed-commit")
    parser.add_argument("--approved-by")
    parser.add_argument("--approved-at")
    args = parser.parse_args(argv)
    repo_root = args.repo_root.resolve(strict=True)
    try:
        receipt_arguments = (args.review_uri, args.reviewed_commit, args.approved_by, args.approved_at)
        if any(receipt_arguments) and not all(receipt_arguments):
            raise GATE.GateError(
                "receipt creation requires --review-uri, --reviewed-commit, --approved-by, and --approved-at"
            )
        output, plan = create_plan(
            repo_root,
            row_id=args.row_id,
            generation=args.authority_generation,
            reviewer=args.reviewer,
        )
        write_append_only(output, serialized(plan))
        if all(receipt_arguments):
            receipt_output, receipt, bound_files = create_deletion_receipt(
                repo_root,
                row_id=args.row_id,
                generation=args.authority_generation,
                plan_path=output,
                plan=plan,
                review_uri=args.review_uri,
                reviewed_commit=args.reviewed_commit,
                approved_by=args.approved_by,
                approved_at=args.approved_at,
            )
            GATE.SignedEvidenceVerifier().verify_deletion_review(receipt["deletionReview"], bound_files)
            write_append_only(receipt_output, serialized(receipt))
            output = receipt_output
    except (GATE.GateError, OSError) as error:
        print(f"ERROR: cannot create deletion plan: {error}", file=sys.stderr)
        return 1
    print(output.relative_to(repo_root).as_posix())
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
