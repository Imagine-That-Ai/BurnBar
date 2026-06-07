from pathlib import Path

from scripts.ci.check_cloudvault_at_rest_runtime import validate_cloudvault_at_rest_evidence


def valid_evidence() -> dict[str, object]:
    def proof(command: str, artifact_paths: list[str]) -> dict[str, object]:
        return {
            "status": "passed",
            "command": command,
            "artifactPaths": artifact_paths,
            "notes": "Proof-only release evidence; no plaintext, keys, ciphertext, or document identifiers.",
        }

    return {
        "schemaVersion": 1,
        "generatedAt": "2026-06-06T00:00:00Z",
        "privacy": "proof_only_no_plaintext_keys_ciphertext_or_document_identifiers",
        "runtime": "cloudvault_at_rest",
        "proofs": {
            "signal_envelope_contracts": proof(
                "node --test packages/signal-envelope-contracts/lib/index.test.js packages/signal-envelope-contracts/lib/cloudVaultSignalEnvelope.test.js",
                [
                    "packages/signal-envelope-contracts/lib/index.test.js",
                    "packages/signal-envelope-contracts/lib/cloudVaultSignalEnvelope.test.js",
                    "packages/signal-envelope-contracts/fixtures/binding-aad-vectors.json",
                ],
            ),
            "libsignal_at_rest_roundtrip": proof(
                "node --test packages/libsignal-protocol/lib/index.test.js",
                ["packages/libsignal-protocol/lib/index.test.js"],
            ),
            "functions_admin_write_guard": proof(
                "node scripts/ci/check_functions_cloudvault_runtime.js --signal-at-rest-write && "
                "python3 -m pytest -o addopts='' tests/test_signal_envelope_contracts_cjs_exports.py",
                [
                    "scripts/ci/check_functions_cloudvault_runtime.js",
                    "functions/lib/signalAtRestWrite.js",
                    "functions/lib/__tests__/signalAtRestWrite.test.js",
                    "tests/test_signal_envelope_contracts_cjs_exports.py",
                ],
            ),
            "privacy_backfill_guard": proof(
                "node scripts/ci/check_functions_cloudvault_runtime.js --privacy-backfill",
                [
                    "scripts/ci/check_functions_cloudvault_runtime.js",
                    "functions/lib/callables/privacyBackfill.js",
                    "functions/lib/__tests__/privacyBackfill.test.js",
                ],
            ),
        },
    }


def test_validates_cloudvault_at_rest_runtime_evidence() -> None:
    assert validate_cloudvault_at_rest_evidence(valid_evidence()) == []


def test_rejects_missing_required_proof() -> None:
    data = valid_evidence()
    del data["proofs"]["privacy_backfill_guard"]  # type: ignore[index]

    assert validate_cloudvault_at_rest_evidence(data) == [
        "proofs missing required proof(s): privacy_backfill_guard"
    ]


def test_rejects_failed_proof() -> None:
    data = valid_evidence()
    data["proofs"]["libsignal_at_rest_roundtrip"]["status"] = "failed"  # type: ignore[index]

    assert "proofs.libsignal_at_rest_roundtrip.status must be 'passed'" in validate_cloudvault_at_rest_evidence(data)


def test_rejects_irrelevant_proof_command() -> None:
    data = valid_evidence()
    data["proofs"]["functions_admin_write_guard"]["command"] = "echo ok"  # type: ignore[index]

    assert (
        "proofs.functions_admin_write_guard.command missing required command fragment(s): "
        "node scripts/ci/check_functions_cloudvault_runtime.js, --signal-at-rest-write, "
        "python3 -m pytest, tests/test_signal_envelope_contracts_cjs_exports.py"
    ) in validate_cloudvault_at_rest_evidence(data)


def test_rejects_embedded_plaintext_or_identifier_fields() -> None:
    data = valid_evidence()
    data["proofs"]["signal_envelope_contracts"]["plaintext"] = "secret"  # type: ignore[index]
    data["proofs"]["signal_envelope_contracts"]["docId"] = "doc-1"  # type: ignore[index]

    errors = validate_cloudvault_at_rest_evidence(data)

    assert "proofs.signal_envelope_contracts.plaintext must not be embedded in proof evidence" in errors
    assert "proofs.signal_envelope_contracts.docId must not be embedded in proof evidence" in errors
    assert "proofs.signal_envelope_contracts has unexpected key: docId" in errors
    assert "proofs.signal_envelope_contracts has unexpected key: plaintext" in errors


def test_validates_artifact_paths_exist_when_repo_root_is_supplied(tmp_path: Path) -> None:
    data = valid_evidence()
    missing = validate_cloudvault_at_rest_evidence(data, repo_root=tmp_path)

    assert any("path does not exist: packages/libsignal-protocol/lib/index.test.js" in error for error in missing)
