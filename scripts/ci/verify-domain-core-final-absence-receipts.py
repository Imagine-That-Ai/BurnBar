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


def run(
    root: Path,
    verifier: Any,
    release_commit: str,
    release_version: str,
    ancestry_verifier: Any | None = None,
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
    return {
        "schemaVersion": 1,
        "completion": "post_deletion_release_complete",
        "authoritySha256": authority,
        "version": version,
        "consumers": list(CONSUMERS),
        "finalArtifactSha256s": final_digests,
        "coveredRows": sorted(covered),
    }


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--evidence-root", required=True, type=Path)
    parser.add_argument("--release-commit", required=True)
    parser.add_argument("--release-version", required=True)
    parser.add_argument("--output", required=True, type=Path)
    args = parser.parse_args()
    try:
        result = run(
            args.evidence_root,
            GATE.SignedEvidenceVerifier(),
            args.release_commit,
            args.release_version,
        )
        args.output.write_text(json.dumps(result, indent=2, sort_keys=True) + "\n")
    except (OSError, json.JSONDecodeError, GATE.GateError) as error:
        parser.error(str(error))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
