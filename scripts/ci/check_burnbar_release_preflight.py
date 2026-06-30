#!/usr/bin/env python3
"""Fail-closed BurnBar product release preflight.

This is the release-manager entrypoint. PR posture checks may validate packet
shape while legal/runtime work is pending, but this command only passes when the
BurnBar product lane is actually release-ready: clean source provenance, runtime
readiness, and signed external-counsel approval.
"""

from __future__ import annotations

import argparse
import importlib.util
import json
import sys
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
DEFAULT_LEGAL_EVIDENCE = ROOT / "launch-evidence/latest-agpl-store-legal-packet.json"


def load_ci_module(repo_root: Path, module_name: str):
    if not module_name.isidentifier():
        raise ValueError(f"release preflight helper name is invalid: {module_name!r}")

    module_path = repo_root / "scripts" / "ci" / f"{module_name}.py"
    if not module_path.is_file():
        raise FileNotFoundError(f"required release preflight helper is missing: {module_path}")

    spec = importlib.util.spec_from_file_location(f"openburnbar_ci_{module_name}", module_path)
    if spec is None or spec.loader is None:
        raise ImportError(f"release preflight helper could not be loaded: {module_path}")

    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def source_provenance_blockers(repo_root: Path, *, include_runtime_readiness: bool = True) -> list[str]:
    provenance = load_ci_module(repo_root, "write_burnbar_source_provenance")

    try:
        manifest = provenance.build_source_provenance_manifest(repo_root=repo_root)
    except Exception as exc:  # pragma: no cover - defensive aggregation path
        return [f"source provenance could not be generated: {exc}"]
    if include_runtime_readiness:
        return provenance.release_preflight_blockers(manifest)
    return provenance.source_integrity_blockers(manifest)


def legal_review_blockers(
    evidence_path: Path,
    repo_root: Path,
    *,
    allow_owner_emergency_approval: bool = False,
) -> list[str]:
    legal_review = load_ci_module(repo_root, "check_agpl_legal_release_review")

    if not evidence_path.is_file():
        return [f"legal release review evidence is missing: {evidence_path}"]

    try:
        data = json.loads(evidence_path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        return [f"legal release review evidence is unreadable: {exc}"]

    status = data.get("reviewStatus") or data.get("status")
    owner_status = getattr(legal_review, "OWNER_ATTESTED_SOFT_APPROVAL_STATUS", "owner_attested_soft_approval")
    if allow_owner_emergency_approval and status == owner_status:
        validator = getattr(legal_review, "validate_owner_attested_soft_approval", None)
        if validator is None:
            return ["owner emergency approval validator is missing"]
        return [
            f"owner emergency approval: {error}"
            for error in validator(data, repo_root=repo_root)
        ]

    if status != "approved":
        blockers = [f"legal release review is not approved: {status!r}"]
        non_approval = data.get("explicitNonApproval", "")
        if "not legal approval" not in non_approval:
            blockers.append("legal release review pending evidence must explicitly say it is not legal approval")
        return blockers

    return [
        f"legal release review: {error}"
        for error in legal_review.validate_legal_release_review(data, require_approved=True)
    ]


def collect_blockers(
    *,
    repo_root: Path,
    legal_evidence: Path,
    include_runtime_readiness: bool = True,
    include_legal_review: bool = True,
    allow_owner_emergency_approval: bool = False,
) -> list[str]:
    blockers = []
    runtime_gate_required = include_runtime_readiness
    if allow_owner_emergency_approval and include_legal_review:
        runtime_gate_required = False
    blockers.extend(source_provenance_blockers(repo_root, include_runtime_readiness=runtime_gate_required))
    if include_legal_review:
        blockers.extend(
            legal_review_blockers(
                legal_evidence,
                repo_root,
                allow_owner_emergency_approval=allow_owner_emergency_approval,
            )
        )
    return blockers


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repo-root", type=Path, default=ROOT)
    parser.add_argument("--legal-evidence", type=Path, default=DEFAULT_LEGAL_EVIDENCE)
    parser.add_argument(
        "--source-provenance-only",
        action="store_true",
        help="Validate clean release source and required corresponding-source files without runtime/legal holds.",
    )
    parser.add_argument(
        "--allow-owner-emergency-approval",
        action="store_true",
        help=(
            "Allow a structured owner-attested soft-approval packet to satisfy "
            "runtime/legal release holds for an emergency artifact release. The "
            "default path still requires signed external-counsel approval."
        ),
    )
    args = parser.parse_args(argv)

    repo_root = args.repo_root.resolve()
    legal_evidence = args.legal_evidence
    if not legal_evidence.is_absolute():
        legal_evidence = repo_root / legal_evidence

    blockers = collect_blockers(
        repo_root=repo_root,
        legal_evidence=legal_evidence,
        include_runtime_readiness=not args.source_provenance_only,
        include_legal_review=not args.source_provenance_only,
        allow_owner_emergency_approval=args.allow_owner_emergency_approval and not args.source_provenance_only,
    )
    if blockers:
        if args.source_provenance_only:
            print("HOLD: BurnBar source provenance preflight is not ready", file=sys.stderr)
        else:
            print("HOLD: BurnBar product release preflight is not ready", file=sys.stderr)
        for blocker in blockers:
            print(f"- {blocker}", file=sys.stderr)
        return 1

    if args.source_provenance_only:
        print("PASS: BurnBar source provenance preflight is ready")
    else:
        print("PASS: BurnBar product release preflight is ready")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
