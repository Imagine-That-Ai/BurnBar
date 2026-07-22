import yaml

import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
DEPLOY = ROOT / ".github/workflows/deploy-production.yml"
EVIDENCE = ROOT / ".github/workflows/domain-core-functions-release-evidence.yml"


def workflow(path: Path) -> dict:
    return yaml.load(path.read_text(encoding="utf-8"), Loader=yaml.BaseLoader)


def step(job: dict, name: str) -> dict:
    return next(value for value in job["steps"] if value.get("name") == name)


class DomainCoreFunctionsReleaseWorkflowTests(unittest.TestCase):
    def test_deploy_selects_profile_and_authorizes_only_manual_rollback(self) -> None:
        source = DEPLOY.read_text(encoding="utf-8")
        required = (
            "domain_core_profile:",
            "public-production",
            "public-production-rollback",
            "authorize-domain-core-rollback:",
            "environment: domain-core-promotion",
            "environment: production",
            'DOMAIN_CORE_PROFILE="public-production"',
            "needs.authorize-domain-core-rollback.result == 'success'",
        )
        for value in required:
            self.assertIn(value, source)
        self.assertLess(source.index("authorize-domain-core-rollback:"), source.index("deploy-functions:"))

    def test_protected_candidate_is_verified_before_build_or_deploy(self) -> None:
        source = DEPLOY.read_text(encoding="utf-8")
        required = (
            "Locate exact deterministic candidate source run",
            "--paginate --slurp",
            "domain-core-candidate-bundle-${{ steps.domain-core-profile.outputs.candidate_commit }}",
            "domain-core-public-production-rollback-${{ steps.domain-core-profile.outputs.candidate_commit }}",
            "gh attestation download",
            "scripts/ci/verify-domain-core-release-gate.mjs",
            '--protected-signer-run-id "$run_id"',
            '--protected-signer-run-attempt "$run_attempt"',
            "No successful protected signer run attests the exact candidate bundle and run attempt",
            "Install and build selected Functions artifact",
            "Create immutable Functions deploy proof",
            "scripts/ci/create-domain-core-functions-deploy-proof.mjs",
        )
        for value in required:
            self.assertIn(value, source)
        self.assertLess(
            source.index("Verify protected promotion and exact rollback before build"),
            source.index("Install and build selected Functions artifact"),
        )
        self.assertLess(
            source.index("Create immutable Functions deploy proof"),
            source.index("Deploy Cloud Functions"),
        )

    def test_functions_artifact_stays_candidate_scoped_at_release(self) -> None:
        deploy = workflow(DEPLOY)["jobs"]["prepare-functions-deploy"]
        build = step(deploy, "Install and build selected Functions artifact")["run"]
        resolver, verifier = build.split(
            "node scripts/ci/verify-domain-core-build-profile-artifact.mjs",
            maxsplit=1,
        )
        self.assertIn("--expected-release-commit", resolver)
        self.assertNotIn("--expected-release-version", resolver)
        self.assertNotIn("--expected-release-tag", resolver)
        self.assertIn("--expected-release-commit", verifier)
        self.assertIn("--expected-release-version", verifier)
        self.assertIn("--expected-release-tag", verifier)

    def test_deploy_health_and_dispatch_bind_exact_receipt(self) -> None:
        source = DEPLOY.read_text(encoding="utf-8")
        required = (
            "HEALTH_GATE_EXPECTED_SOURCE_COMMIT",
            "HEALTH_GATE_EXPECTED_VERSION",
            "HEALTH_GATE_EXPECTED_DOMAIN_CORE_PROFILE",
            "HEALTH_GATE_EXPECTED_DOMAIN_CORE_CANDIDATE_COMMIT",
            "HEALTH_GATE_EXPECTED_DOMAIN_CORE_SOURCE_SHA256",
            "HEALTH_GATE_EXPECTED_DOMAIN_CORE_PRICING_MODE",
            "HEALTH_GATE_EXPECTED_DOMAIN_CORE_RUNTIME_MANIFEST_SHA256",
            "HEALTH_GATE_EXPECTED_DOMAIN_CORE_WASM_SHA256",
            "domain-core-functions-deploy-proof-${RELEASE_TAG}-${GITHUB_RUN_ID}-${GITHUB_RUN_ATTEMPT}",
            "domain-core-functions-deploy-health-${{ needs.deploy-functions.outputs.tag }}-${{ github.run_id }}-${{ github.run_attempt }}",
            "dispatch-domain-core-functions-evidence:",
            "needs: [deploy-functions, functions-health-gate]",
            "gh workflow run domain-core-functions-release-evidence.yml",
            '--field deploy_run_attempt="$GITHUB_RUN_ATTEMPT"',
            '--field domain_core_profile="$DOMAIN_CORE_PROFILE"',
        )
        for value in required:
            self.assertIn(value, source)

    def test_evidence_rechecks_run_profile_health_and_v2_provenance(self) -> None:
        source = EVIDENCE.read_text(encoding="utf-8")
        required = (
            "deploy_run_id:",
            "deploy_run_attempt:",
            "domain_core_profile:",
            "/attempts/$DEPLOY_RUN_ATTEMPT/jobs?per_page=100",
            "select(.total_count == (.jobs | length))",
            ".run_attempt == $attempt",
            "Deploy run did not complete within 10 minutes",
            "scripts/ci/verify-domain-core-functions-deploy-run.mjs",
            '--deploy-run-id "$DEPLOY_RUN_ID"',
            '--deploy-run-attempt "$DEPLOY_RUN_ATTEMPT"',
            'functions-deploy-run-verification.json',
            "scripts/ci/create-domain-core-functions-deploy-proof.mjs",
            "Reverify archived release gate and exact deploy proof",
            '--rollback-sha256 "$rollback_sha256"',
            "scripts/ci/create-domain-core-functions-deployment-evidence.mjs",
            '--deploy-run-verification "$RUNNER_TEMP/functions-deploy-run-verification.json"',
            "scripts/ci/create-domain-core-release-evidence.mjs",
            '--protected-signer-run-id "$SIGNER_RUN_ID"',
            '--protected-signer-run-attempt "$SIGNER_RUN_ATTEMPT"',
            "actions/attest@a1948c3f048ba23858d222213b7c278aabede763",
            "https://openburnbar.dev/attestations/domain-core-release-artifact/v2",
        )
        for value in required:
            self.assertIn(value, source)

    def test_rollback_attestation_follows_deploy_health_and_exact_artifact_readback(self) -> None:
        deploy_jobs = workflow(DEPLOY)["jobs"]
        dispatch = deploy_jobs["dispatch-domain-core-functions-evidence"]
        self.assertEqual(
            set(dispatch["needs"]),
            {"deploy-functions", "functions-health-gate"},
        )
        dispatch_gate = " ".join(dispatch["if"].split())
        for required_result in (
            "needs.deploy-functions.result == 'success'",
            "needs.functions-health-gate.result == 'success'",
            "needs.deploy-functions.outputs.dry_run != 'true'",
            "needs.deploy-functions.outputs.stable_release == 'true'",
        ):
            self.assertIn(required_result, dispatch_gate)

        publish = workflow(EVIDENCE)["jobs"]["publish"]
        proof_download = step(publish, "Download exact deployed Functions proof inputs")
        self.assertEqual(
            proof_download["with"],
            {
                "github-token": "${{ github.token }}",
                "run-id": "${{ inputs.deploy_run_id }}",
                "name": "domain-core-functions-deploy-proof-${{ github.ref_name }}-${{ inputs.deploy_run_id }}-${{ inputs.deploy_run_attempt }}",
                "path": "${{ runner.temp }}/functions-deploy-proof",
            },
        )
        health_download = step(publish, "Download exact post-deploy health evidence")
        self.assertEqual(
            health_download["with"],
            {
                "github-token": "${{ github.token }}",
                "run-id": "${{ inputs.deploy_run_id }}",
                "name": "domain-core-functions-deploy-health-${{ github.ref_name }}-${{ inputs.deploy_run_id }}-${{ inputs.deploy_run_attempt }}",
                "path": "${{ runner.temp }}/functions-deploy-health",
            },
        )
        names = [value.get("name") for value in publish["steps"]]
        self.assertLess(
            names.index("Reverify live deployment evidence"),
            names.index("Create candidate-bound v2 Functions receipt and predicate"),
        )
        self.assertLess(
            names.index("Create candidate-bound v2 Functions receipt and predicate"),
            names.index("Attest exact Functions deployment receipt"),
        )
        retained = step(publish, "Retain unique immutable rollback evidence")["with"]
        self.assertEqual(
            set(retained["path"].splitlines()),
            {
                "${{ steps.evidence.outputs.artifact }}",
                "${{ steps.evidence.outputs.predicate }}",
                "${{ runner.temp }}/${{ steps.evidence.outputs.bundle_asset }}",
                "${{ runner.temp }}/functions-deploy-run-verification.json",
                "${{ runner.temp }}/functions-deploy-proof",
                "${{ runner.temp }}/functions-deploy-health/deploy-health.json",
            },
        )

    def test_rollback_evidence_names_cannot_collide_across_attempts(self) -> None:
        source = EVIDENCE.read_text(encoding="utf-8")
        template = (
            "domain-core-functions-rollback-evidence-${{ github.ref_name }}-"
            "${{ inputs.deploy_run_id }}-${{ inputs.deploy_run_attempt }}"
        )
        self.assertIn(template, source)
        first = "domain-core-functions-rollback-evidence-v1.2.3-100-1"
        rerun = "domain-core-functions-rollback-evidence-v1.2.3-100-2"
        different_run = "domain-core-functions-rollback-evidence-v1.2.3-101-1"
        self.assertEqual(len({first, rerun, different_run}), 3)
        self.assertIn("if: inputs.domain_core_profile == 'public-production'", source)
        self.assertIn("if: inputs.domain_core_profile == 'public-production-rollback'", source)
        self.assertNotIn("publish-domain-core-release-evidence.mjs --manifest", source[source.index("Retain unique immutable rollback evidence") :])

    def test_health_artifact_is_written_only_after_all_live_gates(self) -> None:
        source = (ROOT / "scripts/ci/post-deploy-health-gate.sh").read_text(encoding="utf-8")
        required = (
            "HEALTH_GATE_EXPECTED_SOURCE_COMMIT",
            "HEALTH_GATE_EXPECTED_DOMAIN_CORE_PROFILE",
            'domain_core.get("loadedCore") != expected_loaded',
            'domain_core.get("artifactManifest") != expected_manifest',
            "omits immutable Functions runtime coordinates",
            "OK Sentry enabled on live healthReady",
            "A deploy-health artifact is evidence",
        )
        for value in required:
            self.assertIn(value, source)
        self.assertLess(source.index("OK Sentry enabled on live healthReady"), source.index("A deploy-health artifact is evidence"))


if __name__ == "__main__":
    unittest.main()
