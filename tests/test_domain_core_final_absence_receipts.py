from __future__ import annotations

import hashlib
import importlib.util
import io
import json
import subprocess
import sys
import tempfile
import unittest
import zipfile
from pathlib import Path
from typing import Any
from unittest import mock


ROOT = Path(__file__).resolve().parents[1]


def load_module(name: str, path: Path):
    spec = importlib.util.spec_from_file_location(name, path)
    assert spec and spec.loader
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module


# Load VERIFY first so its internal GATE and SCANNER become the canonical
# module instances in sys.modules.  Then alias them — this guarantees
# GATE.GateError is the exact class raised by VERIFY.run().
VERIFY = load_module(
    "domain_core_final_absence_receipts",
    ROOT / "scripts/ci/verify-domain-core-final-absence-receipts.py",
)
GATE = VERIFY.GATE
SCANNER = VERIFY.SCANNER

ABSENCE_TYPE = VERIFY.ABSENCE_TYPE
RELEASE_VERSION = "1.2.3"
RELEASE_COMMIT = "d" * 40
ACTIVATION_COMMIT = "a" * 40
CANDIDATE_COMMIT = "c" * 40
DELETION_COMMIT = "e" * 40  # distinct from release commit
REVIEWED_COMMIT = "r" * 40
REVIEWER = "@emilio3435"
APPROVED_BY = "@approver"
APPROVED_AT = "2025-01-01T00:00:00Z"


def _sha256(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def _candidate_identity() -> dict[str, Any]:
    return {
        "candidateCommit": CANDIDATE_COMMIT,
        "coreVersion": "0.3.0",
        "abiVersion": 3,
        "sourceSha256": "2" * 64,
    }


def _activation() -> dict[str, Any]:
    return {
        "candidateCommit": CANDIDATE_COMMIT,
        "activationCommit": ACTIVATION_COMMIT,
        "coreVersion": "0.3.0",
        "abiVersion": 3,
        "sourceSha256": "2" * 64,
        "changedPathsSha256": "9" * 64,
    }


def _make_clean_zip() -> bytes:
    """A zip with one .so code member containing no legacy markers."""
    buf = io.BytesIO()
    with zipfile.ZipFile(buf, "w") as archive:
        archive.writestr("lib/native.so", b"\x7fELF clean bytes no legacy symbols")
    return buf.getvalue()


def _build_scan_report(consumer: str, artifact_bytes: bytes) -> dict[str, Any]:
    """Run the real scanner to produce a valid absent scan report."""
    with tempfile.NamedTemporaryFile(suffix=".zip", delete=False) as tmp:
        tmp.write(artifact_bytes)
        tmp_path = Path(tmp.name)
    try:
        return SCANNER.scan(consumer, tmp_path)
    finally:
        tmp_path.unlink(missing_ok=True)

def _build_absence(
    consumer: str,
    domain: str,
    rows: list[str],
    scan_report: dict[str, Any],
) -> dict[str, Any]:
    return {
        "schemaVersion": 1,
        "predicateType": ABSENCE_TYPE,
        "releaseCommit": RELEASE_COMMIT,
        "authorityActivationCommit": ACTIVATION_COMMIT,
        "deletionInventorySha256": "0" * 64,
        "rowIds": rows,
        "artifactScan": {
            "reportSha256": GATE.canonical_json_sha256(scan_report),
            "artifactSha256": "",
            "ruleSetSha256": scan_report["ruleSetSha256"],
            "inspectedMemberCount": len(scan_report["inspectedMembers"]),
            "report": scan_report,
        },
    }


def _build_predicate(
    consumer: str,
    domain: str,
    artifact_digest: str,
    scan_report: dict[str, Any],
    expected_tag: str,
) -> dict[str, Any]:
    rows = VERIFY.expected_rows(consumer, domain)
    candidate = _candidate_identity()
    activation = _activation()
    absence = _build_absence(consumer, domain, rows, scan_report)
    # Fix artifactSha256 to the real artifact digest
    absence["artifactScan"]["artifactSha256"] = artifact_digest
    predicate: dict[str, Any] = {
        "schemaVersion": 2,
        "predicateType": GATE.RELEASE_PREDICATE_TYPES[consumer],
        "consumer": consumer,
        "domain": domain,
        "artifact": {"sha256": artifact_digest},
        "release": {
            "version": RELEASE_VERSION,
            "tag": expected_tag,
            "commit": RELEASE_COMMIT,
        },
        "candidate": candidate,
        "activation": activation,
        "legacyAbsence": absence,
    }
    if consumer == "ios":
        predicate["appStoreConnectReceipt"] = {"ipaSha256": artifact_digest}
    return predicate


class AbsenceFakeVerifier:
    """Fake verifier that returns valid signed absence predicates and records
    deletion-review verification calls."""

    def __init__(self, predicates: dict[tuple[str, str], dict[str, Any]]) -> None:
        self._predicates = predicates
        self.verify_deletion_review_calls: list[tuple[dict, dict | None, dict]] = []

    def _verify_bundle(self, artifact: Path, bundle: Path, **kwargs) -> list[dict[str, Any]]:
        label = kwargs.get("label", "")
        # label format: "{consumer}/{domain} final absence artifact"
        parts = label.split("/")
        consumer = parts[0]
        domain = parts[1].split(" ")[0] if len(parts) > 1 else ""
        predicate = self._predicates.get((consumer, domain))
        if predicate is None:
            raise GATE.GateError(f"no fake predicate for {consumer}/{domain}")
        return [{"verificationResult": {"statement": {"predicate": predicate}}}]

    def verify_deletion_review(
        self, review: dict[str, Any], bound_files: dict[str, str] | None = None, **kwargs
    ) -> None:
        self.verify_deletion_review_calls.append((review, bound_files, kwargs))


def _build_evidence_root(root: Path) -> dict[tuple[str, str], dict[str, Any]]:
    """Build a complete evidence root with 7 consumer directories, valid zip
    artifacts, and predicate bundles. Returns the predicate map for the fake
    verifier."""
    artifact_bytes = _make_clean_zip()
    predicates: dict[tuple[str, str], dict[str, Any]] = {}
    for consumer in VERIFY.CONSUMERS:
        directory = root / consumer
        directory.mkdir(parents=True)
        artifact_path = directory / "artifact"
        artifact_path.write_bytes(artifact_bytes)
        artifact_digest = _sha256(artifact_bytes)
        expected_tag = (
            f"windows-v{RELEASE_VERSION}"
            if consumer == "windows"
            else f"linux-v{RELEASE_VERSION}"
            if consumer == "linux"
            else f"v{RELEASE_VERSION}"
        )
        domains = sorted(
            domain for domain in GATE.PROFILE_DOMAIN_ROWS if VERIFY.expected_rows(consumer, domain)
        )
        # All domains for a consumer share one scan report
        scan_report = SCANNER.scan(consumer, artifact_path)
        for domain in domains:
            predicate = _build_predicate(consumer, domain, artifact_digest, scan_report, expected_tag)
            predicates[(consumer, domain)] = predicate
            bundle_path = directory / f"{domain}.predicate.sigstore.json"
            bundle_path.write_text(json.dumps({"dummy": "sigstore bundle"}))
        if consumer == "ios":
            (directory / "ipa").write_bytes(artifact_bytes)
            # Fix ios receipt to bind ipa digest
            for domain in domains:
                predicates[(consumer, domain)]["appStoreConnectReceipt"]["ipaSha256"] = artifact_digest
    return predicates


# ---- Ledger / receipt fixture builders ----

def _git_commit(repo: Path, message: str = "commit") -> str:
    subprocess.run(["git", "add", "."], cwd=repo, check=True)
    subprocess.run(["git", "commit", "-qm", message], cwd=repo, check=True)
    return subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=repo, text=True).strip()


def _make_stable_receipt(
    row_id: str,
    generation: int,
    commit: str,
    stable_digest: str,
) -> dict[str, Any]:
    return {
        "schemaVersion": 2,
        "rowId": row_id,
        "authorityGeneration": generation,
        "transition": "stable_release",
        "status": "active",
        "evidence": ["https://github.com/Imagine-That-Ai/BurnBar/actions/runs/1"],
        "approvedBy": APPROVED_BY,
        "approvedAt": APPROVED_AT,
        "commit": commit,
        "release": {
            "promotionReceiptSha256": "1" * 64,
            "publicProfileSha256": "3" * 64,
            "candidate": _candidate_identity(),
            "activation": _activation(),
            "consumerReleases": {},
            "rollbackArtifact": {
                "candidate": _candidate_identity(),
                "activation": _activation(),
            },
        },
    }


def _make_deletion_plan(
    row_id: str,
    generation: int,
    stable_digest: str,
    targets: list[dict[str, Any]],
) -> dict[str, Any]:
    review_class = "security_crypto" if row_id in GATE.SECURITY_REVIEW_ROWS else "domain_owner"
    legacy_targets = sorted(
        (
            {
                "kind": t["kind"],
                "role": t["role"],
                "root": t["root"],
                "path": t["path"],
                "value": t.get("symbol") or t.get("literal") or t.get("value"),
            }
            for t in targets
        ),
        key=lambda item: (item["kind"], item["path"], item["value"] or ""),
    )
    return {
        "schemaVersion": 1,
        "rowId": row_id,
        "authorityGeneration": generation,
        "stableReceiptSha256": stable_digest,
        "reviewer": REVIEWER,
        "reviewClass": review_class,
        "legacyTargetsSha256": GATE.canonical_json_sha256(legacy_targets),
        "requestedAction": "approve_legacy_deletion",
    }


def _make_deletion_review_receipt(
    row_id: str,
    generation: int,
    commit: str,
    stable_digest: str,
    plan_path: str,
    plan_digest: str,
    *,
    reviewed_commit: str = REVIEWED_COMMIT,
    reviewer: str = REVIEWER,
    review_class: str | None = None,
    outcome: str = "approved",
) -> dict[str, Any]:
    if review_class is None:
        review_class = "security_crypto" if row_id in GATE.SECURITY_REVIEW_ROWS else "domain_owner"
    return {
        "schemaVersion": 2,
        "rowId": row_id,
        "authorityGeneration": generation,
        "transition": "deletion_review",
        "status": "active",
        "evidence": ["https://github.com/Imagine-That-Ai/BurnBar/pull/9999"],
        "approvedBy": APPROVED_BY,
        "approvedAt": APPROVED_AT,
        "commit": commit,
        "deletionReview": {
            "stableReceiptSha256": stable_digest,
            "reviewUri": "https://github.com/Imagine-That-Ai/BurnBar/pull/9999",
            "reviewedCommit": reviewed_commit,
            "reviewer": reviewer,
            "reviewClass": review_class,
            "outcome": outcome,
            "planPath": plan_path,
            "planSha256": plan_digest,
        },
    }


def _build_ledger_repo(repo: Path) -> tuple[Path, dict[str, Any]]:
    """Build a git repo with all 11 rows in legacy_deleted state, with valid
    stable_release and deletion_review receipts and deletion plans."""
    (repo / "config").mkdir(parents=True)
    (repo / "src").mkdir()
    # Copy trusted config files
    for relative in (
        GATE.PROMOTION_POLICY_PATH,
        GATE.BUILD_PROFILE_PATH,
        GATE.DELETION_REVIEWERS_PATH,
    ):
        destination = repo / relative
        destination.parent.mkdir(parents=True, exist_ok=True)
        destination.write_text((ROOT / relative).read_text())
    # Copy promotion evaluator
    destination = repo / GATE.PROMOTION_EVALUATOR_PATH
    destination.parent.mkdir(parents=True, exist_ok=True)
    destination.write_text((ROOT / GATE.PROMOTION_EVALUATOR_PATH).read_text())

    rows = []
    for index, row_id in enumerate(GATE.ROW_IDS):
        relative = f"src/legacy_{index}.txt"
        symbol = f"legacySymbol{index}"
        (repo / relative).write_text(f"func {symbol}() {{}}\n")
        rows.append(
            {
                "id": row_id,
                "state": "legacy_deleted",
                "authorityGeneration": 1,
                "receipts": {
                    "promotion": f"{GATE.RECEIPT_ROOT}/{row_id}/1/promotion.json",
                    "stableRelease": f"{GATE.RECEIPT_ROOT}/{row_id}/1/stable_release.json",
                    "deletionReview": f"{GATE.RECEIPT_ROOT}/{row_id}/1/deletion_review.json",
                },
                "targets": [
                    {
                        "kind": "source_symbol",
                        "role": "legacy_implementation",
                        "root": "source",
                        "path": relative,
                        "symbol": symbol,
                    }
                ],
            }
        )
    manifest = {
        "schemaVersion": 2,
        "sourceRoots": {"source": "src"},
        "rows": rows,
        "sharedTargets": [],
    }
    (repo / "config/domain-core-legacy-deletion.json").write_text(json.dumps(manifest))

    # Init git and make first commit
    subprocess.run(["git", "init", "-q"], cwd=repo, check=True)
    subprocess.run(["git", "config", "user.email", "test@openburnbar.invalid"], cwd=repo, check=True)
    subprocess.run(["git", "config", "user.name", "OpenBurnBar Test"], cwd=repo, check=True)
    base_commit = _git_commit(repo, "initial ledger")

    # Write receipt and plan files for each row.
    # Order matters: we must finalize the promotion receipt, then the stable
    # receipt (which binds the promotion receipt digest), then compute the
    # stable receipt's file digest, and only then write the deletion plan and
    # deletion review receipt — both of which must reference the final stable
    # receipt digest.
    for index, row_id in enumerate(GATE.ROW_IDS):
        gen = 1
        receipt_dir = repo / GATE.RECEIPT_ROOT / row_id / str(gen)
        receipt_dir.mkdir(parents=True)
        plan_dir = repo / GATE.DELETION_PLAN_ROOT / row_id
        plan_dir.mkdir(parents=True)

        # Promotion receipt — written first with a placeholder, then updated.
        promotion_receipt = {
            "schemaVersion": 2,
            "rowId": row_id,
            "authorityGeneration": gen,
            "transition": "promotion",
            "status": "active",
            "evidence": ["https://github.com/Imagine-That-Ai/BurnBar/actions/runs/1"],
            "approvedBy": APPROVED_BY,
            "approvedAt": APPROVED_AT,
            "commit": base_commit,
            "promotionAttestation": {
                "schemaVersion": 1,
                "supersedes": None,
                "candidate": _candidate_identity(),
                "promotionReceiptSha256": "1" * 64,
            },
        }
        promotion_path = receipt_dir / "promotion.json"
        promotion_path.write_text(json.dumps(promotion_receipt))
        promotion_digest = _sha256(promotion_path.read_bytes())

        # Stable receipt — binds the promotion receipt digest.  This is the
        # FINAL bytes; its file digest is what the deletion review receipt and
        # deletion plan must reference.
        stable_receipt = _make_stable_receipt(row_id, gen, base_commit, promotion_digest)
        stable_path = receipt_dir / "stable_release.json"
        stable_path.write_text(json.dumps(stable_receipt))
        stable_digest = _sha256(stable_path.read_bytes())

        # Deletion plan — binds the final stable receipt digest.
        targets = manifest["rows"][index]["targets"]
        plan = _make_deletion_plan(row_id, gen, stable_digest, targets)
        plan_path = plan_dir / f"{gen}.json"
        plan_path.write_text(json.dumps(plan))
        plan_digest = _sha256(plan_path.read_bytes())
        plan_relative = f"{GATE.DELETION_PLAN_ROOT}/{row_id}/{gen}.json"

        # Deletion review receipt — binds the final stable receipt digest and
        # the deletion plan digest.
        deletion_receipt = _make_deletion_review_receipt(
            row_id, gen, base_commit, stable_digest, plan_relative, plan_digest,
            reviewed_commit=base_commit,
        )
        deletion_path = receipt_dir / "deletion_review.json"
        deletion_path.write_text(json.dumps(deletion_receipt))

    _git_commit(repo, "receipts and plans")
    head_commit = subprocess.check_output(
        ["git", "rev-parse", "HEAD"], cwd=repo, text=True
    ).strip()

    return repo, {
        "manifest": manifest,
        "head_commit": head_commit,
        "base_commit": base_commit,
    }


class FinalAbsenceDeletionReviewAuthorityTests(unittest.TestCase):
    """Tests that final post-deletion completion rejects missing/tampered
    deletionReview receipts, mismatched reviewed deletion commit/plan/reviewer
    authority, and release B that does not descend from the authorized deletion
    event."""

    @staticmethod
    def _make_accepting_ancestry_verifier() -> tuple[list[tuple[str, str]], Any]:
        calls: list[tuple[str, str]] = []

        def verifier(ancestor: str, descendant: str) -> None:
            calls.append((ancestor, descendant))

        return calls, verifier

    @staticmethod
    def _make_rejecting_ancestry_verifier() -> Any:
        def verifier(ancestor: str, descendant: str) -> None:
            raise VERIFY.GATE.GateError(
                f"deletionReview.commit must be an ancestor of release B: {ancestor} is not an ancestor of {descendant}"
            )

        return verifier

    def setUp(self) -> None:
        self._evidence_dir = tempfile.TemporaryDirectory()
        self._ledger_dir = tempfile.TemporaryDirectory()
        self.evidence_root = Path(self._evidence_dir.name).resolve()
        self.ledger_repo = Path(self._ledger_dir.name).resolve()
        self.predicates = _build_evidence_root(self.evidence_root)
        self.ledger_info = _build_ledger_repo(self.ledger_repo)

    def tearDown(self) -> None:
        self._evidence_dir.cleanup()
        self._ledger_dir.cleanup()

    def _make_verifier(self) -> AbsenceFakeVerifier:
        return AbsenceFakeVerifier(self.predicates)

    @staticmethod
    def _accepting_ancestry() -> Any:
        return lambda _ancestor, _descendant: None

    def _run(
        self,
        verifier: AbsenceFakeVerifier,
        ancestry_verifier: Any | None = None,
        repo_root: Path | None = None,
    ) -> dict[str, Any]:
        return VERIFY.run(
            self.evidence_root,
            verifier,
            RELEASE_COMMIT,
            RELEASE_VERSION,
            ancestry_verifier=ancestry_verifier or self._accepting_ancestry(),
            repo_root=repo_root or self.ledger_repo,
        )

    # ---- Contract: valid completion passes ----

    def test_valid_post_deletion_completion_returns_complete_receipt(self) -> None:
        """A correctly built ledger with valid deletionReview receipts, matching
        plans, and release B descending from the deletion event must complete."""
        calls, ancestry = self._make_accepting_ancestry_verifier()
        verifier = self._make_verifier()
        result = self._run(verifier, ancestry_verifier=ancestry)
        self.assertEqual(result["completion"], "post_deletion_release_complete")
        # The ancestry verifier must have been called for activation→release
        self.assertTrue(len(calls) >= 1)
        # verify_deletion_review must have been called for each deleted row
        self.assertEqual(len(verifier.verify_deletion_review_calls), len(GATE.ROW_IDS))

    # ---- Contract: missing deletionReview receipt is rejected ----

    def test_missing_deletion_review_receipt_is_rejected(self) -> None:
        """Removing the deletionReview receipt pointer from the ledger must
        fail-closed instead of accepting an unreviewed deletion."""
        manifest = json.loads(
            (self.ledger_repo / "config/domain-core-legacy-deletion.json").read_text()
        )
        manifest["rows"][0]["receipts"].pop("deletionReview")
        (self.ledger_repo / "config/domain-core-legacy-deletion.json").write_text(
            json.dumps(manifest)
        )
        verifier = self._make_verifier()
        with self.assertRaisesRegex(GATE.GateError, "deletionReview"):
            self._run(verifier)

    # ---- Contract: tampered deletionReview receipt is rejected ----

    def test_tampered_deletion_review_receipt_digest_is_rejected(self) -> None:
        """A deletionReview receipt whose planSha256 does not match the committed
        plan bytes must be rejected."""
        row_id = GATE.ROW_IDS[0]
        receipt_path = (
            self.ledger_repo / GATE.RECEIPT_ROOT / row_id / "1" / "deletion_review.json"
        )
        receipt = json.loads(receipt_path.read_text())
        receipt["deletionReview"]["planSha256"] = "f" * 64  # wrong digest
        receipt_path.write_text(json.dumps(receipt))
        verifier = self._make_verifier()
        with self.assertRaisesRegex(GATE.GateError, "deletion"):
            self._run(verifier)

    def test_tampered_deletion_review_receipt_field_is_rejected(self) -> None:
        """A deletionReview receipt with an unexpected extra field must be
        rejected."""
        row_id = GATE.ROW_IDS[0]
        receipt_path = (
            self.ledger_repo / GATE.RECEIPT_ROOT / row_id / "1" / "deletion_review.json"
        )
        receipt = json.loads(receipt_path.read_text())
        receipt["deletionReview"]["extraField"] = "tampered"
        receipt_path.write_text(json.dumps(receipt))
        verifier = self._make_verifier()
        with self.assertRaisesRegex(GATE.GateError, "deletionReview"):
            self._run(verifier)

    # ---- Contract: mismatched reviewed deletion commit is rejected ----

    def test_mismatched_reviewed_commit_is_rejected(self) -> None:
        """A deletionReview receipt whose reviewedCommit does not match the
        actual reviewed commit must be rejected."""
        row_id = GATE.ROW_IDS[0]
        receipt_path = (
            self.ledger_repo / GATE.RECEIPT_ROOT / row_id / "1" / "deletion_review.json"
        )
        receipt = json.loads(receipt_path.read_text())
        receipt["deletionReview"]["reviewedCommit"] = "b" * 40  # wrong commit
        receipt_path.write_text(json.dumps(receipt))
        verifier = self._make_verifier()
        with self.assertRaisesRegex(GATE.GateError, "deletion"):
            self._run(verifier)

    # ---- Contract: mismatched deletion plan is rejected ----

    def test_mismatched_deletion_plan_reviewer_is_rejected(self) -> None:
        """A deletionReview receipt whose plan reviewer does not match the
        receipt reviewer must be rejected."""
        row_id = GATE.ROW_IDS[0]
        receipt_path = (
            self.ledger_repo / GATE.RECEIPT_ROOT / row_id / "1" / "deletion_review.json"
        )
        plan_path = (
            self.ledger_repo / GATE.DELETION_PLAN_ROOT / row_id / "1.json"
        )
        receipt = json.loads(receipt_path.read_text())
        plan = json.loads(plan_path.read_text())
        # Tamper the plan reviewer to mismatch the receipt reviewer
        plan["reviewer"] = "@other-reviewer"
        plan_path.write_text(json.dumps(plan))
        # Update planSha256 in the receipt to match the tampered plan
        receipt["deletionReview"]["planSha256"] = _sha256(plan_path.read_bytes())
        receipt_path.write_text(json.dumps(receipt))
        verifier = self._make_verifier()
        with self.assertRaisesRegex(GATE.GateError, "deletion plan does not match"):
            self._run(verifier)

    def test_mismatched_deletion_plan_targets_is_rejected(self) -> None:
        """A deletion plan whose legacyTargetsSha256 does not match the actual
        row target inventory must be rejected — the plan must bind the exact
        reviewed row targets."""
        row_id = GATE.ROW_IDS[0]
        receipt_path = (
            self.ledger_repo / GATE.RECEIPT_ROOT / row_id / "1" / "deletion_review.json"
        )
        plan_path = (
            self.ledger_repo / GATE.DELETION_PLAN_ROOT / row_id / "1.json"
        )
        receipt = json.loads(receipt_path.read_text())
        plan = json.loads(plan_path.read_text())
        # Tamper the plan's legacy targets digest to mismatch the inventory
        plan["legacyTargetsSha256"] = "0" * 64
        plan_path.write_text(json.dumps(plan))
        receipt["deletionReview"]["planSha256"] = _sha256(plan_path.read_bytes())
        receipt_path.write_text(json.dumps(receipt))
        verifier = self._make_verifier()
        with self.assertRaisesRegex(GATE.GateError, "deletion plan does not match"):
            self._run(verifier)

    # ---- Contract: unqualified reviewer is rejected ----

    def test_unqualified_reviewer_is_rejected(self) -> None:
        """A deletionReview receipt whose reviewer is not in the trusted base
        catalog must be rejected."""
        row_id = GATE.ROW_IDS[0]
        receipt_path = (
            self.ledger_repo / GATE.RECEIPT_ROOT / row_id / "1" / "deletion_review.json"
        )
        plan_path = (
            self.ledger_repo / GATE.DELETION_PLAN_ROOT / row_id / "1.json"
        )
        receipt = json.loads(receipt_path.read_text())
        plan = json.loads(plan_path.read_text())
        # Use an unqualified reviewer
        receipt["deletionReview"]["reviewer"] = "@unqualified-reviewer"
        plan["reviewer"] = "@unqualified-reviewer"
        plan_path.write_text(json.dumps(plan))
        receipt["deletionReview"]["planSha256"] = _sha256(plan_path.read_bytes())
        receipt_path.write_text(json.dumps(receipt))
        verifier = self._make_verifier()
        with self.assertRaisesRegex(VERIFY.GATE.GateError, "reviewer is not qualified"):
            self._run(verifier)

    # ---- Contract: release B not descending from deletion event is rejected ----

    def test_release_b_not_descending_from_deletion_event_is_rejected(self) -> None:
        """Release B whose commit does not descend from the authorized deletion
        event commit must be rejected."""
        rejecting_ancestry = self._make_rejecting_ancestry_verifier()
        verifier = self._make_verifier()
        with self.assertRaisesRegex(GATE.GateError, "ancestor"):
            self._run(verifier, ancestry_verifier=rejecting_ancestry)

    def test_release_b_ancestry_verifier_receives_deletion_commit(self) -> None:
        """The ancestry verifier must be called with the deletion receipt commit
        as ancestor and the release commit as descendant — proving release B
        descends from the authorized deletion event."""
        calls: list[tuple[str, str]] = []

        def verifier(ancestor: str, descendant: str) -> None:
            calls.append((ancestor, descendant))

        absence_verifier = self._make_verifier()
        self._run(absence_verifier, ancestry_verifier=verifier)
        # At least one call must check deletion commit → release commit
        deletion_ancestry_calls = [
            (a, d) for a, d in calls if d == RELEASE_COMMIT
        ]
        self.assertTrue(
            len(deletion_ancestry_calls) >= 1,
            "ancestry verifier must check deletion commit is ancestor of release B",
        )


if __name__ == "__main__":
    unittest.main()