import json
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
WORKFLOW = ROOT / ".github/workflows/domain-core.yml"
OBSERVATION_WORKFLOW = ROOT / ".github/workflows/domain-core-promotion-observation.yml"
GATE_ROW_IDS = (
    "quota.claude_statusline",
    "quota.codex_usage",
    "quota.cursor_usage",
    "quota.anthropic_headers",
    "cloudvault.portable_primitives",
    "cloudvault.document_rewrap",
    "cloudvault.search",
    "hermes.relay_crypto",
    "hermes.ratchet_transforms",
    "pricing.token_cost",
    "pricing.kimi_historical",
)


class DomainCoreLegacyDeletionWorkflowTests(unittest.TestCase):
    def test_domain_core_workflow_wires_legacy_deletion_gate(self) -> None:
        source = WORKFLOW.read_text(encoding="utf-8")
        required = (
            '"config/domain-core-legacy-deletion.json"',
            '"config/domain-core-legacy-deletion.schema.json"',
            '"config/domain-core-legacy-deletion-receipt.schema.json"',
            '"config/domain-core-legacy-deletion-receipts/**"',
            '"config/domain-core-deletion-plan.schema.json"',
            '"config/domain-core-deletion-plans/**"',
            '"config/domain-core-deletion-reviewers.json"',
            '"config/domain-core-deletion-reviewers.schema.json"',
            '"config/domain-core-promotion-attestation.schema.json"',
            '"config/domain-core-promotion-report.schema.json"',
            '"config/domain-core-promotion-attestations/**"',
            '"config/domain-core-promotion-reports/**"',
            '"config/domain-core-promotion-provenance/**"',
            '"config/domain-core-release-provenance/**"',
            '".github/workflows/domain-core-promotion-observation.yml"',
            '"scripts/ops/create-domain-core-promotion-receipt.py"',
            '"scripts/ops/create-domain-core-deletion-plan.py"',
            '"scripts/ci/verify-domain-core-legacy-deletion.py"',
            '"tests/test_domain_core_legacy_deletion_gate.py"',
            '"tests/test_domain_core_legacy_deletion_workflow.py"',
            '"docs/runbooks/shared-rust-legacy-deletion.md"',
            "python3 tests/test_domain_core_legacy_deletion_gate.py",
            "python3 tests/test_domain_core_legacy_deletion_workflow.py",
            "python3 scripts/ci/verify-domain-core-legacy-deletion.py",
            'fetch-depth: 0',
            "github.event.pull_request.base.sha || github.event.before",
            '--base-ref "$DOMAIN_CORE_BASE_REF"',
            "--verify-signed-evidence",
            "GH_TOKEN: ${{ github.token }}",
            "A trustworthy base SHA is required for append-only governance.",
            '"$DOMAIN_CORE_EVENT_NAME" == "workflow_dispatch"',
            '"$GITHUB_REF" != "refs/heads/main"',
            'DOMAIN_CORE_BASE_REF="$(git rev-parse HEAD^1)"',
        )
        for value in required:
            self.assertIn(value, source, f"domain-core workflow is missing {value}")
        self.assertNotIn("inputs.base_ref", source)

    def test_gate_runs_before_expensive_domain_builds(self) -> None:
        source = WORKFLOW.read_text(encoding="utf-8")
        self.assertLess(source.index("legacy-deletion-gate:"), source.index("rust-and-csharp:"))
        for job in (
            "rust-and-csharp",
            "windows-native",
            "linux-arm64-native",
            "wasm",
            "functions-pricing",
            "android",
            "apple",
            "apple-native-smoke",
            "swift-consumer-contracts",
        ):
            self.assertIn(f"  {job}:\n    needs: legacy-deletion-gate\n", source)

    def test_schema_is_strict_and_covers_every_target_kind(self) -> None:
        schema = json.loads((ROOT / "config/domain-core-legacy-deletion.schema.json").read_text(encoding="utf-8"))
        self.assertFalse(schema["additionalProperties"])
        self.assertEqual(schema["$id"], "https://openburnbar.com/schemas/domain-core-legacy-deletion-v2.json")
        self.assertEqual(schema["properties"]["schemaVersion"]["const"], 2)
        self.assertEqual(
            set(schema["$defs"]["state"]["enum"]),
            {"rollout", "promotion_approved", "rust_authoritative_with_rollback", "rollback_active", "deletion_approved", "legacy_deleted"},
        )
        self.assertEqual(schema["properties"]["rows"]["minItems"], 11)
        self.assertEqual(schema["properties"]["rows"]["maxItems"], 11)
        self.assertEqual(set(schema["$defs"]["row"]["properties"]["id"]["enum"]), set(GATE_ROW_IDS))
        target_refs = schema["$defs"]["target"]["oneOf"]
        self.assertEqual(set(schema["$defs"]["targetRole"]["enum"]), {"legacy_implementation", "rollback_control"})
        self.assertEqual(
            {item["$ref"].rsplit("/", 1)[-1] for item in target_refs},
            {"sourceSymbolTarget", "modeLiteralTarget", "pathTarget"},
        )
        receipt_schema = json.loads(
            (ROOT / "config/domain-core-legacy-deletion-receipt.schema.json").read_text(encoding="utf-8")
        )
        self.assertFalse(receipt_schema["additionalProperties"])
        self.assertEqual(receipt_schema["properties"]["schemaVersion"]["const"], 2)
        self.assertEqual(receipt_schema["properties"]["status"]["const"], "active")
        self.assertEqual(receipt_schema["properties"]["authorityGeneration"]["minimum"], 1)
        self.assertTrue(receipt_schema["properties"]["evidence"]["uniqueItems"])
        self.assertEqual(set(receipt_schema["$defs"]["rowId"]["enum"]), set(GATE_ROW_IDS))
        self.assertEqual(
            set(receipt_schema["properties"]["transition"]["enum"]),
            {"promotion", "stable_release", "rollback", "deletion_review"},
        )
        deletion_plan_schema = json.loads(
            (ROOT / "config/domain-core-deletion-plan.schema.json").read_text(encoding="utf-8")
        )
        self.assertFalse(deletion_plan_schema["additionalProperties"])
        self.assertEqual(deletion_plan_schema["properties"]["schemaVersion"]["const"], 1)
        self.assertEqual(
            deletion_plan_schema["properties"]["requestedAction"]["const"],
            "approve_legacy_deletion",
        )
        self.assertEqual(set(deletion_plan_schema["properties"]["rowId"]["enum"]), set(GATE_ROW_IDS))
        reviewer_schema = json.loads(
            (ROOT / "config/domain-core-deletion-reviewers.schema.json").read_text(encoding="utf-8")
        )
        self.assertFalse(reviewer_schema["additionalProperties"])
        reviewer_catalog = json.loads(
            (ROOT / "config/domain-core-deletion-reviewers.json").read_text(encoding="utf-8")
        )
        self.assertEqual(reviewer_catalog, {"schemaVersion": 1, "reviewers": []})
        attestation_schema = json.loads(
            (ROOT / "config/domain-core-promotion-attestation.schema.json").read_text(encoding="utf-8")
        )
        self.assertFalse(attestation_schema["additionalProperties"])
        self.assertEqual(attestation_schema["properties"]["schemaVersion"]["const"], 1)
        self.assertIn("authorityScope", attestation_schema["required"])
        ledger = json.loads((ROOT / "config/domain-core-legacy-deletion.json").read_text(encoding="utf-8"))
        self.assertEqual(ledger["schemaVersion"], schema["properties"]["schemaVersion"]["const"])

        report_schema = json.loads(
            (ROOT / "config/domain-core-promotion-report.schema.json").read_text(encoding="utf-8")
        )
        self.assertFalse(report_schema["additionalProperties"])
        self.assertEqual(report_schema["properties"]["schemaVersion"]["const"], 2)
        self.assertEqual(report_schema["properties"]["status"]["const"], "ready")
        self.assertEqual(report_schema["properties"]["ready"]["const"], True)

    def test_protected_observation_workflow_exports_and_attests_exact_candidate(self) -> None:
        source = OBSERVATION_WORKFLOW.read_text(encoding="utf-8")
        required = (
            "workflow_dispatch:",
            "environment: domain-core-promotion",
            "id-token: write",
            'persist-credentials: false',
            '"$GITHUB_REF" != "refs/heads/main"',
            'git merge-base --is-ancestor "$CANDIDATE_COMMIT" HEAD',
            "BUILDER_COMMIT: ${{ github.sha }}",
            'candidate_version="$(git show',
            "--query-revision \"$CANDIDATE_COMMIT\"",
            "export-domain-core-promotion-evidence.mjs",
            "evaluate-domain-core-promotion.mjs",
            "actions/attest-build-provenance@43d14bc2b83dec42d39ecae14e916627a18bb661",
            "domain-core-promotion-report.sigstore.json",
            "actions/upload-artifact@ea165f8d65b6e75b540449e92b4886f43607fa02",
            "Enforce a ready result",
        )
        for value in required:
            self.assertIn(value, source, f"promotion observation workflow is missing {value}")


if __name__ == "__main__":
    unittest.main()
