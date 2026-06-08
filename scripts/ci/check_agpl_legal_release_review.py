#!/usr/bin/env python3
"""Validate the AGPL/libsignal legal release-review evidence packet."""

from __future__ import annotations

import argparse
import hashlib
import json
import subprocess
import sys
from pathlib import Path
from typing import Any


ROOT = Path(__file__).resolve().parents[2]
DEFAULT_EVIDENCE = ROOT / "launch-evidence/latest-agpl-store-legal-packet.json"
REQUIRED_DOCS = (
    "docs/legal/AGPL_RELEASE_REVIEW_PACKET.md",
    "docs/legal/HERMES_GATEWAY_SIGNAL_REQUIRED_ROLLOUT.md",
)
SIGNATURE_FORMAT = "openssl-sha256-rsa"


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def validate_approval_signature(approval: dict[str, Any], *, repo_root: Path = ROOT) -> list[str]:
    errors: list[str] = []
    for field in (
        "reviewerName",
        "approvedAt",
        "documentPath",
        "documentSha256",
        "signaturePath",
        "publicKeyPath",
        "signatureFormat",
    ):
        if not approval.get(field):
            errors.append(f"approval.{field} is required for approved legal release evidence")
    if errors:
        return errors

    if approval.get("signatureFormat") != SIGNATURE_FORMAT:
        errors.append(f"approval.signatureFormat must be {SIGNATURE_FORMAT}")

    document_path = repo_root / str(approval["documentPath"])
    signature_path = repo_root / str(approval["signaturePath"])
    public_key_path = repo_root / str(approval["publicKeyPath"])
    if str(approval["documentPath"]) not in REQUIRED_DOCS:
        errors.append("approval.documentPath must be one of the required legal review documents")
    if not document_path.is_file():
        errors.append(f"approval.documentPath does not exist: {approval['documentPath']}")
    if not signature_path.is_file():
        errors.append(f"approval.signaturePath does not exist: {approval['signaturePath']}")
    if not public_key_path.is_file():
        errors.append(f"approval.publicKeyPath does not exist: {approval['publicKeyPath']}")
    if errors:
        return errors

    actual_hash = sha256_file(document_path)
    if approval.get("documentSha256") != actual_hash:
        errors.append(f"approval.documentSha256 mismatch: {actual_hash} != {approval.get('documentSha256')}")
        return errors

    result = subprocess.run(
        [
            "openssl",
            "dgst",
            "-sha256",
            "-verify",
            str(public_key_path),
            "-signature",
            str(signature_path),
            str(document_path),
        ],
        cwd=repo_root,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=False,
    )
    if result.returncode != 0:
        errors.append(f"approval signature verification failed: {(result.stderr or result.stdout).strip()}")
    return errors


def validate_legal_release_review(
    data: dict[str, Any],
    *,
    require_approved: bool = True,
    repo_root: Path = ROOT,
) -> list[str]:
    """Return legal-review blockers.

    The required review scope includes app store and commercial distribution terms,
    must be performed by external_counsel, must name the exact
    distributionChannels covered by the approval, and is wired into
    check_burnbar_license_posture.py.
    """

    errors: list[str] = []
    status = data.get("reviewStatus") or data.get("status")
    if require_approved and status != "approved":
        errors.append(f"legal review is not approved: {status!r}")
    if data.get("reviewerRole") != "external_counsel":
        errors.append("reviewerRole must be external_counsel")
    channels = data.get("distributionChannels") or data.get("counselMustDecide") or []
    if not channels:
        errors.append("distributionChannels or counselMustDecide must be present")
    non_approval = data.get("explicitNonApproval", "")
    if status != "approved" and "not legal approval" not in non_approval:
        errors.append("pending evidence must explicitly say it is not legal approval")
    if status == "approved":
        errors.extend(validate_approval_signature(data.get("approval") or {}, repo_root=repo_root))
    return errors


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--evidence", type=Path, default=DEFAULT_EVIDENCE)
    parser.add_argument("--repo-root", type=Path, default=ROOT)
    parser.add_argument(
        "--allow-pending",
        action="store_true",
        help="Validate packet shape for CI drift checks without treating pending evidence as release approval.",
    )
    args = parser.parse_args(argv)

    repo_root = args.repo_root.resolve()
    evidence_path = args.evidence if args.evidence.is_absolute() else repo_root / args.evidence

    missing_docs = [rel_path for rel_path in REQUIRED_DOCS if not (repo_root / rel_path).is_file()]
    if missing_docs:
        print("FAIL: missing legal review document(s): " + ", ".join(missing_docs), file=sys.stderr)
        return 1

    try:
        data = json.loads(evidence_path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        print(f"FAIL: legal release review evidence is unreadable: {exc}", file=sys.stderr)
        return 1

    require_approved = not args.allow_pending
    errors = validate_legal_release_review(data, require_approved=require_approved, repo_root=repo_root)
    if errors:
        print("FAIL: AGPL/libsignal legal release review is not release-approved", file=sys.stderr)
        for error in errors:
            print(f"- {error}", file=sys.stderr)
        return 1
    status = data.get("reviewStatus") or data.get("status")
    if args.allow_pending and status != "approved":
        print(
            "PASS: AGPL/libsignal legal review packet shape is valid, "
            f"but it is NOT release-approved (status={status!r})"
        )
    else:
        print("PASS: AGPL/libsignal legal release review evidence is approved and signature-verified")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
