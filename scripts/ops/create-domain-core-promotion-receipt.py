#!/usr/bin/env python3
"""Create a generation-scoped promotion receipt from a verified readiness report."""

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
GATE = sys.modules.get("domain_core_legacy_deletion_gate")
if GATE is None:
    if SPEC is None or SPEC.loader is None:
        raise RuntimeError(f"cannot load {GATE_PATH}")
    GATE = importlib.util.module_from_spec(SPEC)
    sys.modules[SPEC.name] = GATE
    SPEC.loader.exec_module(GATE)

READY_REPORT_FIELDS = {
    "schemaVersion",
    "domain",
    "coreVersion",
    "generatedAt",
    "provenance",
    "status",
    "ready",
    "policy",
    "summary",
    "blockers",
}


def ready_report(path: Path, expected_domain: str, expected_policy: dict[str, Any]) -> dict[str, Any]:
    report = GATE.require_object(GATE.load_json(path, "promotion readiness report"), "promotion readiness report")
    GATE.exact_keys(report, READY_REPORT_FIELDS, READY_REPORT_FIELDS, "promotion readiness report")
    return GATE.validate_ready_report(report, expected_domain, expected_policy, "promotion readiness report")


def create_artifacts(
    repo_root: Path,
    *,
    row_id: str,
    generation: int,
    report_path: Path,
    report_provenance_path: Path,
    report_uri: str,
    candidate_commit: str,
    builder_commit: str,
    approved_by: str,
    approved_at: str,
) -> tuple[dict[str, Any], bytes, dict[str, Any], dict[str, Any]]:
    if row_id not in GATE.ROW_IDS:
        raise GATE.GateError(f"unknown row id: {row_id}")
    if not isinstance(generation, int) or isinstance(generation, bool) or generation < 1:
        raise GATE.GateError("authority generation must be a positive integer")
    profile_domain = GATE.profile_domain_for_row(row_id)
    promotion_domain = GATE.PROMOTION_DOMAINS[profile_domain]
    scope = GATE.PROMOTION_SCOPES[profile_domain]
    report_uri = GATE.validate_https_uri(report_uri, "report URI")
    candidate_commit = GATE.require_commit(repo_root, candidate_commit, "candidate")
    builder_commit = GATE.require_commit(repo_root, builder_commit, "trusted builder")
    GATE.require_ancestor(repo_root, candidate_commit, builder_commit, "trusted builder")
    candidate_policies, candidate_policy_digests = GATE.policies_at_commit(repo_root, candidate_commit)
    report = ready_report(report_path, promotion_domain, candidate_policies[promotion_domain])
    if report["provenance"]["queryRevision"] != candidate_commit:
        raise GATE.GateError("promotion report query revision must equal candidate commit")
    provenance_bytes = report_provenance_path.read_bytes()
    if not provenance_bytes:
        raise GATE.GateError("promotion report provenance bundle must not be empty")
    approved = GATE.parse_rfc3339_utc(approved_at, "approvedAt")
    generated = GATE.parse_rfc3339_utc(report["generatedAt"], "promotion readiness report.generatedAt")
    if generated > approved:
        raise GATE.GateError("approvedAt must not be earlier than report.generatedAt")
    if not isinstance(approved_by, str) or not GATE.RECEIPT_ACTOR_RE.fullmatch(approved_by):
        raise GATE.GateError("approvedBy must be a GitHub handle")

    supersedes: dict[str, str] | None = None
    if generation > 1:
        path = f"{GATE.RECEIPT_ROOT}/{row_id}/{generation - 1}/rollback.json"
        rollback = GATE.secure_path(repo_root, path, "previous rollback receipt", must_exist=True)
        supersedes = {"path": path, "sha256": GATE.sha256_path(rollback)}

    report_relative = f"{GATE.REPORT_ROOT}/{scope}/{generation}.json"
    attestation_relative = f"{GATE.ATTESTATION_ROOT}/{scope}/{generation}.json"
    provenance_relative = f"{GATE.PROMOTION_PROVENANCE_ROOT}/{scope}/{generation}.json"
    report_bytes = (json.dumps(report, indent=2, ensure_ascii=True) + "\n").encode("utf-8")
    attestation = {
        "schemaVersion": 1,
        "domain": promotion_domain,
        "authorityScope": scope,
        "authorityGeneration": generation,
        "reportPath": report_relative,
        "reportUri": report_uri,
        "reportSha256": hashlib.sha256(report_bytes).hexdigest(),
        "reportProvenancePath": provenance_relative,
        "reportProvenanceSha256": hashlib.sha256(provenance_bytes).hexdigest(),
        "coreVersion": report["coreVersion"],
        "candidateCommit": candidate_commit,
        "builderCommit": builder_commit,
        "sourceFingerprint": GATE.source_fingerprint_at_commit(repo_root, candidate_commit),
        "policySha256": candidate_policy_digests[promotion_domain],
        "status": "ready",
        "generatedAt": report["generatedAt"],
    }
    attestation_bytes = (json.dumps(attestation, indent=2, ensure_ascii=True) + "\n").encode("utf-8")
    receipt = {
        "schemaVersion": 2,
        "rowId": row_id,
        "authorityGeneration": generation,
        "transition": "promotion",
        "status": "active",
        "evidence": [report_uri],
        "approvedBy": approved_by,
        "approvedAt": approved_at,
        "commit": candidate_commit,
        "promotionAttestation": {
            "path": attestation_relative,
            "sha256": hashlib.sha256(attestation_bytes).hexdigest(),
            "supersedesRollback": supersedes,
        },
    }
    return report, provenance_bytes, attestation, receipt


def serialized(value: dict[str, Any]) -> bytes:
    return (json.dumps(value, indent=2, ensure_ascii=True) + "\n").encode("utf-8")


def verify_append_only_destination(path: Path, value: dict[str, Any]) -> None:
    verify_append_only_bytes(path, serialized(value))


def verify_append_only_bytes(path: Path, contents: bytes) -> None:
    if not path.exists():
        return
    if not path.is_file() or path.is_symlink():
        raise GATE.GateError(f"refusing to replace non-regular artifact: {path}")
    if path.read_bytes() != contents:
        raise GATE.GateError(f"refusing to rewrite append-only artifact: {path}")


def write_atomically(path: Path, value: dict[str, Any]) -> None:
    write_bytes_atomically(path, serialized(value))


def write_bytes_atomically(path: Path, contents: bytes) -> None:
    verify_append_only_bytes(path, contents)
    if path.exists():
        return
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_name(f".{path.name}.{os.getpid()}.tmp")
    try:
        temporary.write_bytes(contents)
        temporary.chmod(0o600)
        os.replace(temporary, path)
    finally:
        temporary.unlink(missing_ok=True)


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repo-root", type=Path, default=REPO_ROOT)
    parser.add_argument("--row-id", required=True)
    parser.add_argument("--authority-generation", required=True, type=int)
    parser.add_argument("--report", required=True, type=Path)
    parser.add_argument("--report-provenance", required=True, type=Path)
    parser.add_argument("--report-uri", required=True)
    parser.add_argument("--candidate-commit", required=True)
    parser.add_argument("--builder-commit", required=True)
    parser.add_argument("--approved-by", required=True)
    parser.add_argument("--approved-at", required=True)
    args = parser.parse_args(argv)
    repo_root = args.repo_root.resolve(strict=True)
    try:
        report, provenance, attestation, receipt = create_artifacts(
            repo_root,
            row_id=args.row_id,
            generation=args.authority_generation,
            report_path=args.report.resolve(strict=True),
            report_provenance_path=args.report_provenance.resolve(strict=True),
            report_uri=args.report_uri,
            candidate_commit=args.candidate_commit,
            builder_commit=args.builder_commit,
            approved_by=args.approved_by,
            approved_at=args.approved_at,
        )
        profile_domain = GATE.profile_domain_for_row(args.row_id)
        scope = GATE.PROMOTION_SCOPES[profile_domain]
        report_output = repo_root / GATE.REPORT_ROOT / scope / f"{args.authority_generation}.json"
        provenance_output = repo_root / GATE.PROMOTION_PROVENANCE_ROOT / scope / f"{args.authority_generation}.json"
        attestation_output = repo_root / GATE.ATTESTATION_ROOT / scope / f"{args.authority_generation}.json"
        output = repo_root / GATE.RECEIPT_ROOT / args.row_id / str(args.authority_generation) / "promotion.json"
        structured_artifacts = ((report_output, report), (attestation_output, attestation), (output, receipt))
        for path, value in structured_artifacts:
            verify_append_only_destination(path, value)
        verify_append_only_bytes(provenance_output, provenance)
        for path, value in structured_artifacts:
            write_atomically(path, value)
        write_bytes_atomically(provenance_output, provenance)
    except (GATE.GateError, OSError) as error:
        print(f"ERROR: cannot create promotion receipt: {error}", file=sys.stderr)
        return 1
    print(output.relative_to(repo_root).as_posix())
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
