import copy
from datetime import UTC, datetime, timedelta

from scripts.ci.check_signal_envelope_contract_runtime import (
    REQUIRED_ASSERTIONS,
    REQUIRED_COMMAND_FRAGMENTS,
    validate_signal_envelope_contract_runtime_evidence,
)


def _entry(command: str, assertions: list[str]):
    return {
        "command": command,
        "status": "pass",
        "exitCode": 0,
        "durationMs": 1,
        "stdoutSha256": "0" * 64,
        "stderrSha256": "0" * 64,
        "assertions": assertions,
    }


def valid_evidence():
    return {
        "schemaVersion": 1,
        "generatedAt": datetime.now(UTC).isoformat().replace("+00:00", "Z"),
        "generatedBy": "scripts/ci/write_signal_envelope_contract_runtime_evidence.py",
        "privacy": "proof_only_no_plaintext_keys_ciphertext_or_user_data",
        "commandEvidence": [
            _entry("npm ci --prefix packages/signal-envelope-contracts", []),
            _entry("npm test --prefix packages/signal-envelope-contracts", list(REQUIRED_ASSERTIONS[:6])),
            _entry("npm ci --prefix functions", []),
            _entry("npm run build --prefix functions", ["functions_typescript_builds_with_contracts"]),
            _entry(
                "npx vitest run src/__tests__/hermesGatewaySignalEnvelope.test.ts "
                "src/__tests__/dataExport.test.ts src/__tests__/hermesGatewaySealedEvent.test.ts --reporter=verbose",
                [
                    "functions_gateway_signal_envelope_tests",
                    "functions_export_sanitization_tests",
                    "functions_sealed_event_contract_tests",
                ],
            ),
            _entry("npm run test:hermes-gateway --prefix functions", ["functions_hermes_gateway_script_tests"]),
            _entry("npm ci --prefix services/hosted-mcp", []),
            _entry("npm test --prefix services/hosted-mcp", ["hosted_mcp_signal_contract_tests"]),
            _entry("npm ci --prefix services/hermes-realtime-relay", []),
            _entry(
                "npm test --prefix services/hermes-realtime-relay",
                ["hermes_realtime_relay_signal_contract_tests"],
            ),
        ],
    }


def test_validates_node_signal_envelope_contract_runtime_evidence():
    assert validate_signal_envelope_contract_runtime_evidence(valid_evidence()) == []


def test_rejects_missing_required_command_and_assertion():
    evidence = valid_evidence()
    evidence["commandEvidence"] = evidence["commandEvidence"][2:]

    errors = validate_signal_envelope_contract_runtime_evidence(evidence)

    assert f"missing passing command evidence for {REQUIRED_COMMAND_FRAGMENTS[1]}" in errors
    assert "missing proof assertion: signal_envelope_contracts_package_tests_pass" in errors


def test_failed_command_does_not_count_assertions_as_proof():
    evidence = valid_evidence()
    evidence["commandEvidence"][1]["status"] = "fail"
    evidence["commandEvidence"][1]["exitCode"] = 1

    errors = validate_signal_envelope_contract_runtime_evidence(evidence)

    assert f"missing passing command evidence for {REQUIRED_COMMAND_FRAGMENTS[1]}" in errors
    assert "missing proof assertion: deterministic_binding_aad_vectors" in errors


def test_rejects_raw_output_and_stale_evidence():
    evidence = copy.deepcopy(valid_evidence())
    evidence["generatedAt"] = (datetime.now(UTC) - timedelta(days=2)).isoformat().replace("+00:00", "Z")
    evidence["commandEvidence"][0]["stdoutText"] = "raw TAP output"

    errors = validate_signal_envelope_contract_runtime_evidence(evidence)

    assert "generatedAt must be within the last 24 hours" in errors
    assert any("stdoutText" in error for error in errors)
