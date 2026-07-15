from __future__ import annotations

import json
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
DOMAIN_WORKFLOW = ROOT / ".github/workflows/domain-core.yml"
SIGNER_WORKFLOW = ROOT / ".github/workflows/domain-core-promotion-proof.yml"
TRUSTED_GUARD_WORKFLOW = ROOT / ".github/workflows/domain-core-deletion-guard.yml"


class DomainCoreLegacyDeletionWorkflowTests(unittest.TestCase):
    def test_domain_workflow_runs_governance_and_append_only_gate(self) -> None:
        source = DOMAIN_WORKFLOW.read_text()
        for marker in (
            "python3 tests/test_domain_core_legacy_deletion_gate.py",
            "python3 tests/test_domain_core_legacy_deletion_workflow.py",
            "verify-domain-core-legacy-deletion.py",
            "Domain Core PR Gate",
            "verify-domain-core-legacy-absence.py",
            "Check out trusted default-branch evaluator",
            '--base-ref "$DOMAIN_CORE_BASE_REF"',
            "--verify-signed-evidence",
            "fetch-depth: 0",
        ):
            self.assertIn(marker, source)

    def test_workflow_triggers_cover_every_governance_surface(self) -> None:
        source = DOMAIN_WORKFLOW.read_text()
        for marker in (
            "config/domain-core-legacy-deletion*.json",
            "config/domain-core-legacy-deletion-receipts/**",
            "config/domain-core-deletion-*.json",
            "config/domain-core-deletion-plans/**",
            "config/domain-core-promotion-attestation.schema.json",
            "config/domain-core-promotion-attestations/**",
            "config/domain-core-promotion-bundles/**",
            "config/domain-core-promotion-provenance/**",
            "config/domain-core-release-provenance/**",
            "scripts/ci/verify-domain-core-legacy-deletion.py",
            "scripts/ops/create-domain-core-promotion-receipt.py",
            "scripts/ops/create-domain-core-deletion-plan.py",
            "tests/test_domain_core_legacy_deletion*.py",
            "docs/runbooks/shared-rust-legacy-deletion.md",
            "docs/SHARED_RUST_DOMAIN_INVENTORY.md",
        ):
            self.assertGreaterEqual(source.count(marker), 2, marker)

    def test_protected_signer_publishes_official_provenance_bundle(self) -> None:
        source = SIGNER_WORKFLOW.read_text()
        for marker in (
            "environment: domain-core-promotion",
            "id: attest",
            "actions/attest-build-provenance@",
            "subject-path: ${{ runner.temp }}/candidate-bundle/domain-core-candidate-bundle.json",
            "${{ steps.attest.outputs.bundle-path }}",
            "domain-core-protected-attestation-",
            "retention-days: 90",
        ):
            self.assertIn(marker, source)
        self.assertIn("protected-verification.json", source)

    def test_deletion_guard_executes_only_default_branch_evaluator(self) -> None:
        source = TRUSTED_GUARD_WORKFLOW.read_text()
        for marker in (
            "pull_request_target:",
            "pull_request_review:",
            "Domain Core Trusted Deletion Guard",
            "path: trusted",
            "path: candidate",
            "python3 trusted/scripts/ci/verify-domain-core-legacy-deletion.py",
            '--repo-root "$GITHUB_WORKSPACE/candidate"',
            '--deletion-head "$HEAD_SHA"',
            "node trusted/scripts/ci/verify-domain-core-default-branch-controls.mjs",
            "DOMAIN_CORE_EVIDENCE_CACHE: ${{ runner.temp }}/domain-core-evidence-cache",
            "timeout-minutes: 60",
        ):
            self.assertIn(marker, source)
        self.assertNotIn("candidate/scripts/", source)

    def test_linux_release_preserves_candidate_activation_history_in_every_job(self) -> None:
        source = (ROOT / ".github/workflows/linux-release.yml").read_text()
        self.assertEqual(source.count("fetch-depth: 0"), 3)
        self.assertEqual(source.count("fetch-tags: true"), 3)
        self.assertIn("Verify official Linux release history", source)
        self.assertEqual(source.count("Verify candidate-to-activation history is complete"), 2)
        self.assertGreaterEqual(source.count("git merge-base --is-ancestor"), 3)

    def test_signer_uses_trusted_main_and_exact_source_push_run(self) -> None:
        source = SIGNER_WORKFLOW.read_text()
        for marker in (
            "ref: ${{ github.sha }}",
            "persist-credentials: false",
            '[[ "$GITHUB_REF" == "refs/heads/main" ]]',
            '[[ "$(git rev-parse HEAD)" == "$GITHUB_SHA" ]]',
            "event=push&status=completed&head_sha=$CANDIDATE_COMMIT",
            "expected exactly one successful push run",
            "run_attempt",
            '--expected-evaluator-commit "$GITHUB_SHA"',
            "Revalidate with trusted main policy and evaluator",
            "domain-core-promotion-environment.json",
            'type == "required_reviewers"',
        ):
            self.assertIn(marker, source)

    def test_unsigned_or_diagnostic_artifacts_are_never_called_authority(self) -> None:
        gate = (ROOT / "scripts/ci/verify-domain-core-legacy-deletion.py").read_text()
        creator = (ROOT / "scripts/ops/create-domain-core-promotion-receipt.py").read_text()
        combined = gate + creator
        self.assertNotIn("validate_ready_report", combined)
        self.assertNotIn("domain-core-promotion-observation.yml", combined)
        self.assertNotIn("minimumCoverageSeconds", combined)
        self.assertNotIn("minimumSamples", combined)
        self.assertIn("protected-verification output is not provenance authority", combined)
        self.assertIn('value["promotionAuthorized"] is not False', combined)

    def test_candidate_bundle_requires_all_deterministic_jobs(self) -> None:
        source = DOMAIN_WORKFLOW.read_text()
        candidate_job = source[source.index("  candidate-bundle:") :]
        for job in (
            "promotion-contracts",
            "rust-and-csharp",
            "windows-native",
            "linux-arm64-native",
            "wasm",
            "functions-pricing",
            "android",
            "apple",
            "apple-native-smoke",
            "swift-consumer-contracts",
            "console-consumer-contracts",
            "rollback-drill",
        ):
            self.assertIn(f"      - {job}", candidate_job)
        self.assertIn('all(.value.result == "success")', candidate_job)

    def test_schemas_encode_exact_candidate_and_retained_rollback(self) -> None:
        promotion = json.loads((ROOT / "config/domain-core-promotion-attestation.schema.json").read_text())
        receipt = json.loads((ROOT / "config/domain-core-legacy-deletion-receipt.schema.json").read_text())
        candidate = promotion["$defs"]["candidate"]
        self.assertEqual(
            candidate["required"],
            ["candidateCommit", "coreVersion", "abiVersion", "sourceSha256"],
        )
        rollback = receipt["$defs"]["rollbackArtifact"]
        self.assertEqual(
            rollback["properties"]["retentionPolicy"]["const"],
            "retain_until_legacy_deletion_complete",
        )
        self.assertEqual(rollback["properties"]["artifactKind"]["const"], "legacy-rollback-bundle")

    def test_native_and_deletion_contracts_share_the_shipped_apple_identity(self) -> None:
        release = json.loads((ROOT / "config/domain-core-release-predicate.schema.json").read_text())
        receipt = json.loads((ROOT / "config/domain-core-legacy-deletion-receipt.schema.json").read_text())
        apple_release = release["oneOf"][0]["properties"]
        artifact = receipt["$defs"]["consumerRelease"]
        self.assertEqual(apple_release["target"]["const"], "macos-arm64")
        self.assertIn("macos-arm64", artifact["properties"]["target"]["enum"])
        self.assertNotIn("macos-universal", artifact["properties"]["target"]["enum"])

    def test_retained_rollback_contains_source_and_executable_settings(self) -> None:
        release = (ROOT / ".github/workflows/release.yml").read_text()
        creator = (ROOT / "scripts/ci/create-domain-core-rollback-bundle.py").read_text()
        gate = (ROOT / "scripts/ci/verify-domain-core-legacy-deletion.py").read_text()
        for marker in (
            "git archive",
            '"$candidate"',
            "--source-archive",
            "legacy-source.tar.gz",
            "rollback.env",
        ):
            self.assertIn(marker, release + creator)
        for marker in (
            "rollback artifact legacy source omits required build inputs",
            "rollback artifact environment cannot restore every legacy domain",
            "sourceCommit",
        ):
            self.assertIn(marker, gate)

    def test_ios_release_requires_processed_ipa_and_executable_derived_identity(self) -> None:
        workflow = (ROOT / ".github/workflows/domain-core-ios-release-evidence.yml").read_text()
        verifier = (ROOT / "scripts/ci/verify-domain-core-ios-binary-identity.py").read_text()
        for marker in (
            "xcrun altool --upload-app",
            "xcrun altool --build-status",
            "--wait",
            "app-store-connect-receipt.json",
            "ipa-loaded-rust-identity.json",
        ):
            self.assertIn(marker, workflow)
        for marker in (
            "__TEXT",
            "__obb_core_id",
            "OPENBURNBAR_DOMAIN_CORE_IDENTITY_V1",
            "uniffi_openburnbar_domain_ffi_fn_func_domain_core_abi_version",
            "observed != candidate",
        ):
            self.assertIn(marker, verifier)

    def test_post_deletion_completion_is_a_separate_protected_release_b_gate(self) -> None:
        workflow = (ROOT / ".github/workflows/domain-core-post-deletion-completion.yml").read_text()
        creator = (ROOT / "scripts/ci/create-domain-core-release-evidence.mjs").read_text()
        runbook = (ROOT / "docs/runbooks/shared-rust-legacy-deletion.md").read_text()
        for marker in (
            "workflow_dispatch:",
            "environment: domain-core-promotion",
            "verify-domain-core-final-absence-receipts.py",
            "post_deletion_release_complete",
            "actions/attest-build-provenance@",
            "git merge-base --is-ancestor",
            "all(.rows[]; .state == \"legacy_deleted\")",
        ):
            self.assertIn(marker, workflow)
        self.assertIn("inspect-domain-core-release-legacy-absence.py", creator)
        self.assertIn("legacyAbsence", creator)
        self.assertIn("Stable release **A**", runbook)
        self.assertIn("Stable release **B**", runbook)

    def test_release_b_scans_each_final_artifact_shape_and_deployed_js_root(self) -> None:
        scanner = (ROOT / "scripts/ci/scan-domain-core-final-artifact-legacy.py").read_text()
        creator = (ROOT / "scripts/ci/create-domain-core-release-evidence.mjs").read_text()
        console = (ROOT / ".github/workflows/domain-core-console-release-evidence.yml").read_text()
        functions = (ROOT / ".github/workflows/domain-core-functions-release-evidence.yml").read_text()
        deploy = (ROOT / ".github/workflows/deploy-production.yml").read_text()
        completion = (ROOT / ".github/workflows/domain-core-post-deletion-completion.yml").read_text()

        for marker in (
            ".wasm",
            "hdiutil",
            "--zstd",
            "zipfile.ZipFile",
            "with zipfile.ZipFile(io.BytesIO(data)) as nested",
        ):
            self.assertIn(marker, scanner)
        for marker in (
            "scan-domain-core-final-artifact-legacy.py",
            "--legacy-absence-root",
            "artifactScan",
            "canonicalSha256(report)",
        ):
            self.assertIn(marker, creator)
        self.assertIn('$RUNNER_TEMP/hosting-artifact/apps/console/out', console)
        self.assertIn('$proof_dir/functions-lib', functions)
        self.assertIn('cp -a functions/lib "$stage/functions-lib"', deploy)
        for marker in (
            "OpenBurnBar-${version}-macOS.dmg",
            "OpenBurnBar-${version}-iOS.xcarchive.zip",
            "OpenBurnBar-${version}-Android.aab",
            "OpenBurnBar-${version}-windows-release.zip",
            "OpenBurnBar-${version}-linux-release.tar.zst",
            "OpenBurnBar-${version}-console-deployment.json",
            "OpenBurnBar-${version}-functions-deployment.json",
            "OpenBurnBarMobile\\.ipa",
        ):
            self.assertIn(marker, completion)


if __name__ == "__main__":
    unittest.main()
