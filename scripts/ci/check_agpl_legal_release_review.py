#!/usr/bin/env python3
"""Validate BurnBar AGPL legal-release review evidence.

This is not legal advice and does not replace counsel. It only makes the
release gate machine-checkable: the runtime-readiness manifest must not mark the
legal review complete unless a dated approval record covers the known AGPL,
store-distribution, hosted-gateway, and Signal/libsignal/SPQR questions.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import shutil
import subprocess
import sys
from pathlib import Path
from typing import Any


APPROVED_STATUS = "approved"

# Pinned external-counsel signing key. The approval signature is verified
# against THIS key — never against a public key named by the evidence JSON,
# because that would let any committer ship their own key alongside a forged
# approval. We pin the SHA-256 fingerprint of the DER-encoded SubjectPublicKeyInfo
# (i.e. `openssl pkey -pubin -outform DER | sha256sum`) so the key bytes can live
# in the repo and rotate via reviewable diff, while a swapped key fails the gate.
#
# TODO(legal): replace the sentinel below with the real counsel key fingerprint
# the first time counsel issues a signed approval. Until then this gate is
# fail-closed for the release/deploy preflight (it cannot be exercised on a
# per-PR lane); a release simply cannot claim a signed approval until the real
# key is pinned here. That is the intended one-time, reviewable unlock — not a
# permanently-red gate, and emphatically not a green-while-blind one.
COUNSEL_PUBLIC_KEY_SHA256 = (
    "REPLACE_WITH_PINNED_COUNSEL_PUBLIC_KEY_SHA256_FINGERPRINT"
)
COUNSEL_KEY_PLACEHOLDER = "REPLACE_WITH_PINNED_COUNSEL_PUBLIC_KEY_SHA256_FINGERPRINT"
SUPPORTED_SIGNATURE_FORMATS = {"openssl-sha256-rsa", "openssl-sha256-ecdsa"}
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


def _resolve_repo_path(repo_root: Path, rel: str) -> Path | None:
    """Resolve a repo-relative path, rejecting absolute/parent-escape values."""
    candidate = Path(rel)
    if candidate.is_absolute() or ".." in candidate.parts:
        return None
    return repo_root / candidate


def _sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(65536), b""):
            digest.update(chunk)
    return digest.hexdigest()


def _public_key_fingerprint(public_key_path: Path) -> str | None:
    """SHA-256 over the DER SubjectPublicKeyInfo of the supplied public key.

    Returns None when openssl cannot parse the file as a public key, so a bogus
    key file fails the pin comparison rather than silently matching.
    """
    openssl = shutil.which("openssl")
    if openssl is None:
        return None
    try:
        result = subprocess.run(
            [openssl, "pkey", "-pubin", "-in", str(public_key_path), "-outform", "DER"],
            capture_output=True,
            check=False,
        )
    except OSError:
        return None
    if result.returncode != 0 or not result.stdout:
        return None
    return hashlib.sha256(result.stdout).hexdigest()


def _verify_detached_signature(
    *, document_path: Path, signature_path: Path, public_key_path: Path, signature_format: str
) -> bool:
    """Verify a detached signature over the document using openssl + the key file.

    The key is the on-disk public key (already pinned by fingerprint by the
    caller). openssl returns non-zero on any tamper, so this is fail-closed.
    """
    if signature_format not in SUPPORTED_SIGNATURE_FORMATS:
        return False
    openssl = shutil.which("openssl")
    if openssl is None:
        return False
    digest = "sha256"
    try:
        result = subprocess.run(
            [
                openssl,
                "dgst",
                f"-{digest}",
                "-verify",
                str(public_key_path),
                "-signature",
                str(signature_path),
                str(document_path),
            ],
            capture_output=True,
            check=False,
        )
    except OSError:
        return False
    return result.returncode == 0


def _approval_diff_touches_public_key(repo_root: Path, public_key_rel: str) -> bool | None:
    """True when publicKeyPath was added/modified in the same commit as the approval.

    A signed approval whose trust anchor (the public key) is introduced or
    rewritten in the very same change is self-certifying: the attacker brings
    their own key. We reject that. Returns None when git history is unavailable
    (e.g. shallow/no-git checkout) so the caller can fail closed.
    """
    git = shutil.which("git")
    if git is None:
        return None
    try:
        head = subprocess.run(
            [git, "-C", str(repo_root), "rev-parse", "HEAD"],
            capture_output=True,
            text=True,
            check=False,
        )
        if head.returncode != 0:
            return None
        changed = subprocess.run(
            [git, "-C", str(repo_root), "diff", "--name-only", "HEAD~1", "HEAD"],
            capture_output=True,
            text=True,
            check=False,
        )
        if changed.returncode != 0:
            # No parent commit (root commit) — treat as introduced-in-this-diff.
            return True
    except OSError:
        return None
    touched = {line.strip() for line in changed.stdout.splitlines() if line.strip()}
    return public_key_rel in touched


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

            signature_format = approval.get("signatureFormat")
            if (
                isinstance(signature_format, str)
                and signature_format.strip()
                and signature_format not in SUPPORTED_SIGNATURE_FORMATS
            ):
                errors.append(
                    "approval.signatureFormat must be one of: "
                    + ", ".join(sorted(SUPPORTED_SIGNATURE_FORMATS))
                )

            # Cryptographic verification runs whenever a release claims approval,
            # NOT only when a repo_root is threaded in. The release preflight
            # calls validate_legal_release_review(require_approved=True) without a
            # repo_root, so gating crypto on `repo_root is not None` would let a
            # forged approval pass the one gate that actually matters. Resolve
            # against the supplied root or the current working directory.
            verify_root = repo_root if repo_root is not None else Path.cwd()
            path_rels: dict[str, str] = {}
            resolved: dict[str, Path] = {}
            for key in ("documentPath", "signaturePath", "publicKeyPath"):
                value = approval.get(key)
                if not isinstance(value, str) or not value.strip():
                    continue
                candidate = _resolve_repo_path(verify_root, value)
                if candidate is None:
                    errors.append(f"approval.{key} must be repo-relative")
                    continue
                path_rels[key] = value
                if not candidate.is_file():
                    errors.append(f"approval.{key} path does not exist: {value}")
                    continue
                resolved[key] = candidate

            have_all_paths = {"documentPath", "signaturePath", "publicKeyPath"}.issubset(resolved)

            # 1. Document integrity: the named document must hash to the claimed SHA-256.
            if "documentPath" in resolved and isinstance(document_sha, str) and document_sha.strip():
                actual_sha = _sha256_file(resolved["documentPath"])
                if actual_sha.lower() != document_sha.lower():
                    errors.append(
                        "approval.documentSha256 does not match the SHA-256 of "
                        f"{path_rels['documentPath']} (computed {actual_sha})"
                    )

            # 2. The public key must match the PINNED counsel fingerprint — never
            #    a key trusted on the evidence's say-so.
            pinned_key_ok = False
            if COUNSEL_PUBLIC_KEY_SHA256 == COUNSEL_KEY_PLACEHOLDER:
                errors.append(
                    "counsel signing key is not pinned: set COUNSEL_PUBLIC_KEY_SHA256 in "
                    "scripts/ci/check_agpl_legal_release_review.py to the real counsel public-key "
                    "fingerprint before claiming a signed approval"
                )
            elif "publicKeyPath" in resolved:
                fingerprint = _public_key_fingerprint(resolved["publicKeyPath"])
                if fingerprint is None:
                    errors.append(
                        f"approval.publicKeyPath is not a readable public key: {path_rels['publicKeyPath']}"
                    )
                elif fingerprint.lower() != COUNSEL_PUBLIC_KEY_SHA256.lower():
                    errors.append(
                        "approval.publicKeyPath does not match the pinned counsel signing key "
                        f"(fingerprint {fingerprint})"
                    )
                else:
                    pinned_key_ok = True

            # 3. The detached signature must verify over the document under the pinned key.
            if have_all_paths and pinned_key_ok:
                if not _verify_detached_signature(
                    document_path=resolved["documentPath"],
                    signature_path=resolved["signaturePath"],
                    public_key_path=resolved["publicKeyPath"],
                    signature_format=str(signature_format),
                ):
                    errors.append(
                        "approval signature failed verification: the detached signature at "
                        f"{path_rels['signaturePath']} does not validate over {path_rels['documentPath']} "
                        "under the pinned counsel key"
                    )

            # 4. Reject self-certifying approvals: the trust anchor (public key)
            #    must not be introduced or modified in the same diff as the approval.
            if "publicKeyPath" in path_rels:
                touched = _approval_diff_touches_public_key(verify_root, path_rels["publicKeyPath"])
                if touched is None:
                    errors.append(
                        "approval.publicKeyPath provenance is unverifiable (git history unavailable); "
                        "cannot confirm the counsel key was not introduced alongside this approval"
                    )
                elif touched:
                    errors.append(
                        "approval.publicKeyPath was added or modified in the same commit as this "
                        "approval; the counsel signing key must be pinned in a prior, separately "
                        "reviewed change"
                    )

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
