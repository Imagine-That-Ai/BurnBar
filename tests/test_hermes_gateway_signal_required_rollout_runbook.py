from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
RUNBOOK = ROOT / "docs/legal/HERMES_GATEWAY_SIGNAL_REQUIRED_ROLLOUT.md"


def test_signal_required_rollout_runbook_names_guarded_production_sequence() -> None:
    text = RUNBOOK.read_text(encoding="utf-8")

    required = [
        "explicit release-owner approval",
        "OPENBURNBAR_GATEWAY_SIGNAL_REQUIRED=true",
        "rollout_hermes_gateway_signal_required.js",
        "--confirm enable-hermes-gateway-signal-required",
        "--confirm rollback-hermes-gateway-signal-required",
        "gcloud run services update burnbarhermesgateway",
        "gcloud run services update enqueuehermesgatewayevent",
        "Cloud Functions gen2 source redeploy",
        "gcloud functions deploy burnBarHermesGateway",
        "latest ready revisions",
        "write_hermes_gateway_migration_drain_evidence.js",
        "--runtime-mode-from-gcloud",
        "drain_hermes_gateway_legacy_records.js",
        "--confirm delete-legacy-hermes-gateway-records",
        "check_hermes_gateway_migration_drain.py",
        "aggregate_counts_only_no_document_values_or_identifiers",
        "--remove-env-vars OPENBURNBAR_GATEWAY_SIGNAL_REQUIRED",
    ]

    missing = [needle for needle in required if needle not in text]

    assert missing == []


def test_signal_required_rollout_runbook_is_not_a_completion_claim() -> None:
    text = RUNBOOK.read_text(encoding="utf-8").lower()
    normalized = " ".join(text.split())

    assert "only after that validation passes" in text
    assert "may mark" in text
    assert "cannot restore deleted legacy queue records" in normalized
