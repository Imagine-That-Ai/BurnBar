from __future__ import annotations

import json
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
DOMAIN_WORKFLOW = ROOT / ".github/workflows/domain-core.yml"
SIGNER_WORKFLOW = ROOT / ".github/workflows/domain-core-promotion-proof.yml"


class DomainCoreLegacyDeletionWorkflowTests(unittest.TestCase):
    def test_domain_workflow_runs_governance_and_append_only_gate(self) -> None:
        source = DOMAIN_WORKFLOW.read_text()
        for marker in (
            "python3 tests/test_domain_core_legacy_deletion_gate.py",
            "python3 tests/test_domain_core_legacy_deletion_workflow.py",
            "python3 scripts/ci/verify-domain-core-legacy-deletion.py",
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
        candidate_job = source[source.index("  candidate-bundle:"):]
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
        self.assertIn("all(.value.result == \"success\")", candidate_job)

    def test_schemas_encode_exact_candidate_and_retained_rollback(self) -> None:
        promotion = json.loads((ROOT / "config/domain-core-promotion-attestation.schema.json").read_text())
        receipt = json.loads((ROOT / "config/domain-core-legacy-deletion-receipt.schema.json").read_text())
        candidate = promotion["$defs"]["candidate"]
        self.assertEqual(
            candidate["required"],
            ["candidateCommit", "coreVersion", "abiVersion", "sourceSha256"],
        )
        rollback = receipt["$defs"]["rollbackArtifact"]
        self.assertEqual(rollback["properties"]["retentionPolicy"]["const"], "retain_until_legacy_deletion_complete")
        self.assertEqual(rollback["properties"]["artifactKind"]["const"], "legacy-rollback-bundle")


if __name__ == "__main__":
    unittest.main()
