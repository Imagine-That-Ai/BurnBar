from __future__ import annotations

import copy
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

    def test_current_rollout_ledger_passes(self) -> None:
        GATE.run_gate(ROOT, ROOT / "config/domain-core-legacy-deletion.json")

    def test_ios_release_consumers_match_mobile_runtime_ownership(self) -> None:
        ios_rows = {
            row_id
            for row_id, consumers in GATE.ROW_RELEASE_CONSUMERS.items()
            if "ios" in consumers
        }
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

    def test_inventory_and_lifecycle_are_exact(self) -> None:
        ledger = json.loads((ROOT / "config/domain-core-legacy-deletion.json").read_text())
        self.assertEqual(tuple(row["id"] for row in ledger["rows"]), GATE.ROW_IDS)
        self.assertEqual(len(ledger["rows"]), 11)
        self.assertEqual(
            GATE.STATES,
            {
                "rollout",
                "promotion_approved",
                "rust_authoritative_with_rollback",
                "deletion_approved",
                "rollback_active",
                "legacy_deleted",
            },
        )
        for row in ledger["rows"]:
            self.assertTrue(any(target["role"] == "legacy_implementation" for target in row["targets"]))

    def test_receipt_sets_fail_closed_for_every_state(self) -> None:
        self.assertEqual(GATE.required_receipts("rollout"), set())
        self.assertEqual(GATE.required_receipts("promotion_approved"), {"promotion"})
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

    def test_two_commit_activation_is_non_circular_and_path_restricted(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            repo = Path(directory).resolve()
            (repo / "crates/openburnbar-domain-core").mkdir(parents=True)
            (repo / "config").mkdir()
            (repo / "crates/openburnbar-domain-core/union-abi-manifest.json").write_text(
                json.dumps({"coreVersion": "0.3.0", "abiVersion": 3, "sourceSha256": "2" * 64})
            )
            (repo / "crates/openburnbar-domain-core/Cargo.toml").write_text('[workspace]\n[workspace.package]\nversion = "0.3.0"\n')
            profiles = json.loads((ROOT / GATE.BUILD_PROFILE_PATH).read_text())
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
            proof = GATE.validate_activation_closure(repo, candidate, activation)
            self.assertEqual(proof["candidateCommit"], candidate)
            self.assertEqual(proof["activationCommit"], activation)

            (repo / "crates/openburnbar-domain-core/src.rs").write_text("fn drift() {}\n")
            subprocess.run(["git", "add", "."], cwd=repo, check=True)
            subprocess.run(["git", "commit", "-qm", "forbidden drift"], cwd=repo, check=True)
            drift = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=repo, text=True).strip()
            with self.assertRaisesRegex(GATE.GateError, "only profile"):
                GATE.validate_activation_closure(repo, candidate, drift)

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

    def test_rollback_artifact_verifier_binds_candidate_and_retention(self) -> None:
        verifier = GATE.SignedEvidenceVerifier()
        contents = b"retained legacy rollback bytes"
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
        response = FakeDownloadResponse(contents, "https://objects.githubusercontent.com/rollback.zip")
        result = [{"verificationResult": {"statement": {"predicate": predicate}}}]
        with (
            mock.patch.object(GATE, "urlopen", return_value=response),
            mock.patch.object(verifier, "_verify_bundle", return_value=result) as verify,
        ):
            verifier.verify_rollback_artifact(item, ROOT / "README.md", hashlib.sha256(contents).hexdigest())
        self.assertEqual(verify.call_args.kwargs["predicate_type"], GATE.ROLLBACK_PREDICATE_TYPE)
        wrong = copy.deepcopy(result)
        wrong[0]["verificationResult"]["statement"]["predicate"]["release"]["retentionPolicy"] = "ephemeral"
        response = FakeDownloadResponse(contents, "https://objects.githubusercontent.com/rollback.zip")
        with (
            mock.patch.object(GATE, "urlopen", return_value=response),
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
            "bundleKind": "unsigned-deterministic-candidate",
            "status": "eligible_for_attestation",
            "proofComplete": True,
            "eligibleForAttestation": True,
            "promotionAuthorized": False,
            "trust": {
                "authority": "none",
                "attestationRequired": True,
                "requiredSigner": GATE.PROMOTION_SIGNER_WORKFLOW,
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
        (repo / "crates/openburnbar-domain-core/Cargo.toml").write_text('[workspace]\n[workspace.package]\nversion = "0.3.0"\n')
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
        return repo, manifest


if __name__ == "__main__":
    unittest.main()
