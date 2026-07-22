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
  * An all-legacy ``public-production`` profile may emit an empty plan before
    activation, while any Rust-active Windows domain requires the exact
    corresponding native-evidence entry.
  * Rollback remains fail-closed: its canonical plan must stay empty.
  * A malformed plan fails nonzero, and predicate iteration uses a real file.
  * The supply-chain job structurally needs the native-release gate and carries the gate-output env keys (dependency-free; actionlint owns YAML syntax).
"""

import json
import os
import re
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


def _plan_validation_source() -> str:
    """Return the executable plan-validation and predicate-list fragment."""
    step = _evidence_step_source()
    start = step.index(
        'plan="$evidence_dir/domain-core-native-evidence-plan.json"'
    )
    end = step.index("while IFS= read -r predicate; do", start)
    return textwrap.dedent(step[start:end])


def _job_block(source: str, job_name: str) -> str:
    """Return the YAML text of a top-level ``jobs:`` entry by indentation scope.

    Dependency-free (no PyYAML): GitHub Actions workflow YAML uses two-space
    indentation, so a job key at column 2 (``  <name>:``) extends until the next
    column-2 key line or end-of-file.  This mirrors the scoping pattern already
    used by ``_evidence_step_source``.
    """
    marker = f"\n  {job_name}:\n"
    start = source.find(marker)
    if start == -1:
        raise AssertionError(f"could not find job '{job_name}' in workflow")
    body_start = start + len(marker)
    # The block ends at the next top-level job key: a line starting with exactly
    # two spaces then a word char and ending with ':' (e.g. ``  build-sign:``).
    # Four-space lines (``    needs:``, ``    env:``) are job-body keys, not siblings.
    sibling = re.compile(r"^  [A-Za-z][\w-]*:$", re.MULTILINE)
    match = sibling.search(source, body_start)
    return source[body_start : match.start() if match else len(source)]


class WindowsReleaseEvidencePlanTests(unittest.TestCase):
    def test_supply_chain_job_has_gate_need_and_generator_env(self) -> None:
        # Validate the supply-chain job's structural contract without PyYAML
        # (the product-posture CI job runs `python -m pytest` with only pytest +
        # cryptography — no PyYAML).  The repo's convention for workflow tests is
        # scoped text assertions; actionlint (workflow-lint.yml) separately
        # enforces YAML *syntax*.  Here we scope to the supply-chain job block
        # and assert it needs the native-release gate and carries the gate-output
        # env keys the evidence generator consumes.
        source = WORKFLOW.read_text(encoding="utf-8")
        self.assertIn("\n  supply-chain:\n", source)
        supply_chain = _job_block(source, "supply-chain")
        self.assertIn("    needs:", supply_chain)
        self.assertIn("      - domain-core-native-release-gate", supply_chain)
        self.assertIn("    env:", supply_chain)
        self.assertIn("      PROFILE:", supply_chain)
        self.assertIn("      SIGNER_RUN_ID:", supply_chain)
        self.assertIn("      SIGNER_RUN_ATTEMPT:", supply_chain)
        self.assertIn("      RELEASE_TAG:", supply_chain)

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

    @staticmethod
    def _profile(profile_name: str, **modes: str) -> str:
        return json.dumps({"name": profile_name, "modes": modes})

    @staticmethod
    def _plan(profile_name: str, domains: list[str]) -> str:
        return json.dumps({
            "schemaVersion": 2,
            "consumer": "windows",
            "version": "1.0.28",
            "tag": "windows-v1.0.28",
            "commit": "a" * 40,
            "profileName": profile_name,
            "domains": [
                {
                    "domain": domain,
                    "publicProfileSha256": "a" * 64,
                    "predicatePath": f"/tmp/evidence/{domain}.predicate.json",
                    "predicateType": "https://openburnbar.dev/attestations/domain-core-release-artifact/v2",
                    "bundleAssetName": f"{domain}.sigstore.json",
                }
                for domain in domains
            ],
        })

    def _run_plan_validation(
        self,
        plan_json: str,
        *,
        profile_json: str | None = None,
        profile_name: str = "public-production",
    ) -> subprocess.CompletedProcess:
        """Execute the workflow's real validation + predicate extraction."""
        with tempfile.TemporaryDirectory() as tmp:
            evidence_dir = Path(tmp) / "evidence"
            evidence_dir.mkdir()
            plan = evidence_dir / "domain-core-native-evidence-plan.json"
            plan.write_text(plan_json, encoding="utf-8")
            gate_dir = Path(tmp) / "gate"
            gate_dir.mkdir()
            selected_profile = gate_dir / "domain-core-selected-public-profile.json"
            selected_profile.write_text(
                profile_json
                or self._profile(
                    profile_name,
                    quota="rust",
                    cloudVault="rust",
                ),
                encoding="utf-8",
            )
            script = "set -euo pipefail\n" + _plan_validation_source()
            script += '\ncat "$predicate_list"\n'
            env = os.environ.copy()
            env.update({
                "PROFILE": profile_name,
                "RUNNER_TEMP": tmp,
                "evidence_dir": str(evidence_dir),
                "gate_dir": str(gate_dir),
            })
            return subprocess.run(
                ["bash", "-c", script],
                capture_output=True,
                text=True,
                env=env,
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
        self.assertIn("2 domain(s)", result.stdout)
        self.assertIn("quota-domain-core.predicate.json", result.stdout)
        self.assertIn("cloudVault-domain-core.predicate.json", result.stdout)

    def test_all_legacy_public_production_allows_empty_plan(self) -> None:
        profile = self._profile(
            "public-production",
            quota="legacy",
            cloudVault="legacy",
            hermes="legacy",
        )
        result = self._run_plan_validation(
            self._plan("public-production", []),
            profile_json=profile,
        )
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_rust_active_public_production_requires_exact_windows_domains(self) -> None:
        for active_domain in ("quota", "cloudVault"):
            with self.subTest(active_domain=active_domain):
                modes = {
                    "quota": "legacy",
                    "cloudVault": "legacy",
                    "hermes": "rust",
                }
                modes[active_domain] = "rust"
                profile = self._profile("public-production", **modes)

                exact = self._run_plan_validation(
                    self._plan("public-production", [active_domain]),
                    profile_json=profile,
                )
                self.assertEqual(exact.returncode, 0, exact.stderr)

                missing = self._run_plan_validation(
                    self._plan("public-production", []),
                    profile_json=profile,
                )
                self.assertNotEqual(missing.returncode, 0)

                extra = self._run_plan_validation(
                    self._plan("public-production", ["quota", "cloudVault"]),
                    profile_json=profile,
                )
                self.assertNotEqual(extra.returncode, 0)

    def test_same_cardinality_wrong_windows_domain_fails(self) -> None:
        profile = self._profile(
            "public-production",
            quota="rust",
            cloudVault="legacy",
        )
        wrong_domain = self._run_plan_validation(
            self._plan("public-production", ["cloudVault"]),
            profile_json=profile,
        )
        self.assertNotEqual(wrong_domain.returncode, 0)

    def test_rollback_plan_remains_fail_closed(self) -> None:
        profile = self._profile(
            "public-production-rollback",
            quota="legacy",
            cloudVault="legacy",
        )
        empty = self._run_plan_validation(
            self._plan("public-production-rollback", []),
            profile_json=profile,
            profile_name="public-production-rollback",
        )
        self.assertEqual(empty.returncode, 0, empty.stderr)

        nonempty = self._run_plan_validation(
            self._plan("public-production-rollback", ["quota"]),
            profile_json=profile,
            profile_name="public-production-rollback",
        )
        self.assertNotEqual(nonempty.returncode, 0)

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
