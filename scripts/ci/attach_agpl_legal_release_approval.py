#!/usr/bin/env python3
"""Create a signed AGPL/libsignal legal release-approval evidence packet.

This does not grant legal approval. It converts external counsel's detached
signature over a reviewed legal document into the exact JSON shape the release
gate accepts, then immediately verifies that packet with the same checker used
by CI.
"""

from __future__ import annotations

import argparse
from datetime import UTC, datetime
import json
import os
from pathlib import Path
import sys
from typing import Any

ROOT = Path(__file__).resolve().parents[2]
if str(ROOT) not in sys.path:
    sys.path.insert(0, str(ROOT))

from scripts.ci.check_agpl_legal_release_review import (  # noqa: E402
    REQUIRED_DOCS,
    SIGNATURE_FORMAT,
    sha256_file,
    validate_legal_release_review,
)


DEFAULT_CHANNELS = (
    "Mac App Store",
    "iOS App Store",
    "direct download",
    "browser extension marketplace",
    "npm",
    "Docker",
    "hosted service",
)
DEFAULT_SCOPE = (
    "AGPL-3.0-only product license",
    "MIT-compatible Nous/Hermes upstream boundary",
    "official libsignal runtime posture",
    "app store and commercial distribution terms",
    "corresponding source availability",
)


class ApprovalAttachError(RuntimeError):
    """Raised when approval evidence cannot be safely materialized."""


def _now_iso() -> str:
    return datetime.now(UTC).isoformat().replace("+00:00", "Z")


def _repo_relative_path(raw: Path, *, repo_root: Path, field: str) -> tuple[str, Path]:
    if raw.is_absolute():
        raise ApprovalAttachError(f"{field} must be repo-relative, not absolute: {raw}")
    resolved = (repo_root / raw).resolve()
    try:
        rel = resolved.relative_to(repo_root.resolve())
    except ValueError as exc:
        raise ApprovalAttachError(f"{field} must stay under repo root: {raw}") from exc
    if any(part == ".." for part in rel.parts):
        raise ApprovalAttachError(f"{field} must not traverse outside repo root: {raw}")
    return rel.as_posix(), resolved


def _require_existing_repo_file(raw: Path, *, repo_root: Path, field: str) -> tuple[str, Path]:
    rel, resolved = _repo_relative_path(raw, repo_root=repo_root, field=field)
    if not resolved.is_file():
        raise ApprovalAttachError(f"{field} does not exist: {rel}")
    return rel, resolved


def _parse_approved_at(value: str) -> str:
    raw = value.strip()
    if not raw:
        raise ApprovalAttachError("--approved-at is required")
    try:
        parsed = datetime.fromisoformat(raw.replace("Z", "+00:00"))
    except ValueError as exc:
        raise ApprovalAttachError("--approved-at must be an ISO-8601 timestamp") from exc
    if parsed.tzinfo is None:
        raise ApprovalAttachError("--approved-at must include a timezone, e.g. 2026-06-08T15:00:00Z")
    return parsed.astimezone(UTC).isoformat().replace("+00:00", "Z")


def write_atomic(path: Path, text: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp_path = path.with_name(f".{path.name}.legal-approval.tmp")
    try:
        with tmp_path.open("w", encoding="utf-8") as handle:
            handle.write(text)
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(tmp_path, path)
        dir_fd = os.open(str(path.parent), os.O_DIRECTORY)
        try:
            os.fsync(dir_fd)
        finally:
            os.close(dir_fd)
    except Exception:
        try:
            tmp_path.unlink()
        except FileNotFoundError:
            pass
        raise


def build_approval_packet(
    *,
    repo_root: Path,
    reviewer_name: str,
    approved_at: str,
    document: Path,
    signature: Path,
    public_key: Path,
    distribution_channels: list[str],
    review_scope: list[str] | None = None,
) -> dict[str, Any]:
    repo_root = repo_root.resolve()
    if not reviewer_name.strip():
        raise ApprovalAttachError("--reviewer-name is required")
    if not distribution_channels:
        raise ApprovalAttachError("at least one --distribution-channel is required")

    document_rel, document_abs = _require_existing_repo_file(document, repo_root=repo_root, field="--document")
    if document_rel not in REQUIRED_DOCS:
        raise ApprovalAttachError("--document must be one of: " + ", ".join(REQUIRED_DOCS))
    signature_rel, _ = _require_existing_repo_file(signature, repo_root=repo_root, field="--signature")
    public_key_rel, _ = _require_existing_repo_file(public_key, repo_root=repo_root, field="--public-key")

    approved_at_iso = _parse_approved_at(approved_at)
    packet: dict[str, Any] = {
        "schemaVersion": 1,
        "reviewStatus": "approved",
        "status": "approved",
        "reviewerRole": "external_counsel",
        "distributionChannels": distribution_channels,
        "reviewScope": review_scope or list(DEFAULT_SCOPE),
        "documents": list(REQUIRED_DOCS),
        "approval": {
            "reviewerName": reviewer_name.strip(),
            "approvedAt": approved_at_iso,
            "documentPath": document_rel,
            "documentSha256": sha256_file(document_abs),
            "signaturePath": signature_rel,
            "publicKeyPath": public_key_rel,
            "signatureFormat": SIGNATURE_FORMAT,
        },
        "generatedAt": _now_iso(),
        "generatedBy": "scripts/ci/attach_agpl_legal_release_approval.py",
        "explicitApprovalBoundary": (
            "This packet is release approval evidence only for the named distributionChannels "
            "and reviewed document hash. It is not a broader legal opinion."
        ),
    }
    errors = validate_legal_release_review(packet, require_approved=True, repo_root=repo_root)
    if errors:
        raise ApprovalAttachError("; ".join(errors))
    return packet


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repo-root", type=Path, default=ROOT)
    parser.add_argument("--reviewer-name", required=True)
    parser.add_argument("--approved-at", required=True)
    parser.add_argument("--document", type=Path, default=Path("docs/legal/AGPL_RELEASE_REVIEW_PACKET.md"))
    parser.add_argument("--signature", required=True, type=Path)
    parser.add_argument("--public-key", required=True, type=Path)
    parser.add_argument(
        "--distribution-channel",
        action="append",
        default=[],
        help="A channel external counsel approved. Repeat for every approved channel.",
    )
    parser.add_argument(
        "--use-required-channels",
        action="store_true",
        help="Use the full required release-channel list from docs/legal/AGPL_RELEASE_REVIEW_PACKET.md.",
    )
    parser.add_argument("--output", type=Path, default=Path("launch-evidence/latest-agpl-store-legal-packet.json"))
    parser.add_argument("--check", action="store_true", help="Validate and print the packet without writing it")
    args = parser.parse_args(argv)

    repo_root = args.repo_root.resolve()
    output = args.output if args.output.is_absolute() else repo_root / args.output
    channels = list(DEFAULT_CHANNELS) if args.use_required_channels else args.distribution_channel

    try:
        packet = build_approval_packet(
            repo_root=repo_root,
            reviewer_name=args.reviewer_name,
            approved_at=args.approved_at,
            document=args.document,
            signature=args.signature,
            public_key=args.public_key,
            distribution_channels=channels,
        )
    except (ApprovalAttachError, OSError, json.JSONDecodeError) as exc:
        print(f"FAIL: AGPL/libsignal legal approval was not attached: {exc}", file=sys.stderr)
        return 1

    text = json.dumps(packet, indent=2) + "\n"
    if args.check:
        print(text, end="")
        print("PASS: AGPL/libsignal legal approval packet verified; no file was written", file=sys.stderr)
        return 0

    write_atomic(output, text)
    try:
        display_path = output.relative_to(repo_root)
    except ValueError:
        display_path = output
    print(f"PASS: wrote approved AGPL/libsignal legal release evidence to {display_path}")
    print(
        "NEXT: attach the legal gate with "
        "python3 scripts/ci/attach_libsignal_runtime_evidence.py "
        "--gate store_and_counsel_approval --artifact "
        f"{display_path.as_posix() if isinstance(display_path, Path) else display_path}"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
