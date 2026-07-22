#!/usr/bin/env python3
"""Create an append-only rollback receipt only from verified completed rollback actions."""

from __future__ import annotations

import argparse
import hashlib
import importlib.util
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

WRITER_PATH = ROOT / "scripts/ops/create-domain-core-promotion-receipt.py"
WRITER_SPEC = importlib.util.spec_from_file_location("domain_core_promotion_writer", WRITER_PATH)
if WRITER_SPEC is None or WRITER_SPEC.loader is None:
    raise RuntimeError(f"cannot load {WRITER_PATH}")
WRITER = importlib.util.module_from_spec(WRITER_SPEC)
sys.modules[WRITER_SPEC.name] = WRITER
WRITER_SPEC.loader.exec_module(WRITER)


def load(path: Path, label: str) -> dict[str, Any]:
    return GATE.require_object(GATE.load_json(path, label), label)


def repository_relative(repo_root: Path, path: Path, label: str) -> str:
    resolved = path.resolve(strict=True)
    try:
        relative = resolved.relative_to(repo_root).as_posix()
    except ValueError as error:
        raise GATE.GateError(f"{label} must be inside the repository") from error
    GATE.repository_path(relative, label)
    return relative


def completion_record(
    repo_root: Path,
    *,
    row_id: str,
    generation: int,
    artifact_path: Path,
    provenance_path: Path,
    signer_run_id: int,
    signer_run_attempt: int,
    completed_at: str,
) -> dict[str, Any]:
    artifact_relative = repository_relative(repo_root, artifact_path, "rollback completion artifact")
    provenance_relative = repository_relative(repo_root, provenance_path, "rollback completion provenance")
    receipt = load(artifact_path, "rollback completion artifact")
    consumer = receipt.get("consumer")
    if consumer not in GATE.RELEASE_ARTIFACT_IDENTITIES:
        raise GATE.GateError("rollback completion artifact consumer is unknown")
    expected_artifact = f"{GATE.ROLLBACK_COMPLETION_ROOT}/{row_id}/{generation}/{consumer}.json"
    expected_provenance = f"{GATE.ROLLBACK_COMPLETION_ROOT}/{row_id}/{generation}/{consumer}.sigstore.json"
    if artifact_relative != expected_artifact or provenance_relative != expected_provenance:
        raise GATE.GateError(
            f"{consumer}: rollback completion inputs must use {expected_artifact} and {expected_provenance}"
        )
    public_profile = GATE.require_object(receipt.get("publicProfile"), f"{consumer} rollback publicProfile")
    if public_profile.get("profile") != "public-production-rollback" or public_profile.get("mode") != "legacy":
        raise GATE.GateError(f"{consumer}: completion artifact is not an executed legacy rollback")
    release = GATE.require_object(receipt.get("release"), f"{consumer} rollback release")
    deployment = receipt.get("deployment")
    if consumer in GATE.ROLLBACK_ACTION_WORKFLOWS:
        deployment = GATE.require_object(deployment, f"{consumer} rollback deployment")
        if deployment.get("status") != "healthy":
            raise GATE.GateError(f"{consumer}: rollback completion must contain healthy post-action evidence")
        action_run = GATE.require_object(deployment.get("deployRun"), f"{consumer} rollback deployRun")
        deployed_artifact_sha256 = GATE.require_digest(
            GATE.require_object(
                deployment.get("deployedArtifact"),
                f"{consumer} rollback deployedArtifact",
            ).get("sha256"),
            f"{consumer} rollback deployedArtifact.sha256",
        )
        health_artifact_sha256: str | None = GATE.require_digest(
            deployment.get("healthArtifactSha256"),
            f"{consumer} rollback healthArtifactSha256",
        )
    else:
        action_run = {
            "repository": GATE.SignedEvidenceVerifier.repository,
            "workflowPath": GATE.RELEASE_SIGNER_WORKFLOWS[consumer],
            "runId": signer_run_id,
            "runAttempt": signer_run_attempt,
            "event": "workflow_dispatch",
            "ref": f"refs/tags/{release.get('tag')}",
            "headSha": release.get("commit"),
        }
        deployed_artifact_sha256 = GATE.sha256_path(artifact_path)
        health_artifact_sha256 = None
    GATE.parse_rfc3339_utc(completed_at, f"{consumer} rollback completedAt")
    return {
        "consumer": consumer,
        "domain": receipt.get("domain"),
        "artifactPath": artifact_relative,
        "artifactSha256": GATE.sha256_path(artifact_path),
        "provenancePath": provenance_relative,
        "provenanceSha256": GATE.sha256_path(provenance_path),
        "rollbackProfileSha256": GATE.require_digest(
            public_profile.get("sha256"),
            f"{consumer} rollback publicProfile.sha256",
        ),
        "release": {
            "version": release.get("version"),
            "tag": release.get("tag"),
            "commit": release.get("commit"),
        },
        "signer": {
            "workflowPath": GATE.RELEASE_SIGNER_WORKFLOWS[consumer],
            "runId": signer_run_id,
            "runAttempt": signer_run_attempt,
            "runInvocationUri": (
                f"https://github.com/{GATE.SignedEvidenceVerifier.repository}/actions/runs/"
                f"{signer_run_id}/attempts/{signer_run_attempt}"
            ),
        },
        "actionRun": action_run,
        "deployedArtifactSha256": deployed_artifact_sha256,
        "healthArtifactSha256": health_artifact_sha256,
        "completedAt": completed_at,
    }


def create_receipt(
    repo_root: Path,
    *,
    row_id: str,
    generation: int,
    stable_receipt_path: Path,
    rollback_commit: str,
    issue_uri: str,
    completion_inputs: list[tuple[Path, Path, int, int, str]],
    approved_by: str,
    approved_at: str,
    evidence_verifier: Any | None = None,
) -> dict[str, Any]:
    if row_id not in GATE.ROW_IDS:
        raise GATE.GateError(f"unknown row id: {row_id}")
    GATE.positive_integer(generation, "authority generation")
    if not isinstance(approved_by, str) or not GATE.RECEIPT_ACTOR_RE.fullmatch(approved_by):
        raise GATE.GateError("approvedBy must be a GitHub handle")
    approved = GATE.parse_rfc3339_utc(approved_at, "approvedAt")
    if approved > datetime.now(UTC):
        raise GATE.GateError("approvedAt cannot be in the future")
    GATE.validate_https_uri(issue_uri, "rollback issueUri")
    rollback_commit = GATE.require_commit(repo_root, rollback_commit, "rollback trusted-main commit")

    stable_relative = f"{GATE.RECEIPT_ROOT}/{row_id}/{generation}/stable_release.json"
    if repository_relative(repo_root, stable_receipt_path, "stable receipt") != stable_relative:
        raise GATE.GateError(f"stable receipt must use exact path {stable_relative}")
    promotion_relative = f"{GATE.RECEIPT_ROOT}/{row_id}/{generation}/promotion.json"
    seen: set[str] = set()
    promotion = GATE.validate_receipt(
        repo_root,
        promotion_relative,
        row_id,
        generation,
        "promotion",
        seen,
    )
    stable = GATE.validate_receipt(
        repo_root,
        stable_relative,
        row_id,
        generation,
        "stable_release",
        seen,
    )
    GATE.require_ancestor(repo_root, stable.commit, rollback_commit, "rollback trusted-main commit")
    authority = GATE.rollback_authority_binding(repo_root, row_id, generation, promotion, stable)

    completions = [
        completion_record(
            repo_root,
            row_id=row_id,
            generation=generation,
            artifact_path=artifact,
            provenance_path=provenance,
            signer_run_id=signer_run_id,
            signer_run_attempt=signer_run_attempt,
            completed_at=completed_at,
        )
        for artifact, provenance, signer_run_id, signer_run_attempt, completed_at in completion_inputs
    ]
    if not completions:
        raise GATE.GateError("rollback completion evidence is required; a plan alone cannot activate rollback")
    activated_at = max(
        GATE.parse_rfc3339_utc(item["completedAt"], f"{item['consumer']} completedAt") for item in completions
    )
    activated_at_text = activated_at.isoformat().replace("+00:00", "Z")
    review_class = "security_crypto" if row_id in GATE.SECURITY_REVIEW_ROWS else "domain_owner"
    trusted_approver_commit = authority["promotionSigner"]["trustedMainCommit"]
    catalog_bytes = GATE.git_file(
        repo_root,
        trusted_approver_commit,
        GATE.DELETION_REVIEWERS_PATH,
        "rollback approver catalog",
    )
    evidence = sorted(
        {
            issue_uri,
            authority["retainedRollbackArtifact"]["artifactUri"],
            *(item["signer"]["runInvocationUri"] for item in completions),
        }
    )
    receipt = {
        "schemaVersion": 2,
        "rowId": row_id,
        "authorityGeneration": generation,
        "transition": "rollback",
        "status": "active",
        "evidence": evidence,
        "approvedBy": approved_by,
        "approvedAt": approved_at,
        "commit": rollback_commit,
        "rollback": {
            "stableReceiptSha256": stable.digest,
            "issueUri": issue_uri,
            "activatedAt": activated_at_text,
            "candidate": authority["candidate"],
            "activation": authority["activation"],
            "authority": {
                "candidateBundleSha256": authority["candidateBundleSha256"],
                "sourceRun": authority["sourceRun"],
                "promotionSigner": authority["promotionSigner"],
            },
            "retainedRollbackArtifact": authority["retainedRollbackArtifact"],
            "approverAuthority": {
                "reviewClass": review_class,
                "catalogSha256": hashlib.sha256(catalog_bytes).hexdigest(),
                "trustedMainCommit": trusted_approver_commit,
            },
            "completionEvidence": sorted(completions, key=lambda item: item["consumer"]),
        },
    }
    encoded = WRITER.serialized(receipt)
    rollback = GATE.Receipt(
        path=f"{GATE.RECEIPT_ROOT}/{row_id}/{generation}/rollback.json",
        transition="rollback",
        generation=generation,
        approved_at=approved,
        commit=rollback_commit,
        digest=hashlib.sha256(encoded).hexdigest(),
        evidence=tuple(evidence),
        payload=receipt["rollback"],
        approved_by=approved_by,
    )
    verifier = evidence_verifier or GATE.SignedEvidenceVerifier()
    GATE.validate_receipt_chain(
        repo_root,
        row_id,
        "rollback_active",
        generation,
        {"promotion": promotion, "stableRelease": stable, "rollback": rollback},
        verifier,
    )
    return receipt


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repo-root", type=Path, default=ROOT)
    parser.add_argument("--row-id", required=True)
    parser.add_argument("--authority-generation", type=int, required=True)
    parser.add_argument("--stable-receipt", type=Path, required=True)
    parser.add_argument("--rollback-commit", required=True)
    parser.add_argument("--issue-uri", required=True)
    parser.add_argument(
        "--completion-evidence",
        action="append",
        nargs=5,
        metavar=("ARTIFACT", "PROVENANCE", "SIGNER_RUN_ID", "SIGNER_RUN_ATTEMPT", "COMPLETED_AT"),
        required=True,
        help="Committed signed post-action receipt, provenance, exact signer run/attempt, and completion time",
    )
    parser.add_argument("--approved-by", required=True)
    parser.add_argument("--approved-at", required=True)
    args = parser.parse_args(argv)
    repo_root = args.repo_root.resolve(strict=True)
    try:
        completion_inputs = [
            (
                Path(values[0]).resolve(strict=True),
                Path(values[1]).resolve(strict=True),
                int(values[2]),
                int(values[3]),
                values[4],
            )
            for values in args.completion_evidence
        ]
        receipt = create_receipt(
            repo_root,
            row_id=args.row_id,
            generation=args.authority_generation,
            stable_receipt_path=args.stable_receipt.resolve(strict=True),
            rollback_commit=args.rollback_commit,
            issue_uri=args.issue_uri,
            completion_inputs=completion_inputs,
            approved_by=args.approved_by,
            approved_at=args.approved_at,
        )
        output = repo_root / GATE.RECEIPT_ROOT / args.row_id / str(args.authority_generation) / "rollback.json"
        WRITER.append_only(output, WRITER.serialized(receipt))
    except (GATE.GateError, OSError, KeyError, TypeError, ValueError) as error:
        print(f"ERROR: cannot create rollback receipt: {error}", file=sys.stderr)
        return 1
    print(output.relative_to(repo_root).as_posix())
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
