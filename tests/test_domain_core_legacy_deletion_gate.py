from __future__ import annotations

import copy
import base64
import hashlib
import importlib.util
import json
import os
import subprocess
import sys
import tempfile
import unittest
from datetime import UTC, datetime, timedelta
from pathlib import Path
from unittest import mock


ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts/ci/verify-domain-core-legacy-deletion.py"
SPEC = importlib.util.spec_from_file_location("domain_core_legacy_deletion_gate", SCRIPT)
assert SPEC and SPEC.loader
GATE = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = GATE
SPEC.loader.exec_module(GATE)
RECEIPT_SCRIPT = ROOT / "scripts/ops/create-domain-core-promotion-receipt.py"
RECEIPT_SPEC = importlib.util.spec_from_file_location("domain_core_promotion_receipt", RECEIPT_SCRIPT)
assert RECEIPT_SPEC and RECEIPT_SPEC.loader
RECEIPT = importlib.util.module_from_spec(RECEIPT_SPEC)
sys.modules[RECEIPT_SPEC.name] = RECEIPT
RECEIPT_SPEC.loader.exec_module(RECEIPT)
DELETION_PLAN_SCRIPT = ROOT / "scripts/ops/create-domain-core-deletion-plan.py"
DELETION_PLAN_SPEC = importlib.util.spec_from_file_location("domain_core_deletion_plan", DELETION_PLAN_SCRIPT)
assert DELETION_PLAN_SPEC and DELETION_PLAN_SPEC.loader
DELETION_PLAN = importlib.util.module_from_spec(DELETION_PLAN_SPEC)
sys.modules[DELETION_PLAN_SPEC.name] = DELETION_PLAN
DELETION_PLAN_SPEC.loader.exec_module(DELETION_PLAN)


class FakeSignedEvidenceVerifier:
    def verify_report(self, report: Path, bundle: Path, candidate_commit: str) -> None:
        self.last_report = (report, bundle, candidate_commit)

    def verify_release(self, item: dict, bundle: Path, expected_sha256: str) -> None:
        self.last_release = (item, bundle, expected_sha256)

    def verify_deletion_review(self, review: dict, bound_files: dict[str, str] | None = None) -> None:
        self.last_deletion_review = (review, bound_files)


class FakeDownloadResponse:
    def __init__(self, contents: bytes, url: str) -> None:
        self.contents = contents
        self.url = url
        self.offset = 0

    def __enter__(self) -> FakeDownloadResponse:
        return self

    def __exit__(self, *_args: object) -> None:
        return None

    def geturl(self) -> str:
        return self.url

    def read(self, size: int) -> bytes:
        chunk = self.contents[self.offset:self.offset + size]
        self.offset += len(chunk)
        return chunk


class DomainCoreLegacyDeletionGateTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temp = tempfile.TemporaryDirectory()
        self.repo = Path(self.temp.name).resolve()
        (self.repo / "config").mkdir()
        (self.repo / "src").mkdir()
        self.manifest_path = self.repo / "config/domain-core-legacy-deletion.json"
        self.manifest = self.make_manifest()
        self.evidence_verifier = FakeSignedEvidenceVerifier()
        self.release_commits: dict[tuple[str, int], tuple[str, str]] = {}
        self.public_modes = {domain: "legacy" for domain in GATE.PROFILE_DOMAIN_ROWS}
        union_path = self.repo / "crates/openburnbar-domain-core"
        union_path.mkdir(parents=True)
        self.source_fingerprint = "b" * 64
        (union_path / "union-abi-manifest.json").write_text(
            json.dumps({"schemaVersion": 1, "sourceSha256": self.source_fingerprint}) + "\n",
            encoding="utf-8",
        )
        (union_path / "Cargo.toml").write_text(
            '[workspace]\n[workspace.package]\nversion = "0.3.0"\n',
            encoding="utf-8",
        )
        (self.repo / "config/domain-core-promotion-policy.json").write_text(
            (ROOT / "config/domain-core-promotion-policy.json").read_text(encoding="utf-8"),
            encoding="utf-8",
        )
        (self.repo / "config/domain-core-deletion-reviewers.json").write_text(
            json.dumps(
                {
                    "schemaVersion": 1,
                    "reviewers": [
                        {
                            "handle": "@independent-reviewer",
                            "reviewClasses": ["domain_owner", "security_crypto"],
                        }
                    ],
                },
                indent=2,
            )
            + "\n",
            encoding="utf-8",
        )
        self.write_build_profiles()
        self.write_manifest()
        subprocess.run(["git", "init", "-q"], cwd=self.repo, check=True)
        subprocess.run(["git", "config", "user.email", "test@openburnbar.invalid"], cwd=self.repo, check=True)
        subprocess.run(["git", "config", "user.name", "OpenBurnBar Test"], cwd=self.repo, check=True)
        subprocess.run(["git", "add", "."], cwd=self.repo, check=True)
        subprocess.run(["git", "commit", "-qm", "fixture"], cwd=self.repo, check=True)
        self.base_commit = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=self.repo, text=True).strip()

    def tearDown(self) -> None:
        self.temp.cleanup()

    def make_manifest(self) -> dict:
        rows = []
        for index, row_id in enumerate(GATE.ROW_IDS):
            path = f"src/legacy_{index}.txt"
            symbol = f"legacySymbol{index}"
            (self.repo / path).write_text(f"func {symbol}() {{}}\n", encoding="utf-8")
            rows.append(
                {
                    "id": row_id,
                    "state": "rollout",
                    "authorityGeneration": 0,
                    "receipts": {},
                    "targets": [{"kind": "source_symbol", "role": "legacy_implementation", "root": "source", "path": path, "symbol": symbol}],
                }
            )
        return {"schemaVersion": 2, "sourceRoots": {"source": "src"}, "rows": rows, "sharedTargets": []}

    def write_manifest(self) -> None:
        self.manifest_path.write_text(json.dumps(self.manifest, indent=2) + "\n", encoding="utf-8")

    def write_build_profiles(self) -> None:
        domains = list(GATE.PROFILE_DOMAIN_ROWS)

        def modes(value: str) -> dict[str, str]:
            return {domain: value for domain in domains}

        catalog = {
            "schemaVersion": 1,
            "defaultReleaseProfile": "public-production",
            "domains": domains,
            "profiles": {
                "developer": {
                    "artifactAuthority": "development",
                    "distribution": "development",
                    "rolloutChannel": None,
                    "evidenceEnabled": False,
                    "modes": modes("legacy"),
                },
                "public-production": {
                    "artifactAuthority": "signed",
                    "distribution": "public",
                    "rolloutChannel": None,
                    "evidenceEnabled": False,
                    "modes": self.public_modes,
                },
                "internal": {
                    "artifactAuthority": "signed",
                    "distribution": "internal",
                    "rolloutChannel": "internal",
                    "evidenceEnabled": True,
                    "modes": modes("shadow"),
                },
                "beta": {
                    "artifactAuthority": "signed",
                    "distribution": "beta",
                    "rolloutChannel": "beta",
                    "evidenceEnabled": True,
                    "modes": modes("shadow"),
                },
            },
        }
        (self.repo / "config/domain-core-build-profiles.json").write_text(
            json.dumps(catalog, indent=2) + "\n",
            encoding="utf-8",
        )

    def gate(self) -> None:
        GATE.run_gate(self.repo, self.manifest_path, evidence_verifier=self.evidence_verifier)

    def expect_failure(self, pattern: str) -> None:
        with self.assertRaisesRegex(GATE.GateError, pattern):
            self.gate()

    def test_signed_report_verifier_pins_candidate_workflow_and_oidc_identity(self) -> None:
        verifier = GATE.SignedEvidenceVerifier()
        report = self.repo / "report.json"
        bundle = self.repo / "bundle.json"
        report.write_text('{"ready":true}\n', encoding="utf-8")
        bundle.write_text('{"mediaType":"application/vnd.dev.sigstore.bundle.v0.3+json"}\n', encoding="utf-8")
        completed = subprocess.CompletedProcess(args=[], returncode=0, stdout='[{"verificationResult":true}]', stderr="")
        with mock.patch.object(GATE.subprocess, "run", return_value=completed) as run:
            verifier.verify_report(report, bundle, self.base_commit)
        command = run.call_args.args[0]
        self.assertEqual(command[:3], ["gh", "attestation", "verify"])
        self.assertIn(str(report), command)
        self.assertEqual(command[command.index("--bundle") + 1], str(bundle))
        self.assertEqual(command[command.index("--repo") + 1], "Imagine-That-Ai/BurnBar")
        self.assertEqual(
            command[command.index("--signer-workflow") + 1],
            "Imagine-That-Ai/BurnBar/.github/workflows/domain-core-promotion-observation.yml",
        )
        self.assertEqual(command[command.index("--source-digest") + 1], self.base_commit)
        self.assertEqual(command[command.index("--source-ref") + 1], "refs/heads/main")
        self.assertEqual(command[command.index("--signer-digest") + 1], self.base_commit)
        self.assertEqual(
            command[command.index("--cert-oidc-issuer") + 1],
            "https://token.actions.githubusercontent.com",
        )
        self.assertIn("--deny-self-hosted-runners", command)
        self.assertEqual(command[command.index("--predicate-type") + 1], "https://slsa.dev/provenance/v1")

    def test_signed_release_verifier_hashes_downloaded_bytes_and_pins_tag(self) -> None:
        verifier = GATE.SignedEvidenceVerifier()
        bundle = self.repo / "bundle.json"
        bundle.write_text('{"test":true}\n', encoding="utf-8")
        contents = b"published release bytes"
        item = {
            "consumer": "windows",
            "artifactKind": "windows-release-bundle",
            "target": "windows-x64-arm64",
            "artifactUri": "https://github.com/Imagine-That-Ai/BurnBar/releases/download/windows-v1.2.3/windows.zip",
            "commit": self.base_commit,
            "tag": "windows-v1.2.3",
            "version": "1.2.3",
            "publicProfileSha256": "2" * 64,
        }
        response = FakeDownloadResponse(
            contents,
            "https://objects.githubusercontent.com/github-production-release-asset/windows.zip",
        )
        with (
            mock.patch.object(GATE, "urlopen", return_value=response),
            mock.patch.object(verifier, "_verify_bundle") as verify_bundle,
        ):
            verify_bundle.return_value = [
                {
                    "verificationResult": {
                        "statement": {
                            "predicate": {
                                "schemaVersion": 1,
                                "consumer": "windows",
                                "artifactKind": "windows-release-bundle",
                                "target": "windows-x64-arm64",
                                "artifact": {
                                    "fileName": "OpenBurnBar-1.2.3-windows-release.zip",
                                    "sha256": hashlib.sha256(contents).hexdigest(),
                                },
                                "release": {
                                    "version": "1.2.3",
                                    "tag": "windows-v1.2.3",
                                    "commit": self.base_commit,
                                    "publicProfileSha256": "2" * 64,
                                },
                            }
                        }
                    }
                }
            ]
            verifier.verify_release(item, bundle, hashlib.sha256(contents).hexdigest())
        kwargs = verify_bundle.call_args.kwargs
        self.assertEqual(kwargs["signer_workflow"], ".github/workflows/openburnbar-release-windows.yml")
        self.assertEqual(kwargs["source_digest"], self.base_commit)
        self.assertEqual(kwargs["source_ref"], "refs/tags/windows-v1.2.3")
        self.assertEqual(kwargs["predicate_type"], "https://openburnbar.dev/attestations/domain-core-release-artifact/v1")
        self.assertEqual(kwargs["signer_digest"], self.base_commit)

        mismatched = copy.deepcopy(verify_bundle.return_value)
        mismatched[0]["verificationResult"]["statement"]["predicate"]["consumer"] = "android"
        response = FakeDownloadResponse(
            contents,
            "https://objects.githubusercontent.com/github-production-release-asset/windows.zip",
        )
        with (
            mock.patch.object(GATE, "urlopen", return_value=response),
            mock.patch.object(verifier, "_verify_bundle", return_value=mismatched),
        ):
            with self.assertRaisesRegex(GATE.GateError, "signed predicate does not bind"):
                verifier.verify_release(item, bundle, hashlib.sha256(contents).hexdigest())

        response = FakeDownloadResponse(
            contents,
            "https://objects.githubusercontent.com/github-production-release-asset/windows.zip",
        )
        with mock.patch.object(GATE, "urlopen", return_value=response):
            with self.assertRaisesRegex(GATE.GateError, "SHA-256 does not match published bytes"):
                verifier.verify_release(item, bundle, "0" * 64)

    def test_live_deletion_review_must_be_current_and_independent(self) -> None:
        verifier = GATE.SignedEvidenceVerifier()
        receipt_commit = "1" * 40
        review = {
            "reviewUri": "https://github.com/Imagine-That-Ai/BurnBar/pull/1728",
            "reviewer": "@independent-reviewer",
            "reviewedCommit": receipt_commit,
            "reviewClass": "domain_owner",
        }
        responses = [
            subprocess.CompletedProcess(
                args=[],
                returncode=0,
                stdout=json.dumps({
                    "draft": False,
                    "head": {"sha": receipt_commit, "repo": {"full_name": "Imagine-That-Ai/BurnBar"}},
                    "user": {"login": "author"},
                }),
                stderr="",
            ),
            subprocess.CompletedProcess(
                args=[],
                returncode=0,
                stdout=json.dumps([[
                    {
                        "state": "APPROVED",
                        "commit_id": receipt_commit,
                        "id": 1,
                        "submitted_at": "2026-07-14T01:00:00Z",
                        "user": {"login": "independent-reviewer"},
                    }
                ]]),
                stderr="",
            ),
        ]
        with mock.patch.object(GATE.subprocess, "run", side_effect=responses):
            verifier.verify_deletion_review(review)

        responses[0] = subprocess.CompletedProcess(
            args=[],
            returncode=0,
            stdout=json.dumps(
                {
                    "draft": False,
                    "head": {"sha": receipt_commit, "repo": {"full_name": "Imagine-That-Ai/BurnBar"}},
                    "user": {"login": "independent-reviewer"},
                }
            ),
            stderr="",
        )
        with mock.patch.object(GATE.subprocess, "run", side_effect=responses):
            with self.assertRaisesRegex(GATE.GateError, "independent"):
                verifier.verify_deletion_review(review)

    def test_later_changes_requested_revokes_earlier_deletion_approval(self) -> None:
        verifier = GATE.SignedEvidenceVerifier()
        receipt_commit = "1" * 40
        review = {
            "reviewUri": "https://github.com/Imagine-That-Ai/BurnBar/pull/1728",
            "reviewer": "@independent-reviewer",
            "reviewedCommit": receipt_commit,
            "reviewClass": "domain_owner",
        }
        page_one = [
            {
                "state": "APPROVED", "commit_id": receipt_commit, "id": 1,
                "submitted_at": "2026-07-14T01:00:00Z",
                "user": {"login": "independent-reviewer"},
            },
            *[
                {
                    "state": "COMMENTED", "commit_id": receipt_commit, "id": review_id,
                    "submitted_at": "2026-07-14T01:30:00Z",
                    "user": {"login": f"commenter-{review_id}"},
                }
                for review_id in range(2, 101)
            ],
        ]
        responses = [
            subprocess.CompletedProcess(
                args=[], returncode=0,
                stdout=json.dumps({
                    "draft": False,
                    "head": {"sha": receipt_commit, "repo": {"full_name": "Imagine-That-Ai/BurnBar"}},
                    "user": {"login": "author"},
                }),
                stderr="",
            ),
            subprocess.CompletedProcess(
                args=[], returncode=0,
                stdout=json.dumps([page_one, [
                    {
                        "state": "CHANGES_REQUESTED", "commit_id": receipt_commit, "id": 2,
                        "submitted_at": "2026-07-14T02:00:00Z",
                        "user": {"login": "independent-reviewer"},
                    },
                ]]),
                stderr="",
            ),
        ]
        with mock.patch.object(GATE.subprocess, "run", side_effect=responses) as run:
            with self.assertRaisesRegex(GATE.GateError, "latest decisive review.*APPROVED"):
                verifier.verify_deletion_review(review)
        self.assertIn("--paginate", run.call_args_list[1].args[0])
        self.assertIn("--slurp", run.call_args_list[1].args[0])

    def test_live_deletion_review_verifies_bound_file_bytes_at_pr_head(self) -> None:
        verifier = GATE.SignedEvidenceVerifier()
        receipt_commit = "1" * 40
        review = {
            "reviewUri": "https://github.com/Imagine-That-Ai/BurnBar/pull/1728",
            "reviewer": "@independent-reviewer",
            "reviewedCommit": receipt_commit,
            "reviewClass": "domain_owner",
        }
        responses = [
            subprocess.CompletedProcess(
                args=[], returncode=0,
                stdout=json.dumps({
                    "draft": False,
                    "head": {"sha": receipt_commit, "repo": {"full_name": "Imagine-That-Ai/BurnBar"}},
                    "user": {"login": "author"},
                }),
                stderr="",
            ),
            subprocess.CompletedProcess(
                args=[], returncode=0,
                stdout=json.dumps([[{
                    "state": "APPROVED", "commit_id": receipt_commit, "id": 1,
                    "submitted_at": "2026-07-14T01:00:00Z",
                    "user": {"login": "independent-reviewer"},
                }]]),
                stderr="",
            ),
            subprocess.CompletedProcess(
                args=[], returncode=0,
                stdout=json.dumps({"encoding": "base64", "content": base64.b64encode(b"wrong").decode()}),
                stderr="",
            ),
        ]
        with mock.patch.object(GATE.subprocess, "run", side_effect=responses):
            with self.assertRaisesRegex(GATE.GateError, "digest does not match approved PR head"):
                verifier.verify_deletion_review(review, {"config/plan.json": hashlib.sha256(b"right").hexdigest()})

    def add_receipts(
        self,
        row_index: int,
        *,
        promotion_only: bool = False,
        deleted: bool = False,
    ) -> None:
        row = self.manifest["rows"][row_index]
        row["authorityGeneration"] = max(1, row["authorityGeneration"])
        generation = row["authorityGeneration"]
        profile_domain = GATE.profile_domain_for_row(row["id"])
        promotion_domain = GATE.PROMOTION_DOMAINS[profile_domain]
        scope = GATE.PROMOTION_SCOPES[profile_domain]
        policies, policy_digests = GATE.promotion_policies(self.repo)
        policy = policies[promotion_domain]
        policy_digest = policy_digests[promotion_domain]
        month = min(generation, 12)
        observation_end = datetime(2026, month, 1, tzinfo=UTC)
        observation_start = observation_end - timedelta(seconds=policy["minimumCoverageSeconds"])
        started_at = observation_start.isoformat().replace("+00:00", "Z")
        ended_at = observation_end.isoformat().replace("+00:00", "Z")
        coverage = [
            {
                "slice": cell["slice"],
                "consumer": cell["consumer"],
                "channel": "beta",
                "startedAt": started_at,
                "endedAt": ended_at,
                "coverageSeconds": policy["minimumCoverageSeconds"],
                "sampleCount": policy["minimumSamples"] - len(policy["requiredCoverage"]) + 1 if index == 0 else 1,
                "unexplainedMismatchCount": 0,
                "p95RegressionBasisPoints": 0,
            }
            for index, cell in enumerate(policy["requiredCoverage"])
        ]
        report = {
            "schemaVersion": 2,
            "domain": promotion_domain,
            "coreVersion": "0.3.0",
            "generatedAt": ended_at,
            "provenance": {
                "collector": "domain-core-shadow-exporter",
                "queryRevision": self.base_commit,
                "sourceUri": "https://console.cloud.google.com/firestore/databases/-default-/data/panel/domain_core_shadow_samples",
            },
            "status": "ready",
            "ready": True,
            "policy": policy,
            "summary": {
                "totalSamples": policy["minimumSamples"],
                "unexplainedMismatchCount": 0,
                "coverage": coverage,
            },
            "blockers": [],
        }
        report_path = f"config/domain-core-promotion-reports/{scope}/{generation}.json"
        (self.repo / report_path).parent.mkdir(parents=True, exist_ok=True)
        (self.repo / report_path).write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
        report_digest = hashlib.sha256((self.repo / report_path).read_bytes()).hexdigest()
        report_provenance_path = f"config/domain-core-promotion-provenance/{scope}/{generation}.json"
        (self.repo / report_provenance_path).parent.mkdir(parents=True, exist_ok=True)
        (self.repo / report_provenance_path).write_text('{"testBundle":true}\n', encoding="utf-8")
        report_uri = "https://github.com/Imagine-That-Ai/BurnBar/actions/runs/1"
        attestation = {
            "schemaVersion": 1,
            "domain": promotion_domain,
            "authorityScope": scope,
            "authorityGeneration": generation,
            "reportPath": report_path,
            "reportUri": report_uri,
            "reportSha256": report_digest,
            "reportProvenancePath": report_provenance_path,
            "reportProvenanceSha256": hashlib.sha256((self.repo / report_provenance_path).read_bytes()).hexdigest(),
            "coreVersion": "0.3.0",
            "candidateCommit": self.base_commit,
            "builderCommit": self.base_commit,
            "sourceFingerprint": self.source_fingerprint,
            "policySha256": policy_digest,
            "status": "ready",
            "generatedAt": ended_at,
        }
        attestation_path = f"config/domain-core-promotion-attestations/{scope}/{generation}.json"
        (self.repo / attestation_path).parent.mkdir(parents=True, exist_ok=True)
        (self.repo / attestation_path).write_text(json.dumps(attestation, indent=2) + "\n", encoding="utf-8")
        attestation_digest = hashlib.sha256((self.repo / attestation_path).read_bytes()).hexdigest()
        supersedes_rollback = None
        if generation > 1:
            previous = f"config/domain-core-legacy-deletion-receipts/{row['id']}/{generation - 1}/rollback.json"
            supersedes_rollback = {
                "path": previous,
                "sha256": hashlib.sha256((self.repo / previous).read_bytes()).hexdigest(),
            }

        release_key = (profile_domain, generation)
        if release_key in self.release_commits:
            release_commit, version = self.release_commits[release_key]
        else:
            saved_profile = (self.repo / "config/domain-core-build-profiles.json").read_bytes()
            saved_public_modes = dict(self.public_modes)
            release_modes = dict(self.public_modes)
            release_modes[profile_domain] = "rust"
            self.public_modes = release_modes
            self.write_build_profiles()
            subprocess.run(["git", "add", "config/domain-core-build-profiles.json"], cwd=self.repo, check=True)
            subprocess.run(["git", "commit", "--allow-empty", "-qm", f"release {profile_domain} {generation}"], cwd=self.repo, check=True)
            release_commit = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=self.repo, text=True).strip()
            version = f"1.{generation}.{list(GATE.PROFILE_DOMAIN_ROWS).index(profile_domain) + 1}"
            release_tags = {
                f"windows-v{version}" if consumer == "windows" else f"v{version}"
                for consumer in GATE.release_consumers_for_row(row["id"])
            }
            for tag in release_tags:
                subprocess.run(["git", "tag", tag, release_commit], cwd=self.repo, check=True)
            (self.repo / "config/domain-core-build-profiles.json").write_bytes(saved_profile)
            self.public_modes = saved_public_modes
            self.release_commits[release_key] = (release_commit, version)
        rust_profile_digest = GATE.canonical_json_sha256(
            {
                "artifactAuthority": "signed",
                "distribution": "public",
                "rolloutChannel": None,
                "evidenceEnabled": False,
                "domain": profile_domain,
                "mode": "rust",
            }
        )
        receipts = {"promotion": "promotion"}
        if not promotion_only:
            receipts["stableRelease"] = "stable_release"
        if deleted:
            receipts["deletionReview"] = "deletion_review"
        row["receipts"] = {}
        receipt_digests: dict[str, str] = {}
        for key, transition in receipts.items():
            path = f"config/domain-core-legacy-deletion-receipts/{row['id']}/{generation}/{transition}.json"
            (self.repo / path).parent.mkdir(parents=True, exist_ok=True)
            evidence_uri = f"https://evidence.openburnbar.com/{promotion_domain}/{transition}"
            payload: dict = {
                "schemaVersion": 2,
                "rowId": row["id"],
                "authorityGeneration": generation,
                "transition": transition,
                "status": "active",
                "evidence": [evidence_uri],
                "approvedBy": "@release-owner",
                "approvedAt": f"2026-{month:02d}-01T00:00:00Z",
                "commit": self.base_commit if transition == "promotion" else release_commit,
            }
            if transition == "promotion":
                payload["evidence"] = [report_uri]
                payload["promotionAttestation"] = {
                    "path": attestation_path,
                    "sha256": attestation_digest,
                    "supersedesRollback": supersedes_rollback,
                }
            elif transition == "stable_release":
                payload["approvedAt"] = f"2026-{month:02d}-03T00:00:00Z"
                consumer_releases = []
                payload["evidence"] = []
                for consumer in sorted(GATE.release_consumers_for_row(row["id"])):
                    tag = f"windows-v{version}" if consumer == "windows" else f"v{version}"
                    artifact_uri = (
                        f"https://github.com/Imagine-That-Ai/BurnBar/releases/download/{tag}/"
                        f"{GATE.expected_release_asset_name(consumer, version)}"
                    )
                    provenance_path = (
                        f"config/domain-core-release-provenance/{row['id']}/{generation}/{consumer}.json"
                    )
                    (self.repo / provenance_path).parent.mkdir(parents=True, exist_ok=True)
                    (self.repo / provenance_path).write_text('{"testBundle":true}\n', encoding="utf-8")
                    payload["evidence"].append(artifact_uri)
                    consumer_releases.append(
                        {
                            "consumer": consumer,
                            "artifactKind": GATE.RELEASE_ARTIFACT_IDENTITIES[consumer][0],
                            "target": GATE.RELEASE_ARTIFACT_IDENTITIES[consumer][1],
                            "version": version,
                            "tag": tag,
                            "commit": release_commit,
                            "publishedAt": f"2026-{month:02d}-02T00:00:00Z",
                            "artifactUri": artifact_uri,
                            "artifactSha256": hashlib.sha256(f"{consumer}-artifact".encode()).hexdigest(),
                            "publicProfileSha256": rust_profile_digest,
                            "provenancePath": provenance_path,
                            "provenanceSha256": hashlib.sha256((self.repo / provenance_path).read_bytes()).hexdigest(),
                        }
                    )
                payload["release"] = {
                    "promotionReceiptSha256": receipt_digests["promotion"],
                    "publicProfileSha256": rust_profile_digest,
                    "consumerReleases": consumer_releases,
                }
            else:
                payload["approvedAt"] = f"2026-{month:02d}-05T00:00:00Z"
                target_digest = GATE.canonical_json_sha256(
                    [
                        {
                            "kind": target["kind"],
                            "role": target["role"],
                            "root": target["root"],
                            "path": target["path"],
                            "value": target.get("symbol", target.get("literal")),
                        }
                        for target in sorted(
                            row["targets"],
                            key=lambda item: (item["kind"], item["root"], item["path"], item.get("symbol", item.get("literal", ""))),
                        )
                    ]
                )
                reviewer = "@independent-reviewer"
                review_class = "security_crypto" if row["id"] in GATE.SECURITY_REVIEW_ROWS else "domain_owner"
                plan_path = f"config/domain-core-deletion-plans/{row['id']}/{generation}.json"
                plan = {
                    "schemaVersion": 1,
                    "rowId": row["id"],
                    "authorityGeneration": generation,
                    "stableReceiptSha256": receipt_digests["stableRelease"],
                    "reviewer": reviewer,
                    "reviewClass": review_class,
                    "legacyTargetsSha256": target_digest,
                    "requestedAction": "approve_legacy_deletion",
                }
                (self.repo / plan_path).parent.mkdir(parents=True, exist_ok=True)
                (self.repo / plan_path).write_text(json.dumps(plan, indent=2) + "\n", encoding="utf-8")
                subprocess.run(
                    ["git", "add", row["receipts"]["stableRelease"], plan_path],
                    cwd=self.repo,
                    check=True,
                )
                subprocess.run(
                    ["git", "commit", "--allow-empty", "-qm", f"review deletion plan {row['id']} {generation}"],
                    cwd=self.repo,
                    check=True,
                )
                reviewed_commit = subprocess.check_output(
                    ["git", "rev-parse", "HEAD"], cwd=self.repo, text=True
                ).strip()
                payload["commit"] = reviewed_commit
                payload["deletionReview"] = {
                    "stableReceiptSha256": receipt_digests["stableRelease"],
                    "reviewUri": "https://github.com/Imagine-That-Ai/BurnBar/pull/1",
                    "reviewedCommit": reviewed_commit,
                    "reviewer": reviewer,
                    "reviewClass": review_class,
                    "outcome": "approved",
                    "planPath": plan_path,
                    "planSha256": hashlib.sha256((self.repo / plan_path).read_bytes()).hexdigest(),
                }
            (self.repo / path).write_text(
                json.dumps(payload) + "\n",
                encoding="utf-8",
            )
            row["receipts"][key] = path
            receipt_digests[key] = hashlib.sha256((self.repo / path).read_bytes()).hexdigest()

    def delete_row_target(self, row_index: int) -> None:
        (self.repo / self.manifest["rows"][row_index]["targets"][0]["path"]).unlink()

    def add_rollback_receipt(self, row_index: int) -> None:
        row = self.manifest["rows"][row_index]
        row["state"] = "rollback_active"
        stable_path = self.repo / row["receipts"]["stableRelease"]
        stable_digest = hashlib.sha256(stable_path.read_bytes()).hexdigest()
        rollback_path = (
            f"config/domain-core-legacy-deletion-receipts/{row['id']}/{row['authorityGeneration']}/rollback.json"
        )
        subprocess.run(
            ["git", "commit", "--allow-empty", "-qm", f"activate rollback {row['id']}"],
            cwd=self.repo,
            check=True,
        )
        rollback_commit = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=self.repo, text=True).strip()
        deletion = row["receipts"].get("deletionReview")
        activated_at = "2026-01-06T00:00:00Z" if deletion else "2026-01-04T00:00:00Z"
        approved_at = "2026-01-07T00:00:00Z" if deletion else "2026-01-05T00:00:00Z"
        rollback_receipt = {
            "schemaVersion": 2,
            "rowId": row["id"],
            "authorityGeneration": row["authorityGeneration"],
            "transition": "rollback",
            "status": "active",
            "evidence": ["https://github.com/Imagine-That-Ai/BurnBar/issues/1"],
            "approvedBy": "@release-owner",
            "approvedAt": approved_at,
            "commit": rollback_commit,
            "rollback": {
                "stableReceiptSha256": stable_digest,
                "issueUri": "https://github.com/Imagine-That-Ai/BurnBar/issues/1",
                "activatedAt": activated_at,
            },
        }
        (self.repo / rollback_path).write_text(json.dumps(rollback_receipt) + "\n", encoding="utf-8")
        row["receipts"]["rollback"] = rollback_path

    def test_committed_manifest_passes_against_checkout(self) -> None:
        GATE.run_gate(ROOT, ROOT / "config/domain-core-legacy-deletion.json")

    def test_rollout_manifest_passes(self) -> None:
        self.gate()

    def test_rollout_target_cannot_disappear(self) -> None:
        self.delete_row_target(0)
        self.expect_failure("absent before legacy_deleted")

    def test_policy_thresholds_and_channels_are_immutable(self) -> None:
        path = self.repo / "config/domain-core-promotion-policy.json"
        original = path.read_bytes()
        mutations = (
            ("minimumCoverageSeconds", 1),
            ("minimumSamples", 1),
            ("maximumP95RegressionBasisPoints", 10_000),
            ("allowedChannels", ["internal", "public"]),
        )
        for field, value in mutations:
            with self.subTest(field=field):
                policy = json.loads(original)
                policy["domains"]["quota"][field] = value
                path.write_text(json.dumps(policy) + "\n", encoding="utf-8")
                self.expect_failure(f"{field} must remain pinned")
        policy = json.loads(original)
        policy["domains"]["quota"]["requiredCoverage"].pop()
        path.write_text(json.dumps(policy) + "\n", encoding="utf-8")
        self.expect_failure("requiredCoverage must match the pinned consumer contract")
        path.write_bytes(original)

    def test_append_only_artifacts_cannot_be_rewritten_deleted_or_renamed(self) -> None:
        row_index = GATE.ROW_IDS.index("cloudvault.search")
        row = self.manifest["rows"][row_index]
        row["state"] = "promotion_approved"
        self.public_modes["cloudVaultSearch"] = "rust"
        self.write_build_profiles()
        self.add_receipts(row_index, promotion_only=True)
        self.write_build_profiles()
        self.write_manifest()
        subprocess.run(["git", "add", "."], cwd=self.repo, check=True)
        subprocess.run(["git", "commit", "-qm", "promotion artifacts"], cwd=self.repo, check=True)
        base_ref = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=self.repo, text=True).strip()
        receipt_path = self.repo / row["receipts"]["promotion"]
        receipt = json.loads(receipt_path.read_text(encoding="utf-8"))
        paths = (
            receipt_path,
            self.repo / receipt["promotionAttestation"]["path"],
            self.repo / json.loads((self.repo / receipt["promotionAttestation"]["path"]).read_text())["reportPath"],
            self.repo / json.loads((self.repo / receipt["promotionAttestation"]["path"]).read_text())["reportProvenancePath"],
        )
        for path in paths:
            with self.subTest(path=path.name):
                original = path.read_bytes()
                path.write_bytes(original + b" ")
                with self.assertRaisesRegex(GATE.GateError, "cannot be rewritten"):
                    GATE.run_gate(self.repo, self.manifest_path, base_ref=base_ref)
                path.write_bytes(original)
        original = receipt_path.read_bytes()
        receipt_path.unlink()
        with self.assertRaisesRegex(GATE.GateError, "required path is missing"):
            GATE.run_gate(self.repo, self.manifest_path, base_ref=base_ref)
        receipt_path.write_bytes(original)
        renamed = receipt_path.with_name("renamed.json")
        receipt_path.rename(renamed)
        with self.assertRaisesRegex(GATE.GateError, "required path is missing"):
            GATE.run_gate(self.repo, self.manifest_path, base_ref=base_ref)
        renamed.rename(receipt_path)
        receipt_path.chmod(0o755)
        with self.assertRaisesRegex(GATE.GateError, "executable mode cannot change"):
            GATE.run_gate(self.repo, self.manifest_path, base_ref=base_ref)
        receipt_path.chmod(0o644)

    def test_base_ref_must_be_real_and_ancestral(self) -> None:
        with self.assertRaisesRegex(GATE.GateError, "full lowercase Git SHA"):
            GATE.run_gate(self.repo, self.manifest_path, base_ref="main")
        with self.assertRaisesRegex(GATE.GateError, "ancestor of HEAD"):
            GATE.run_gate(self.repo, self.manifest_path, base_ref="a" * 40)

    def test_complete_rollback_history_is_required_before_generation_two(self) -> None:
        row_index = GATE.ROW_IDS.index("cloudvault.search")
        row = self.manifest["rows"][row_index]
        row["state"] = "rust_authoritative_with_rollback"
        self.public_modes["cloudVaultSearch"] = "rust"
        self.write_build_profiles()
        self.add_receipts(row_index)
        self.add_rollback_receipt(row_index)
        self.public_modes["cloudVaultSearch"] = "legacy"
        self.write_build_profiles()
        row["authorityGeneration"] = 2
        row["state"] = "promotion_approved"
        self.add_receipts(row_index, promotion_only=True)
        self.public_modes["cloudVaultSearch"] = "rust"
        self.write_build_profiles()
        self.write_manifest()
        self.gate()

        previous_stable = self.repo / GATE.RECEIPT_ROOT / row["id"] / "1/stable_release.json"
        saved = previous_stable.read_bytes()
        previous_stable.unlink()
        self.expect_failure("receipt files must be exactly")
        previous_stable.write_bytes(saved)

        generation_one = previous_stable.parent
        generation_one.rename(generation_one.with_name("3"))
        self.expect_failure("generations must be contiguous")

    def test_post_rollback_promotion_rejects_replayed_observation(self) -> None:
        row_index = GATE.ROW_IDS.index("cloudvault.search")
        row = self.manifest["rows"][row_index]
        row["state"] = "rust_authoritative_with_rollback"
        self.public_modes["cloudVaultSearch"] = "rust"
        self.write_build_profiles()
        self.add_receipts(row_index)
        self.add_rollback_receipt(row_index)
        row["authorityGeneration"] = 2
        row["state"] = "promotion_approved"
        self.add_receipts(row_index, promotion_only=True)
        self.public_modes["cloudVaultSearch"] = "rust"
        self.write_build_profiles()

        promotion_path = self.repo / row["receipts"]["promotion"]
        promotion = json.loads(promotion_path.read_text(encoding="utf-8"))
        attestation_path = self.repo / promotion["promotionAttestation"]["path"]
        attestation = json.loads(attestation_path.read_text(encoding="utf-8"))
        report_path = self.repo / attestation["reportPath"]
        report = json.loads(report_path.read_text(encoding="utf-8"))
        for window in report["summary"]["coverage"]:
            window["startedAt"] = "2025-12-17T00:00:00Z"
            window["endedAt"] = "2025-12-31T00:00:00Z"
        report_path.write_text(json.dumps(report) + "\n", encoding="utf-8")
        attestation["reportSha256"] = hashlib.sha256(report_path.read_bytes()).hexdigest()
        attestation_path.write_text(json.dumps(attestation) + "\n", encoding="utf-8")
        promotion["promotionAttestation"]["sha256"] = hashlib.sha256(attestation_path.read_bytes()).hexdigest()
        promotion_path.write_text(json.dumps(promotion) + "\n", encoding="utf-8")
        self.write_manifest()
        self.expect_failure("post-rollback promotion requires a fresh observation window")

    def test_unicode_generation_alias_is_rejected(self) -> None:
        row_index = GATE.ROW_IDS.index("cloudvault.search")
        row = self.manifest["rows"][row_index]
        row["state"] = "promotion_approved"
        self.public_modes["cloudVaultSearch"] = "rust"
        self.write_build_profiles()
        self.add_receipts(row_index, promotion_only=True)
        (self.repo / GATE.RECEIPT_ROOT / row["id"] / "١").mkdir()
        self.write_build_profiles()
        self.write_manifest()
        self.expect_failure("invalid generation directory")

    def test_base_ledger_allows_only_one_state_transition(self) -> None:
        row_index = GATE.ROW_IDS.index("cloudvault.search")
        row = self.manifest["rows"][row_index]
        row["state"] = "legacy_deleted"
        self.add_receipts(row_index, deleted=True)
        self.public_modes["cloudVaultSearch"] = "rust"
        self.write_build_profiles()
        self.delete_row_target(row_index)
        self.write_manifest()
        with self.assertRaisesRegex(GATE.GateError, "illegal ledger transition"):
            GATE.run_gate(self.repo, self.manifest_path, base_ref=self.base_commit)

    def test_initial_ledger_bootstrap_requires_empty_generation_zero_rollout(self) -> None:
        subprocess.run(
            ["git", "rm", "-q", "config/domain-core-legacy-deletion.json"], cwd=self.repo, check=True
        )
        subprocess.run(["git", "commit", "-qm", "base without deletion ledger"], cwd=self.repo, check=True)
        bootstrap_base = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=self.repo, text=True).strip()
        self.write_manifest()
        GATE.run_gate(
            self.repo,
            self.manifest_path,
            base_ref=bootstrap_base,
            evidence_verifier=self.evidence_verifier,
        )

        self.manifest["rows"][0]["state"] = "promotion_approved"
        self.manifest["rows"][0]["authorityGeneration"] = 1
        self.write_manifest()
        with self.assertRaisesRegex(GATE.GateError, "must bootstrap every row"):
            GATE.run_gate(
                self.repo,
                self.manifest_path,
                base_ref=bootstrap_base,
                evidence_verifier=self.evidence_verifier,
            )

    def test_stable_authority_must_enter_deletion_approved_before_deleting(self) -> None:
        row_index = GATE.ROW_IDS.index("cloudvault.search")
        row = self.manifest["rows"][row_index]
        row["state"] = "rust_authoritative_with_rollback"
        self.public_modes["cloudVaultSearch"] = "rust"
        self.write_build_profiles()
        self.add_receipts(row_index)
        self.write_build_profiles()
        self.write_manifest()
        subprocess.run(["git", "add", "."], cwd=self.repo, check=True)
        subprocess.run(["git", "commit", "-qm", "stable authority"], cwd=self.repo, check=True)
        stable_base = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=self.repo, text=True).strip()

        row["state"] = "legacy_deleted"
        self.add_receipts(row_index, deleted=True)
        self.delete_row_target(row_index)
        self.write_manifest()
        with self.assertRaisesRegex(GATE.GateError, "illegal ledger transition"):
            GATE.run_gate(
                self.repo,
                self.manifest_path,
                base_ref=stable_base,
                evidence_verifier=self.evidence_verifier,
            )

    def test_deletion_approval_can_roll_back_without_discarding_review(self) -> None:
        row_index = GATE.ROW_IDS.index("cloudvault.search")
        row = self.manifest["rows"][row_index]
        row["state"] = "deletion_approved"
        self.public_modes["cloudVaultSearch"] = "rust"
        self.write_build_profiles()
        self.add_receipts(row_index, deleted=True)
        self.write_manifest()
        subprocess.run(["git", "add", "."], cwd=self.repo, check=True)
        subprocess.run(["git", "commit", "-qm", "approve deletion"], cwd=self.repo, check=True)
        deletion_base = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=self.repo, text=True).strip()

        self.add_rollback_receipt(row_index)
        self.public_modes["cloudVaultSearch"] = "legacy"
        self.write_build_profiles()
        self.write_manifest()
        GATE.run_gate(
            self.repo,
            self.manifest_path,
            base_ref=deletion_base,
            evidence_verifier=self.evidence_verifier,
        )
        self.assertIn("deletionReview", row["receipts"])

    def test_deletion_review_binds_exact_plan_and_stable_receipt(self) -> None:
        row_index = GATE.ROW_IDS.index("cloudvault.search")
        row = self.manifest["rows"][row_index]
        row["state"] = "deletion_approved"
        self.public_modes["cloudVaultSearch"] = "rust"
        self.write_build_profiles()
        self.add_receipts(row_index, deleted=True)
        self.write_manifest()
        self.gate()
        review, bound_files = self.evidence_verifier.last_deletion_review
        plan_path = review["planPath"]
        stable_path = row["receipts"]["stableRelease"]
        self.assertEqual(bound_files[plan_path], review["planSha256"])
        self.assertEqual(bound_files[stable_path], review["stableReceiptSha256"])

    def test_deletion_plan_generator_binds_stable_receipt_and_target_inventory(self) -> None:
        row_index = GATE.ROW_IDS.index("cloudvault.search")
        row = self.manifest["rows"][row_index]
        row["state"] = "rust_authoritative_with_rollback"
        self.public_modes["cloudVaultSearch"] = "rust"
        self.write_build_profiles()
        self.add_receipts(row_index)
        self.write_manifest()

        output, plan = DELETION_PLAN.create_plan(
            self.repo,
            row_id=row["id"],
            generation=1,
            reviewer="@independent-reviewer",
        )
        stable_path = self.repo / row["receipts"]["stableRelease"]
        self.assertEqual(plan["stableReceiptSha256"], hashlib.sha256(stable_path.read_bytes()).hexdigest())
        self.assertEqual(plan["requestedAction"], "approve_legacy_deletion")
        DELETION_PLAN.write_append_only(output, DELETION_PLAN.serialized(plan))
        receipt_output, receipt, bound_files = DELETION_PLAN.create_deletion_receipt(
            self.repo,
            row_id=row["id"],
            generation=1,
            plan_path=output,
            plan=plan,
            review_uri="https://github.com/Imagine-That-Ai/BurnBar/pull/1",
            reviewed_commit=self.base_commit,
            approved_by="@release-owner",
            approved_at="2026-07-14T00:00:00Z",
        )
        self.assertEqual(receipt_output.name, "deletion_review.json")
        self.assertEqual(receipt["deletionReview"]["planSha256"], bound_files[output.relative_to(self.repo).as_posix()])
        self.assertEqual(receipt["deletionReview"]["reviewer"], "@independent-reviewer")
        with self.assertRaisesRegex(GATE.GateError, "refusing to rewrite append-only artifact"):
            DELETION_PLAN.write_append_only(output, DELETION_PLAN.serialized({**plan, "reviewer": "@other"}))

    def test_deletion_receipt_cli_verifies_review_before_append_only_write(self) -> None:
        row_index = GATE.ROW_IDS.index("cloudvault.search")
        row = self.manifest["rows"][row_index]
        row["state"] = "rust_authoritative_with_rollback"
        self.public_modes["cloudVaultSearch"] = "rust"
        self.write_build_profiles()
        self.add_receipts(row_index)
        self.write_manifest()
        with mock.patch.object(GATE.SignedEvidenceVerifier, "verify_deletion_review") as verify:
            status = DELETION_PLAN.main([
                "--repo-root", str(self.repo),
                "--row-id", row["id"],
                "--authority-generation", "1",
                "--reviewer", "@independent-reviewer",
                "--review-uri", "https://github.com/Imagine-That-Ai/BurnBar/pull/1",
                "--reviewed-commit", self.base_commit,
                "--approved-by", "@release-owner",
                "--approved-at", "2026-07-14T00:00:00Z",
            ])
        self.assertEqual(status, 0)
        receipt_path = self.repo / GATE.RECEIPT_ROOT / row["id"] / "1/deletion_review.json"
        self.assertTrue(receipt_path.is_file())
        review, bound_files = verify.call_args.args
        self.assertEqual(review["reviewedCommit"], self.base_commit)
        self.assertEqual(set(bound_files), {review["planPath"], row["receipts"]["stableRelease"]})

    def test_deletion_reviewer_must_be_qualified_in_trusted_catalog(self) -> None:
        row_index = GATE.ROW_IDS.index("cloudvault.search")
        row = self.manifest["rows"][row_index]
        row["state"] = "deletion_approved"
        self.public_modes["cloudVaultSearch"] = "rust"
        self.write_build_profiles()
        self.add_receipts(row_index, deleted=True)
        (self.repo / "config/domain-core-deletion-reviewers.json").write_text(
            '{"schemaVersion":1,"reviewers":[]}\n', encoding="utf-8"
        )
        self.write_manifest()
        self.expect_failure("security_crypto reviewer is not qualified by the trusted base catalog")

    def test_domain_owner_reviewer_must_also_be_qualified(self) -> None:
        for row_id in GATE.PROFILE_DOMAIN_ROWS["pricing"]:
            row_index = GATE.ROW_IDS.index(row_id)
            self.manifest["rows"][row_index]["state"] = "deletion_approved"
            self.add_receipts(row_index, deleted=True)
        self.public_modes["pricing"] = "rust"
        self.write_build_profiles()
        (self.repo / "config/domain-core-deletion-reviewers.json").write_text(
            '{"schemaVersion":1,"reviewers":[]}\n', encoding="utf-8"
        )
        self.write_manifest()
        self.expect_failure("domain_owner reviewer is not qualified by the trusted base catalog")

    def test_stable_receipt_requires_every_consumer_and_historical_rust_profile(self) -> None:
        row_index = GATE.ROW_IDS.index("cloudvault.portable_primitives")
        row = self.manifest["rows"][row_index]
        row["state"] = "rust_authoritative_with_rollback"
        self.public_modes["cloudVault"] = "rust"
        self.write_build_profiles()
        self.add_receipts(row_index)
        self.write_build_profiles()
        self.write_manifest()
        stable_path = self.repo / row["receipts"]["stableRelease"]
        stable = json.loads(stable_path.read_text(encoding="utf-8"))
        original = copy.deepcopy(stable)
        stable["release"]["consumerReleases"].pop()
        stable_path.write_text(json.dumps(stable) + "\n", encoding="utf-8")
        self.expect_failure("exact applicable consumer set")

        stable = copy.deepcopy(original)
        for item in stable["release"]["consumerReleases"]:
            tag = item["tag"]
            subprocess.run(["git", "tag", "-d", tag], cwd=self.repo, check=True, capture_output=True)
            subprocess.run(["git", "tag", tag, self.base_commit], cwd=self.repo, check=True)
            item["commit"] = self.base_commit
        stable_path.write_text(json.dumps(stable) + "\n", encoding="utf-8")
        self.expect_failure("did not contain the Rust public profile")

    def test_stable_receipt_rejects_cross_consumer_artifact_substitution(self) -> None:
        row_index = GATE.ROW_IDS.index("cloudvault.portable_primitives")
        row = self.manifest["rows"][row_index]
        row["state"] = "rust_authoritative_with_rollback"
        self.public_modes["cloudVault"] = "rust"
        self.write_build_profiles()
        self.add_receipts(row_index)
        stable_path = self.repo / row["receipts"]["stableRelease"]
        stable = json.loads(stable_path.read_text(encoding="utf-8"))
        android = next(item for item in stable["release"]["consumerReleases"] if item["consumer"] == "android")
        android["artifactKind"] = "macos-dmg"
        android["target"] = "macos-universal"
        stable_path.write_text(json.dumps(stable) + "\n", encoding="utf-8")
        self.write_build_profiles()
        self.write_manifest()
        self.expect_failure("artifact kind and target do not match consumer android")

    def test_authoritative_state_requires_both_active_receipts(self) -> None:
        row_index = GATE.ROW_IDS.index("cloudvault.search")
        self.manifest["rows"][row_index]["state"] = "rust_authoritative_with_rollback"
        self.write_manifest()
        self.expect_failure("missing fields: promotion, stableRelease")

        self.public_modes["cloudVaultSearch"] = "rust"
        self.write_build_profiles()
        self.add_receipts(row_index)
        self.write_manifest()
        self.gate()

    def test_promotion_candidate_requires_receipt_and_public_rust_mode(self) -> None:
        row_index = GATE.ROW_IDS.index("cloudvault.document_rewrap")
        self.manifest["rows"][row_index]["state"] = "promotion_approved"
        self.write_manifest()
        self.expect_failure("missing fields: promotion")

        self.add_receipts(row_index, promotion_only=True)
        self.write_manifest()
        self.expect_failure("cloudVaultRewrap=legacy is allowed only")

        self.public_modes["cloudVaultRewrap"] = "rust"
        self.write_build_profiles()
        self.gate()

    def test_promoted_state_requires_signed_evidence_verifier(self) -> None:
        row_index = GATE.ROW_IDS.index("cloudvault.search")
        self.manifest["rows"][row_index]["state"] = "promotion_approved"
        self.public_modes["cloudVaultSearch"] = "rust"
        self.write_build_profiles()
        self.add_receipts(row_index, promotion_only=True)
        self.write_build_profiles()
        self.write_manifest()
        with self.assertRaisesRegex(GATE.GateError, "signed promotion evidence verification is required"):
            GATE.run_gate(self.repo, self.manifest_path)

    def test_public_rust_mode_requires_every_domain_row_to_be_approved(self) -> None:
        self.public_modes["quota"] = "rust"
        self.write_build_profiles()
        self.write_manifest()
        self.expect_failure("quota=rust requires promotion approval for every row")

        for row_id in GATE.PROFILE_DOMAIN_ROWS["quota"]:
            row_index = GATE.ROW_IDS.index(row_id)
            self.manifest["rows"][row_index]["state"] = "promotion_approved"
            self.add_receipts(row_index, promotion_only=True)
        self.write_manifest()
        self.gate()

    def test_atomic_pricing_rows_share_union_consumer_release(self) -> None:
        self.public_modes["pricing"] = "rust"
        self.write_build_profiles()
        for row_id in GATE.PROFILE_DOMAIN_ROWS["pricing"]:
            row_index = GATE.ROW_IDS.index(row_id)
            self.manifest["rows"][row_index]["state"] = "rust_authoritative_with_rollback"
            self.add_receipts(row_index)
        self.write_build_profiles()
        self.write_manifest()
        self.gate()

    def test_promotion_rejects_nonexistent_candidate_commit(self) -> None:
        row_index = GATE.ROW_IDS.index("cloudvault.search")
        row = self.manifest["rows"][row_index]
        row["state"] = "promotion_approved"
        self.public_modes["cloudVaultSearch"] = "rust"
        self.write_build_profiles()
        self.add_receipts(row_index, promotion_only=True)
        receipt_path = self.repo / row["receipts"]["promotion"]
        receipt = json.loads(receipt_path.read_text(encoding="utf-8"))
        receipt["commit"] = "a" * 40
        receipt_path.write_text(json.dumps(receipt) + "\n", encoding="utf-8")
        self.write_manifest()
        self.expect_failure("commit must exist and be an ancestor")

    def test_generator_binds_only_ready_reports_to_canonical_receipt(self) -> None:
        row_index = GATE.ROW_IDS.index("cloudvault.search")
        row = self.manifest["rows"][row_index]
        report_path = self.repo / "ready-report.json"
        policy = GATE.promotion_policies(self.repo)[0]["cloudvault"]
        report = {
            "schemaVersion": 2,
            "domain": "cloudvault",
            "coreVersion": "0.3.0",
            "generatedAt": "2025-12-31T00:00:00Z",
            "provenance": {
                "collector": "domain-core-shadow-exporter",
                "queryRevision": self.base_commit,
                "sourceUri": "https://console.cloud.google.com/firestore/databases/-default-/data/panel/domain_core_shadow_samples",
            },
            "status": "ready",
            "ready": True,
            "policy": policy,
            "summary": {
                "totalSamples": policy["minimumSamples"],
                "unexplainedMismatchCount": 0,
                "coverage": [
                    {
                        "slice": cell["slice"],
                        "consumer": cell["consumer"],
                        "channel": "beta",
                        "startedAt": "2025-12-17T00:00:00Z",
                        "endedAt": "2025-12-31T00:00:00Z",
                        "coverageSeconds": policy["minimumCoverageSeconds"],
                        "sampleCount": policy["minimumSamples"] - len(policy["requiredCoverage"]) + 1 if index == 0 else 1,
                        "unexplainedMismatchCount": 0,
                        "p95RegressionBasisPoints": 0,
                    }
                    for index, cell in enumerate(policy["requiredCoverage"])
                ],
            },
            "blockers": [],
        }
        report_path.write_text(json.dumps(report) + "\n", encoding="utf-8")
        report_provenance_path = self.repo / "ready-report.sigstore.json"
        report_provenance_path.write_text('{"testBundle":true}\n', encoding="utf-8")
        committed_report, provenance, attestation, receipt = RECEIPT.create_artifacts(
            self.repo,
            row_id=row["id"],
            generation=1,
            report_path=report_path,
            report_provenance_path=report_provenance_path,
            report_uri="https://github.com/Imagine-That-Ai/BurnBar/actions/runs/1",
            candidate_commit=self.base_commit,
            builder_commit=self.base_commit,
            approved_by="@release-owner",
            approved_at="2026-01-01T00:00:00Z",
        )
        scope = GATE.PROMOTION_SCOPES[GATE.profile_domain_for_row(row["id"])]
        committed_report_path = self.repo / GATE.REPORT_ROOT / scope / "1.json"
        committed_provenance_path = self.repo / GATE.PROMOTION_PROVENANCE_ROOT / scope / "1.json"
        attestation_path = self.repo / GATE.ATTESTATION_ROOT / scope / "1.json"
        path = self.repo / GATE.RECEIPT_ROOT / row["id"] / "1/promotion.json"
        RECEIPT.write_atomically(committed_report_path, committed_report)
        RECEIPT.write_bytes_atomically(committed_provenance_path, provenance)
        RECEIPT.write_atomically(attestation_path, attestation)
        RECEIPT.write_atomically(path, receipt)
        row["state"] = "promotion_approved"
        row["authorityGeneration"] = 1
        row["receipts"] = {"promotion": path.relative_to(self.repo).as_posix()}
        self.public_modes["cloudVaultSearch"] = "rust"
        self.write_build_profiles()
        self.write_manifest()
        self.gate()

        report["status"] = "not_ready"
        report["ready"] = False
        report["blockers"] = [{"code": "insufficient_samples"}]
        report_path.write_text(json.dumps(report) + "\n", encoding="utf-8")
        with self.assertRaisesRegex(GATE.GateError, "status must be ready with no blockers"):
            RECEIPT.create_artifacts(
                self.repo,
                row_id=row["id"],
                generation=1,
                report_path=report_path,
                report_provenance_path=report_provenance_path,
                report_uri="https://github.com/Imagine-That-Ai/BurnBar/actions/runs/1",
                candidate_commit=self.base_commit,
                builder_commit=self.base_commit,
                approved_by="@release-owner",
                approved_at="2026-01-01T00:00:00Z",
            )

    def test_promotion_report_binding_rejects_drift(self) -> None:
        row_index = GATE.ROW_IDS.index("cloudvault.search")
        row = self.manifest["rows"][row_index]
        row["state"] = "promotion_approved"
        self.public_modes["cloudVaultSearch"] = "rust"
        self.write_build_profiles()
        self.add_receipts(row_index, promotion_only=True)
        receipt_path = self.repo / row["receipts"]["promotion"]
        receipt = json.loads(receipt_path.read_text(encoding="utf-8"))
        attestation_path = self.repo / receipt["promotionAttestation"]["path"]
        original = json.loads(attestation_path.read_text(encoding="utf-8"))
        mutations = (
            ("domain", "quota", "domain or authority scope is incorrect"),
            ("sourceFingerprint", "c" * 64, "does not match the candidate commit"),
            ("policySha256", "d" * 64, "does not match the candidate commit"),
            ("status", "not_ready", "attestation status must be ready"),
        )
        for field, value, error in mutations:
            with self.subTest(field=field):
                attestation = copy.deepcopy(original)
                attestation[field] = value
                attestation_path.write_text(json.dumps(attestation) + "\n", encoding="utf-8")
                receipt["promotionAttestation"]["sha256"] = hashlib.sha256(attestation_path.read_bytes()).hexdigest()
                receipt_path.write_text(json.dumps(receipt) + "\n", encoding="utf-8")
                self.write_manifest()
                self.expect_failure(error)

    def test_multi_row_profile_requires_one_report_and_candidate(self) -> None:
        self.public_modes["quota"] = "rust"
        self.write_build_profiles()
        row_indexes = [GATE.ROW_IDS.index(row_id) for row_id in GATE.PROFILE_DOMAIN_ROWS["quota"]]
        for row_index in row_indexes:
            self.manifest["rows"][row_index]["state"] = "promotion_approved"
            self.add_receipts(row_index, promotion_only=True)
        receipt_path = self.repo / self.manifest["rows"][row_indexes[-1]]["receipts"]["promotion"]
        receipt = json.loads(receipt_path.read_text(encoding="utf-8"))
        receipt["promotionAttestation"]["sha256"] = "e" * 64
        receipt_path.write_text(json.dumps(receipt) + "\n", encoding="utf-8")
        self.write_manifest()
        self.expect_failure("attestation digest does not match committed bytes")

    def test_stable_authority_requires_rust_profile_until_explicit_rollback(self) -> None:
        row_index = GATE.ROW_IDS.index("cloudvault.search")
        self.manifest["rows"][row_index]["state"] = "rust_authoritative_with_rollback"
        self.add_receipts(row_index)
        self.write_manifest()
        self.expect_failure("cloudVaultSearch=legacy is allowed only")

        self.add_rollback_receipt(row_index)
        self.write_manifest()
        self.gate()

    def test_rollback_invalidates_old_stable_receipt_for_deletion(self) -> None:
        row_index = GATE.ROW_IDS.index("cloudvault.search")
        row = self.manifest["rows"][row_index]
        row["state"] = "rust_authoritative_with_rollback"
        self.public_modes["cloudVaultSearch"] = "rust"
        self.write_build_profiles()
        self.add_receipts(row_index)
        self.add_rollback_receipt(row_index)

        row["state"] = "legacy_deleted"
        row["receipts"].pop("rollback")
        stable_path = self.repo / row["receipts"]["stableRelease"]
        stable_digest = hashlib.sha256(stable_path.read_bytes()).hexdigest()
        deletion_path = f"config/domain-core-legacy-deletion-receipts/{row['id']}/1/deletion_review.json"
        deletion_receipt = {
            "schemaVersion": 2,
            "rowId": row["id"],
            "authorityGeneration": 1,
            "transition": "deletion_review",
            "status": "active",
            "evidence": ["https://github.com/Imagine-That-Ai/BurnBar/pull/1"],
            "approvedBy": "@release-owner",
            "approvedAt": "2026-01-07T00:00:00Z",
            "commit": json.loads(stable_path.read_text(encoding="utf-8"))["commit"],
            "deletionReview": {
                "stableReceiptSha256": stable_digest,
                "reviewUri": "https://github.com/Imagine-That-Ai/BurnBar/pull/1",
                "reviewedAt": "2026-01-06T00:00:00Z",
            },
        }
        (self.repo / deletion_path).write_text(json.dumps(deletion_receipt) + "\n", encoding="utf-8")
        row["receipts"]["deletionReview"] = deletion_path
        self.delete_row_target(row_index)
        self.write_manifest()
        self.expect_failure("receipt files must be exactly")

    def test_incomplete_build_profile_catalog_is_rejected(self) -> None:
        path = self.repo / "config/domain-core-build-profiles.json"
        catalog = json.loads(path.read_text(encoding="utf-8"))
        del catalog["profiles"]["internal"]
        path.write_text(json.dumps(catalog) + "\n", encoding="utf-8")
        self.expect_failure("missing fields: internal")

    def test_deleted_state_requires_receipts_and_absent_target(self) -> None:
        row_index = GATE.ROW_IDS.index("cloudvault.document_rewrap")
        row = self.manifest["rows"][row_index]
        row["state"] = "legacy_deleted"
        self.add_receipts(row_index, deleted=True)
        self.public_modes["cloudVaultRewrap"] = "rust"
        self.write_build_profiles()
        self.write_manifest()
        self.expect_failure("remains after legacy_deleted")
        self.delete_row_target(row_index)
        self.gate()

    def test_deleted_state_cannot_drop_receipt(self) -> None:
        row_index = GATE.ROW_IDS.index("cloudvault.document_rewrap")
        row = self.manifest["rows"][row_index]
        row["state"] = "legacy_deleted"
        self.add_receipts(row_index, deleted=True)
        del row["receipts"]["deletionReview"]
        self.delete_row_target(row_index)
        self.write_manifest()
        self.expect_failure("missing fields: deletionReview")

    def test_deleted_state_requires_public_rust_mode(self) -> None:
        row_index = GATE.ROW_IDS.index("cloudvault.document_rewrap")
        self.manifest["rows"][row_index]["state"] = "legacy_deleted"
        self.add_receipts(row_index, deleted=True)
        self.delete_row_target(row_index)
        self.write_manifest()
        self.expect_failure("cloudVaultRewrap=legacy is allowed only")

    def test_exact_stable_row_set_is_required(self) -> None:
        self.manifest["rows"].pop()
        self.write_manifest()
        self.expect_failure("exact stable row set")

    def test_duplicate_row_id_is_rejected(self) -> None:
        self.manifest["rows"][1]["id"] = self.manifest["rows"][0]["id"]
        self.write_manifest()
        self.expect_failure("duplicate row id")

    def test_unknown_manifest_row_and_target_fields_are_rejected(self) -> None:
        for location, pattern in (
            ("manifest", "manifest: unknown fields"),
            ("row", r"rows\[0\]: unknown fields"),
            ("target", r"targets\[0\]: unknown fields"),
        ):
            mutated = self.make_manifest()
            if location == "manifest":
                mutated["surprise"] = True
            elif location == "row":
                mutated["rows"][0]["surprise"] = True
            else:
                mutated["rows"][0]["targets"][0]["surprise"] = True
            self.manifest = mutated
            self.write_manifest()
            self.expect_failure(pattern)

    def test_unknown_state_kind_and_root_are_rejected(self) -> None:
        mutations = (
            ("state", "complete", "unknown state"),
            ("kind", "regex", "unknown target kind"),
            ("root", "missing", "unknown source root"),
        )
        for field, value, pattern in mutations:
            manifest = self.make_manifest()
            if field == "state":
                manifest["rows"][0][field] = value
            else:
                manifest["rows"][0]["targets"][0][field] = value
            self.manifest = manifest
            self.write_manifest()
            self.expect_failure(pattern)

    def test_duplicate_json_keys_and_malformed_json_are_rejected(self) -> None:
        self.manifest_path.write_text('{"schemaVersion":1,"schemaVersion":1}', encoding="utf-8")
        self.expect_failure("duplicate JSON key")
        self.manifest_path.write_text("{", encoding="utf-8")
        self.expect_failure("invalid JSON")

    def test_duplicate_root_paths_and_targets_are_rejected(self) -> None:
        self.manifest["sourceRoots"]["duplicate"] = "src"
        self.write_manifest()
        self.expect_failure("duplicate root path")

        self.manifest = self.make_manifest()
        self.manifest["rows"][1]["targets"][0] = copy.deepcopy(self.manifest["rows"][0]["targets"][0])
        self.write_manifest()
        self.expect_failure("duplicate target")

    def test_noncanonical_and_escaping_paths_are_rejected(self) -> None:
        for value in ("/src/file", "src/../file", "src\\file", "src/./file"):
            self.manifest = self.make_manifest()
            self.manifest["rows"][0]["targets"][0]["path"] = value
            self.write_manifest()
            self.expect_failure("canonical POSIX")

    def test_target_must_be_inside_declared_root(self) -> None:
        (self.repo / "outside.txt").write_text("legacySymbol0", encoding="utf-8")
        self.manifest["rows"][0]["targets"][0]["path"] = "outside.txt"
        self.write_manifest()
        self.expect_failure("outside declared source root")

    def test_missing_root_is_rejected(self) -> None:
        self.manifest["sourceRoots"]["source"] = "missing"
        self.write_manifest()
        self.expect_failure("required path is missing")

    @unittest.skipIf(os.name == "nt", "symlink setup is platform-specific")
    def test_root_and_target_symlinks_are_rejected(self) -> None:
        real = self.repo / "real"
        real.mkdir()
        (self.repo / "linked").symlink_to(real, target_is_directory=True)
        self.manifest["sourceRoots"]["source"] = "linked"
        self.write_manifest()
        self.expect_failure("symlink components are forbidden")

        self.manifest = self.make_manifest()
        target = self.repo / self.manifest["rows"][0]["targets"][0]["path"]
        target.unlink()
        outside = self.repo / "outside-source.txt"
        outside.write_text("legacySymbol0", encoding="utf-8")
        target.symlink_to(outside)
        self.write_manifest()
        self.expect_failure("symlink components are forbidden")

    def test_receipt_is_strict_active_and_bound_to_transition(self) -> None:
        self.manifest["rows"][0]["state"] = "rust_authoritative_with_rollback"
        self.add_receipts(0)
        self.write_manifest()
        receipt_path = self.repo / self.manifest["rows"][0]["receipts"]["promotion"]
        baseline = json.loads(receipt_path.read_text(encoding="utf-8"))
        mutations = (
            ("status", "revoked", "status must be active"),
            ("rowId", GATE.ROW_IDS[1], "rowId must be"),
            ("transition", "deletion_review", "transition must be promotion"),
            ("commit", "abc", "full lowercase Git SHA"),
            ("approvedBy", "release-owner", "GitHub handle"),
            ("approvedAt", "2999-01-01T00:00:00Z", "cannot be in the future"),
        )
        for field, value, pattern in mutations:
            receipt = dict(baseline)
            receipt[field] = value
            receipt_path.write_text(json.dumps(receipt), encoding="utf-8")
            self.expect_failure(pattern)

    def test_receipt_rejects_unknown_fields_duplicate_keys_and_unsafe_evidence(self) -> None:
        self.manifest["rows"][0]["state"] = "rust_authoritative_with_rollback"
        self.add_receipts(0)
        self.write_manifest()
        receipt_path = self.repo / self.manifest["rows"][0]["receipts"]["promotion"]
        receipt = json.loads(receipt_path.read_text(encoding="utf-8"))
        receipt["surprise"] = True
        receipt_path.write_text(json.dumps(receipt), encoding="utf-8")
        self.expect_failure("unknown fields")

        receipt_path.write_text('{"schemaVersion":1,"schemaVersion":1}', encoding="utf-8")
        self.expect_failure("duplicate JSON key")

        receipt.pop("surprise")
        receipt["evidence"] = ["https://user:secret@example.com/run?token=x"]
        receipt_path.write_text(json.dumps(receipt), encoding="utf-8")
        self.expect_failure("credential-free HTTPS URI")

        receipt["evidence"] = [{"url": "https://example.com"}]
        receipt_path.write_text(json.dumps(receipt), encoding="utf-8")
        self.expect_failure("expected HTTPS URI")

        receipt["evidence"] = ["https://example.com/run", "https://example.com/run"]
        receipt_path.write_text(json.dumps(receipt), encoding="utf-8")
        self.expect_failure("non-empty unique array")

    def test_receipt_paths_must_exist_and_be_unique(self) -> None:
        self.manifest["rows"][0]["state"] = "rust_authoritative_with_rollback"
        self.add_receipts(0)
        self.manifest["rows"][0]["receipts"]["stableRelease"] = self.manifest["rows"][0]["receipts"]["promotion"]
        self.write_manifest()
        self.expect_failure("must use exact path")

        self.manifest["rows"][0]["receipts"]["stableRelease"] = (
            f"config/domain-core-legacy-deletion-receipts/{GATE.ROW_IDS[0]}/1/stable_release.json"
        )
        (self.repo / self.manifest["rows"][0]["receipts"]["stableRelease"]).unlink()
        self.write_manifest()
        self.expect_failure("required path is missing")

    def test_mode_literal_and_path_targets_follow_state(self) -> None:
        row = self.manifest["rows"][0]
        source = self.repo / row["targets"][0]["path"]
        source.write_text("OPENBURNBAR_TEST_MODE\n", encoding="utf-8")
        row["targets"] = [
            {
                "kind": "mode_literal",
                "role": "legacy_implementation",
                "root": "source",
                "path": source.relative_to(self.repo).as_posix(),
                "literal": "OPENBURNBAR_TEST_MODE",
            }
        ]
        self.write_manifest()
        self.gate()

        row["targets"] = [{"kind": "path", "role": "legacy_implementation", "root": "source", "path": source.relative_to(self.repo).as_posix()}]
        self.write_manifest()
        self.gate()

    @unittest.skipIf(os.name == "nt", "FIFO setup is platform-specific")
    def test_path_target_rejects_special_files(self) -> None:
        row = self.manifest["rows"][0]
        source = self.repo / row["targets"][0]["path"]
        source.unlink()
        os.mkfifo(source)
        row["targets"] = [{"kind": "path", "role": "legacy_implementation", "root": "source", "path": source.relative_to(self.repo).as_posix()}]
        self.write_manifest()
        self.expect_failure("regular file or directory")

    def test_shared_target_remains_until_every_member_is_deleted(self) -> None:
        shared_path = self.repo / "src/shared.txt"
        shared_path.write_text("OPENBURNBAR_SHARED_MODE\n", encoding="utf-8")
        members = ["cloudvault.portable_primitives", "cloudvault.document_rewrap"]
        self.manifest["sharedTargets"] = [
            {
                "rowIds": members,
                "target": {
                    "kind": "mode_literal",
                    "role": "rollback_control",
                    "root": "source",
                    "path": "src/shared.txt",
                    "literal": "OPENBURNBAR_SHARED_MODE",
                },
            }
        ]
        for domain, row_id in (("cloudVault", members[0]), ("cloudVaultRewrap", members[1])):
            index = GATE.ROW_IDS.index(row_id)
            self.manifest["rows"][index]["state"] = "legacy_deleted"
            self.add_receipts(index, deleted=True)
            self.delete_row_target(index)
            self.public_modes[domain] = "rust"
        self.write_build_profiles()
        self.write_manifest()
        self.expect_failure("remains after every member row")
        shared_path.unlink()
        self.gate()

    def test_shared_target_cannot_disappear_while_one_member_is_active(self) -> None:
        self.manifest["sharedTargets"] = [
            {
                "rowIds": list(GATE.ROW_IDS[:2]),
                "target": {
                    "kind": "mode_literal",
                    "role": "rollback_control",
                    "root": "source",
                    "path": "src/missing-shared.txt",
                    "literal": "OPENBURNBAR_SHARED_MODE",
                },
            }
        ]
        self.write_manifest()
        self.expect_failure("absent while a member row is active")


if __name__ == "__main__":
    unittest.main()
