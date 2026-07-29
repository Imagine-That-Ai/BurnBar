#!/usr/bin/env python3
"""Create an append-only receipt annulling an unshipped Domain Core activation."""

from __future__ import annotations

import argparse
import hashlib
import importlib.util
import sys
from datetime import UTC, datetime
from pathlib import Path
from typing import Any


ROOT = Path(__file__).resolve().parents[2]
GATE_PATH = ROOT / "scripts/ci/verify-domain-core-legacy-deletion.py"
SPEC = importlib.util.spec_from_file_location("domain_core_legacy_deletion_gate", GATE_PATH)
if SPEC is None or SPEC.loader is None:
    raise RuntimeError(f"cannot load {GATE_PATH}")
GATE = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = GATE
SPEC.loader.exec_module(GATE)

PROMOTION_WRITER = ROOT / "scripts/ops/create-domain-core-promotion-receipt.py"
PROMOTION_SPEC = importlib.util.spec_from_file_location(
    "domain_core_promotion_writer",
    PROMOTION_WRITER,
)
if PROMOTION_SPEC is None or PROMOTION_SPEC.loader is None:
    raise RuntimeError(f"cannot load {PROMOTION_WRITER}")
WRITER = importlib.util.module_from_spec(PROMOTION_SPEC)
sys.modules[PROMOTION_SPEC.name] = WRITER
PROMOTION_SPEC.loader.exec_module(WRITER)


def load(path: Path, label: str) -> dict[str, Any]:
    return GATE.require_object(GATE.load_json(path, label), label)


def create_receipt(
    repo_root: Path,
    *,
    row_id: str,
    generation: int,
    activation_commit: str,
    advanced_main_commit: str,
    evidence: list[str],
    approved_by: str,
    approved_at: str,
) -> dict[str, Any]:
    if row_id not in GATE.ROW_IDS:
        raise GATE.GateError(f"unknown row id: {row_id}")
    GATE.positive_integer(generation, "authority generation")
    if not isinstance(approved_by, str) or not GATE.RECEIPT_ACTOR_RE.fullmatch(approved_by):
        raise GATE.GateError("approvedBy must be a GitHub handle")
    approved = GATE.parse_rfc3339_utc(approved_at, "approvedAt")
    if approved > datetime.now(UTC):
        raise GATE.GateError("approvedAt cannot be in the future")
    if not evidence or len(evidence) != len(set(evidence)):
        raise GATE.GateError("evidence must be a non-empty unique list")
    evidence = sorted(GATE.validate_https_uri(uri, "evidence URI") for uri in evidence)

    promotion_relative = f"{GATE.RECEIPT_ROOT}/{row_id}/{generation}/promotion.json"
    promotion = GATE.validate_receipt(
        repo_root,
        promotion_relative,
        row_id,
        generation,
        "promotion",
        set(),
    )
    promotion_document = load(repo_root / promotion_relative, "promotion receipt")
    pointer = GATE.require_object(
        promotion_document.get("promotionAttestation"),
        "promotion attestation pointer",
    )
    attestation = load(
        GATE.secure_path(
            repo_root,
            pointer["path"],
            "promotion attestation",
            must_exist=True,
        ),
        "promotion attestation",
    )
    candidate = GATE.require_object(attestation.get("candidate"), "promotion candidate")
    candidate_commit = candidate["candidateCommit"]
    activation_commit = GATE.require_commit(repo_root, activation_commit, "activation commit")
    activation = GATE.validate_activation_closure(
        repo_root,
        candidate_commit,
        activation_commit,
    )
    advanced_main_commit = GATE.require_commit(
        repo_root,
        advanced_main_commit,
        "advanced main commit",
    )

    modes, _ = GATE.public_production_profile(repo_root)
    domain = GATE.profile_domain_for_row(row_id)
    if modes[domain] != "legacy":
        raise GATE.GateError(
            f"public-production.{domain} must be legacy in the annulment candidate"
        )

    receipt = {
        "schemaVersion": 2,
        "rowId": row_id,
        "authorityGeneration": generation,
        "transition": "annulment",
        "status": "active",
        "evidence": evidence,
        "approvedBy": approved_by,
        "approvedAt": approved_at,
        "commit": advanced_main_commit,
        "activationAnnulment": {
            "promotionReceiptSha256": promotion.digest,
            "candidate": candidate,
            "activation": activation,
            "advancedMainCommit": advanced_main_commit,
            "reason": "release_train_advanced_before_stable_receipt",
            "replacementCandidateRequired": True,
        },
    }
    encoded = WRITER.serialized(receipt)
    annulment = GATE.Receipt(
        path=f"{GATE.RECEIPT_ROOT}/{row_id}/{generation}/annulment.json",
        transition="annulment",
        generation=generation,
        approved_at=approved,
        commit=advanced_main_commit,
        digest=hashlib.sha256(encoded).hexdigest(),
        evidence=tuple(evidence),
        payload=receipt["activationAnnulment"],
        approved_by=approved_by,
    )
    GATE.validate_activation_annulment_receipt(
        repo_root,
        row_id,
        generation,
        annulment,
        promotion,
    )
    return receipt


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repo-root", type=Path, default=ROOT)
    parser.add_argument("--row-id", required=True)
    parser.add_argument("--authority-generation", required=True, type=int)
    parser.add_argument("--activation-commit", required=True)
    parser.add_argument("--advanced-main-commit", required=True)
    parser.add_argument("--evidence", action="append", default=[])
    parser.add_argument("--approved-by", required=True)
    parser.add_argument("--approved-at", required=True)
    args = parser.parse_args(argv)
    repo_root = args.repo_root.resolve(strict=True)
    try:
        receipt = create_receipt(
            repo_root,
            row_id=args.row_id,
            generation=args.authority_generation,
            activation_commit=args.activation_commit,
            advanced_main_commit=args.advanced_main_commit,
            evidence=args.evidence,
            approved_by=args.approved_by,
            approved_at=args.approved_at,
        )
        output = (
            repo_root
            / GATE.RECEIPT_ROOT
            / args.row_id
            / str(args.authority_generation)
            / "annulment.json"
        )
        WRITER.append_only(output, WRITER.serialized(receipt))
    except (GATE.GateError, OSError, KeyError, TypeError, ValueError) as error:
        print(f"ERROR: cannot create activation-annulment receipt: {error}", file=sys.stderr)
        return 1
    print(output.relative_to(repo_root).as_posix())
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
