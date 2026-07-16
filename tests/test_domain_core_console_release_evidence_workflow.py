import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
DEPLOY = ROOT / ".github/workflows/deploy-hosting.yml"
EVIDENCE = ROOT / ".github/workflows/domain-core-console-release-evidence.yml"


class ConsoleReleaseWorkflowTests(unittest.TestCase):
    def test_automatic_deploy_is_public_production_and_rollback_is_separately_authorized(self) -> None:
        source = DEPLOY.read_text(encoding="utf-8")
        required = (
            'tags: ["v*"]',
            "domain_core_profile:",
            "- public-production",
            "- public-production-rollback",
            "authorize-domain-core-rollback:",
            "environment: domain-core-promotion",
            "github.event_name == 'workflow_dispatch'",
            "inputs.domain_core_profile == 'public-production-rollback'",
            'profile="public-production"',
            'if [[ "$EVENT_NAME" == "workflow_dispatch" ]]',
            'if [[ "$profile" == "public-production-rollback" ]]',
            '[[ "$EVENT_NAME" != "workflow_dispatch" || -z "$release_tag" ]]',
            "Rollback is manual-only and must target an exact stable release tag",
            "needs.authorize-domain-core-rollback.result == 'success'",
        )
        for value in required:
            self.assertIn(value, source)
        self.assertNotIn("environment: domain-core-promotion\n    permissions:\n      id-token", source)

    def test_deploy_consumes_exact_protected_candidate_and_retained_rollback(self) -> None:
        source = DEPLOY.read_text(encoding="utf-8")
        required = (
            "actions/artifacts?name=$artifact_name&per_page=100",
            "--paginate --slurp",
            "artifacts API pagination incomplete",
            ".github/workflows/domain-core-promotion-proof.yml",
            "protected-domain-core-signer",
            'jq -e --arg sha "$CANDIDATE_COMMIT" \'.candidate.candidateCommit == $sha\'',
            "domain-core-candidate-bundle-${CANDIDATE_COMMIT}-${SOURCE_RUN_ID}-${SOURCE_RUN_ATTEMPT}",
            "domain-core-public-production-rollback-${CANDIDATE_COMMIT}-${SOURCE_RUN_ID}-${SOURCE_RUN_ATTEMPT}",
            "gh attestation download",
            "verify-domain-core-release-gate.mjs",
            '--expected-candidate-commit "$CANDIDATE_COMMIT"',
            "create-domain-core-deployment-identity.mjs",
            "domain-core-release-inputs/domain-core-release-gate.json",
        )
        for value in required:
            self.assertIn(value, source)
        self.assertNotIn("domain-core-legacy-rollback", source)

    def test_live_smoke_and_evidence_dispatch_are_exact_run_attempt_bound(self) -> None:
        source = DEPLOY.read_text(encoding="utf-8")
        required = (
            "HOSTING_SMOKE_EXPECTED_COMMIT:",
            "HOSTING_SMOKE_EXPECTED_TAG:",
            "HOSTING_SMOKE_PROFILE_RECEIPT:",
            "HOSTING_SMOKE_RELEASE_GATE:",
            "console-deploy-health-${{ github.run_id }}-${{ github.run_attempt }}",
            "dispatch-domain-core-console-evidence:",
            "needs.hosting-smoke-result.result == 'success'",
            '--field deploy_run_id="$GITHUB_RUN_ID"',
            '--field deploy_run_attempt="$GITHUB_RUN_ATTEMPT"',
        )
        for value in required:
            self.assertIn(value, source)

    def test_evidence_reverifies_exact_deploy_proof_and_v2_attestation(self) -> None:
        source = EVIDENCE.read_text(encoding="utf-8")
        required = (
            "deploy_run_id:",
            "deploy_run_attempt:",
            "domain-core-console-release-evidence-${{ inputs.deploy_run_id }}-${{ inputs.deploy_run_attempt }}",
            'git rev-parse "refs/tags/$release_tag^{commit}"',
            'gh run watch "$DEPLOY_RUN_ID"',
            "actions/runs/$DEPLOY_RUN_ID/attempts/$DEPLOY_RUN_ATTEMPT/jobs?per_page=100",
            "hosting-artifacts-${GITHUB_SHA}-${DEPLOY_RUN_ID}-${DEPLOY_RUN_ATTEMPT}",
            "console-deploy-health-${DEPLOY_RUN_ID}-${DEPLOY_RUN_ATTEMPT}",
            "sha256sum -c SHA256SUMS",
            "verify-domain-core-release-gate.mjs",
            "cmp \"$gate\" \"$RUNNER_TEMP/reverified-release-gate.json\"",
            "verify-domain-core-console-deploy-evidence.mjs",
            'echo "deployment=$RUNNER_TEMP/console-deploy-verification.json"',
            "create-domain-core-release-evidence.mjs",
            "--artifact-kind console-deployment-receipt",
            "--target firebase-hosting-production",
            '--deployment "$DEPLOYMENT"',
            "predicate-type: https://openburnbar.dev/attestations/domain-core-release-artifact/v2",
        )
        for value in required:
            self.assertIn(value, source)

    def test_normal_publication_is_create_only_and_rollback_results_are_run_bound(self) -> None:
        source = EVIDENCE.read_text(encoding="utf-8")
        required = (
            "publish-domain-core-release-evidence.mjs",
            "schemaVersion: 2",
            'signerWorkflow: ".github/workflows/domain-core-console-release-evidence.yml"',
            "domain-core-console-rollback-evidence-${{ steps.ref.outputs.release_tag }}-${{ inputs.deploy_run_id }}-${{ inputs.deploy_run_attempt }}-${{ github.run_id }}-${{ github.run_attempt }}",
            "Stage run-bound rollback evidence without duplicating signer rollback artifact",
            "Retain this rollback evidence workflow result",
        )
        for value in required:
            self.assertIn(value, source)
        self.assertNotIn("--clobber", source)
        self.assertNotIn("gh release create", source)
        self.assertNotIn("gh release edit", source)
        self.assertNotIn("Reject replayed rollback evidence publication", source)
        self.assertNotIn("Rollback evidence already exists", source)
        rollback_stage = source[source.index("Stage run-bound rollback evidence without duplicating") :]
        self.assertNotIn("domain-core-public-production-rollback.json", rollback_stage)


if __name__ == "__main__":
    unittest.main()
