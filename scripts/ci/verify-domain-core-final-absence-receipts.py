#!/usr/bin/env python3
"""Aggregate seven signed release-B legacy-absence evidence surfaces."""

from __future__ import annotations

import argparse
import hashlib
import importlib.util
import json
import sys
import zipfile
from pathlib import Path
from typing import Any


ROOT = Path(__file__).resolve().parents[2]
GATE_PATH = ROOT / "scripts/ci/verify-domain-core-legacy-deletion.py"


def load_module(path: Path, name: str) -> Any:
    spec = importlib.util.spec_from_file_location(name, path)
    if spec is None or spec.loader is None:
        raise RuntimeError(f"cannot load {path}")
    value = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = value
    spec.loader.exec_module(value)
    return value


GATE = load_module(GATE_PATH, "domain_core_legacy_deletion_gate")
SCANNER = load_module(ROOT / "scripts/ci/scan-domain-core-final-artifact-legacy.py", "domain_core_final_scan")
CONSUMERS = ("apple", "ios", "android", "windows", "linux", "console", "functions")
ABSENCE_TYPE = "https://openburnbar.dev/attestations/domain-core-final-legacy-absence/v1"


def expected_rows(consumer: str, domain: str) -> list[str]:
    return sorted(
        row_id
        for row_id, consumers in GATE.ROW_RELEASE_CONSUMERS.items()
        if consumer in consumers and GATE.profile_domain_for_row(row_id) == domain
    )


def _verify_deletion_review_receipts(
    repo_root: Path,
    verifier: Any,
    release_commit: str,
    ancestry_verifier: Any,
) -> dict[str, Any]:
    """Verify every legacy_deleted ledger row has a valid deletionReview receipt.

    Reuses the canonical GATE.validate_receipt and GATE.validate_deletion_review_receipt
    verifiers — no weaker parser duplication.  Enforces that the authorized deletion
    commit is an ancestor of exact release B, binds the approved plan digest, and
    verifies the reviewed deletion commit/PR/reviewer authority already enforced by
    the trusted deletion guard.  Fail-closed: evidence_verifier must be non-None.
    """
    repo_root = repo_root.resolve(strict=True)
    manifest_path = GATE.secure_path(
        repo_root,
        "config/domain-core-legacy-deletion.json",
        "release-B deletion ledger",
        must_exist=True,
    )
    manifest = GATE.require_object(
        GATE.load_json(manifest_path, "release-B deletion ledger"),
        "release-B deletion ledger",
    )
    GATE.exact_keys(
        manifest,
        {"schemaVersion", "sourceRoots", "rows", "sharedTargets"},
        {"schemaVersion", "sourceRoots", "rows", "sharedTargets"},
        "release-B deletion ledger",
    )
    if manifest["schemaVersion"] != 2 or isinstance(manifest["schemaVersion"], bool):
        raise GATE.GateError("release-B deletion ledger.schemaVersion must be 2")
    raw_rows = GATE.require_array(manifest["rows"], "release-B deletion ledger.rows")
    deleted_rows: list[tuple[str, int, dict[str, Any]]] = []
    for index, raw_row in enumerate(raw_rows):
        label = f"release-B deletion ledger.rows[{index}]"
        row = GATE.require_object(raw_row, label)
        GATE.exact_keys(
            row,
            {"id", "state", "authorityGeneration", "receipts", "targets"},
            {"id", "state", "authorityGeneration", "receipts", "targets"},
            label,
        )
        row_id = row["id"]
        if not isinstance(row_id, str) or not GATE.ROW_ID_RE.fullmatch(row_id):
            raise GATE.GateError(f"{label}.id: invalid row id")
        state = row["state"]
        if not isinstance(state, str) or state not in GATE.STATES:
            raise GATE.GateError(f"{label}.state: unknown state: {state!r}")
        if state != "legacy_deleted":
            continue
        generation = row["authorityGeneration"]
        if not isinstance(generation, int) or isinstance(generation, bool) or generation < 1:
            raise GATE.GateError(f"{label}.authorityGeneration: expected positive integer for legacy_deleted row")
        receipts = GATE.require_object(row["receipts"], f"{label}.receipts")
        GATE.exact_keys(
            receipts,
            GATE.allowed_receipts(state),
            GATE.required_receipts(state),
            f"{label}.receipts",
        )
        deleted_rows.append((row_id, generation, receipts))
    if not deleted_rows:
        raise GATE.GateError(
            "release-B deletion ledger contains no legacy_deleted rows; "
            "post-deletion completion requires authorized deletion review for every deleted row"
        )
    deletion_reviewers = GATE.load_deletion_reviewers(repo_root)
    seen_receipts: set[str] = set()
    deletion_authority: dict[str, Any] = {}
    for row_id, generation, receipts in deleted_rows:
        stable_receipt = GATE.validate_receipt(
            repo_root,
            GATE.repository_path(receipts["stableRelease"], f"row {row_id} stableRelease"),
            row_id,
            generation,
            "stable_release",
            seen_receipts,
        )
        deletion_receipt = GATE.validate_receipt(
            repo_root,
            GATE.repository_path(receipts["deletionReview"], f"row {row_id} deletionReview"),
            row_id,
            generation,
            "deletion_review",
            seen_receipts,
        )
        raw_targets = GATE.require_array(
            manifest_rows_targets(manifest, row_id),
            f"row {row_id} targets",
        )
        targets = [
            GATE.parse_target(raw_target, f"row {row_id} targets[{idx}]", _manifest_roots(repo_root, manifest))
            for idx, raw_target in enumerate(raw_targets)
        ]
        GATE.validate_deletion_review_receipt(
            repo_root,
            row_id,
            generation,
            deletion_receipt,
            stable_receipt,
            targets,
            deletion_reviewers,
            verifier,
        )
        ancestry_verifier(deletion_receipt.commit, release_commit)
        payload = deletion_receipt.payload
        deletion_authority[row_id] = {
            "deletionCommit": deletion_receipt.commit,
            "reviewedCommit": payload["reviewedCommit"],
            "reviewer": payload["reviewer"],
            "reviewClass": payload["reviewClass"],
            "planSha256": payload["planSha256"],
            "reviewUri": payload["reviewUri"],
        }
    return {
        "coveredDeletedRows": sorted(row_id for row_id, _gen, _rec in deleted_rows),
        "rowAuthorities": deletion_authority,
    }


def _manifest_roots(repo_root: Path, manifest: dict[str, Any]) -> dict[str, str]:
    """Extract validated source roots from a ledger manifest."""
    raw_roots = GATE.require_object(manifest["sourceRoots"], "manifest.sourceRoots")
    roots: dict[str, str] = {}
    for root_id, raw_path in raw_roots.items():
        path = GATE.repository_path(raw_path, f"manifest.sourceRoots.{root_id}")
        roots[root_id] = path
    return roots


def manifest_rows_targets(manifest: dict[str, Any], row_id: str) -> list[Any]:
    """Extract the targets array for a specific row from a ledger manifest."""
    for raw_row in manifest["rows"]:
        row = GATE.require_object(raw_row, "manifest.rows entry")
        if row.get("id") == row_id:
            return GATE.require_array(row["targets"], f"row {row_id} targets")
    raise GATE.GateError(f"manifest.rows: row {row_id} not found")


def run(
    root: Path,
    verifier: Any,
    release_commit: str,
    release_version: str,
    ancestry_verifier: Any | None = None,
    repo_root: Path | None = None,
) -> dict[str, Any]:
    if not GATE.COMMIT_RE.fullmatch(release_commit):
        raise GATE.GateError("release-B commit must be a full lowercase Git SHA")
    ancestry_verifier = ancestry_verifier or (
        lambda ancestor, descendant: GATE.require_ancestor(
            ROOT, ancestor, descendant, "release-A activation P to release-B deletion D"
        )
    )
    if not root.is_dir() or root.is_symlink():
        raise GATE.GateError("final absence evidence root must be a safe directory")
    directories = {path.name for path in root.iterdir() if path.is_dir() and not path.is_symlink()}
    if directories != set(CONSUMERS):
        raise GATE.GateError(
            f"final absence consumer set mismatch; missing={sorted(set(CONSUMERS) - directories)}; "
            f"extra={sorted(directories - set(CONSUMERS))}"
        )
    authority: str | None = None
    version: str | None = None
    covered: set[str] = set()
    final_digests: dict[str, str] = {}
    for consumer in CONSUMERS:
        directory = root / consumer
        artifact = directory / "artifact"
        if not artifact.is_file() or artifact.is_symlink():
            raise GATE.GateError(f"{consumer}: exact final artifact is missing")
        artifact_digest = hashlib.sha256(artifact.read_bytes()).hexdigest()
        domains = sorted(domain for domain in GATE.PROFILE_DOMAIN_ROWS if expected_rows(consumer, domain))
        scan_report: dict[str, Any] | None = None
        allowed_files = {"artifact"}
        if consumer == "ios":
            allowed_files.add("ipa")
        ios_receipt_digests: list[str] = []
        for domain in domains:
            bundle = directory / f"{domain}.predicate.sigstore.json"
            allowed_files.add(bundle.name)
            if not bundle.is_file() or bundle.is_symlink():
                raise GATE.GateError(f"{consumer}/{domain}: signed predicate bundle is missing")
            expected_tag = (
                f"windows-v{release_version}"
                if consumer == "windows"
                else f"linux-v{release_version}"
                if consumer == "linux"
                else f"v{release_version}"
            )
            results = verifier._verify_bundle(
                artifact,
                bundle,
                signer_workflow=GATE.RELEASE_SIGNER_WORKFLOWS[consumer],
                source_digest=release_commit,
                source_ref=f"refs/tags/{expected_tag}",
                predicate_type=GATE.RELEASE_PREDICATE_TYPES[consumer],
                signer_digest=release_commit,
                label=f"{consumer}/{domain} final absence artifact",
            )
            signed = []
            for result in results:
                verification = result.get("verificationResult")
                statement = verification.get("statement") if isinstance(verification, dict) else None
                value = statement.get("predicate") if isinstance(statement, dict) else None
                if isinstance(value, dict):
                    signed.append(value)
            candidates = [
                value for value in signed if value.get("consumer") == consumer and value.get("domain") == domain
            ]
            if len(candidates) != 1:
                raise GATE.GateError(f"{consumer}/{domain}: bundle must contain one exact release predicate")
            predicate = candidates[0]
            release = GATE.require_object(predicate.get("release"), f"{consumer}/{domain} release")
            candidate = GATE.require_object(predicate.get("candidate"), f"{consumer}/{domain} candidate")
            activation = GATE.require_object(predicate.get("activation"), f"{consumer}/{domain} activation")
            absence = GATE.require_object(predicate.get("legacyAbsence"), f"{consumer}/{domain} legacyAbsence")
            rows = expected_rows(consumer, domain)
            if (
                predicate.get("schemaVersion") != 2
                or predicate.get("predicateType") != GATE.RELEASE_PREDICATE_TYPES[consumer]
                or predicate.get("consumer") != consumer
                or predicate.get("domain") != domain
                or predicate.get("artifact", {}).get("sha256") != artifact_digest
                or release.get("version") != release_version
                or release.get("commit") != release_commit
                or release.get("tag") != expected_tag
                or absence
                != {
                    "schemaVersion": 1,
                    "predicateType": ABSENCE_TYPE,
                    "releaseCommit": release.get("commit"),
                    "authorityActivationCommit": activation.get("activationCommit"),
                    "deletionInventorySha256": absence.get("deletionInventorySha256"),
                    "rowIds": rows,
                    "artifactScan": absence.get("artifactScan"),
                }
                or not GATE.DIGEST_RE.fullmatch(absence.get("deletionInventorySha256", ""))
                or activation.get("activationCommit") == release.get("commit")
                or any(
                    activation.get(key) != candidate.get(key)
                    for key in ("candidateCommit", "coreVersion", "abiVersion", "sourceSha256")
                )
            ):
                raise GATE.GateError(f"{consumer}/{domain}: signed final absence predicate identity is invalid")
            scan_binding = GATE.require_object(absence.get("artifactScan"), f"{consumer}/{domain} artifactScan")
            signed_report = GATE.require_object(scan_binding.get("report"), f"{consumer}/{domain} scan report")
            if (
                scan_binding
                != {
                    "reportSha256": GATE.canonical_json_sha256(signed_report),
                    "artifactSha256": artifact_digest,
                    "ruleSetSha256": signed_report.get("ruleSetSha256"),
                    "inspectedMemberCount": len(signed_report.get("inspectedMembers", [])),
                    "report": signed_report,
                }
                or signed_report.get("result") != "absent"
                or signed_report.get("matches") != []
            ):
                raise GATE.GateError(f"{consumer}/{domain}: signed scan report does not bind exact clean bytes")
            if scan_report is None:
                scan_report = signed_report
            elif scan_report != signed_report:
                raise GATE.GateError(f"{consumer}: domain predicates do not share one artifact scan")
            ancestry_verifier(activation["activationCommit"], release["commit"])
            if consumer == "ios":
                ios_receipt = GATE.require_object(
                    predicate.get("appStoreConnectReceipt"), "signed iOS App Store Connect receipt"
                )
                ios_receipt_digests.append(ios_receipt.get("ipaSha256"))
            binding = GATE.canonical_json_sha256({"candidate": candidate, "activation": activation})
            if authority is None:
                authority = binding
                version = release.get("version")
            elif binding != authority or release.get("version") != version:
                raise GATE.GateError("final absence predicates do not share one candidate, activation, and version")
            covered.update(rows)
        actual_files = {path.name for path in directory.iterdir() if path.is_file() and not path.is_symlink()}
        if actual_files != allowed_files:
            raise GATE.GateError(f"{consumer}: final absence package contains missing or extra files")
        if consumer == "ios":
            ipa = directory / "ipa"
            if not ipa.is_file() or ipa.is_symlink():
                raise GATE.GateError("ios: exact App Store Connect IPA bytes are missing")
            ipa_digest = hashlib.sha256(ipa.read_bytes()).hexdigest()
            if any(value != ipa_digest for value in ios_receipt_digests):
                raise GATE.GateError("ios: signed App Store Connect receipt does not bind the staged IPA bytes")
            final_digests[consumer] = ipa_digest
        else:
            final_digests[consumer] = artifact_digest
        try:
            with zipfile.ZipFile(artifact):
                rescanned = SCANNER.scan(consumer, artifact)
            if scan_report is None or GATE.canonical_json_sha256(rescanned) != GATE.canonical_json_sha256(scan_report):
                raise GATE.GateError(f"{consumer}: downloaded exact archive scan differs from signed report")
        except zipfile.BadZipFile:
            pass
    if covered != set(GATE.ROW_IDS):
        raise GATE.GateError("release-B final absence evidence does not cover the exact deletion inventory")
    deletion_authority = _verify_deletion_review_receipts(
        repo_root or ROOT,
        verifier,
        release_commit,
        ancestry_verifier,
    )
    return {
        "schemaVersion": 1,
        "completion": "post_deletion_release_complete",
        "authoritySha256": authority,
        "version": version,
        "consumers": list(CONSUMERS),
        "finalArtifactSha256s": final_digests,
        "coveredRows": sorted(covered),
        "deletionReviewAuthority": deletion_authority,
    }


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--evidence-root", required=True, type=Path)
    parser.add_argument("--release-commit", required=True)
    parser.add_argument("--release-version", required=True)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument(
        "--repo-root",
        type=Path,
        default=ROOT,
        help="Release-B checkout root containing the deletion ledger and receipt history",
    )
    args = parser.parse_args()
    try:
        result = run(
            args.evidence_root,
            GATE.SignedEvidenceVerifier(),
            args.release_commit,
            args.release_version,
            repo_root=args.repo_root,
        )
        args.output.write_text(json.dumps(result, indent=2, sort_keys=True) + "\n")
    except (OSError, json.JSONDecodeError, GATE.GateError) as error:
        parser.error(str(error))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
