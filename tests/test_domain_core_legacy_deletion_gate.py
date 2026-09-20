from __future__ import annotations

import copy
from datetime import UTC, datetime
import hashlib
import importlib.util
import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

try:
    from tests.support.domain_core_rollback_archive import (
        create_candidate_repository,
        write_git_source_archive,
    )
except ModuleNotFoundError:
    from support.domain_core_rollback_archive import (
        create_candidate_repository,
        write_git_source_archive,
    )


ROOT = Path(__file__).resolve().parents[1]


def load_module(name: str, path: Path):
    spec = importlib.util.spec_from_file_location(name, path)
    assert spec and spec.loader
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module


GATE = load_module(
    "domain_core_legacy_deletion_gate",
    ROOT / "scripts/ci/verify-domain-core-legacy-deletion.py",
)
RECEIPT = load_module(
    "domain_core_promotion_receipt",
    ROOT / "scripts/ops/create-domain-core-promotion-receipt.py",
)
DELETION_PLAN = load_module(
    "domain_core_deletion_plan",
    ROOT / "scripts/ops/create-domain-core-deletion-plan.py",
)
ROLLBACK_BUNDLE = load_module(
    "domain_core_rollback_bundle",
    ROOT / "scripts/ci/create-domain-core-rollback-bundle.py",
)


class FakeVerifier:
    def verify_candidate_bundle(self, artifact: Path, bundle: Path, **kwargs) -> None:
        self.candidate_call = (artifact, bundle, kwargs)

    def verify_release(self, item: dict, bundle: Path, digest: str, domain: str) -> None:
        self.release_call = (item, bundle, digest, domain)

    def verify_rollback_artifact(self, item: dict, bundle: Path, digest: str) -> None:
        self.rollback_call = (item, bundle, digest)

    def verify_deletion_review(self, review: dict, bound_files: dict[str, str] | None = None, **kwargs) -> None:
        self.review_call = (review, bound_files, kwargs)

    def verify_deletion_head(self, **kwargs) -> None:
        self.deletion_head_call = kwargs


class FakeDownloadResponse:
    def __init__(self, contents: bytes, url: str) -> None:
        self.contents = contents
        self.url = url
        self.offset = 0

    def __enter__(self):
        return self

    def __exit__(self, *_args):
        return None

    def geturl(self) -> str:
        return self.url

    def read(self, size: int) -> bytes:
        chunk = self.contents[self.offset : self.offset + size]
        self.offset += len(chunk)
        return chunk


class DomainCoreLegacyDeletionGateTests(unittest.TestCase):
    def test_signed_evidence_cache_reuses_digest_addressed_immutable_bytes(
        self,
    ) -> None:
        contents = b"cached release bytes"
        digest = hashlib.sha256(contents).hexdigest()
        with tempfile.TemporaryDirectory() as directory:
            verifier = GATE.SignedEvidenceVerifier(Path(directory))
            response = FakeDownloadResponse(contents, "https://objects.githubusercontent.com/release.zip")
            with mock.patch.object(GATE, "urlopen", return_value=response) as download:
                first = verifier._cached_artifact(
                    "https://github.com/Imagine-That-Ai/BurnBar/releases/download/v1.2.3/release.zip",
                    digest,
                    "release artifact",
                )
                second = verifier._cached_artifact(
                    "https://github.com/Imagine-That-Ai/BurnBar/releases/download/v1.2.3/release.zip",
                    digest,
                    "release artifact",
                )
            self.assertEqual(first, second)
            self.assertEqual(first.read_bytes(), contents)
            download.assert_called_once()

    def test_attestation_cache_deduplicates_equal_bytes_and_verification_key(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory).resolve()
            artifact_one = root / "artifact-one"
            artifact_two = root / "artifact-two"
            bundle_one = root / "bundle-one"
            bundle_two = root / "bundle-two"
            artifact_one.write_bytes(b"same artifact")
            artifact_two.write_bytes(b"same artifact")
            bundle_one.write_bytes(b"same bundle")
            bundle_two.write_bytes(b"same bundle")
            verifier = GATE.SignedEvidenceVerifier(root / "cache")
            result = subprocess.CompletedProcess(
                [],
                0,
                '[{"verificationResult":{"statement":{"predicate":{}}}}]',
                "",
            )
            arguments = {
                "signer_workflow": ".github/workflows/release.yml",
                "source_digest": "1" * 40,
                "source_ref": "refs/tags/v1.2.3",
                "predicate_type": GATE.ROLLBACK_PREDICATE_TYPE,
                "signer_digest": "1" * 40,
                "label": "release",
            }
            with mock.patch.object(GATE.subprocess, "run", return_value=result) as execute:
                first = verifier._verify_bundle(artifact_one, bundle_one, **arguments)
                second = verifier._verify_bundle(artifact_two, bundle_two, **arguments)
            self.assertEqual(first, second)
            execute.assert_called_once()

    def test_current_ledger_passes_with_trusted_evidence_verifier(self) -> None:
        verifier = mock.Mock(spec=GATE.SignedEvidenceVerifier)
        GATE.run_gate(
            ROOT,
            ROOT / "config/domain-core-legacy-deletion.json",
            evidence_verifier=verifier,
        )

    def test_extracted_legacy_owners_are_whole_file_deletion_targets(self) -> None:
        ledger = json.loads((ROOT / "config/domain-core-legacy-deletion.json").read_text())
        path_targets = {
            target["path"]
            for row in ledger["rows"]
            for target in row["targets"]
            if target["kind"] == "path" and target["role"] == "legacy_implementation"
        }
        self.assertTrue(
            {
                "OpenBurnBarCore/Sources/OpenBurnBarQuota/ProviderQuota/Legacy/ClaudeQuotaLegacy.swift",
                "OpenBurnBarCore/Sources/OpenBurnBarQuota/ProviderQuota/Legacy/CodexQuotaLegacy.swift",
                "OpenBurnBarCore/Sources/OpenBurnBarKernel/SharedModels/Legacy/CloudVaultLegacyCrypto.swift",
                "OpenBurnBarCore/Sources/OpenBurnBarKernel/SharedModels/Legacy/CloudVaultLegacyDocumentRewrap.swift",
                "OpenBurnBarCore/Sources/OpenBurnBarKernel/SharedModels/Legacy/CloudVaultLegacySearch.swift",
                "OpenBurnBarCore/Sources/OpenBurnBarKernel/SharedModels/Legacy/HermesRelayLegacyCrypto.swift",
                "OpenBurnBarCore/Sources/OpenBurnBarKernel/SharedModels/Legacy/HermesRatchetLegacyCrypto.swift",
                "android/app/src/main/java/com/openburnbar/data/cloud/CloudVaultLegacyCrypto.kt",
                "android/app/src/main/java/com/openburnbar/data/cloud/CloudVaultLegacySearch.kt",
                "android/app/src/main/java/com/openburnbar/data/cloud/CloudVaultLegacyDocumentRewrap.kt",
                "android/app/src/main/java/com/openburnbar/data/hermes/relay/HermesRelayLegacyCrypto.kt",
                "android/app/src/main/java/com/openburnbar/data/hermes/relay/HermesRatchetLegacyCrypto.kt",
                "windows/cloudsync/OpenBurnBar.CloudSync.Crypto/Legacy/CloudVaultLegacyCrypto.cs",
                "windows/cloudsync/OpenBurnBar.CloudSync.Crypto/Legacy/AesGcmBox.cs",
            }.issubset(path_targets)
        )

    def test_ios_release_consumers_match_mobile_runtime_ownership(self) -> None:
        ios_rows = {row_id for row_id, consumers in GATE.ROW_RELEASE_CONSUMERS.items() if "ios" in consumers}
        self.assertEqual(
            ios_rows,
            {
                "cloudvault.portable_primitives",
                "cloudvault.document_rewrap",
                "cloudvault.search",
                "hermes.relay_crypto",
                "hermes.ratchet_transforms",
            },
        )

    def test_release_consumer_ownership_is_exact_and_exhaustive(self) -> None:
        self.assertEqual(
            GATE.ROW_RELEASE_CONSUMERS,
            {
                "quota.claude_statusline": {"apple", "linux", "windows"},
                "quota.codex_usage": {"apple", "linux", "windows"},
                "quota.cursor_usage": {"apple", "linux", "windows"},
                "quota.anthropic_headers": {"apple", "linux", "windows"},
                "cloudvault.portable_primitives": {"apple", "ios", "linux", "android", "windows", "console"},
                "cloudvault.document_rewrap": {"apple", "ios", "linux", "android"},
                "cloudvault.search": {"apple", "ios", "linux", "android"},
                "hermes.relay_crypto": {"apple", "ios", "linux", "android"},
                "hermes.ratchet_transforms": {"apple", "ios", "linux", "android"},
                "pricing.token_cost": {"apple", "linux", "functions"},
                "pricing.kimi_historical": {"functions"},
            },
        )
        declared = set().union(*GATE.ROW_RELEASE_CONSUMERS.values())
        self.assertEqual(declared, set(GATE.RELEASE_SIGNER_WORKFLOWS))
        self.assertEqual(declared, set(GATE.RELEASE_ARTIFACT_IDENTITIES))

    def test_inventory_and_lifecycle_are_exact(self) -> None:
        ledger = json.loads((ROOT / "config/domain-core-legacy-deletion.json").read_text())
        self.assertEqual(tuple(row["id"] for row in ledger["rows"]), GATE.ROW_IDS)
        self.assertEqual(len(ledger["rows"]), 11)
        self.assertEqual(
            GATE.STATES,
            {
                "rollout",
                "promotion_approved",
                "activation_annulled",
                "rust_authoritative_with_rollback",
                "deletion_approved",
                "rollback_active",
                "legacy_deleted",
            },
        )
        for row in ledger["rows"]:
            self.assertTrue(any(target["role"] == "legacy_implementation" for target in row["targets"]))

    def test_ledger_transition_inventory_is_monotonic_then_freezes(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            repo, manifest = self.make_minimal_rollout_repo(Path(directory).resolve())
            subprocess.run(["git", "init", "-q"], cwd=repo, check=True)
            subprocess.run(["git", "config", "user.email", "test@openburnbar.invalid"], cwd=repo, check=True)
            subprocess.run(["git", "config", "user.name", "OpenBurnBar Test"], cwd=repo, check=True)
            subprocess.run(["git", "add", "."], cwd=repo, check=True)
            subprocess.run(["git", "commit", "-qm", "immutable deletion inventory"], cwd=repo, check=True)
            base = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=repo, text=True).strip()

            added = copy.deepcopy(manifest)
            added["sourceRoots"]["new-source"] = "new-src"
            added["rows"][0]["targets"].append(
                {
                    "kind": "source_symbol",
                    "role": "legacy_implementation",
                    "root": "new-source",
                    "path": "new-src/new-legacy.txt",
                    "symbol": "newLegacySymbol",
                }
            )
            GATE.validate_ledger_transition(repo, base, added)

            removed = copy.deepcopy(manifest)
            removed["rows"][0]["targets"].clear()
            with self.assertRaisesRegex(GATE.GateError, "monotonic"):
                GATE.validate_ledger_transition(repo, base, removed)

            relabeled = copy.deepcopy(manifest)
            relabeled["rows"][0]["targets"][0]["symbol"] = "replacementSymbol"
            with self.assertRaisesRegex(GATE.GateError, "monotonic"):
                GATE.validate_ledger_transition(repo, base, relabeled)

            remapped = copy.deepcopy(manifest)
            remapped["sourceRoots"]["source"] = "other"
            with self.assertRaisesRegex(GATE.GateError, "mapping is immutable"):
                GATE.validate_ledger_transition(repo, base, remapped)

            unused_root = copy.deepcopy(manifest)
            unused_root["sourceRoots"]["unused"] = "unused"
            with self.assertRaisesRegex(GATE.GateError, "introduced exactly"):
                GATE.validate_ledger_transition(repo, base, unused_root)

            promoted = copy.deepcopy(manifest)
            promoted["rows"][0]["state"] = "promotion_approved"
            promoted["rows"][0]["authorityGeneration"] = 1
            promoted["rows"][0]["receipts"] = {"promotion": "receipts/original.json"}
            (repo / "config/domain-core-legacy-deletion.json").write_text(json.dumps(promoted))
            subprocess.run(["git", "add", "."], cwd=repo, check=True)
            subprocess.run(["git", "commit", "-qm", "promotion pointer"], cwd=repo, check=True)
            promoted_base = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=repo, text=True).strip()
            substituted = copy.deepcopy(promoted)
            substituted["rows"][0]["receipts"]["promotion"] = "receipts/substituted.json"
            with self.assertRaisesRegex(GATE.GateError, "receipt pointer promotion is immutable"):
                GATE.validate_ledger_transition(repo, promoted_base, substituted)

            stable_generation_one = copy.deepcopy(promoted)
            stable_generation_one["rows"][0]["state"] = "rust_authoritative_with_rollback"
            stable_generation_one["rows"][0]["receipts"]["stableRelease"] = "receipts/stable-1.json"
            (repo / "config/domain-core-legacy-deletion.json").write_text(json.dumps(stable_generation_one))
            subprocess.run(["git", "add", "."], cwd=repo, check=True)
            subprocess.run(["git", "commit", "-qm", "stable generation one"], cwd=repo, check=True)
            stable_base = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=repo, text=True).strip()
            generation_two = copy.deepcopy(stable_generation_one)
            generation_two["rows"][0]["state"] = "promotion_approved"
            generation_two["rows"][0]["authorityGeneration"] = 2
            generation_two["rows"][0]["receipts"] = {"promotion": "receipts/promotion-2.json"}
            GATE.validate_ledger_transition(repo, stable_base, generation_two)
            stale_generation = copy.deepcopy(generation_two)
            stale_generation["rows"][0]["authorityGeneration"] = 1
            with self.assertRaisesRegex(GATE.GateError, "requires authority generation 2"):
                GATE.validate_ledger_transition(repo, stable_base, stale_generation)

            frozen = copy.deepcopy(promoted)
            frozen["rows"][0]["state"] = "deletion_approved"
            frozen["rows"][0]["receipts"] = {
                "promotion": "receipts/original.json",
                "stableRelease": "receipts/stable.json",
                "deletionReview": "receipts/deletion.json",
            }
            (repo / "config/domain-core-legacy-deletion.json").write_text(json.dumps(frozen))
            subprocess.run(["git", "add", "."], cwd=repo, check=True)
            subprocess.run(["git", "commit", "-qm", "freeze approved inventory"], cwd=repo, check=True)
            frozen_base = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=repo, text=True).strip()
            post_approval = copy.deepcopy(frozen)
            post_approval["rows"][0]["targets"].append(copy.deepcopy(post_approval["rows"][1]["targets"][0]))
            with self.assertRaisesRegex(GATE.GateError, "frozen after deletion approval"):
                GATE.validate_ledger_transition(repo, frozen_base, post_approval)

    def test_receipt_sets_fail_closed_for_every_state(self) -> None:
        self.assertEqual(GATE.required_receipts("rollout"), set())
        self.assertEqual(GATE.required_receipts("promotion_approved"), {"promotion"})
        self.assertEqual(
            GATE.required_receipts("activation_annulled"),
            {"promotion", "activationAnnulment"},
        )
        self.assertEqual(
            GATE.required_receipts("rust_authoritative_with_rollback"),
            {"promotion", "stableRelease"},
        )
        self.assertEqual(
            GATE.required_receipts("rollback_active"),
            {"promotion", "stableRelease", "rollback"},
        )
        self.assertEqual(
            GATE.required_receipts("deletion_approved"),
            {"promotion", "stableRelease", "deletionReview"},
        )
        self.assertEqual(
            GATE.required_receipts("legacy_deleted"),
            {"promotion", "stableRelease", "deletionReview"},
        )

    def test_second_authority_epoch_supersedes_annulment_stable_or_rollback_receipt(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory).resolve()
            receipt_root = root / GATE.RECEIPT_ROOT / GATE.ROW_IDS[0] / "1"
            receipt_root.mkdir(parents=True)
            annulment = receipt_root / "annulment.json"
            annulment.write_text('{"transition":"annulment"}\n')
            pointer = RECEIPT.superseded_authority_pointer(root, GATE.ROW_IDS[0], 2)
            self.assertEqual(pointer["transition"], "annulment")
            self.assertEqual(pointer["sha256"], hashlib.sha256(annulment.read_bytes()).hexdigest())
            annulment.unlink()
            stable = receipt_root / "stable_release.json"
            stable.write_text('{"transition":"stable_release"}\n')
            pointer = RECEIPT.superseded_authority_pointer(root, GATE.ROW_IDS[0], 2)
            self.assertEqual(pointer["transition"], "stable_release")
            self.assertEqual(pointer["sha256"], hashlib.sha256(stable.read_bytes()).hexdigest())
            rollback = receipt_root / "rollback.json"
            rollback.write_text('{"transition":"rollback"}\n')
            pointer = RECEIPT.superseded_authority_pointer(root, GATE.ROW_IDS[0], 2)
            self.assertEqual(pointer["transition"], "rollback")
            with self.assertRaisesRegex(RECEIPT.GATE.GateError, "must supersede"):
                RECEIPT.superseded_authority_pointer(root, GATE.ROW_IDS[0], 3)

    def test_unshipped_activation_can_be_annulled_then_reattested_in_next_generation(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            repo, manifest = self.make_minimal_rollout_repo(Path(directory).resolve())
            subprocess.run(["git", "init", "-q"], cwd=repo, check=True)
            subprocess.run(["git", "config", "user.email", "test@openburnbar.invalid"], cwd=repo, check=True)
            subprocess.run(["git", "config", "user.name", "OpenBurnBar Test"], cwd=repo, check=True)
            subprocess.run(["git", "add", "."], cwd=repo, check=True)
            subprocess.run(["git", "commit", "-qm", "rollout"], cwd=repo, check=True)

            promoted = copy.deepcopy(manifest)
            promoted["rows"][0]["state"] = "promotion_approved"
            promoted["rows"][0]["authorityGeneration"] = 1
            promoted["rows"][0]["receipts"] = {"promotion": "receipts/promotion-1.json"}
            (repo / "config/domain-core-legacy-deletion.json").write_text(json.dumps(promoted))
            subprocess.run(["git", "add", "."], cwd=repo, check=True)
            subprocess.run(["git", "commit", "-qm", "promotion"], cwd=repo, check=True)
            promoted_base = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=repo, text=True).strip()

            annulled = copy.deepcopy(promoted)
            annulled["rows"][0]["state"] = "activation_annulled"
            annulled["rows"][0]["receipts"]["activationAnnulment"] = "receipts/annulment-1.json"
            GATE.validate_ledger_transition(repo, promoted_base, annulled)
            (repo / "config/domain-core-legacy-deletion.json").write_text(json.dumps(annulled))
            subprocess.run(["git", "add", "."], cwd=repo, check=True)
            subprocess.run(["git", "commit", "-qm", "annul activation"], cwd=repo, check=True)
            annulled_base = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=repo, text=True).strip()

            generation_two = copy.deepcopy(annulled)
            generation_two["rows"][0]["state"] = "promotion_approved"
            generation_two["rows"][0]["authorityGeneration"] = 2
            generation_two["rows"][0]["receipts"] = {"promotion": "receipts/promotion-2.json"}
            GATE.validate_ledger_transition(repo, annulled_base, generation_two)
            stale = copy.deepcopy(generation_two)
            stale["rows"][0]["authorityGeneration"] = 1
            with self.assertRaisesRegex(GATE.GateError, "requires authority generation 2"):
                GATE.validate_ledger_transition(repo, annulled_base, stale)

    def test_activation_annulment_binds_stale_activation_and_incidental_main_advance(self) -> None:
        candidate = {
            "candidateCommit": "1" * 40,
            "coreVersion": "0.1.0",
            "abiVersion": 3,
            "sourceSha256": "2" * 64,
        }
        activation = {
            **candidate,
            "activationCommit": "3" * 40,
            "changedPathsSha256": "4" * 64,
        }
        promotion = GATE.Receipt(
            path="promotion.json",
            transition="promotion",
            generation=1,
            approved_at=datetime(2026, 7, 27, tzinfo=UTC),
            commit=candidate["candidateCommit"],
            digest="5" * 64,
            evidence=("https://github.com/Imagine-That-Ai/BurnBar/attestations/1",),
            payload={},
        )
        payload = {
            "promotionReceiptSha256": promotion.digest,
            "candidate": candidate,
            "activation": activation,
            "advancedMainCommit": "6" * 40,
            "reason": "release_train_advanced_before_stable_receipt",
            "replacementCandidateRequired": True,
        }
        annulment = GATE.Receipt(
            path="annulment.json",
            transition="annulment",
            generation=1,
            approved_at=datetime(2026, 7, 28, tzinfo=UTC),
            commit=payload["advancedMainCommit"],
            digest="7" * 64,
            evidence=("https://github.com/Imagine-That-Ai/BurnBar/pull/2097",),
            payload=payload,
        )

        def git_output(_repo: Path, args: list[str], _label: str) -> str:
            if args[:2] == ["rev-parse", "HEAD"]:
                return "8" * 40
            if args[0] == "rev-parse" and args[1].endswith("^{commit}"):
                return args[1][:40] + "\n"
            if args[0] == "diff":
                return "OpenBurnBarMobile/App/OpenBurnBarMobileApp.swift\n"
            if args[:2] == ["tag", "--points-at"]:
                return ""
            raise AssertionError(args)

        with tempfile.TemporaryDirectory() as directory:
            repo = Path(directory).resolve()
            (repo / GATE.RECEIPT_ROOT / GATE.ROW_IDS[0] / "1").mkdir(parents=True)
            with (
                mock.patch.object(GATE, "require_commit", side_effect=lambda _repo, value, _label: value),
                mock.patch.object(GATE, "candidate_identity_at_commit", return_value=candidate),
                mock.patch.object(
                    GATE,
                    "validate_annullable_activation_closure",
                    return_value=activation,
                ),
                mock.patch.object(GATE, "require_ancestor") as require_ancestor_mock,
                mock.patch.object(GATE, "git_output", side_effect=git_output),
                mock.patch.object(
                    GATE,
                    "public_production_profile_at_commit",
                    return_value=({"quota": "rust"}, {"quota": "9" * 64}),
                ),
            ):
                GATE.validate_activation_annulment_receipt(
                    repo,
                    GATE.ROW_IDS[0],
                    1,
                    annulment,
                    promotion,
                )
                self.assertIn(
                    mock.call(
                        repo,
                        payload["advancedMainCommit"],
                        "8" * 40,
                        f"row {GATE.ROW_IDS[0]} activation annulment protected main",
                    ),
                    require_ancestor_mock.call_args_list,
                )
                require_ancestor_mock.reset_mock()
                GATE.validate_activation_annulment_receipt(
                    repo,
                    GATE.ROW_IDS[0],
                    1,
                    annulment,
                    promotion,
                    "b" * 40,
                )
                self.assertIn(
                    mock.call(
                        repo,
                        payload["advancedMainCommit"],
                        "b" * 40,
                        f"row {GATE.ROW_IDS[0]} activation annulment protected main",
                    ),
                    require_ancestor_mock.call_args_list,
                )

                def reject_protected_main(_repo: Path, _ancestor: str, _descendant: str, label: str) -> None:
                    if "protected main" in label:
                        raise GATE.GateError(f"{label}: not an ancestor of protected main")

                require_ancestor_mock.side_effect = reject_protected_main
                with self.assertRaisesRegex(GATE.GateError, "protected main"):
                    GATE.validate_activation_annulment_receipt(
                        repo,
                        GATE.ROW_IDS[0],
                        1,
                        annulment,
                        promotion,
                        "b" * 40,
                    )
                require_ancestor_mock.side_effect = None
                invalid = copy.deepcopy(payload)
                invalid["replacementCandidateRequired"] = False
                with self.assertRaisesRegex(GATE.GateError, "replacement exact-main candidate"):
                    GATE.validate_activation_annulment_receipt(
                        repo,
                        GATE.ROW_IDS[0],
                        1,
                        GATE.Receipt(
                            **{
                                **annulment.__dict__,
                                "payload": invalid,
                            }
                        ),
                        promotion,
                    )

    def test_multi_row_domain_requires_one_shared_annulment_event(self) -> None:
        candidate = {
            "candidateCommit": "1" * 40,
            "coreVersion": "0.1.0",
            "abiVersion": 3,
            "sourceSha256": "2" * 64,
        }
        activation = {
            **candidate,
            "activationCommit": "3" * 40,
            "changedPathsSha256": "4" * 64,
        }

        def annulment_receipt(advanced_main: str) -> GATE.Receipt:
            return GATE.Receipt(
                path="annulment.json",
                transition="annulment",
                generation=1,
                approved_at=datetime(2026, 7, 28, tzinfo=UTC),
                commit=advanced_main,
                digest="7" * 64,
                evidence=("https://github.com/Imagine-That-Ai/BurnBar/pull/2097",),
                payload={
                    "promotionReceiptSha256": "5" * 64,
                    "candidate": candidate,
                    "activation": activation,
                    "advancedMainCommit": advanced_main,
                    "reason": "release_train_advanced_before_stable_receipt",
                    "replacementCandidateRequired": True,
                },
            )

        def build_rows(annulments: dict[str, GATE.Receipt | None]) -> dict[str, GATE.Row]:
            rows: dict[str, GATE.Row] = {}
            for domain, row_ids in GATE.PROFILE_DOMAIN_ROWS.items():
                for row_id in row_ids:
                    if domain == "quota":
                        receipts: dict[str, GATE.Receipt] = {}
                        receipt = annulments[row_id]
                        if receipt is not None:
                            receipts["activationAnnulment"] = receipt
                        rows[row_id] = GATE.Row(
                            state="activation_annulled",
                            generation=1,
                            receipts=receipts,
                            targets=[],
                        )
                    else:
                        rows[row_id] = GATE.Row(state="rollout", generation=0, receipts={}, targets=[])
            return rows

        modes = {domain: "legacy" for domain in GATE.PROFILE_DOMAIN_ROWS}
        quota_rows = GATE.PROFILE_DOMAIN_ROWS["quota"]
        bindings: dict[str, tuple[str, str, str] | None] = {
            row_id: None for row_ids in GATE.PROFILE_DOMAIN_ROWS.values() for row_id in row_ids
        }

        shared: dict[str, GATE.Receipt | None] = {row_id: annulment_receipt("6" * 40) for row_id in quota_rows}
        GATE.validate_public_profile_transitions(build_rows(shared), modes, bindings)

        divergent = dict(shared)
        divergent[quota_rows[0]] = annulment_receipt("a" * 40)
        with self.assertRaisesRegex(GATE.GateError, "share one annulment event"):
            GATE.validate_public_profile_transitions(build_rows(divergent), modes, bindings)

        partial = dict(shared)
        partial[quota_rows[0]] = None
        with self.assertRaisesRegex(GATE.GateError, "annulled atomically"):
            GATE.validate_public_profile_transitions(build_rows(partial), modes, bindings)

    def test_promotion_after_annulment_requires_fresh_descendant_candidate(self) -> None:
        row_id = GATE.ROW_IDS[0]
        annulled_candidate = "1" * 40
        advanced_main = "6" * 40
        with tempfile.TemporaryDirectory() as directory:
            repo = Path(directory).resolve()
            receipt_dir = repo / GATE.RECEIPT_ROOT / row_id / "1"
            receipt_dir.mkdir(parents=True)
            previous = {
                "schemaVersion": 2,
                "rowId": row_id,
                "authorityGeneration": 1,
                "transition": "annulment",
                "status": "active",
                "approvedAt": "2026-07-28T00:00:00Z",
                "activationAnnulment": {
                    "candidate": {"candidateCommit": annulled_candidate},
                    "advancedMainCommit": advanced_main,
                },
            }
            receipt_path = receipt_dir / "annulment.json"
            receipt_path.write_text(json.dumps(previous))
            link = {
                "transition": "annulment",
                "path": f"{GATE.RECEIPT_ROOT}/{row_id}/1/annulment.json",
                "sha256": hashlib.sha256(receipt_path.read_bytes()).hexdigest(),
            }
            approved_at = datetime(2026, 7, 29, tzinfo=UTC)
            with (
                mock.patch.object(GATE, "require_commit", side_effect=lambda _repo, value, _label: value),
                mock.patch.object(GATE, "require_ancestor") as require_ancestor_mock,
            ):
                GATE.validate_superseded_authority(repo, row_id, 2, link, approved_at, "c" * 40)
                self.assertIn(
                    mock.call(
                        repo,
                        advanced_main,
                        "c" * 40,
                        "promotion after annulment replacement candidate",
                    ),
                    require_ancestor_mock.call_args_list,
                )
                with self.assertRaisesRegex(GATE.GateError, "fresh replacement candidate"):
                    GATE.validate_superseded_authority(repo, row_id, 2, link, approved_at, annulled_candidate)

                def reject_replacement(_repo: Path, _ancestor: str, _descendant: str, label: str) -> None:
                    if label == "promotion after annulment replacement candidate":
                        raise GATE.GateError(f"{label}: not a descendant")

                require_ancestor_mock.side_effect = reject_replacement
                with self.assertRaisesRegex(GATE.GateError, "replacement candidate"):
                    GATE.validate_superseded_authority(repo, row_id, 2, link, approved_at, "c" * 40)

    def test_premature_legacy_deleted_state_is_blocked(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            repo, manifest = self.make_minimal_rollout_repo(Path(directory).resolve())
            manifest["rows"][0]["state"] = "legacy_deleted"
            manifest["rows"][0]["authorityGeneration"] = 1
            (repo / "config/domain-core-legacy-deletion.json").write_text(json.dumps(manifest))
            with self.assertRaisesRegex(GATE.GateError, "missing fields.*promotion"):
                GATE.run_gate(repo, repo / "config/domain-core-legacy-deletion.json")

    def test_source_absence_before_legacy_deleted_is_blocked(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            repo, manifest = self.make_minimal_rollout_repo(Path(directory).resolve())
            first_path = repo / manifest["rows"][0]["targets"][0]["path"]
            first_path.unlink()
            with self.assertRaisesRegex(GATE.GateError, "legacy target is absent before legacy_deleted"):
                GATE.run_gate(repo, repo / "config/domain-core-legacy-deletion.json")

    def test_json_and_repository_paths_reject_ambiguous_input(self) -> None:
        with self.assertRaisesRegex(GATE.GateError, "duplicate JSON key"):
            GATE.load_json_bytes(b'{"a":1,"a":2}', "fixture")
        for value in ("../escape", "/absolute", "a/../b", "a\\b", "a/"):
            with self.subTest(value=value), self.assertRaises(GATE.GateError):
                GATE.repository_path(value, "fixture")

    def test_secure_paths_reject_symlink_components(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory).resolve()
            outside = root / "outside"
            outside.mkdir()
            (root / "link").symlink_to(outside, target_is_directory=True)
            with self.assertRaisesRegex(GATE.GateError, "symlink"):
                GATE.secure_path(root, "link/file.json", "fixture", must_exist=False)

    def test_atomic_public_profile_groups_cover_multi_row_domains(self) -> None:
        source = (ROOT / "scripts/ci/verify-domain-core-legacy-deletion.py").read_text()
        self.assertIn("mapped rows must move atomically", source)
        self.assertEqual(len(GATE.PROFILE_DOMAIN_ROWS["quota"]), 4)
        self.assertEqual(len(GATE.PROFILE_DOMAIN_ROWS["hermes"]), 2)
        self.assertEqual(len(GATE.PROFILE_DOMAIN_ROWS["pricing"]), 2)

    def test_policy_is_deterministic_and_telemetry_has_no_authority(self) -> None:
        GATE.validate_deterministic_promotion_policy(ROOT)
        policy = json.loads((ROOT / GATE.PROMOTION_POLICY_PATH).read_text())
        self.assertFalse(policy["promotionAuthority"])
        self.assertTrue(policy["protectedAttestationRequired"])
        self.assertTrue(policy["rollbackRequired"])
        self.assertTrue(policy["oneStableReleaseBeforeDeletion"])
        serialized = json.dumps(policy)
        self.assertNotIn("minimumSamples", serialized)
        self.assertNotIn("minimumCoverageSeconds", serialized)

    def test_public_rollback_profile_is_permanently_all_legacy(self) -> None:
        catalog = json.loads((ROOT / GATE.BUILD_PROFILE_PATH).read_text())
        GATE.validate_build_profile_catalog(catalog)
        rollback = catalog["profiles"]["public-production-rollback"]
        self.assertTrue(all(mode == "legacy" for mode in rollback["modes"].values()))

        weakened = copy.deepcopy(catalog)
        weakened["profiles"]["public-production-rollback"]["modes"]["pricing"] = "rust"
        with self.assertRaisesRegex(
            GATE.GateError,
            "public-production-rollback modes must all be legacy",
        ):
            GATE.validate_build_profile_catalog(weakened)

    def test_activation_closures_share_first_parent_incidental_semantics(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            repo = Path(directory).resolve()
            (repo / "crates/openburnbar-domain-core").mkdir(parents=True)
            (repo / "config").mkdir()
            (repo / "crates/openburnbar-domain-core/union-abi-manifest.json").write_text(
                json.dumps({"coreVersion": "0.3.0", "abiVersion": 3, "sourceSha256": "2" * 64})
            )
            (repo / "crates/openburnbar-domain-core/Cargo.toml").write_text(
                '[workspace]\n[workspace.package]\nversion = "0.3.0"\n'
            )
            profiles = json.loads((ROOT / GATE.BUILD_PROFILE_PATH).read_text())
            profiles["profiles"]["public-production"]["modes"] = {domain: "legacy" for domain in profiles["domains"]}
            (repo / GATE.BUILD_PROFILE_PATH).write_text(json.dumps(profiles))
            (repo / "config/domain-core-legacy-deletion.json").write_text('{"state":"rollout"}\n')
            subprocess.run(["git", "init", "-q"], cwd=repo, check=True)
            subprocess.run(
                ["git", "config", "user.email", "test@openburnbar.invalid"],
                cwd=repo,
                check=True,
            )
            subprocess.run(["git", "config", "user.name", "OpenBurnBar Test"], cwd=repo, check=True)
            subprocess.run(["git", "add", "."], cwd=repo, check=True)
            subprocess.run(
                ["git", "commit", "-qm", "candidate C remains legacy"],
                cwd=repo,
                check=True,
            )
            candidate = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=repo, text=True).strip()
            evidence_path = "config/domain-core-legacy-deletion-receipts/quota.codex_usage/2/promotion.json"
            (repo / evidence_path).parent.mkdir(parents=True)
            (repo / evidence_path).write_text("{}\n")
            subprocess.run(["git", "add", "."], cwd=repo, check=True)
            subprocess.run(
                ["git", "commit", "-qm", "activation evidence before main advance"],
                cwd=repo,
                check=True,
            )
            (repo / "functions").mkdir()
            (repo / "functions/.env.burnbar.production").write_text("MIN_INSTANCES=1\n")
            subprocess.run(["git", "add", "."], cwd=repo, check=True)
            subprocess.run(
                ["git", "commit", "-qm", "unrelated protected main advance"],
                cwd=repo,
                check=True,
            )
            profiles["profiles"]["public-production"]["modes"] = {domain: "rust" for domain in profiles["domains"]}
            (repo / GATE.BUILD_PROFILE_PATH).write_text(json.dumps(profiles))
            (repo / "config/domain-core-legacy-deletion.json").write_text('{"state":"promotion_approved"}\n')
            subprocess.run(["git", "add", "."], cwd=repo, check=True)
            subprocess.run(
                ["git", "commit", "-qm", "activation P adds receipts and Rust profile"],
                cwd=repo,
                check=True,
            )
            activation = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=repo, text=True).strip()
            # The strict release closure shares the annullable first-parent
            # semantics: a path-disjoint protected-main advance between C and P
            # is incidental, never blocks release activation, and both closures
            # bind the identical changedPathsSha256 that the JS resolver
            # (scripts/lib/domain-core-activation.mjs) derives.
            release_proof = GATE.validate_activation_closure(repo, candidate, activation)
            proof = GATE.validate_annullable_activation_closure(repo, candidate, activation)
            self.assertEqual(release_proof, proof)
            self.assertEqual(proof["candidateCommit"], candidate)
            self.assertEqual(proof["activationCommit"], activation)
            changed = GATE.annullable_activation_changed_paths(repo, candidate, activation)
            self.assertEqual(GATE.activation_changed_paths(repo, candidate, activation), changed)
            self.assertNotIn("functions/.env.burnbar.production", changed)
            # Evidence committed before the unrelated protected-main advance
            # must remain part of the validated annulment closure.
            self.assertIn(evidence_path, changed)

            (repo / "functions/.env.burnbar.production").write_text("MIN_INSTANCES=2\n")
            (repo / "config/domain-core-legacy-deletion.json").write_text('{"state":"smuggled"}\n')
            subprocess.run(["git", "add", "."], cwd=repo, check=True)
            subprocess.run(
                ["git", "commit", "-qm", "mixed protected main advance"],
                cwd=repo,
                check=True,
            )
            (repo / GATE.BUILD_PROFILE_PATH).write_text(json.dumps(profiles) + "\n")
            (repo / "config/domain-core-legacy-deletion.json").write_text('{"state":"promotion_approved_again"}\n')
            subprocess.run(["git", "add", "."], cwd=repo, check=True)
            subprocess.run(
                ["git", "commit", "-qm", "activation after mixed advance"],
                cwd=repo,
                check=True,
            )
            mixed_activation = subprocess.check_output(
                ["git", "rev-parse", "HEAD"], cwd=repo, text=True
            ).strip()
            with self.assertRaisesRegex(
                GATE.GateError,
                "annullable incidental protected-main commit .* must not change activation authority paths",
            ):
                GATE.annullable_activation_changed_paths(repo, candidate, mixed_activation)
            with self.assertRaisesRegex(
                GATE.GateError,
                "activation incidental protected-main commit .* must not change activation authority paths",
            ):
                GATE.activation_changed_paths(repo, candidate, mixed_activation)
            subprocess.run(["git", "reset", "-q", "--hard", activation], cwd=repo, check=True)

            (repo / "crates/openburnbar-domain-core/src.rs").write_text("fn drift() {}\n")
            subprocess.run(["git", "add", "."], cwd=repo, check=True)
            subprocess.run(["git", "commit", "-qm", "forbidden drift"], cwd=repo, check=True)
            drift = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=repo, text=True).strip()
            with self.assertRaisesRegex(GATE.GateError, "may end only"):
                GATE.validate_annullable_activation_closure(repo, candidate, drift)
            subprocess.run(["git", "reset", "-q", "--hard", activation], cwd=repo, check=True)

            # An incidental protected-main commit that swaps attested Rust
            # source must fail closed for both closures.
            (repo / "crates/openburnbar-domain-core/src.rs").write_text("fn incidental() {}\n")
            (repo / "functions/.env.burnbar.production").write_text("MIN_INSTANCES=3\n")
            subprocess.run(["git", "add", "."], cwd=repo, check=True)
            subprocess.run(["git", "commit", "-qm", "incidental rust drift"], cwd=repo, check=True)
            (repo / "config/domain-core-legacy-deletion.json").write_text('{"state":"promotion_after_rust_drift"}\n')
            (repo / GATE.BUILD_PROFILE_PATH).write_text(json.dumps(profiles) + "\n\n")
            subprocess.run(["git", "add", "."], cwd=repo, check=True)
            subprocess.run(["git", "commit", "-qm", "activation after rust drift"], cwd=repo, check=True)
            rust_drift = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=repo, text=True).strip()
            with self.assertRaisesRegex(GATE.GateError, "must not change attested Rust source"):
                GATE.activation_changed_paths(repo, candidate, rust_drift)
            with self.assertRaisesRegex(GATE.GateError, "must not change attested Rust source"):
                GATE.annullable_activation_changed_paths(repo, candidate, rust_drift)
            subprocess.run(["git", "reset", "-q", "--hard", activation], cwd=repo, check=True)

            # An incidental protected-main commit that swaps a deployed
            # domain-core artifact (vendored wasm, bindings, prebuilt binaries)
            # must fail closed for both closures: the promotion sidecars pin
            # only the Rust source fingerprint, not the artifact bytes.
            wasm_path = repo / "functions/vendor/openburnbar/domain-core-wasm/openburnbar_domain_core_bg.wasm"
            wasm_path.parent.mkdir(parents=True)
            wasm_path.write_bytes(b"\x00asm swapped")
            subprocess.run(["git", "add", "."], cwd=repo, check=True)
            subprocess.run(["git", "commit", "-qm", "incidental artifact swap"], cwd=repo, check=True)
            (repo / "config/domain-core-legacy-deletion.json").write_text('{"state":"promotion_after_artifact_swap"}\n')
            (repo / GATE.BUILD_PROFILE_PATH).write_text(json.dumps(profiles) + "\n\n\n")
            subprocess.run(["git", "add", "."], cwd=repo, check=True)
            subprocess.run(["git", "commit", "-qm", "activation after artifact swap"], cwd=repo, check=True)
            artifact_drift = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=repo, text=True).strip()
            with self.assertRaisesRegex(GATE.GateError, "must not change deployed domain-core artifacts"):
                GATE.activation_changed_paths(repo, candidate, artifact_drift)
            with self.assertRaisesRegex(GATE.GateError, "must not change deployed domain-core artifacts"):
                GATE.annullable_activation_changed_paths(repo, candidate, artifact_drift)

    def test_historical_activation_closure_accepts_trusted_manifest_refresh(self) -> None:
        candidate = "3efe9feecb4bb10ca67b21109914b2f0f8e40601"
        activation = "6d17960b8969d5eff8620fa21184b1a5b0958602"
        changed_paths = GATE.activation_changed_paths(ROOT, candidate, activation)
        self.assertIn(GATE.CONTROL_PLANE_MANIFEST_PATH, changed_paths)
        proof = GATE.validate_activation_closure(ROOT, candidate, activation)
        self.assertEqual(proof["candidateCommit"], candidate)
        self.assertEqual(proof["activationCommit"], activation)

    def test_actual_deletion_head_requires_official_main_and_exact_approval(
        self,
    ) -> None:
        verifier = GATE.SignedEvidenceVerifier()
        head = "a" * 40
        pull = {
            "draft": False,
            "merged": False,
            "state": "open",
            "user": {"login": "deletion-author"},
            "head": {"sha": head, "repo": {"full_name": verifier.repository}},
            "base": {"ref": "main", "repo": {"full_name": verifier.repository}},
        }
        reviews = [
            {
                "id": 7,
                "commit_id": head,
                "state": "APPROVED",
                "submitted_at": "2026-07-15T01:00:00Z",
                "user": {"login": "qualified-reviewer"},
            }
        ]
        with (
            mock.patch.object(verifier, "_github_json", return_value=pull),
            mock.patch.object(verifier, "_github_list", return_value=reviews),
        ):
            verifier.verify_deletion_head(
                pull_number=123,
                deletion_head=head,
                reviewer="@qualified-reviewer",
            )
        fork = copy.deepcopy(pull)
        fork["head"]["repo"]["full_name"] = "attacker/fork"
        with (
            mock.patch.object(verifier, "_github_json", return_value=fork),
            self.assertRaisesRegex(GATE.GateError, "same-repository"),
        ):
            verifier.verify_deletion_head(
                pull_number=123,
                deletion_head=head,
                reviewer="@qualified-reviewer",
            )

    def test_unsigned_bundle_must_disclaim_authority_and_bind_exact_tuple(self) -> None:
        identity = {
            "candidateCommit": "1" * 40,
            "coreVersion": "0.3.0",
            "abiVersion": 3,
            "sourceSha256": "2" * 64,
        }
        bundle = self.make_bundle(identity)
        generated = GATE.validate_unsigned_candidate_bundle(bundle, identity, 11, 2, "bundle")
        self.assertEqual(generated.isoformat(), "2026-07-15T00:00:00+00:00")
        authoritative = copy.deepcopy(bundle)
        authoritative["promotionAuthorized"] = True
        with self.assertRaisesRegex(GATE.GateError, "not eligible"):
            GATE.validate_unsigned_candidate_bundle(authoritative, identity, 11, 2, "bundle")
        telemetry = copy.deepcopy(bundle)
        telemetry["bundleKind"] = "shadow-observation-report"
        with self.assertRaisesRegex(GATE.GateError, "not eligible"):
            GATE.validate_unsigned_candidate_bundle(telemetry, identity, 11, 2, "bundle")
        wrong = copy.deepcopy(bundle)
        wrong["candidate"]["abiVersion"] = 4
        with self.assertRaisesRegex(GATE.GateError, "exact candidate"):
            GATE.validate_unsigned_candidate_bundle(wrong, identity, 11, 2, "bundle")

    def test_protected_verification_json_is_not_provenance_authority(self) -> None:
        diagnostic = json.dumps(
            {
                "verificationKind": "protected-domain-core-attestation-input",
                "promotionAuthorized": False,
            }
        ).encode()
        with self.assertRaisesRegex(GATE.GateError, "not provenance authority"):
            GATE.validate_github_provenance_bundle(diagnostic, "provenance")
        with self.assertRaisesRegex(GATE.GateError, "official Sigstore"):
            GATE.validate_github_provenance_bundle(b'{"mediaType":"telemetry"}', "provenance")
        GATE.validate_github_provenance_bundle(self.provenance_bytes(), "provenance")

    def test_signed_candidate_verifier_pins_workflows_runs_and_oidc(self) -> None:
        verifier = GATE.SignedEvidenceVerifier()
        candidate = "1" * 40
        trusted = "2" * 40
        artifact = ROOT / "config/domain-core-promotion-policy.json"
        provenance = ROOT / "config/domain-core-deterministic-candidate-bundle.schema.json"
        responses = [
            subprocess.CompletedProcess([], 0, '[{"verificationResult":{}}]', ""),
            subprocess.CompletedProcess(
                [],
                0,
                json.dumps(self.run_json(candidate, "push", 2, GATE.SOURCE_WORKFLOW)),
                "",
            ),
            subprocess.CompletedProcess(
                [],
                0,
                json.dumps(self.run_json(trusted, "workflow_dispatch", 3, GATE.PROMOTION_SIGNER_WORKFLOW)),
                "",
            ),
        ]
        with mock.patch.object(GATE.subprocess, "run", side_effect=responses) as run:
            verifier.verify_candidate_bundle(
                artifact,
                provenance,
                trusted_main_commit=trusted,
                source_run_id=11,
                source_run_attempt=2,
                signer_run_id=22,
                signer_run_attempt=3,
                candidate_commit=candidate,
            )
        command = run.call_args_list[0].args[0]
        self.assertEqual(command[:3], ["gh", "attestation", "verify"])
        self.assertEqual(
            command[command.index("--signer-workflow") + 1],
            "Imagine-That-Ai/BurnBar/.github/workflows/domain-core-promotion-proof.yml",
        )
        self.assertEqual(command[command.index("--source-digest") + 1], trusted)
        self.assertEqual(command[command.index("--signer-digest") + 1], trusted)
        self.assertIn("--deny-self-hosted-runners", command)
        self.assertIn("/actions/runs/11/attempts/2", " ".join(run.call_args_list[1].args[0]))
        self.assertIn("/actions/runs/22/attempts/3", " ".join(run.call_args_list[2].args[0]))

    def test_signed_candidate_verifier_rejects_wrong_source_workflow(self) -> None:
        verifier = GATE.SignedEvidenceVerifier()
        candidate = "1" * 40
        trusted = "2" * 40
        wrong_source = self.run_json(candidate, "push", 2, ".github/workflows/other.yml")
        responses = [
            subprocess.CompletedProcess([], 0, '[{"verificationResult":{}}]', ""),
            subprocess.CompletedProcess([], 0, json.dumps(wrong_source), ""),
        ]
        with (
            mock.patch.object(GATE.subprocess, "run", side_effect=responses),
            self.assertRaisesRegex(GATE.GateError, "source run.path"),
        ):
            verifier.verify_candidate_bundle(
                ROOT / "config/domain-core-promotion-policy.json",
                ROOT / "config/domain-core-deterministic-candidate-bundle.schema.json",
                trusted_main_commit=trusted,
                source_run_id=11,
                source_run_attempt=2,
                signer_run_id=22,
                signer_run_attempt=3,
                candidate_commit=candidate,
            )

    def test_promotion_creator_binds_exact_identity_and_official_provenance(
        self,
    ) -> None:
        with tempfile.TemporaryDirectory() as directory:
            repo, commit = self.make_candidate_repo(Path(directory))
            identity = GATE.candidate_identity_at_commit(repo, commit)
            bundle_path = repo / "bundle.json"
            bundle_path.write_text(json.dumps(self.make_bundle(identity)) + "\n")
            provenance_path = repo / "provenance.json"
            provenance_path.write_bytes(self.provenance_bytes())
            verifier = FakeVerifier()
            attestation, receipt, bundle_bytes, provenance_bytes = RECEIPT.create_artifacts(
                repo,
                row_id="quota.claude_statusline",
                generation=1,
                bundle_path=bundle_path,
                provenance_path=provenance_path,
                candidate_commit=commit,
                trusted_main_commit=commit,
                source_run_id=11,
                source_run_attempt=2,
                signer_run_id=22,
                signer_run_attempt=3,
                attestation_uri="https://github.com/Imagine-That-Ai/BurnBar/attestations/99",
                attested_at="2026-07-15T01:00:00Z",
                approved_by="@release-owner",
                approved_at="2026-07-15T02:00:00Z",
                verifier=verifier,
            )
            self.assertEqual(attestation["candidate"], identity)
            self.assertEqual(attestation["status"], "attested")
            self.assertEqual(
                attestation["unsignedBundle"]["sha256"],
                hashlib.sha256(bundle_bytes).hexdigest(),
            )
            self.assertEqual(
                attestation["provenance"]["sha256"],
                hashlib.sha256(provenance_bytes).hexdigest(),
            )
            self.assertEqual(
                attestation["provenance"]["signerWorkflow"],
                GATE.PROMOTION_SIGNER_WORKFLOW,
            )
            self.assertEqual(receipt["commit"], commit)
            self.assertNotIn("report", json.dumps(attestation).lower())
            self.assertTrue(hasattr(verifier, "candidate_call"))

    def test_append_only_writer_refuses_replacement(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "receipt.json"
            RECEIPT.append_only(path, b"first\n")
            RECEIPT.append_only(path, b"first\n")
            with self.assertRaisesRegex(RECEIPT.GATE.GateError, "append-only"):
                RECEIPT.append_only(path, b"second\n")

    def test_release_predicate_is_v2_and_binds_candidate(self) -> None:
        verifier = GATE.SignedEvidenceVerifier()
        contents = b"release bytes"
        identity = {
            "candidateCommit": "1" * 40,
            "coreVersion": "0.3.0",
            "abiVersion": 3,
            "sourceSha256": "2" * 64,
        }
        activation = {
            "candidateCommit": identity["candidateCommit"],
            "activationCommit": "4" * 40,
            "coreVersion": identity["coreVersion"],
            "abiVersion": identity["abiVersion"],
            "sourceSha256": identity["sourceSha256"],
            "changedPathsSha256": "5" * 64,
        }
        item = {
            "consumer": "windows",
            "artifactKind": "windows-release-bundle",
            "target": "windows-x64-arm64",
            "artifactUri": "https://github.com/Imagine-That-Ai/BurnBar/releases/download/windows-v1.2.3/OpenBurnBar-1.2.3-windows-release.zip",
            "commit": activation["activationCommit"],
            "tag": "windows-v1.2.3",
            "version": "1.2.3",
            "publicProfileSha256": "3" * 64,
            "candidate": identity,
            "activation": activation,
        }
        predicate = {
            "schemaVersion": 2,
            "predicateType": GATE.RELEASE_PREDICATE_TYPES["windows"],
            "consumer": "windows",
            "domain": "quota",
            "artifactKind": item["artifactKind"],
            "target": item["target"],
            "publicProfile": {
                "profile": "public-production",
                "domain": "quota",
                "mode": "rust",
                "sha256": "3" * 64,
            },
            "candidate": identity,
            "activation": activation,
            "sourceRun": {
                "repository": GATE.SignedEvidenceVerifier.repository,
                "workflowPath": GATE.SOURCE_WORKFLOW,
                "headSha": identity["candidateCommit"],
            },
            "promotionProof": {
                "signerWorkflow": GATE.PROMOTION_SIGNER_WORKFLOW,
                "predicateType": "https://slsa.dev/provenance/v1",
            },
            "rollbackArtifact": {"candidate": identity, "activation": activation},
            "artifact": {
                "fileName": "OpenBurnBar-1.2.3-windows-release.zip",
                "sha256": hashlib.sha256(contents).hexdigest(),
            },
            "release": {
                "version": "1.2.3",
                "tag": "windows-v1.2.3",
                "commit": activation["activationCommit"],
                "publicProfileSha256": "3" * 64,
            },
        }
        response = FakeDownloadResponse(contents, "https://objects.githubusercontent.com/release.zip")
        result = [{"verificationResult": {"statement": {"predicate": predicate}}}]
        with (
            mock.patch.object(GATE, "urlopen", return_value=response),
            mock.patch.object(verifier, "_verify_bundle", return_value=result) as verify,
        ):
            verifier.verify_release(item, ROOT / "README.md", hashlib.sha256(contents).hexdigest(), "quota")
        self.assertEqual(
            verify.call_args.kwargs["predicate_type"],
            GATE.RELEASE_PREDICATE_TYPES["windows"],
        )
        wrong = copy.deepcopy(result)
        wrong[0]["verificationResult"]["statement"]["predicate"]["candidate"]["abiVersion"] = 4
        response = FakeDownloadResponse(contents, "https://objects.githubusercontent.com/release.zip")
        with (
            mock.patch.object(GATE, "urlopen", return_value=response),
            mock.patch.object(verifier, "_verify_bundle", return_value=wrong),
            self.assertRaisesRegex(GATE.GateError, "signed predicate does not bind"),
        ):
            verifier.verify_release(item, ROOT / "README.md", hashlib.sha256(contents).hexdigest(), "quota")

        rollback_profile = copy.deepcopy(result)
        rollback_profile[0]["verificationResult"]["statement"]["predicate"]["publicProfile"]["mode"] = "legacy"
        response = FakeDownloadResponse(contents, "https://objects.githubusercontent.com/release.zip")
        with (
            mock.patch.object(GATE, "urlopen", return_value=response),
            mock.patch.object(verifier, "_verify_bundle", return_value=rollback_profile),
            self.assertRaisesRegex(GATE.GateError, "signed predicate does not bind"),
        ):
            verifier.verify_release(item, ROOT / "README.md", hashlib.sha256(contents).hexdigest(), "quota")

    def test_stable_release_requires_exact_candidate_and_retained_signed_rollback(
        self,
    ) -> None:
        source = (ROOT / "scripts/ci/verify-domain-core-legacy-deletion.py").read_text()
        for marker in (
            "stable release must tag the exact activation commit",
            "activation changed the attested core version, ABI, or source fingerprint",
            "stable release requires the dedicated cross-consumer rollback artifact",
            "retain_until_legacy_deletion_complete",
            "verify_rollback_artifact",
            "legacy target remains after legacy_deleted",
        ):
            self.assertIn(marker, source)

    def test_ios_distribution_receipt_rejects_binary_identity_spoof(self) -> None:
        candidate = {
            "candidateCommit": "1" * 40,
            "coreVersion": "0.3.0",
            "abiVersion": 3,
            "sourceSha256": "2" * 64,
        }
        activation = {
            **candidate,
            "activationCommit": "3" * 40,
            "changedPathsSha256": "4" * 64,
        }
        item = {
            "version": "1.2.3",
            "tag": "v1.2.3",
            "commit": activation["activationCommit"],
            "candidate": candidate,
            "activation": activation,
        }
        receipt = {
            "schemaVersion": 1,
            "status": "processed",
            "processedStatus": "complete",
            "deliveryId": "delivery-123",
            "archiveSha256": "5" * 64,
            "ipaSha256": "6" * 64,
            "uploadResponseSha256": "9" * 64,
            "statusResponseSha256": "a" * 64,
            "release": {
                "version": "1.2.3",
                "tag": "v1.2.3",
                "commit": activation["activationCommit"],
            },
            "candidate": candidate,
            "activation": activation,
            "loadedRustIdentity": {
                "schemaVersion": 1,
                "verificationKind": "ios-loaded-rust-slice-identity",
                "bundleId": "com.openburnbar.mobile",
                "version": "1.2.3",
                "buildNumber": "123",
                "executable": "OpenBurnBarMobile",
                "architectures": ["arm64"],
                "candidate": candidate,
                "executableSha256": "7" * 64,
                "identitySectionSha256": "8" * 64,
                "identitySymbols": [
                    "OPENBURNBAR_DOMAIN_CORE_IDENTITY_V1",
                    "uniffi_openburnbar_domain_ffi_fn_func_domain_core_abi_version",
                    "uniffi_openburnbar_domain_ffi_fn_func_domain_core_candidate_commit",
                    "uniffi_openburnbar_domain_ffi_fn_func_domain_core_source_fingerprint",
                    "uniffi_openburnbar_domain_ffi_fn_func_domain_core_version",
                ],
                "observed": {
                    "candidateCommit": "1" * 40,
                    "coreVersion": "0.3.0",
                    "abiVersion": 3,
                    "sourceSha256": "2" * 64,
                },
            },
        }
        GATE.validate_ios_app_store_receipt(receipt, item, "5" * 64)
        spoof = copy.deepcopy(receipt)
        spoof["loadedRustIdentity"]["observed"]["sourceSha256"] = "8" * 64
        with self.assertRaisesRegex(GATE.GateError, "loaded Rust slice"):
            GATE.validate_ios_app_store_receipt(spoof, item, "5" * 64)
        spoof = copy.deepcopy(receipt)
        spoof["statusResponseSha256"] = "not-a-digest"
        with self.assertRaisesRegex(GATE.GateError, "status response SHA-256"):
            GATE.validate_ios_app_store_receipt(spoof, item, "5" * 64)

    def test_rollback_artifact_verifier_binds_candidate_and_retention(self) -> None:
        verifier = GATE.SignedEvidenceVerifier()
        source_files = {
            "Cargo.toml": b"[workspace]\nresolver = \"2\"\n",
            "domain-core/src/lib.rs": (
                b"pub const DOMAIN_CORE_ABI_VERSION: u32 = 3;\n"
            ),
        }
        identity = {
            "candidateCommit": "1" * 40,
            "coreVersion": "0.1.0",
            "abiVersion": 3,
            "sourceSha256": ROLLBACK_BUNDLE.source_fingerprint(source_files),
        }
        activation = {
            "candidateCommit": identity["candidateCommit"],
            "activationCommit": "4" * 40,
            "coreVersion": identity["coreVersion"],
            "abiVersion": identity["abiVersion"],
            "sourceSha256": identity["sourceSha256"],
            "changedPathsSha256": "5" * 64,
        }
        item = {
            "artifactKind": "legacy-rollback-bundle",
            "target": "all-supported-consumers",
            "artifactUri": "https://github.com/Imagine-That-Ai/BurnBar/releases/download/v1.2.3/OpenBurnBar-1.2.3-legacy-rollback.zip",
            "commit": activation["activationCommit"],
            "tag": "v1.2.3",
            "version": "1.2.3",
            "candidate": identity,
            "activation": activation,
            "retentionPolicy": "retain_until_legacy_deletion_complete",
        }
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            profile = root / "profile.json"
            activation_path = root / "activation.json"
            source_path = root / "legacy-source.tar.gz"
            bundle_path = root / "rollback.zip"
            repository, candidate_commit = create_candidate_repository(
                root,
                source_files=source_files,
                core_version=identity["coreVersion"],
                abi_version=identity["abiVersion"],
                source_sha256=identity["sourceSha256"],
                extra_repository_files={
                    "config/domain-core-build-profiles.json": b"{}\n"
                },
            )
            identity["candidateCommit"] = candidate_commit
            activation["candidateCommit"] = candidate_commit
            profile_value = {
                "schemaVersion": 1,
                "name": "public-production-rollback",
                "artifactAuthority": "signed",
                "distribution": "public",
                "rolloutChannel": None,
                "evidenceEnabled": False,
                "modes": {domain: "legacy" for domain in GATE.PROFILE_DOMAIN_ROWS},
                "candidateIdentity": identity,
                "release": {
                    "version": "1.2.3",
                    "tag": "v1.2.3",
                    "commit": activation["activationCommit"],
                },
            }
            write_git_source_archive(
                repository,
                source_path,
                candidate_commit=candidate_commit,
                version="1.2.3",
            )
            profile.write_text(json.dumps(profile_value))
            activation_path.write_text(json.dumps(activation))
            download_bytes = {}
            ROLLBACK_BUNDLE.create_bundle(
                profile,
                activation_path,
                bundle_path,
                source_path,
                version="1.2.3",
                tag="v1.2.3",
                commit=activation["activationCommit"],
                repository_root=repository,
            )
            contents = bundle_path.read_bytes()
        predicate = {
            "schemaVersion": 1,
            "artifactKind": "legacy-rollback-bundle",
            "target": "all-supported-consumers",
            "artifact": {
                "fileName": "OpenBurnBar-1.2.3-legacy-rollback.zip",
                "sha256": hashlib.sha256(contents).hexdigest(),
            },
            "release": {
                "version": "1.2.3",
                "tag": "v1.2.3",
                "commit": activation["activationCommit"],
                "candidate": identity,
                "activation": activation,
                "retentionPolicy": "retain_until_legacy_deletion_complete",
            },
        }
        download_bytes[item["artifactUri"]] = contents
        result = [{"verificationResult": {"statement": {"predicate": predicate}}}]

        def download(request, timeout=0):
            del timeout
            uri = request.full_url
            return FakeDownloadResponse(download_bytes[uri], "https://objects.githubusercontent.com/retained")

        with (
            mock.patch.object(GATE, "urlopen", side_effect=download),
            mock.patch.object(verifier, "_verify_bundle", return_value=result) as verify,
        ):
            verifier.verify_rollback_artifact(item, ROOT / "README.md", hashlib.sha256(contents).hexdigest())
        self.assertEqual(verify.call_args.kwargs["predicate_type"], GATE.ROLLBACK_PREDICATE_TYPE)
        wrong = copy.deepcopy(result)
        wrong[-1]["verificationResult"]["statement"]["predicate"]["release"]["retentionPolicy"] = "ephemeral"
        with (
            mock.patch.object(GATE, "urlopen", side_effect=download),
            mock.patch.object(verifier, "_verify_bundle", return_value=wrong),
            self.assertRaisesRegex(GATE.GateError, "does not bind the exact candidate"),
        ):
            verifier.verify_rollback_artifact(item, ROOT / "README.md", hashlib.sha256(contents).hexdigest())

    def test_security_rows_require_security_crypto_review(self) -> None:
        self.assertEqual(
            GATE.SECURITY_REVIEW_ROWS,
            {
                "cloudvault.portable_primitives",
                "cloudvault.document_rewrap",
                "cloudvault.search",
                "hermes.relay_crypto",
                "hermes.ratchet_transforms",
            },
        )
        catalog = GATE.load_deletion_reviewers(ROOT)
        self.assertEqual(set(catalog), {"domain_owner", "security_crypto"})
        self.assertEqual(catalog["domain_owner"], {"@emilio3435"})
        self.assertEqual(catalog["security_crypto"], {"@emilio3435"})

    def test_reviewer_catalog_rejects_an_empty_operational_roster(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory).resolve()
            (root / "config").mkdir()
            (root / GATE.DELETION_REVIEWERS_PATH).write_text(json.dumps({"schemaVersion": 1, "reviewers": []}))
            with self.assertRaisesRegex(GATE.GateError, "at least one qualified reviewer"):
                GATE.load_deletion_reviewers(root)
            self.assertEqual(
                GATE.load_deletion_reviewers(root, allow_missing=True),
                {"domain_owner": set(), "security_crypto": set()},
            )

    def test_reviewer_catalog_rejects_duplicates_and_unknown_classes(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory).resolve()
            (root / "config").mkdir()
            path = root / GATE.DELETION_REVIEWERS_PATH
            path.write_text(
                json.dumps(
                    {
                        "schemaVersion": 1,
                        "reviewers": [
                            {"handle": "@reviewer", "reviewClasses": ["domain_owner"]},
                            {
                                "handle": "@Reviewer",
                                "reviewClasses": ["security_crypto"],
                            },
                        ],
                    }
                )
            )
            with self.assertRaisesRegex(GATE.GateError, "duplicate reviewer"):
                GATE.load_deletion_reviewers(root)
            path.write_text(
                json.dumps(
                    {
                        "schemaVersion": 1,
                        "reviewers": [{"handle": "@reviewer", "reviewClasses": ["unqualified"]}],
                    }
                )
            )
            with self.assertRaisesRegex(GATE.GateError, "review classes"):
                GATE.load_deletion_reviewers(root)

    def test_rollback_authority_is_derived_from_protected_promotion_and_stable_bytes(self) -> None:
        candidate = {
            "candidateCommit": "1" * 40,
            "coreVersion": "1.2.3",
            "abiVersion": 3,
            "sourceSha256": "2" * 64,
        }
        activation = {
            **candidate,
            "activationCommit": "3" * 40,
            "changedPathsSha256": "4" * 64,
        }
        retained = {
            "artifactUri": "https://github.com/Imagine-That-Ai/BurnBar/releases/download/v1.2.3/OpenBurnBar-1.2.3-legacy-rollback.zip",
            "artifactSha256": "5" * 64,
            "provenanceSha256": "6" * 64,
            "retentionPolicy": "retain_until_legacy_deletion_complete",
        }
        with tempfile.TemporaryDirectory() as directory:
            repo = Path(directory).resolve()
            relative = f"{GATE.ATTESTATION_ROOT}/quota/1.json"
            attestation = repo / relative
            attestation.parent.mkdir(parents=True)
            attestation.write_text(
                json.dumps(
                    {
                        "unsignedBundle": {
                            "sha256": "7" * 64,
                            "sourceRunId": 11,
                            "sourceRunAttempt": 2,
                        },
                        "provenance": {
                            "signerRunId": 21,
                            "signerRunAttempt": 3,
                            "trustedMainCommit": "8" * 40,
                            "sha256": "9" * 64,
                        },
                    }
                )
            )
            promotion = GATE.Receipt(
                "promotion.json",
                "promotion",
                1,
                datetime(2026, 7, 14, tzinfo=UTC),
                candidate["candidateCommit"],
                "a" * 64,
                (),
                {"path": relative},
            )
            stable = GATE.Receipt(
                "stable_release.json",
                "stable_release",
                1,
                datetime(2026, 7, 15, tzinfo=UTC),
                activation["activationCommit"],
                "b" * 64,
                (),
                {
                    "candidate": candidate,
                    "activation": activation,
                    "rollbackArtifact": retained,
                },
            )
            with mock.patch.object(GATE, "require_commit", return_value="8" * 40):
                authority = GATE.rollback_authority_binding(
                    repo,
                    "quota.claude_statusline",
                    1,
                    promotion,
                    stable,
                )
        self.assertEqual(authority["candidate"], candidate)
        self.assertEqual(authority["activation"], activation)
        self.assertEqual(authority["candidateBundleSha256"], "7" * 64)
        self.assertEqual(
            authority["sourceRun"],
            {
                "repository": GATE.SignedEvidenceVerifier.repository,
                "workflowPath": GATE.SOURCE_WORKFLOW,
                "runId": 11,
                "runAttempt": 2,
                "event": "push",
                "ref": "refs/heads/main",
                "headSha": candidate["candidateCommit"],
            },
        )
        self.assertEqual(
            authority["promotionSigner"],
            {
                "workflowPath": GATE.PROMOTION_SIGNER_WORKFLOW,
                "runId": 21,
                "runAttempt": 3,
                "trustedMainCommit": "8" * 40,
                "provenanceSha256": "9" * 64,
            },
        )
        self.assertEqual(authority["retainedRollbackArtifact"], retained)

    def test_signed_rollback_completion_binds_authority_identity_and_live_action(self) -> None:
        candidate = {
            "candidateCommit": "1" * 40,
            "coreVersion": "1.2.3",
            "abiVersion": 3,
            "sourceSha256": "2" * 64,
        }
        activation = {
            **candidate,
            "activationCommit": "3" * 40,
            "changedPathsSha256": "4" * 64,
        }
        source_run = {
            "repository": GATE.SignedEvidenceVerifier.repository,
            "workflowPath": GATE.SOURCE_WORKFLOW,
            "runId": 51,
            "runAttempt": 2,
            "event": "push",
            "ref": "refs/heads/main",
            "headSha": candidate["candidateCommit"],
        }
        promotion_signer = {
            "workflowPath": GATE.PROMOTION_SIGNER_WORKFLOW,
            "runId": 61,
            "runAttempt": 3,
            "trustedMainCommit": "5" * 40,
            "provenanceSha256": "6" * 64,
        }
        action_run = {
            "repository": GATE.SignedEvidenceVerifier.repository,
            "workflowPath": GATE.ROLLBACK_ACTION_WORKFLOWS["console"],
            "runId": 81,
            "runAttempt": 4,
            "event": "workflow_dispatch",
            "ref": "refs/tags/v1.2.3",
            "headSha": activation["activationCommit"],
            "jobSetSha256": "7" * 64,
        }
        artifact_bytes = b"completed console rollback"
        provenance_bytes = b"signed rollback provenance"
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory).resolve()
            artifact = root / "console.json"
            bundle = root / "console.sigstore.json"
            artifact.write_bytes(artifact_bytes)
            bundle.write_bytes(provenance_bytes)
            item = {
                "consumer": "console",
                "domain": "cloudVault",
                "artifactSha256": hashlib.sha256(artifact_bytes).hexdigest(),
                "provenanceSha256": hashlib.sha256(provenance_bytes).hexdigest(),
                "rollbackProfileSha256": "8" * 64,
                "release": {
                    "version": "1.2.3",
                    "tag": "v1.2.3",
                    "commit": activation["activationCommit"],
                },
                "signer": {
                    "runId": 71,
                    "runAttempt": 2,
                },
                "actionRun": action_run,
                "deployedArtifactSha256": "9" * 64,
                "healthArtifactSha256": "a" * 64,
                "completedAt": "2026-07-17T00:00:00Z",
            }
            predicate = {
                "schemaVersion": 2,
                "predicateType": GATE.RELEASE_PREDICATE_TYPES["console"],
                "consumer": "console",
                "domain": "cloudVault",
                "artifactKind": "console-deployment-receipt",
                "target": "firebase-hosting-production",
                "candidate": candidate,
                "activation": activation,
                "publicProfile": {
                    "profile": "public-production-rollback",
                    "domain": "cloudVault",
                    "mode": "legacy",
                    "sha256": item["rollbackProfileSha256"],
                },
                "release": {
                    **item["release"],
                    "publicProfileSha256": item["rollbackProfileSha256"],
                },
                "artifact": {
                    "fileName": "OpenBurnBar-1.2.3-console-deployment.json",
                    "sha256": item["artifactSha256"],
                },
                "sourceRun": source_run,
                "promotionProof": {
                    "signerWorkflow": GATE.PROMOTION_SIGNER_WORKFLOW,
                    "predicateType": "https://slsa.dev/provenance/v1",
                    "signerRun": {
                        "runId": promotion_signer["runId"],
                        "runAttempt": promotion_signer["runAttempt"],
                    },
                    "attestationSubject": {
                        "fileName": "domain-core-candidate-bundle.json",
                        "sha256": "b" * 64,
                    },
                },
                "rollbackArtifact": {
                    "sha256": "c" * 64,
                    "candidate": candidate,
                    "activation": activation,
                },
                "deployment": {
                    "status": "healthy",
                    "deployRun": action_run,
                    "deployedArtifact": {"sha256": item["deployedArtifactSha256"]},
                    "healthArtifactSha256": item["healthArtifactSha256"],
                },
            }

            def verified(value: dict, invocation_attempt: int = 2) -> list[dict]:
                return [
                    {
                        "verificationResult": {
                            "statement": {"predicate": value},
                            "signature": {
                                "certificate": {
                                    "runInvocationURI": (
                                        "https://github.com/Imagine-That-Ai/BurnBar/actions/runs/71/attempts/"
                                        f"{invocation_attempt}"
                                    )
                                }
                            },
                        }
                    }
                ]

            def github_json(endpoint: str, _label: str) -> dict:
                if endpoint.endswith("/actions/runs/71/attempts/2"):
                    return {
                        "path": GATE.RELEASE_SIGNER_WORKFLOWS["console"],
                        "head_sha": activation["activationCommit"],
                        "status": "completed",
                        "conclusion": "success",
                        "run_attempt": 2,
                        "head_branch": "v1.2.3",
                        "repository": {"full_name": GATE.SignedEvidenceVerifier.repository},
                    }
                if endpoint.endswith("/actions/runs/81/attempts/4"):
                    return {
                        "path": GATE.ROLLBACK_ACTION_WORKFLOWS["console"],
                        "event": "workflow_dispatch",
                        "head_sha": activation["activationCommit"],
                        "status": "completed",
                        "conclusion": "success",
                        "run_attempt": 4,
                        "head_branch": "v1.2.3",
                        "updated_at": "2026-07-17T00:00:00Z",
                        "repository": {"full_name": GATE.SignedEvidenceVerifier.repository},
                    }
                raise AssertionError(endpoint)

            verifier = GATE.SignedEvidenceVerifier()
            with (
                mock.patch.object(verifier, "_verify_bundle", return_value=verified(predicate)),
                mock.patch.object(verifier, "_github_json", side_effect=github_json),
            ):
                completed_at = verifier.verify_rollback_completion(
                    item,
                    artifact,
                    bundle,
                    candidate=candidate,
                    activation=activation,
                    source_run=source_run,
                    promotion_signer=promotion_signer,
                    candidate_bundle_sha256="b" * 64,
                    retained_rollback_sha256="c" * 64,
                    domain="cloudVault",
                )
            self.assertEqual(completed_at, datetime(2026, 7, 17, tzinfo=UTC))

            substitutions = (
                ("candidate", ("candidate", "candidateCommit"), "d" * 40),
                ("activation", ("activation", "changedPathsSha256"), "d" * 64),
                ("source attempt", ("sourceRun", "runAttempt"), 99),
                ("promotion attempt", ("promotionProof", "signerRun", "runAttempt"), 99),
                ("retained rollback", ("rollbackArtifact", "sha256"), "d" * 64),
                ("consumer artifact", ("artifactKind",), "macos-dmg"),
                ("release tag", ("release", "tag"), "v1.2.4"),
                ("deployment status", ("deployment", "status"), "pending"),
                ("deployed bytes", ("deployment", "deployedArtifact", "sha256"), "d" * 64),
                ("health bytes", ("deployment", "healthArtifactSha256"), "d" * 64),
            )
            for label, path, replacement in substitutions:
                substituted = copy.deepcopy(predicate)
                target = substituted
                for key in path[:-1]:
                    target = target[key]
                target[path[-1]] = replacement
                with (
                    self.subTest(label=label),
                    mock.patch.object(verifier, "_verify_bundle", return_value=verified(substituted)),
                    self.assertRaisesRegex(GATE.GateError, "exactly one signed predicate"),
                ):
                    verifier.verify_rollback_completion(
                        item,
                        artifact,
                        bundle,
                        candidate=candidate,
                        activation=activation,
                        source_run=source_run,
                        promotion_signer=promotion_signer,
                        candidate_bundle_sha256="b" * 64,
                        retained_rollback_sha256="c" * 64,
                        domain="cloudVault",
                    )
            with (
                mock.patch.object(verifier, "_verify_bundle", return_value=verified(predicate, 9)),
                self.assertRaisesRegex(GATE.GateError, "exact signer run and attempt"),
            ):
                verifier.verify_rollback_completion(
                    item,
                    artifact,
                    bundle,
                    candidate=candidate,
                    activation=activation,
                    source_run=source_run,
                    promotion_signer=promotion_signer,
                    candidate_bundle_sha256="b" * 64,
                    retained_rollback_sha256="c" * 64,
                    domain="cloudVault",
                )
            stale = {**item, "completedAt": "2026-07-16T00:00:00Z"}
            with (
                mock.patch.object(verifier, "_verify_bundle", return_value=verified(predicate)),
                mock.patch.object(verifier, "_github_json", side_effect=github_json),
                self.assertRaisesRegex(GATE.GateError, "completion timestamp"),
            ):
                verifier.verify_rollback_completion(
                    stale,
                    artifact,
                    bundle,
                    candidate=candidate,
                    activation=activation,
                    source_run=source_run,
                    promotion_signer=promotion_signer,
                    candidate_bundle_sha256="b" * 64,
                    retained_rollback_sha256="c" * 64,
                    domain="cloudVault",
                )

    def test_rollback_receipt_rejects_substituted_authority_and_self_approval(self) -> None:
        candidate = {
            "candidateCommit": "1" * 40,
            "coreVersion": "1.2.3",
            "abiVersion": 3,
            "sourceSha256": "2" * 64,
        }
        activation = {
            **candidate,
            "activationCommit": "3" * 40,
            "changedPathsSha256": "4" * 64,
        }
        authority = {
            "candidate": candidate,
            "activation": activation,
            "candidateBundleSha256": "5" * 64,
            "sourceRun": {
                "repository": GATE.SignedEvidenceVerifier.repository,
                "workflowPath": GATE.SOURCE_WORKFLOW,
                "runId": 11,
                "runAttempt": 2,
                "event": "push",
                "ref": "refs/heads/main",
                "headSha": candidate["candidateCommit"],
            },
            "promotionSigner": {
                "workflowPath": GATE.PROMOTION_SIGNER_WORKFLOW,
                "runId": 21,
                "runAttempt": 3,
                "trustedMainCommit": "6" * 40,
                "provenanceSha256": "7" * 64,
            },
            "retainedRollbackArtifact": {
                "artifactUri": "https://github.com/Imagine-That-Ai/BurnBar/releases/download/v1.2.3/OpenBurnBar-1.2.3-legacy-rollback.zip",
                "artifactSha256": "8" * 64,
                "provenanceSha256": "9" * 64,
                "retentionPolicy": "retain_until_legacy_deletion_complete",
            },
        }
        catalog = b'{"reviewers":["@release-owner"]}\n'
        payload = {
            "stableReceiptSha256": "a" * 64,
            "issueUri": "https://github.com/Imagine-That-Ai/BurnBar/issues/123",
            "activatedAt": "2026-07-17T00:00:00Z",
            "candidate": candidate,
            "activation": activation,
            "authority": {
                key: copy.deepcopy(authority[key]) for key in ("candidateBundleSha256", "sourceRun", "promotionSigner")
            },
            "retainedRollbackArtifact": copy.deepcopy(authority["retainedRollbackArtifact"]),
            "approverAuthority": {
                "reviewClass": "domain_owner",
                "catalogSha256": hashlib.sha256(catalog).hexdigest(),
                "trustedMainCommit": authority["promotionSigner"]["trustedMainCommit"],
            },
            "completionEvidence": [],
        }
        promotion = GATE.Receipt(
            "promotion.json",
            "promotion",
            1,
            datetime(2026, 7, 14, tzinfo=UTC),
            candidate["candidateCommit"],
            "b" * 64,
            (),
            {},
        )
        stable = GATE.Receipt(
            "stable_release.json",
            "stable_release",
            1,
            datetime(2026, 7, 15, tzinfo=UTC),
            activation["activationCommit"],
            payload["stableReceiptSha256"],
            (),
            {},
        )

        mutations = (
            ("candidate", ("candidate", "candidateCommit"), "c" * 40, "governed promotion"),
            ("activation", ("activation", "changedPathsSha256"), "c" * 64, "governed stable release"),
            ("source run", ("authority", "sourceRun", "runAttempt"), 99, "source and promotion authority"),
            ("signer run", ("authority", "promotionSigner", "runAttempt"), 99, "source and promotion authority"),
            ("artifact digest", ("retainedRollbackArtifact", "artifactSha256"), "c" * 64, "retained rollback artifact"),
            (
                "provenance digest",
                ("retainedRollbackArtifact", "provenanceSha256"),
                "c" * 64,
                "retained rollback artifact",
            ),
            ("trusted main", ("approverAuthority", "trustedMainCommit"), "c" * 40, "protected trusted main"),
            ("catalog", ("approverAuthority", "catalogSha256"), "c" * 64, "catalog digest"),
        )
        for label, path, replacement, error in mutations:
            mutated = copy.deepcopy(payload)
            target = mutated
            for key in path[:-1]:
                target = target[key]
            target[path[-1]] = replacement
            receipt = GATE.Receipt(
                "rollback.json",
                "rollback",
                1,
                datetime(2026, 7, 18, tzinfo=UTC),
                "d" * 40,
                "e" * 64,
                (),
                mutated,
                approved_by="@release-owner",
            )
            with (
                self.subTest(label=label),
                mock.patch.object(GATE, "require_ancestor"),
                mock.patch.object(GATE, "rollback_authority_binding", return_value=authority),
                mock.patch.object(GATE, "git_file", return_value=catalog),
                mock.patch.object(
                    GATE,
                    "load_deletion_reviewers",
                    return_value={"domain_owner": {"@release-owner"}},
                ),
                self.assertRaisesRegex(GATE.GateError, error),
            ):
                GATE.validate_rollback_receipt(
                    ROOT,
                    "quota.claude_statusline",
                    1,
                    receipt,
                    promotion,
                    stable,
                    mock.Mock(),
                )

        self_authored = GATE.Receipt(
            "rollback.json",
            "rollback",
            1,
            datetime(2026, 7, 18, tzinfo=UTC),
            "d" * 40,
            "e" * 64,
            (),
            payload,
            approved_by="@rollback-author",
        )
        with (
            mock.patch.object(GATE, "require_ancestor"),
            mock.patch.object(GATE, "rollback_authority_binding", return_value=authority),
            mock.patch.object(GATE, "git_file", return_value=catalog),
            mock.patch.object(
                GATE,
                "load_deletion_reviewers",
                return_value={"domain_owner": {"@release-owner"}},
            ),
            self.assertRaisesRegex(GATE.GateError, "approver is not qualified"),
        ):
            GATE.validate_rollback_receipt(
                ROOT,
                "quota.claude_statusline",
                1,
                self_authored,
                promotion,
                stable,
                mock.Mock(),
            )

    def test_rollback_completion_covers_exact_consumers_with_native_release_tags(self) -> None:
        row_id = "quota.claude_statusline"
        candidate = {
            "candidateCommit": "1" * 40,
            "coreVersion": "1.2.3",
            "abiVersion": 3,
            "sourceSha256": "2" * 64,
        }
        activation = {
            **candidate,
            "activationCommit": "3" * 40,
            "changedPathsSha256": "4" * 64,
        }
        authority = {
            "candidate": candidate,
            "activation": activation,
            "candidateBundleSha256": "5" * 64,
            "sourceRun": {
                "repository": GATE.SignedEvidenceVerifier.repository,
                "workflowPath": GATE.SOURCE_WORKFLOW,
                "runId": 11,
                "runAttempt": 2,
                "event": "push",
                "ref": "refs/heads/main",
                "headSha": candidate["candidateCommit"],
            },
            "promotionSigner": {
                "workflowPath": GATE.PROMOTION_SIGNER_WORKFLOW,
                "runId": 21,
                "runAttempt": 3,
                "trustedMainCommit": "6" * 40,
                "provenanceSha256": "7" * 64,
            },
            "retainedRollbackArtifact": {
                "artifactUri": "https://github.com/Imagine-That-Ai/BurnBar/releases/download/v1.2.3/OpenBurnBar-1.2.3-legacy-rollback.zip",
                "artifactSha256": "8" * 64,
                "provenanceSha256": "9" * 64,
                "retentionPolicy": "retain_until_legacy_deletion_complete",
            },
        }
        catalog = b"protected approver catalog"
        with tempfile.TemporaryDirectory() as directory:
            repo = Path(directory).resolve()
            completions = []
            for index, (consumer, tag) in enumerate(
                (("apple", "v1.2.3"), ("linux", "linux-v1.2.3"), ("windows", "windows-v1.2.3")),
                start=1,
            ):
                root = repo / GATE.ROLLBACK_COMPLETION_ROOT / row_id / "1"
                root.mkdir(parents=True, exist_ok=True)
                artifact = root / f"{consumer}.json"
                provenance = root / f"{consumer}.sigstore.json"
                artifact.write_text(json.dumps({"consumer": consumer, "completed": True}))
                provenance.write_text(json.dumps({"consumer": consumer, "signed": True}))
                artifact_digest = hashlib.sha256(artifact.read_bytes()).hexdigest()
                provenance_digest = hashlib.sha256(provenance.read_bytes()).hexdigest()
                completions.append(
                    {
                        "consumer": consumer,
                        "domain": "quota",
                        "artifactPath": artifact.relative_to(repo).as_posix(),
                        "artifactSha256": artifact_digest,
                        "provenancePath": provenance.relative_to(repo).as_posix(),
                        "provenanceSha256": provenance_digest,
                        "rollbackProfileSha256": "a" * 64,
                        "release": {
                            "version": "1.2.3",
                            "tag": tag,
                            "commit": activation["activationCommit"],
                        },
                        "signer": {
                            "workflowPath": GATE.RELEASE_SIGNER_WORKFLOWS[consumer],
                            "runId": 30 + index,
                            "runAttempt": 2,
                            "runInvocationUri": (
                                f"https://github.com/Imagine-That-Ai/BurnBar/actions/runs/{30 + index}/attempts/2"
                            ),
                        },
                        "actionRun": {
                            "repository": GATE.SignedEvidenceVerifier.repository,
                            "workflowPath": GATE.RELEASE_SIGNER_WORKFLOWS[consumer],
                            "runId": 30 + index,
                            "runAttempt": 2,
                            "event": "workflow_dispatch",
                            "ref": f"refs/tags/{tag}",
                            "headSha": activation["activationCommit"],
                        },
                        "deployedArtifactSha256": artifact_digest,
                        "healthArtifactSha256": None,
                        "completedAt": "2026-07-17T00:00:00Z",
                    }
                )
            payload = {
                "stableReceiptSha256": "b" * 64,
                "issueUri": "https://github.com/Imagine-That-Ai/BurnBar/issues/123",
                "activatedAt": "2026-07-17T00:00:00Z",
                "candidate": candidate,
                "activation": activation,
                "authority": {
                    key: copy.deepcopy(authority[key])
                    for key in ("candidateBundleSha256", "sourceRun", "promotionSigner")
                },
                "retainedRollbackArtifact": copy.deepcopy(authority["retainedRollbackArtifact"]),
                "approverAuthority": {
                    "reviewClass": "domain_owner",
                    "catalogSha256": hashlib.sha256(catalog).hexdigest(),
                    "trustedMainCommit": authority["promotionSigner"]["trustedMainCommit"],
                },
                "completionEvidence": completions,
            }
            promotion = GATE.Receipt(
                "promotion.json",
                "promotion",
                1,
                datetime(2026, 7, 14, tzinfo=UTC),
                candidate["candidateCommit"],
                "c" * 64,
                (),
                {},
            )
            stable = GATE.Receipt(
                "stable_release.json",
                "stable_release",
                1,
                datetime(2026, 7, 15, tzinfo=UTC),
                activation["activationCommit"],
                payload["stableReceiptSha256"],
                (),
                {},
            )
            rollback = GATE.Receipt(
                "rollback.json",
                "rollback",
                1,
                datetime(2026, 7, 18, tzinfo=UTC),
                "d" * 40,
                "e" * 64,
                (),
                payload,
                approved_by="@release-owner",
            )
            verifier = mock.Mock()
            verifier.verify_rollback_completion.return_value = datetime(2026, 7, 17, tzinfo=UTC)

            def committed_bytes(_repo: Path, _commit: str, path: str, _label: str) -> bytes:
                if path == GATE.DELETION_REVIEWERS_PATH:
                    return catalog
                return (repo / path).read_bytes()

            with (
                mock.patch.object(GATE, "require_ancestor"),
                mock.patch.object(GATE, "rollback_authority_binding", return_value=authority),
                mock.patch.object(GATE, "git_file", side_effect=committed_bytes),
                mock.patch.object(
                    GATE,
                    "load_deletion_reviewers",
                    return_value={"domain_owner": {"@release-owner"}},
                ),
            ):
                GATE.validate_rollback_receipt(
                    repo,
                    row_id,
                    1,
                    rollback,
                    promotion,
                    stable,
                    verifier,
                )
            self.assertEqual(verifier.verify_rollback_completion.call_count, 3)

            missing = copy.deepcopy(payload)
            missing["completionEvidence"] = copy.deepcopy(completions[:-1])
            missing_receipt = GATE.Receipt(
                "rollback.json",
                "rollback",
                1,
                datetime(2026, 7, 18, tzinfo=UTC),
                "d" * 40,
                "e" * 64,
                (),
                missing,
                approved_by="@release-owner",
            )
            with (
                mock.patch.object(GATE, "require_ancestor"),
                mock.patch.object(GATE, "rollback_authority_binding", return_value=authority),
                mock.patch.object(GATE, "git_file", side_effect=committed_bytes),
                mock.patch.object(
                    GATE,
                    "load_deletion_reviewers",
                    return_value={"domain_owner": {"@release-owner"}},
                ),
                self.assertRaisesRegex(GATE.GateError, "exact governed consumer set"),
            ):
                GATE.validate_rollback_receipt(
                    repo,
                    row_id,
                    1,
                    missing_receipt,
                    promotion,
                    stable,
                    verifier,
                )

    def test_all_governance_schemas_are_valid_json(self) -> None:
        for path in (
            ROOT / "config/domain-core-legacy-deletion.schema.json",
            ROOT / "config/domain-core-legacy-deletion-receipt.schema.json",
            ROOT / "config/domain-core-deletion-plan.schema.json",
            ROOT / "config/domain-core-deletion-reviewers.schema.json",
            ROOT / "config/domain-core-promotion-attestation.schema.json",
        ):
            self.assertIsInstance(json.loads(path.read_text()), dict)

    @staticmethod
    def make_bundle(identity: dict) -> dict:
        return {
            "schemaVersion": 1,
            "bundleKind": "unsigned-domain-core-candidate",
            "status": "eligible_for_attestation",
            "proofComplete": True,
            "eligibleForAttestation": True,
            "promotionAuthorized": False,
            "trust": {
                "authority": "none",
                "attestationRequired": True,
                "requiredSigner": GATE.PROMOTION_SIGNER_JOB,
                "verificationSteps": [
                    "query-github-api",
                    "download-exact-run-artifacts",
                    "revalidate-with-trusted-main",
                    "sign-protected-attestation",
                ],
            },
            "generatedAt": "2026-07-15T00:00:00Z",
            "candidate": identity,
            "policySha256": "4" * 64,
            "workflow": {
                "repository": GATE.SignedEvidenceVerifier.repository,
                "workflowPath": GATE.SOURCE_WORKFLOW,
                "workflowName": "Shared Rust domain core",
                "runId": 11,
                "runAttempt": 2,
                "event": "push",
                "ref": "refs/heads/main",
                "headSha": identity["candidateCommit"],
                "jobs": [],
            },
            "suites": [],
            "coverage": [],
            "artifacts": [],
            "benchmarks": [],
            "rollback": {},
        }

    @staticmethod
    def provenance_bytes() -> bytes:
        return json.dumps(
            {
                "mediaType": "application/vnd.dev.sigstore.bundle.v0.3+json",
                "verificationMaterial": {},
                "dsseEnvelope": {},
            }
        ).encode()

    @staticmethod
    def run_json(commit: str, event: str, attempt: int, path: str) -> dict:
        return {
            "event": event,
            "path": path,
            "head_branch": "main",
            "head_sha": commit,
            "status": "completed",
            "conclusion": "success",
            "run_attempt": attempt,
            "repository": {"full_name": GATE.SignedEvidenceVerifier.repository},
        }

    @staticmethod
    def make_candidate_repo(repo: Path) -> tuple[Path, str]:
        (repo / "crates/openburnbar-domain-core").mkdir(parents=True)
        (repo / "scripts/lib").mkdir(parents=True)
        (repo / "config").mkdir(parents=True)
        (repo / "crates/openburnbar-domain-core/union-abi-manifest.json").write_text(
            json.dumps(
                {
                    "schemaVersion": 1,
                    "coreVersion": "0.3.0",
                    "abiVersion": 3,
                    "sourceSha256": "2" * 64,
                }
            )
            + "\n"
        )
        (repo / "crates/openburnbar-domain-core/Cargo.toml").write_text(
            '[workspace]\n[workspace.package]\nversion = "0.3.0"\n'
        )
        (repo / GATE.PROMOTION_POLICY_PATH).write_text((ROOT / GATE.PROMOTION_POLICY_PATH).read_text())
        (repo / GATE.PROMOTION_EVALUATOR_PATH).write_text((ROOT / GATE.PROMOTION_EVALUATOR_PATH).read_text())
        subprocess.run(["git", "init", "-q"], cwd=repo, check=True)
        subprocess.run(
            ["git", "config", "user.email", "test@openburnbar.invalid"],
            cwd=repo,
            check=True,
        )
        subprocess.run(["git", "config", "user.name", "OpenBurnBar Test"], cwd=repo, check=True)
        subprocess.run(["git", "add", "."], cwd=repo, check=True)
        subprocess.run(["git", "commit", "-qm", "candidate"], cwd=repo, check=True)
        commit = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=repo, text=True).strip()
        return repo, commit

    @staticmethod
    def make_minimal_rollout_repo(repo: Path) -> tuple[Path, dict]:
        (repo / "config").mkdir(parents=True)
        (repo / "src").mkdir()
        rows = []
        for index, row_id in enumerate(GATE.ROW_IDS):
            relative = f"src/legacy_{index}.txt"
            symbol = f"legacySymbol{index}"
            (repo / relative).write_text(f"func {symbol}() {{}}\n")
            rows.append(
                {
                    "id": row_id,
                    "state": "rollout",
                    "authorityGeneration": 0,
                    "receipts": {},
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
        for relative in (
            GATE.PROMOTION_POLICY_PATH,
            GATE.BUILD_PROFILE_PATH,
            GATE.DELETION_REVIEWERS_PATH,
        ):
            destination = repo / relative
            destination.parent.mkdir(parents=True, exist_ok=True)
            destination.write_text((ROOT / relative).read_text())
        profile_path = repo / GATE.BUILD_PROFILE_PATH
        profiles = json.loads(profile_path.read_text())
        profiles["profiles"]["public-production"]["modes"] = {domain: "legacy" for domain in profiles["domains"]}
        profile_path.write_text(json.dumps(profiles))
        return repo, manifest


if __name__ == "__main__":
    unittest.main()
