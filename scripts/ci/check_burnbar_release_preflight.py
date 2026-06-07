#!/usr/bin/env python3
"""Fail-closed BurnBar product release preflight.

This is the release-manager entrypoint. PR posture checks may validate packet
shape while legal/runtime work is pending, but this command only passes when the
BurnBar product lane is actually release-ready: clean source provenance, runtime
readiness, and signed external-counsel approval.
"""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
DEFAULT_LEGAL_EVIDENCE_REL = Path("launch-evidence/latest-agpl-store-legal-packet.json")
DEFAULT_LEGAL_EVIDENCE = ROOT / DEFAULT_LEGAL_EVIDENCE_REL
LEGAL_TEMPLATE = Path("docs/legal/agpl-release-review.evidence.template.json")
LEGAL_VALIDATOR = "python3 scripts/ci/check_agpl_legal_release_review.py --evidence launch-evidence/latest-agpl-store-legal-packet.json"


def source_provenance_blockers(repo_root: Path) -> list[str]:
    sys.path.insert(0, str(repo_root))
    try:
        from scripts.ci.write_burnbar_source_provenance import (
            build_source_provenance_manifest,
            release_preflight_blockers,
        )
    finally:
        sys.path.pop(0)

    try:
        manifest = build_source_provenance_manifest(repo_root=repo_root)
    except Exception as exc:  # pragma: no cover - defensive aggregation path
        return [f"source provenance could not be generated: {exc}"]
    return release_preflight_blockers(manifest)


def legal_review_blockers(evidence_path: Path, repo_root: Path) -> list[str]:
    sys.path.insert(0, str(repo_root))
    try:
        from scripts.ci.check_agpl_legal_release_review import validate_legal_release_review
    finally:
        sys.path.pop(0)

    if not evidence_path.is_file():
        return [
            f"legal release review evidence is missing: {evidence_path}",
            (
                "legal release review required action: create a signed external_counsel approval packet at "
                f"{DEFAULT_LEGAL_EVIDENCE_REL} using {LEGAL_TEMPLATE}; validate with "
                f"{LEGAL_VALIDATOR} (without --allow-pending)"
            ),
        ]

    try:
        data = json.loads(evidence_path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        return [f"legal release review evidence is unreadable: {exc}"]

    status = data.get("reviewStatus") or data.get("status")
    if status != "approved":
        blockers = [f"legal release review is not approved: {status!r}"]
        non_approval = data.get("explicitNonApproval", "")
        if "not legal approval" not in non_approval:
            blockers.append("legal release review pending evidence must explicitly say it is not legal approval")
        blockers.append(
            "legal release review required action: replace pending evidence with an approved external_counsel "
            f"packet signed over the review document hash; validate with {LEGAL_VALIDATOR} (without --allow-pending)"
        )
        return blockers

    return [f"legal release review: {error}" for error in validate_legal_release_review(data, require_approved=True)]


def collect_blockers(*, repo_root: Path, legal_evidence: Path) -> list[str]:
    blockers = []
    blockers.extend(source_provenance_blockers(repo_root))
    blockers.extend(legal_review_blockers(legal_evidence, repo_root))
    return blockers


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repo-root", type=Path, default=ROOT)
    parser.add_argument("--legal-evidence", type=Path, default=DEFAULT_LEGAL_EVIDENCE)
    args = parser.parse_args(argv)

    repo_root = args.repo_root.resolve()
    legal_evidence = args.legal_evidence
    if not legal_evidence.is_absolute():
        legal_evidence = repo_root / legal_evidence

    blockers = collect_blockers(repo_root=repo_root, legal_evidence=legal_evidence)
    if blockers:
        print("HOLD: BurnBar product release preflight is not ready", file=sys.stderr)
        for blocker in blockers:
            print(f"- {blocker}", file=sys.stderr)
        return 1

    print("PASS: BurnBar product release preflight is ready")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
