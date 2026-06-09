#!/usr/bin/env python3
"""Validate BurnBar AGPL legal-release review evidence.

This is not legal advice and does not replace counsel. It only makes the
release gate machine-checkable: the runtime-readiness manifest must not mark the
legal review complete unless a dated approval record covers the known AGPL,
store-distribution, hosted-gateway, and Signal/libsignal/SPQR questions.
"""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path
from typing import Any


APPROVED_STATUS = "approved"
REQUIRED_SCOPE = {
    "AGPL-3.0-only product license",
    "Signal/libsignal/SPQR product dependency",
    "corresponding source for shipped apps",
    "hosted gateway network source obligations",
    "app store and commercial distribution terms",
    "MIT-compatible Nous/Hermes upstream boundary",
}
REQUIRED_ARTIFACTS = {
    ".github/workflows/license-posture.yml",
    "LICENSE",
    "THIRD_PARTY_NOTICES.md",
    "docs/legal/SOURCE_AVAILABILITY.md",
    "docs/legal/DEPENDENCY_LICENSE_MANIFEST.md",
    "docs/legal/AGPL_RELEASE_REVIEW_PACKET.md",
    "docs/legal/agpl-release-review.evidence.template.json",
    "docs/legal/HERMES_GATEWAY_SIGNAL_REQUIRED_ROLLOUT.md",
    "functions/package.json",
    "packages/signal-envelope-contracts/package.json",
    "scripts/ci/check_burnbar_license_posture.py",
    "scripts/ci/check_libsignal_runtime_readiness.py",
    "scripts/ci/write_burnbar_source_provenance.py",
    "scripts/verify_burnbar_mit_pr_clean.py",
    "third_party/libsignal/runtime-readiness.json",
}
REQUIRED_DISTRIBUTION_CHANNELS = {
    "Apple App Store and TestFlight",
    "Google Play",
    "direct download",
    "hosted gateway network service",
    "commercial distribution",
}
TOP_LEVEL_KEYS = {
    "schemaVersion",
    "reviewStatus",
    "reviewedAt",
    "reviewer",
    "reviewerRole",
    "scope",
    "distributionChannels",
    "reviewedArtifacts",
    "approval",
    "notes",
}
APPROVAL_KEYS = {
    "reviewerName",
    "approvedAt",
    "documentPath",
    "documentSha256",
    "signatureFormat",
    "signaturePath",
    "publicKeyPath",
}


def _path(path: tuple[str, ...]) -> str:
    return ".".join(path) if path else "root"


def _unexpected_keys(value: dict[str, Any], allowed: set[str], path: tuple[str, ...]) -> list[str]:
    return [f"{_path(path)} has unexpected key: {key}" for key in sorted(set(value).difference(allowed))]


def _string_list(value: Any, path: str) -> tuple[list[str], list[str]]:
    if not isinstance(value, list):
        return [], [f"{path} must be a list"]
    items: list[str] = []
    errors: list[str] = []
    for index, item in enumerate(value):
        if not isinstance(item, str) or not item.strip():
            errors.append(f"{path}[{index}] must be a non-empty string")
        else:
            items.append(item)
    return items, errors


def validate_legal_release_review(
    data: Any,
    *,
    repo_root: Path | None = None,
    require_approved: bool = False,
) -> list[str]:
    errors: list[str] = []
    if not isinstance(data, dict):
        return ["review root must be a JSON object"]

    errors.extend(_unexpected_keys(data, TOP_LEVEL_KEYS, ()))
    if data.get("schemaVersion") != 1:
        errors.append(f"schemaVersion must be 1, found {data.get('schemaVersion')!r}")
    if data.get("reviewStatus") != APPROVED_STATUS:
        errors.append(f"reviewStatus must be {APPROVED_STATUS!r}")
    if not isinstance(data.get("reviewedAt"), str) or not data.get("reviewedAt", "").strip():
        errors.append("reviewedAt must be a non-empty string")
    reviewer = data.get("reviewer")
    if not isinstance(reviewer, str) or len(reviewer.strip()) < 3:
        errors.append("reviewer must be a non-empty reviewer/counsel identifier")
    reviewer_role = data.get("reviewerRole")
    if reviewer_role != "external_counsel":
        errors.append("reviewerRole must be 'external_counsel'")

    scope, scope_errors = _string_list(data.get("scope"), "scope")
    errors.extend(scope_errors)
    missing_scope = sorted(REQUIRED_SCOPE.difference(scope))
    if missing_scope:
        errors.append("scope missing required item(s): " + ", ".join(missing_scope))

    channels, channel_errors = _string_list(data.get("distributionChannels"), "distributionChannels")
    errors.extend(channel_errors)
    missing_channels = sorted(REQUIRED_DISTRIBUTION_CHANNELS.difference(channels))
    if missing_channels:
        errors.append("distributionChannels missing required item(s): " + ", ".join(missing_channels))

    artifacts, artifact_errors = _string_list(data.get("reviewedArtifacts"), "reviewedArtifacts")
    errors.extend(artifact_errors)
    missing_artifacts = sorted(REQUIRED_ARTIFACTS.difference(artifacts))
    if missing_artifacts:
        errors.append("reviewedArtifacts missing required artifact(s): " + ", ".join(missing_artifacts))
    if repo_root is not None:
        for rel_path in artifacts:
            if Path(rel_path).is_absolute() or ".." in Path(rel_path).parts:
                errors.append(f"reviewedArtifacts path must be repo-relative: {rel_path}")
            elif not (repo_root / rel_path).is_file():
                errors.append(f"reviewedArtifacts path does not exist: {rel_path}")

    notes = data.get("notes")
    if not isinstance(notes, str) or not notes.strip():
        errors.append("notes must be a non-empty string explaining the release decision boundary")
    elif "not legal advice" in notes.lower():
        errors.append("notes must record the review outcome, not a placeholder disclaimer")

    if require_approved:
        approval = data.get("approval")
        if not isinstance(approval, dict):
            errors.append("approval must be an object")
        else:
            errors.extend(_unexpected_keys(approval, APPROVAL_KEYS, ("approval",)))
            for key in (
                "reviewerName",
                "approvedAt",
                "documentPath",
                "documentSha256",
                "signatureFormat",
                "signaturePath",
                "publicKeyPath",
            ):
                value = approval.get(key)
                if not isinstance(value, str) or not value.strip():
                    errors.append(f"approval.{key} is required")
            document_sha = approval.get("documentSha256")
            if isinstance(document_sha, str) and document_sha.strip() and (
                len(document_sha) != 64 or any(char not in "0123456789abcdefABCDEF" for char in document_sha)
            ):
                errors.append("approval.documentSha256 must be a 64-character hex SHA-256")
            if repo_root is not None:
                for key in ("documentPath", "signaturePath", "publicKeyPath"):
                    value = approval.get(key)
                    if not isinstance(value, str) or not value.strip():
                        continue
                    path = Path(value)
                    if path.is_absolute() or ".." in path.parts:
                        errors.append(f"approval.{key} must be repo-relative")
                    elif not (repo_root / path).is_file():
                        errors.append(f"approval.{key} path does not exist: {value}")

    return errors


def load_legal_release_review(path: Path) -> Any:
    return json.loads(path.read_text(encoding="utf-8"))


def check_legal_release_review(path: Path, *, repo_root: Path | None = None) -> list[str]:
    if not path.is_file():
        return [f"legal-release review evidence file is missing: {path}"]
    try:
        data = load_legal_release_review(path)
    except json.JSONDecodeError as exc:
        return [f"legal-release review evidence is not valid JSON: {exc}"]
    return validate_legal_release_review(data, repo_root=repo_root)


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("path", type=Path, help="AGPL legal-release review JSON evidence")
    parser.add_argument(
        "--repo-root",
        type=Path,
        default=Path.cwd(),
        help="Repo root used to verify reviewed artifact paths exist",
    )
    args = parser.parse_args(argv)

    errors = check_legal_release_review(args.path, repo_root=args.repo_root)
    if errors:
        print("FAIL: BurnBar AGPL legal-release review evidence is invalid", file=sys.stderr)
        for error in errors:
            print(f"- {error}", file=sys.stderr)
        return 1

    print(f"PASS: BurnBar AGPL legal-release review evidence is valid: {args.path}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
