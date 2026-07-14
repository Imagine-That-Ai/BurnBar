import json
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
DEPLOY_WORKFLOW = ROOT / ".github/workflows/deploy-production.yml"
EVIDENCE_WORKFLOW = ROOT / ".github/workflows/domain-core-functions-release-evidence.yml"
DOMAIN_WORKFLOW = ROOT / ".github/workflows/domain-core.yml"
PUBLISHER = ROOT / "scripts/ci/publish-domain-core-release-evidence.mjs"


class DomainCoreReleaseEvidenceWorkflowTests(unittest.TestCase):
    def test_deploy_dispatches_without_holding_production_concurrency(self) -> None:
        source = DEPLOY_WORKFLOW.read_text(encoding="utf-8")
        required = (
            "stable_release: ${{ steps.tag.outputs.stable_release }}",
            "(\\+[0-9A-Za-z.-]+)?$ ]] && echo true || echo false)",
            "dispatch-domain-core-functions-evidence:",
            "needs: [deploy-functions, functions-health-gate]",
            "needs.functions-health-gate.result == 'success'",
            "needs.deploy-functions.outputs.dry_run != 'true'",
            "needs.deploy-functions.outputs.stable_release == 'true'",
            "actions: write",
            "gh workflow run domain-core-functions-release-evidence.yml",
            '--ref "$RELEASE_TAG"',
            '--field deploy_run_id="$GITHUB_RUN_ID"',
            "HEALTH_GATE_EXPECTED_SOURCE_COMMIT: ${{ needs.deploy-functions.outputs.commit }}",
            "HEALTH_GATE_EXPECTED_VERSION: ${{ needs.deploy-functions.outputs.tag }}",
        )
        for value in required:
            self.assertIn(value, source, f"Functions deploy workflow is missing {value}")
        self.assertNotIn("Waiting for release.yml", source)
        self.assertNotIn("actions/attest@", source)

    def test_publisher_binds_exact_tag_deploy_run_and_health_artifact(self) -> None:
        source = EVIDENCE_WORKFLOW.read_text(encoding="utf-8")
        required = (
            "workflow_dispatch:",
            "deploy_run_id:",
            "domain-core-functions-release-evidence-${{ github.ref }}",
            "environment: production",
            "actions: read",
            "contents: write",
            "id-token: write",
            "attestations: write",
            "artifact-metadata: write",
            'run.get("path") != ".github/workflows/deploy-production.yml"',
            'run.get("head_sha") != commit',
            'run.get("head_branch") != tag',
            '("deploy-functions", "functions-health-gate")',
            'gh run download "$DEPLOY_RUN_ID"',
            '--name "deploy-health-$RELEASE_TAG"',
            'git rev-parse "refs/tags/$release_tag^{commit}"',
            "scripts/ci/create-domain-core-release-evidence.mjs",
            '--health-artifact "$RUNNER_TEMP/deploy-health/deploy-health.json"',
        )
        for value in required:
            self.assertIn(value, source, f"Functions evidence workflow is missing {value}")

    def test_functions_evidence_is_custom_attested_and_published_immutably(self) -> None:
        source = EVIDENCE_WORKFLOW.read_text(encoding="utf-8")
        required = (
            "actions/attest@a1948c3f048ba23858d222213b7c278aabede763",
            "predicate-type: https://openburnbar.dev/attestations/domain-core-release-artifact/v1",
            "predicate-path: ${{ steps.evidence.outputs.predicate }}",
            'consumer: "functions"',
            'signerWorkflow: ".github/workflows/domain-core-functions-release-evidence.yml"',
            "artifactPath,",
            'bundles: [{ domain: "pricing", assetName, bundlePath, predicatePath }]',
            "scripts/ci/publish-domain-core-release-evidence.mjs",
            '--manifest "$manifest"',
        )
        for value in required:
            self.assertIn(value, source, f"Functions evidence workflow is missing {value}")

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

    def test_release_evidence_schemas_are_strict_and_accept_stable_build_metadata(self) -> None:
        predicate = json.loads((ROOT / "config/domain-core-release-predicate.schema.json").read_text())
        receipt = json.loads((ROOT / "config/domain-core-deployment-receipt.schema.json").read_text())
        self.assertFalse(predicate["additionalProperties"])
        self.assertFalse(receipt["additionalProperties"])
        self.assertEqual(predicate["properties"]["schemaVersion"]["const"], 1)
        self.assertEqual(receipt["properties"]["schemaVersion"]["const"], 1)
        self.assertIn("\\+", predicate["$defs"]["release"]["properties"]["version"]["pattern"])
        self.assertIn("\\+", receipt["properties"]["release"]["properties"]["version"]["pattern"])
        self.assertIn("healthChecks", receipt["properties"]["deployment"]["required"])

        predicate_contracts = {
            rule["if"]["properties"]["consumer"]["const"]: rule["then"]["properties"] for rule in predicate["allOf"]
        }
        self.assertEqual(
            predicate_contracts["console"],
            {
                "artifactKind": {"const": "console-deployment-receipt"},
                "target": {"const": "firebase-hosting-production"},
            },
        )

        receipt_contracts = {
            rule["if"]["properties"]["consumer"]["const"]: rule["then"]["properties"] for rule in receipt["allOf"]
        }
        console = receipt_contracts["console"]
        self.assertEqual(console["artifactKind"]["const"], "console-deployment-receipt")
        self.assertEqual(console["target"]["const"], "firebase-hosting-production")
        self.assertEqual(
            console["deployment"]["properties"]["provider"]["const"],
            "firebase-hosting",
        )
        self.assertEqual(
            [item["const"] for item in console["deployment"]["properties"]["healthChecks"]["prefixItems"]],
            ["marketing", "console", "deploymentIdentity"],
        )

    def test_domain_core_ci_runs_release_evidence_contracts(self) -> None:
        source = DOMAIN_WORKFLOW.read_text(encoding="utf-8")
        required = (
            '".github/workflows/domain-core-functions-release-evidence.yml"',
            '"scripts/ci/create-domain-core-release-evidence.test.mjs"',
            '"scripts/ci/publish-domain-core-release-evidence.mjs"',
            '"scripts/ci/publish-domain-core-release-evidence.test.mjs"',
            '"tests/test_domain_core_release_evidence_workflow.py"',
            '"scripts/ci/post-deploy-health-gate.test.sh"',
            "python3 tests/test_domain_core_release_evidence_workflow.py",
            "scripts/ci/publish-domain-core-release-evidence.test.mjs",
            "bash scripts/ci/post-deploy-health-gate.test.sh",
        )
        for value in required:
            self.assertIn(value, source)
        gate_source = (ROOT / "scripts/ci/verify-domain-core-legacy-deletion.py").read_text(encoding="utf-8")
        self.assertIn(
            '"functions": ".github/workflows/domain-core-functions-release-evidence.yml"',
            gate_source,
        )

    def test_health_gate_fails_closed_on_old_deployed_revision(self) -> None:
        source = (ROOT / "scripts/ci/post-deploy-health-gate.sh").read_text(encoding="utf-8")
        required = (
            "HEALTH_GATE_EXPECTED_SOURCE_COMMIT",
            "HEALTH_GATE_EXPECTED_VERSION",
            'source.get("repository") != repository',
            'source.get("commit") != commit',
            'ready.get("version") != version',
            "write it only after availability",
        )
        for value in required:
            self.assertIn(value, source)


if __name__ == "__main__":
    unittest.main()
