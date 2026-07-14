import json
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
WORKFLOW = ROOT / ".github/workflows/domain-core.yml"
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
            '"scripts/ci/verify-domain-core-legacy-deletion.py"',
            '"tests/test_domain_core_legacy_deletion_gate.py"',
            '"tests/test_domain_core_legacy_deletion_workflow.py"',
            '"docs/runbooks/shared-rust-legacy-deletion.md"',
            "python3 tests/test_domain_core_legacy_deletion_gate.py",
            "python3 tests/test_domain_core_legacy_deletion_workflow.py",
            "python3 scripts/ci/verify-domain-core-legacy-deletion.py",
        )
        for value in required:
            self.assertIn(value, source, f"domain-core workflow is missing {value}")

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
        self.assertEqual(schema["properties"]["rows"]["minItems"], 11)
        self.assertEqual(schema["properties"]["rows"]["maxItems"], 11)
        self.assertEqual(set(schema["$defs"]["row"]["properties"]["id"]["enum"]), set(GATE_ROW_IDS))
        target_refs = schema["$defs"]["target"]["oneOf"]
        self.assertEqual(
            {item["$ref"].rsplit("/", 1)[-1] for item in target_refs},
            {"sourceSymbolTarget", "modeLiteralTarget", "pathTarget"},
        )
        receipt_schema = json.loads(
            (ROOT / "config/domain-core-legacy-deletion-receipt.schema.json").read_text(encoding="utf-8")
        )
        self.assertFalse(receipt_schema["additionalProperties"])
        self.assertEqual(receipt_schema["properties"]["status"]["const"], "active")
        self.assertTrue(receipt_schema["properties"]["evidence"]["uniqueItems"])
        self.assertEqual(set(receipt_schema["properties"]["rowId"]["enum"]), set(GATE_ROW_IDS))


if __name__ == "__main__":
    unittest.main()
