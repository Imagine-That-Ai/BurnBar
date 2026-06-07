from datetime import UTC, datetime, timedelta

from scripts.ci.check_cloudvault_at_rest_runtime import validate_cloudvault_at_rest_evidence


REQUIRED_ASSERTIONS = [
    "compiled_functions_imports_signal_at_rest_write",
    "admin_write_validator_accepts_strict_cloudvault_envelope",
    "admin_write_validator_derives_canonical_aad",
    "admin_write_validator_rejects_wrong_binding",
    "admin_write_validator_rejects_plaintext",
    "contract_sanitizer_rejects_gateway_transport_as_cloudvault",
    "sanitized_envelope_drops_plaintext_siblings",
    "cjs_runtime_import_validates_signal_at_rest_write",
]


def generated_at_now():
    return datetime.now(UTC).isoformat().replace("+00:00", "Z")


def valid_evidence():
    return {
        "schemaVersion": 1,
        "generatedAt": generated_at_now(),
        "generatedBy": "tests",
        "privacy": "proof_only_no_plaintext_keys_ciphertext_or_document_identifiers",
        "signalAtRestWritesEnabled": True,
        "commandEvidence": [
            {
                "command": "npm run build --prefix functions && node scripts/ci/check_functions_cloudvault_runtime.js",
                "status": "pass",
                "exitCode": 0,
                "assertions": REQUIRED_ASSERTIONS[:-1],
            },
            {
                "command": "python3 -m pytest tests/test_signal_envelope_contracts_cjs_exports.py -q",
                "status": "pass",
                "exitCode": 0,
                "assertions": [REQUIRED_ASSERTIONS[-1]],
            },
        ],
    }


def test_validates_cloudvault_at_rest_runtime_evidence():
    assert validate_cloudvault_at_rest_evidence(valid_evidence()) == []


def test_rejects_command_evidence_that_only_names_a_command():
    evidence = valid_evidence()
    evidence["commandEvidence"][0].pop("status")

    errors = validate_cloudvault_at_rest_evidence(evidence)

    assert "missing passing command evidence for scripts/ci/check_functions_cloudvault_runtime.js" in errors


def test_rejects_missing_required_assertion():
    evidence = valid_evidence()
    evidence["commandEvidence"][0]["assertions"].remove("admin_write_validator_rejects_plaintext")

    errors = validate_cloudvault_at_rest_evidence(evidence)

    assert "missing proof assertion: admin_write_validator_rejects_plaintext" in errors


def test_rejects_plaintext_ciphertext_or_identifier_leakage():
    evidence = valid_evidence()
    evidence["commandEvidence"][0]["docId"] = "thread-1"
    evidence["commandEvidence"][0]["ciphertext"] = "base64"

    errors = validate_cloudvault_at_rest_evidence(evidence)

    assert any("must not contain plaintext, ciphertext, keys, or document identifiers" in error for error in errors)


def test_rejects_stale_cloudvault_runtime_evidence():
    evidence = valid_evidence()
    evidence["generatedAt"] = (datetime.now(UTC) - timedelta(days=2)).isoformat().replace("+00:00", "Z")

    errors = validate_cloudvault_at_rest_evidence(evidence)

    assert "generatedAt must be within the last 24 hours" in errors
