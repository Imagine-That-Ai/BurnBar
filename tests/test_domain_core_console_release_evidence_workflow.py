import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
DEPLOY_WORKFLOW = ROOT / ".github/workflows/deploy-hosting.yml"
EVIDENCE_WORKFLOW = ROOT / ".github/workflows/domain-core-console-release-evidence.yml"
DOMAIN_WORKFLOW = ROOT / ".github/workflows/domain-core.yml"
PUBLISHER = ROOT / "scripts/ci/publish-domain-core-release-evidence.mjs"


class DomainCoreConsoleReleaseEvidenceWorkflowTests(unittest.TestCase):
    def test_hosting_deploy_binds_tag_identity_and_dispatches_after_live_smoke(self) -> None:
        source = DEPLOY_WORKFLOW.read_text(encoding="utf-8")
        required = (
            'tags: ["v*"]',
            "commit: ${{ steps.ref.outputs.commit }}",
            "release_tag: ${{ steps.ref.outputs.release_tag }}",
            "stable_release: ${{ steps.ref.outputs.stable_release }}",
            'git rev-parse "$GITHUB_REF^{commit}"',
            "scripts/ci/create-domain-core-deployment-identity.mjs",
            "apps/console/public/domain-core-deployment-identity.json",
            "HOSTING_SMOKE_EXPECTED_COMMIT:",
            "HOSTING_SMOKE_EXPECTED_TAG:",
            "CONSOLE_DEPLOY_HEALTH_JSON:",
            "console-deploy-health-${{ needs.build-hosting-artifacts.outputs.release_tag }}",
            "path: console-deploy-health.json",
            "dispatch-domain-core-console-evidence:",
            "needs: [build-hosting-artifacts, deploy-hosting, hosting-smoke-result]",
            "needs.hosting-smoke-result.result == 'success'",
            "needs.build-hosting-artifacts.outputs.stable_release == 'true'",
            "gh workflow run domain-core-console-release-evidence.yml",
            '--ref "$RELEASE_TAG"',
            '--field deploy_run_id="$GITHUB_RUN_ID"',
        )
        for value in required:
            self.assertIn(value, source, f"Console deploy workflow is missing {value}")
        self.assertNotIn("Waiting for release.yml", source)
        self.assertNotIn("actions/attest@", source)

    def test_publisher_binds_exact_tag_deploy_run_and_health_artifact(self) -> None:
        source = EVIDENCE_WORKFLOW.read_text(encoding="utf-8")
        required = (
            "workflow_dispatch:",
            "deploy_run_id:",
            "domain-core-console-release-evidence-${{ github.ref }}",
            "environment: production",
            "actions: read",
            "contents: write",
            "id-token: write",
            "attestations: write",
            "artifact-metadata: write",
            'run.get("path") != ".github/workflows/deploy-hosting.yml"',
            'run.get("head_sha") != commit',
            'run.get("head_branch") != tag',
            '("build-hosting-artifacts", "deploy-hosting", "hosting-smoke-result")',
            'gh run download "$DEPLOY_RUN_ID"',
            '--name "console-deploy-health-$RELEASE_TAG"',
            "console-deploy-health/console-deploy-health.json",
            'git rev-parse "refs/tags/$release_tag^{commit}"',
            "scripts/ci/create-domain-core-release-evidence.mjs",
            "--consumer console",
            "--domain cloudVault",
        )
        for value in required:
            self.assertIn(value, source, f"Console evidence workflow is missing {value}")

    def test_console_evidence_is_custom_attested_and_published_immutably(self) -> None:
        source = EVIDENCE_WORKFLOW.read_text(encoding="utf-8")
        required = (
            "actions/attest@a1948c3f048ba23858d222213b7c278aabede763",
            "predicate-type: https://openburnbar.dev/attestations/domain-core-release-artifact/v1",
            "predicate-path: ${{ steps.evidence.outputs.predicate }}",
            'consumer: "console"',
            'signerWorkflow: ".github/workflows/domain-core-console-release-evidence.yml"',
            'releaseAvailability: "published"',
            "artifactPath,",
            'bundles: [{ domain: "cloudVault", assetName, bundlePath, predicatePath }]',
            "scripts/ci/publish-domain-core-release-evidence.mjs",
            '--manifest "$manifest"',
        )
        for value in required:
            self.assertIn(value, source, f"Console evidence workflow is missing {value}")

        publisher = PUBLISHER.read_text(encoding="utf-8")
        for value in (
            '"--signer-workflow"',
            '"--source-digest"',
            '"--source-ref"',
            '"--signer-digest"',
            '"--cert-oidc-issuer"',
            '"--deny-self-hosted-runners"',
            '"--predicate-type"',
            "refusing to replace non-identical immutable release asset",
            "published artifact bytes differ from the signed local artifact",
        ):
            self.assertIn(value, publisher)
        self.assertNotIn('"--clobber"', publisher)
        self.assertNotIn('["release", "create"', publisher)
        self.assertNotIn('["release", "edit"', publisher)

    def test_domain_core_ci_and_deletion_gate_use_console_publisher(self) -> None:
        source = DOMAIN_WORKFLOW.read_text(encoding="utf-8")
        required = (
            '".github/workflows/domain-core-console-release-evidence.yml"',
            '"scripts/ci/create-domain-core-deployment-identity.test.mjs"',
            '"scripts/ci/publish-domain-core-release-evidence.mjs"',
            '"scripts/ci/publish-domain-core-release-evidence.test.mjs"',
            '"scripts/ci/hosting-smoke-domain-core.test.sh"',
            '"tests/test_domain_core_console_release_evidence_workflow.py"',
            "python3 tests/test_domain_core_console_release_evidence_workflow.py",
            "scripts/ci/publish-domain-core-release-evidence.test.mjs",
            "bash scripts/ci/hosting-smoke-domain-core.test.sh",
        )
        for value in required:
            self.assertIn(value, source)
        gate_source = (ROOT / "scripts/ci/verify-domain-core-legacy-deletion.py").read_text(encoding="utf-8")
        self.assertIn(
            '"console": ".github/workflows/domain-core-console-release-evidence.yml"',
            gate_source,
        )

    def test_console_identity_is_never_served_from_a_stale_cache(self) -> None:
        firebase = (ROOT / "firebase.json").read_text(encoding="utf-8")
        self.assertIn('"source": "/domain-core-deployment-identity.json"', firebase)
        self.assertIn('"value": "no-store, max-age=0"', firebase)
        domain = DOMAIN_WORKFLOW.read_text(encoding="utf-8")
        self.assertEqual(domain.count('- "firebase.json"'), 2)


if __name__ == "__main__":
    unittest.main()
