#!/usr/bin/env python3
"""Create append-only promotion artifacts from an official deterministic provenance attestation."""

from __future__ import annotations

import argparse
import hashlib
import importlib.util
import json
import os
import sys
from pathlib import Path
from typing import Any


REPO_ROOT = Path(__file__).resolve().parents[2]
GATE_PATH = REPO_ROOT / "scripts/ci/verify-domain-core-legacy-deletion.py"
SPEC = importlib.util.spec_from_file_location("domain_core_legacy_deletion_gate", GATE_PATH)
if SPEC is None or SPEC.loader is None:
    raise RuntimeError(f"cannot load {GATE_PATH}")
GATE = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = GATE
SPEC.loader.exec_module(GATE)


def serialized(value: dict[str, Any]) -> bytes:
    return (json.dumps(value, indent=2, ensure_ascii=True) + "\n").encode("utf-8")


def append_only(path: Path, contents: bytes) -> None:
    if path.exists():
        if not path.is_file() or path.is_symlink() or path.read_bytes() != contents:
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


def superseded_authority_pointer(
    repo_root: Path,
    row_id: str,
    generation: int,
) -> dict[str, str] | None:
    if generation == 1:
        return None
    previous_root = f"{GATE.RECEIPT_ROOT}/{row_id}/{generation - 1}"
    for transition, relative in (
        ("rollback", f"{previous_root}/rollback.json"),
        ("stable_release", f"{previous_root}/stable_release.json"),
    ):
        path = GATE.secure_path(repo_root, relative, "previous authority receipt", must_exist=False)
        if path.is_file():
            return {
                "transition": transition,
                "path": relative,
                "sha256": GATE.sha256_path(path),
            }
    raise GATE.GateError(
        "authority generation after the first must supersede the previous stable or rollback receipt"
    )


def create_artifacts(
    repo_root: Path,
    *,
    row_id: str,
    generation: int,
    bundle_path: Path,
    provenance_path: Path,
    candidate_commit: str,
    trusted_main_commit: str,
    source_run_id: int,
    source_run_attempt: int,
    signer_run_id: int,
    signer_run_attempt: int,
    attestation_uri: str,
    attested_at: str,
    approved_by: str,
    approved_at: str,
    verifier: Any,
) -> tuple[dict[str, Any], dict[str, Any], bytes, bytes]:
    if row_id not in GATE.ROW_IDS:
        raise GATE.GateError(f"unknown row id: {row_id}")
    GATE.positive_integer(generation, "authority generation")
    source_run_id = GATE.positive_integer(source_run_id, "source run id")
    source_run_attempt = GATE.positive_integer(source_run_attempt, "source run attempt")
    signer_run_id = GATE.positive_integer(signer_run_id, "signer run id")
    signer_run_attempt = GATE.positive_integer(signer_run_attempt, "signer run attempt")
    candidate = GATE.require_commit(repo_root, candidate_commit, "candidate")
    trusted_main = GATE.require_commit(repo_root, trusted_main_commit, "trusted main")
    GATE.require_ancestor(repo_root, candidate, trusted_main, "trusted main")
    identity = GATE.candidate_identity_at_commit(repo_root, candidate)
    bundle_bytes = bundle_path.read_bytes()
    provenance_bytes = provenance_path.read_bytes()
    if not bundle_bytes or not provenance_bytes:
        raise GATE.GateError("candidate and provenance bundles must not be empty")
    GATE.validate_github_provenance_bundle(provenance_bytes, "GitHub provenance bundle")
    bundle = GATE.load_json_bytes(bundle_bytes, "unsigned deterministic candidate bundle")
    bundle_generated = GATE.validate_unsigned_candidate_bundle(
        bundle, identity, source_run_id, source_run_attempt, "unsigned deterministic candidate bundle"
    )
    attested = GATE.parse_rfc3339_utc(attested_at, "attestedAt")
    approved = GATE.parse_rfc3339_utc(approved_at, "approvedAt")
    if bundle_generated > attested or attested > approved:
        raise GATE.GateError("bundle, attestation, and approval timestamps are inconsistent")
    if not isinstance(approved_by, str) or not GATE.RECEIPT_ACTOR_RE.fullmatch(approved_by):
        raise GATE.GateError("approvedBy must be a GitHub handle")
    attestation_uri = GATE.validate_https_uri(attestation_uri, "attestation URI")
    parsed = GATE.urlsplit(attestation_uri)
    if parsed.hostname != "github.com" or not GATE.re.fullmatch(
        r"/Imagine-That-Ai/BurnBar/attestations/[1-9][0-9]*", parsed.path
    ):
        raise GATE.GateError("attestation URI must identify an official OpenBurnBar GitHub attestation")
    policy_digest = GATE.file_sha256_at_commit(
        repo_root, trusted_main, GATE.PROMOTION_POLICY_PATH, "trusted-main promotion policy"
    )
    evaluator_digest = GATE.file_sha256_at_commit(
        repo_root, trusted_main, GATE.PROMOTION_EVALUATOR_PATH, "trusted-main promotion evaluator"
    )
    verifier.verify_candidate_bundle(
        bundle_path,
        provenance_path,
        trusted_main_commit=trusted_main,
        source_run_id=source_run_id,
        source_run_attempt=source_run_attempt,
        signer_run_id=signer_run_id,
        signer_run_attempt=signer_run_attempt,
        candidate_commit=candidate,
    )
    scope = GATE.PROMOTION_SCOPES[GATE.profile_domain_for_row(row_id)]
    bundle_relative = f"{GATE.PROMOTION_BUNDLE_ROOT}/{scope}/{generation}.json"
    provenance_relative = f"{GATE.PROMOTION_PROVENANCE_ROOT}/{scope}/{generation}.json"
    attestation_relative = f"{GATE.ATTESTATION_ROOT}/{scope}/{generation}.json"
    supersedes = superseded_authority_pointer(repo_root, row_id, generation)
    attestation = {
        "schemaVersion": 2,
        "authorityScope": scope,
        "authorityGeneration": generation,
        "candidate": identity,
        "unsignedBundle": {
            "path": bundle_relative,
            "sha256": hashlib.sha256(bundle_bytes).hexdigest(),
            "sourceRunId": source_run_id,
            "sourceRunAttempt": source_run_attempt,
        },
        "provenance": {
            "path": provenance_relative,
            "sha256": hashlib.sha256(provenance_bytes).hexdigest(),
            "signerWorkflow": GATE.PROMOTION_SIGNER_WORKFLOW,
            "signerRunId": signer_run_id,
            "signerRunAttempt": signer_run_attempt,
            "trustedMainCommit": trusted_main,
            "policySha256": policy_digest,
            "evaluatorSha256": evaluator_digest,
        },
        "status": "attested",
        "generatedAt": attested_at,
        "evidenceUri": attestation_uri,
    }
    attestation_bytes = serialized(attestation)
    receipt = {
        "schemaVersion": 2,
        "rowId": row_id,
        "authorityGeneration": generation,
        "transition": "promotion",
        "status": "active",
        "evidence": [attestation_uri],
        "approvedBy": approved_by,
        "approvedAt": approved_at,
        "commit": candidate,
        "promotionAttestation": {
            "path": attestation_relative,
            "sha256": hashlib.sha256(attestation_bytes).hexdigest(),
            "supersedes": supersedes,
        },
    }
    return attestation, receipt, bundle_bytes, provenance_bytes


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repo-root", type=Path, default=REPO_ROOT)
    parser.add_argument("--row-id", required=True)
    parser.add_argument("--authority-generation", type=int, required=True)
    parser.add_argument("--bundle", type=Path, required=True)
    parser.add_argument("--provenance-bundle", type=Path, required=True)
    parser.add_argument("--candidate-commit", required=True)
    parser.add_argument("--trusted-main-commit", required=True)
    parser.add_argument("--source-run-id", type=int, required=True)
    parser.add_argument("--source-run-attempt", type=int, required=True)
    parser.add_argument("--signer-run-id", type=int, required=True)
    parser.add_argument("--signer-run-attempt", type=int, required=True)
    parser.add_argument("--attestation-uri", required=True)
    parser.add_argument("--attested-at", required=True)
    parser.add_argument("--approved-by", required=True)
    parser.add_argument("--approved-at", required=True)
    args = parser.parse_args(argv)
    repo_root = args.repo_root.resolve(strict=True)
    try:
        attestation, receipt, bundle_bytes, provenance_bytes = create_artifacts(
            repo_root,
            row_id=args.row_id,
            generation=args.authority_generation,
            bundle_path=args.bundle.resolve(strict=True),
            provenance_path=args.provenance_bundle.resolve(strict=True),
            candidate_commit=args.candidate_commit,
            trusted_main_commit=args.trusted_main_commit,
            source_run_id=args.source_run_id,
            source_run_attempt=args.source_run_attempt,
            signer_run_id=args.signer_run_id,
            signer_run_attempt=args.signer_run_attempt,
            attestation_uri=args.attestation_uri,
            attested_at=args.attested_at,
            approved_by=args.approved_by,
            approved_at=args.approved_at,
            verifier=GATE.SignedEvidenceVerifier(),
        )
        scope = GATE.PROMOTION_SCOPES[GATE.profile_domain_for_row(args.row_id)]
        outputs = (
            (repo_root / GATE.PROMOTION_BUNDLE_ROOT / scope / f"{args.authority_generation}.json", bundle_bytes),
            (repo_root / GATE.PROMOTION_PROVENANCE_ROOT / scope / f"{args.authority_generation}.json", provenance_bytes),
            (repo_root / GATE.ATTESTATION_ROOT / scope / f"{args.authority_generation}.json", serialized(attestation)),
            (repo_root / GATE.RECEIPT_ROOT / args.row_id / str(args.authority_generation) / "promotion.json", serialized(receipt)),
        )
        for path, contents in outputs:
            append_only(path, contents)
    except (GATE.GateError, OSError) as error:
        print(f"ERROR: cannot create promotion receipt: {error}", file=sys.stderr)
        return 1
    print(outputs[-1][0].relative_to(repo_root).as_posix())
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
