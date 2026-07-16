"""Focused tests for the Windows release workflow's domain-core v2 evidence step.

Verifies that the ``supply-chain`` job's "Create candidate-bound Windows v2
domain-core evidence" step consumes the canonical native release evidence
plan/gate output produced by ``create-domain-core-native-release-evidence.mjs``
— which derives Windows domains from ``RELEASE_CONSUMERS`` + the selected
profile — rather than iterating over the flat activation JSON's ``.domains[]``
selector with a process-substitution producer whose failure can disappear
behind a successful ``while`` loop.

Acceptance:
  * The flat activation JSON is not used as a domain list — the canonical
    generator is invoked and produces ``domain-core-native-evidence-plan.json``.
  * A valid plan emits all expected Windows domain predicates (the generator
    derives them from ``RELEASE_CONSUMERS.windows.domains`` + profile modes).
  * A malformed or empty plan fails nonzero — the step validates the plan with
    ``jq -e '.schemaVersion == 2 and .consumer == "windows" and (.domains |
    length > 0)'`` and iterates over a real predicate-list file.
  * Workflow YAML syntax remains valid.
"""

import json
import subprocess
import tempfile
import textwrap
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
WORKFLOW = ROOT / ".github/workflows/openburnbar-release-windows.yml"


def _evidence_step_source() -> str:
    """Return the YAML text of the 'Create candidate-bound' evidence step."""
    source = WORKFLOW.read_text(encoding="utf-8")
    marker = "Create candidate-bound Windows v2 domain-core evidence"
    start = source.index(marker)
    rest = source[start:]
    next_step = rest.find("\n      - name: ", len(marker))
    if next_step == -1:
        raise AssertionError("could not find end of evidence step")
    return rest[:next_step]


class WindowsReleaseEvidencePlanTests(unittest.TestCase):
    def test_workflow_yaml_syntax_is_valid(self) -> None:
        import yaml

        data = yaml.safe_load(WORKFLOW.read_text(encoding="utf-8"))
        self.assertIn("supply-chain", data["jobs"])
        supply_chain = data["jobs"]["supply-chain"]
        self.assertIn("domain-core-native-release-gate", supply_chain["needs"])
        # Env must carry the gate outputs needed by the generator.
        env = supply_chain["env"]
        self.assertIn("PROFILE", env)
        self.assertIn("SIGNER_RUN_ID", env)
        self.assertIn("SIGNER_RUN_ATTEMPT", env)
        self.assertIn("RELEASE_TAG", env)

    def test_supply_chain_downloads_gate_artifact_before_evidence(self) -> None:
        """The gate artifact must be downloaded before the evidence step."""
        source = WORKFLOW.read_text(encoding="utf-8")
        download_idx = source.index(
            "name: domain-core-windows-release-gate-"
            "${{ needs.resolve-release.outputs.release_commit }}"
        )
        evidence_idx = source.index("Create candidate-bound Windows v2 domain-core evidence")
        self.assertLess(download_idx, evidence_idx)

    def test_flat_activation_resolver_not_used_as_domain_list(self) -> None:
        """The evidence step must NOT call resolve-domain-core-activation.mjs
        or iterate over the flat activation JSON's .domains[] selector."""
        step = _evidence_step_source()
        self.assertNotIn("resolve-domain-core-activation.mjs", step)
        self.assertNotIn("resolve-domain-core-activation", step)

    def test_no_jq_domains_on_activation(self) -> None:
        """No jq command may read .domains[] from the activation JSON.

        The only .domains[] reference allowed is on the canonical plan file
        ($plan), not on the gate's domain-core-activation.json.
        """
        step = _evidence_step_source()
        # Remove comment lines before checking.
        code_lines = [
            line for line in step.splitlines()
            if not line.strip().startswith("#")
        ]
        code = "\n".join(code_lines)
        # No jq command may reference both 'domains' and 'activation'.
        for line in code_lines:
            if "jq" in line and "domains" in line:
                self.assertIn(
                    "$plan",
                    line,
                    f"jq .domains[] must read from $plan, not activation: {line.strip()}",
                )

    def test_no_process_substitution_domain_iteration(self) -> None:
        """The ``while … done < <(jq …)`` process-substitution pattern must
        be gone — a producer failure there disappears behind a successful
        ``while``.  The predicate list must be written to a real file first.
        """
        step = _evidence_step_source()
        self.assertNotIn("done < <(jq", step)
        self.assertNotIn("done < <(", step)
        self.assertIn('done < "$predicate_list"', step)

    def test_canonical_generator_is_invoked(self) -> None:
        """The step must call create-domain-core-native-release-evidence.mjs
        with gate-validated inputs, not hand-build a jq plan."""
        step = _evidence_step_source()
        self.assertIn("create-domain-core-native-release-evidence.mjs", step)
        self.assertIn("--consumer windows", step)
        self.assertIn("--artifact ", step)
        self.assertIn("--version \"$VERSION\"", step)
        self.assertIn("--tag \"$RELEASE_TAG\"", step)
        self.assertIn("--commit \"$RELEASE_COMMIT\"", step)
        self.assertIn("--profile-name \"$PROFILE\"", step)
        self.assertIn("--profile \"$gate_dir/domain-core-selected-public-profile.json\"", step)
        self.assertIn("--activation \"$gate_dir/domain-core-activation.json\"", step)
        self.assertIn(
            "--candidate-bundle \"$gate_dir/source/domain-core-candidate-bundle.json\"",
            step,
        )
        self.assertIn(
            "--promotion-attestation \"$gate_dir/promotion/"
            "domain-core-promotion-attestation.sigstore.jsonl\"",
            step,
        )
        self.assertIn("--protected-signer-run-id \"$SIGNER_RUN_ID\"", step)
        self.assertIn("--protected-signer-run-attempt \"$SIGNER_RUN_ATTEMPT\"", step)
        self.assertIn(
            "--rollback-artifact \"$gate_dir/source/"
            "domain-core-public-production-rollback.json\"",
            step,
        )
        self.assertIn("--output-dir \"$evidence_dir\"", step)

    def test_plan_path_is_derived_from_generator_output_dir(self) -> None:
        """The plan file must be the canonical
        domain-core-native-evidence-plan.json in the generator's output dir."""
        step = _evidence_step_source()
        self.assertIn(
            'plan="$evidence_dir/domain-core-native-evidence-plan.json"',
            step,
        )
        self.assertIn('test -s "$plan"', step)

    def test_plan_validated_with_schema_and_nonempty_domains(self) -> None:
        """The plan must be validated with jq -e against schemaVersion,
        consumer, and non-empty domains — fail closed on any violation."""
        step = _evidence_step_source()
        self.assertIn(
            'jq -e \'.schemaVersion == 2 and .consumer == "windows" and (.domains | length > 0)\'',
            step,
        )
        self.assertIn('"$plan" >/dev/null', step)

    def test_predicate_paths_written_to_file_before_iteration(self) -> None:
        """Predicate paths must be extracted from the plan to a real file
        before the cosign loop so a jq failure propagates through set -e."""
        step = _evidence_step_source()
        self.assertIn(
            'jq -r \'.domains[].predicatePath\' "$plan" > "$predicate_list"',
            step,
        )
        self.assertIn('predicate_list="$RUNNER_TEMP/domain-core-windows-predicate-paths.txt"', step)

    def test_cosign_attest_uses_plan_predicate_paths(self) -> None:
        """The cosign attest-blob loop must use predicate paths from the plan
        file, preserving supply-chain bundle paths."""
        step = _evidence_step_source()
        self.assertIn("cosign attest-blob --yes", step)
        self.assertIn(
            "--type https://openburnbar.dev/attestations/domain-core-release-artifact/v2",
            step,
        )
        self.assertIn('--predicate "$predicate"', step)
        self.assertIn('--bundle "${predicate}.sigstore.json"', step)
        self.assertIn('"$artifact"', step)


class WindowsReleaseEvidencePlanSimulationTests(unittest.TestCase):
    """Simulate the plan-validation and predicate-iteration logic against a
    synthetic canonical plan to prove fail-closed behavior at the shell level.
    """

    def _run_plan_validation(self, plan_json: str) -> subprocess.CompletedProcess:
        """Run a minimal reproduction of the workflow's plan validation +
        predicate-path extraction."""
        with tempfile.TemporaryDirectory() as tmp:
            plan = Path(tmp) / "domain-core-native-evidence-plan.json"
            plan.write_text(plan_json, encoding="utf-8")
            predicate_list = Path(tmp) / "predicate-paths.txt"
            script = textwrap.dedent(
                f"""\
                set -euo pipefail
                plan="{plan}"
                predicate_list="{predicate_list}"
                test -s "$plan"
                jq -e '.schemaVersion == 2 and .consumer == "windows" and (.domains | length > 0)' "$plan" >/dev/null
                domain_count="$(jq '.domains | length' "$plan")"
                echo "OK: $domain_count domain(s)"
                jq -r '.domains[].predicatePath' "$plan" > "$predicate_list"
                cat "$predicate_list"
                """
            )
            return subprocess.run(
                ["bash", "-c", script],
                capture_output=True,
                text=True,
            )

    def test_valid_plan_emits_quota_and_cloudvault_predicates(self) -> None:
        """A valid v2 Windows plan with quota + cloudVault domains must pass
        validation and produce both predicate paths."""
        plan = json.dumps({
            "schemaVersion": 2,
            "consumer": "windows",
            "version": "1.0.28",
            "tag": "windows-v1.0.28",
            "commit": "a" * 40,
            "profileName": "public-production",
            "domains": [
                {
                    "domain": "quota",
                    "publicProfileSha256": "a" * 64,
                    "predicatePath": "/tmp/evidence/OpenBurnBar-1.0.28-windows-quota-domain-core.predicate.json",
                    "predicateType": "https://openburnbar.dev/attestations/domain-core-release-artifact/v2",
                    "bundleAssetName": "OpenBurnBar-1.0.28-windows-quota-domain-core.sigstore.json",
                },
                {
                    "domain": "cloudVault",
                    "publicProfileSha256": "b" * 64,
                    "predicatePath": "/tmp/evidence/OpenBurnBar-1.0.28-windows-cloudVault-domain-core.predicate.json",
                    "predicateType": "https://openburnbar.dev/attestations/domain-core-release-artifact/v2",
                    "bundleAssetName": "OpenBurnBar-1.0.28-windows-cloudVault-domain-core.sigstore.json",
                },
            ],
        }, indent=2)
        result = self._run_plan_validation(plan)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("OK: 2 domain(s)", result.stdout)
        self.assertIn("quota-domain-core.predicate.json", result.stdout)
        self.assertIn("cloudVault-domain-core.predicate.json", result.stdout)

    def test_empty_domains_plan_fails_nonzero(self) -> None:
        """A plan with zero domains must fail the jq -e validation."""
        plan = json.dumps({
            "schemaVersion": 2,
            "consumer": "windows",
            "version": "1.0.28",
            "tag": "windows-v1.0.28",
            "commit": "a" * 40,
            "profileName": "public-production",
            "domains": [],
        }, indent=2)
        result = self._run_plan_validation(plan)
        self.assertNotEqual(result.returncode, 0)

    def test_wrong_consumer_plan_fails_nonzero(self) -> None:
        """A plan with the wrong consumer must fail validation."""
        plan = json.dumps({
            "schemaVersion": 2,
            "consumer": "apple",
            "version": "1.0.28",
            "tag": "windows-v1.0.28",
            "commit": "a" * 40,
            "profileName": "public-production",
            "domains": [
                {
                    "domain": "quota",
                    "publicProfileSha256": "a" * 64,
                    "predicatePath": "/tmp/evidence/quota.predicate.json",
                    "predicateType": "https://openburnbar.dev/attestations/domain-core-release-artifact/v2",
                    "bundleAssetName": "quota.sigstore.json",
                },
            ],
        }, indent=2)
        result = self._run_plan_validation(plan)
        self.assertNotEqual(result.returncode, 0)

    def test_wrong_schema_version_plan_fails_nonzero(self) -> None:
        """A plan with the wrong schemaVersion must fail validation."""
        plan = json.dumps({
            "schemaVersion": 1,
            "consumer": "windows",
            "version": "1.0.28",
            "tag": "windows-v1.0.28",
            "commit": "a" * 40,
            "profileName": "public-production",
            "domains": [
                {
                    "domain": "quota",
                    "publicProfileSha256": "a" * 64,
                    "predicatePath": "/tmp/evidence/quota.predicate.json",
                    "predicateType": "https://openburnbar.dev/attestations/domain-core-release-artifact/v2",
                    "bundleAssetName": "quota.sigstore.json",
                },
            ],
        }, indent=2)
        result = self._run_plan_validation(plan)
        self.assertNotEqual(result.returncode, 0)

    def test_malformed_json_plan_fails_nonzero(self) -> None:
        """A malformed JSON plan must fail the jq -e validation."""
        result = self._run_plan_validation("{ not valid json")
        self.assertNotEqual(result.returncode, 0)


if __name__ == "__main__":
    unittest.main()