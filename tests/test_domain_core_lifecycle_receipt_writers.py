#!/usr/bin/env python3
"""Contract tests for append-only stable-release and rollback receipt writers."""

from __future__ import annotations

import hashlib
import importlib.util
import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock


ROOT = Path(__file__).resolve().parents[1]


def load(name: str, path: Path):
    spec = importlib.util.spec_from_file_location(name, path)
    if spec is None or spec.loader is None:
        raise RuntimeError(f"cannot load {path}")
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module


STABLE = load(
    "domain_core_stable_receipt_writer",
    ROOT / "scripts/ops/create-domain-core-stable-receipt.py",
)

ANNULMENT = load(
    "domain_core_activation_annulment_receipt_writer",
    ROOT / "scripts/ops/create-domain-core-activation-annulment-receipt.py",
)

ROLLBACK = load(
    "domain_core_rollback_receipt_writer",
    ROOT / "scripts/ops/create-domain-core-rollback-receipt.py",
)


class LifecycleReceiptWriterTests(unittest.TestCase):
    def test_lifecycle_writers_expose_bounded_required_cli(self) -> None:
        for script in (
            "scripts/ops/create-domain-core-activation-annulment-receipt.py",
            "scripts/ops/create-domain-core-stable-receipt.py",
            "scripts/ops/create-domain-core-rollback-receipt.py",
        ):
            result = subprocess.run(
                [sys.executable, script, "--help"],
                cwd=ROOT,
                check=False,
                capture_output=True,
                text=True,
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn("--authority-generation", result.stdout)
            self.assertIn("--approved-at", result.stdout)

    def test_stable_writer_rejects_future_approval_before_reading_authority(
        self,
    ) -> None:
        with self.assertRaisesRegex(STABLE.GATE.GateError, "cannot be in the future"):
            STABLE.create_receipt(
                ROOT,
                row_id="quota.claude_statusline",
                generation=1,
                activation_commit="a" * 40,
                release_paths=[],
                rollback_path=ROOT / "missing.json",
                approved_by="@release-owner",
                approved_at="2999-01-01T00:00:00Z",
            )

    def test_writers_use_create_only_append_semantics(self) -> None:
        annulment = (
            ROOT / "scripts/ops/create-domain-core-activation-annulment-receipt.py"
        ).read_text()
        stable = (ROOT / "scripts/ops/create-domain-core-stable-receipt.py").read_text()
        rollback = (ROOT / "scripts/ops/create-domain-core-rollback-receipt.py").read_text()
        for source in (annulment, stable, rollback):
            self.assertIn("WRITER.append_only", source)
            self.assertIn("WRITER.serialized", source)

    def test_annulment_writer_binds_promotion_activation_and_advanced_main(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            repo = Path(directory).resolve()
            row_id = "quota.claude_statusline"
            promotion_relative = f"{ANNULMENT.GATE.RECEIPT_ROOT}/{row_id}/1/promotion.json"
            attestation_relative = f"{ANNULMENT.GATE.ATTESTATION_ROOT}/quota/1.json"
            promotion_path = repo / promotion_relative
            attestation_path = repo / attestation_relative
            promotion_path.parent.mkdir(parents=True)
            attestation_path.parent.mkdir(parents=True)
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
            promotion_path.write_text(
                json.dumps({"promotionAttestation": {"path": attestation_relative}})
            )
            attestation_path.write_text(json.dumps({"candidate": candidate}))
            promotion = ANNULMENT.GATE.Receipt(
                path=promotion_relative,
                transition="promotion",
                generation=1,
                approved_at=ANNULMENT.GATE.parse_rfc3339_utc(
                    "2026-07-27T00:00:00Z",
                    "approved",
                ),
                commit=candidate["candidateCommit"],
                digest="5" * 64,
                evidence=("https://github.com/Imagine-That-Ai/BurnBar/attestations/1",),
                payload={},
            )
            with (
                mock.patch.object(ANNULMENT.GATE, "validate_receipt", return_value=promotion),
                mock.patch.object(
                    ANNULMENT.GATE,
                    "require_commit",
                    side_effect=lambda _repo, value, _label: value,
                ),
                mock.patch.object(
                    ANNULMENT.GATE,
                    "validate_annullable_activation_closure",
                    return_value=activation,
                ),
                mock.patch.object(
                    ANNULMENT.GATE,
                    "public_production_profile",
                    return_value=({"quota": "legacy"}, {"quota": "6" * 64}),
                ),
                mock.patch.object(
                    ANNULMENT.GATE,
                    "validate_activation_annulment_receipt",
                ) as validate_annulment,
            ):
                receipt = ANNULMENT.create_receipt(
                    repo,
                    row_id=row_id,
                    generation=1,
                    activation_commit=activation["activationCommit"],
                    advanced_main_commit="7" * 40,
                    evidence=["https://github.com/Imagine-That-Ai/BurnBar/pull/2097"],
                    approved_by="@release-owner",
                    approved_at="2026-07-28T00:00:00Z",
                )
            self.assertEqual(receipt["transition"], "annulment")
            self.assertEqual(
                receipt["activationAnnulment"]["promotionReceiptSha256"],
                promotion.digest,
            )
            self.assertTrue(
                receipt["activationAnnulment"]["replacementCandidateRequired"]
            )
            validate_annulment.assert_called_once()

    def test_stable_writer_reuses_full_gate_before_immutable_append(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            repo = Path(directory).resolve()
            row_id = "quota.claude_statusline"
            promotion_relative = f"{STABLE.GATE.RECEIPT_ROOT}/{row_id}/1/promotion.json"
            attestation_relative = f"{STABLE.GATE.ATTESTATION_ROOT}/quota/1.json"
            promotion = repo / promotion_relative
            attestation = repo / attestation_relative
            promotion.parent.mkdir(parents=True)
            attestation.parent.mkdir(parents=True)
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
            promotion.write_text(json.dumps({"promotionAttestation": {"path": attestation_relative}}))
            attestation.write_text(json.dumps({"candidate": candidate}))
            release_paths = []
            for consumer in ("apple", "linux", "windows"):
                path = repo / f"{consumer}.json"
                path.write_text(
                    json.dumps(
                        {
                            "consumer": consumer,
                            "candidate": candidate,
                            "activation": activation,
                            "commit": activation["activationCommit"],
                            "artifactUri": f"https://example.com/{consumer}",
                        }
                    )
                )
                release_paths.append(path)
            rollback = repo / "rollback.json"
            rollback.write_text(
                json.dumps(
                    {
                        "candidate": candidate,
                        "activation": activation,
                        "commit": activation["activationCommit"],
                        "artifactUri": "https://example.com/rollback",
                    }
                )
            )
            promotion_receipt = STABLE.GATE.Receipt(
                path=promotion_relative,
                transition="promotion",
                generation=1,
                approved_at=STABLE.GATE.parse_rfc3339_utc("2026-07-14T00:00:00Z", "approved"),
                commit=candidate["candidateCommit"],
                digest="5" * 64,
                evidence=("https://example.com/promotion",),
                payload={},
            )
            verifier = object()
            with (
                mock.patch.object(STABLE.GATE, "validate_activation_closure", return_value=activation),
                mock.patch.object(
                    STABLE.GATE,
                    "public_production_profile",
                    return_value=({"quota": "rust"}, {"quota": "6" * 64}),
                ),
                mock.patch.object(STABLE.GATE, "validate_receipt", return_value=promotion_receipt),
                mock.patch.object(STABLE.GATE, "validate_receipt_chain") as validate_chain,
            ):
                STABLE.create_receipt(
                    repo,
                    row_id=row_id,
                    generation=1,
                    activation_commit=activation["activationCommit"],
                    release_paths=release_paths,
                    rollback_path=rollback,
                    approved_by="@release-owner",
                    approved_at="2026-07-15T00:00:00Z",
                    evidence_verifier=verifier,
                )
            validate_chain.assert_called_once()
            self.assertIs(validate_chain.call_args.args[5], verifier)

    def test_rollback_writer_rejects_plan_without_post_action_completion(self) -> None:
        promotion = ROLLBACK.GATE.Receipt(
            path="promotion.json",
            transition="promotion",
            generation=1,
            approved_at=ROLLBACK.GATE.parse_rfc3339_utc("2026-07-14T00:00:00Z", "approved"),
            commit="1" * 40,
            digest="2" * 64,
            evidence=(),
            payload={},
        )
        stable = ROLLBACK.GATE.Receipt(
            path="stable_release.json",
            transition="stable_release",
            generation=1,
            approved_at=ROLLBACK.GATE.parse_rfc3339_utc("2026-07-15T00:00:00Z", "approved"),
            commit="3" * 40,
            digest="4" * 64,
            evidence=(),
            payload={},
        )
        authority = {
            "promotionSigner": {"trustedMainCommit": "5" * 40},
            "retainedRollbackArtifact": {"artifactUri": "https://example.com/rollback.zip"},
        }
        with tempfile.TemporaryDirectory() as directory:
            repo = Path(directory).resolve()
            stable_path = (
                repo
                / ROLLBACK.GATE.RECEIPT_ROOT
                / "quota.claude_statusline"
                / "1"
                / "stable_release.json"
            )
            stable_path.parent.mkdir(parents=True)
            stable_path.write_text("{}\n")
            with (
                mock.patch.object(ROLLBACK.GATE, "require_commit", return_value="6" * 40),
                mock.patch.object(ROLLBACK.GATE, "require_ancestor"),
                mock.patch.object(
                    ROLLBACK.GATE,
                    "validate_receipt",
                    side_effect=[promotion, stable],
                ),
                mock.patch.object(
                    ROLLBACK.GATE,
                    "rollback_authority_binding",
                    return_value=authority,
                ),
                mock.patch.object(ROLLBACK.GATE, "validate_receipt_chain") as validate_chain,
                self.assertRaisesRegex(
                    ROLLBACK.GATE.GateError,
                    "plan alone cannot activate rollback",
                ),
            ):
                ROLLBACK.create_receipt(
                    repo,
                    row_id="quota.claude_statusline",
                    generation=1,
                    stable_receipt_path=stable_path,
                    rollback_commit="6" * 40,
                    issue_uri="https://github.com/Imagine-That-Ai/BurnBar/issues/123",
                    completion_inputs=[],
                    approved_by="@release-owner",
                    approved_at="2026-07-16T00:00:00Z",
                )
            validate_chain.assert_not_called()

    def test_hosting_completion_requires_healthy_post_deploy_evidence(self) -> None:
        row_id = "cloudvault.portable_primitives"
        with tempfile.TemporaryDirectory() as directory:
            repo = Path(directory).resolve()
            completion_root = repo / ROLLBACK.GATE.ROLLBACK_COMPLETION_ROOT / row_id / "1"
            completion_root.mkdir(parents=True)
            artifact = completion_root / "console.json"
            provenance = completion_root / "console.sigstore.json"
            receipt = {
                "consumer": "console",
                "domain": "cloudVault",
                "publicProfile": {
                    "profile": "public-production-rollback",
                    "mode": "legacy",
                    "sha256": "1" * 64,
                },
                "release": {
                    "version": "1.2.3",
                    "tag": "v1.2.3",
                    "commit": "2" * 40,
                },
                "deployment": {
                    "status": "healthy",
                    "deployRun": {
                        "repository": ROLLBACK.GATE.SignedEvidenceVerifier.repository,
                        "workflowPath": ROLLBACK.GATE.ROLLBACK_ACTION_WORKFLOWS["console"],
                        "runId": 31,
                        "runAttempt": 2,
                        "event": "workflow_dispatch",
                        "ref": "refs/tags/v1.2.3",
                        "headSha": "2" * 40,
                        "jobSetSha256": "3" * 64,
                    },
                    "deployedArtifact": {"sha256": "4" * 64},
                    "healthArtifactSha256": "5" * 64,
                },
            }
            artifact.write_text(json.dumps(receipt))
            provenance.write_bytes(b"signed provenance")
            completion = ROLLBACK.completion_record(
                repo,
                row_id=row_id,
                generation=1,
                artifact_path=artifact,
                provenance_path=provenance,
                signer_run_id=41,
                signer_run_attempt=3,
                completed_at="2026-07-16T00:00:00Z",
            )
            self.assertEqual(completion["actionRun"], receipt["deployment"]["deployRun"])
            self.assertEqual(completion["deployedArtifactSha256"], "4" * 64)
            self.assertEqual(completion["healthArtifactSha256"], "5" * 64)
            self.assertEqual(
                completion["artifactSha256"],
                hashlib.sha256(artifact.read_bytes()).hexdigest(),
            )
            self.assertEqual(
                completion["provenanceSha256"],
                hashlib.sha256(provenance.read_bytes()).hexdigest(),
            )

            receipt["deployment"]["status"] = "pending"
            artifact.write_text(json.dumps(receipt))
            with self.assertRaisesRegex(
                ROLLBACK.GATE.GateError,
                "healthy post-action evidence",
            ):
                ROLLBACK.completion_record(
                    repo,
                    row_id=row_id,
                    generation=1,
                    artifact_path=artifact,
                    provenance_path=provenance,
                    signer_run_id=41,
                    signer_run_attempt=3,
                    completed_at="2026-07-16T00:00:00Z",
                )


if __name__ == "__main__":
    unittest.main()
