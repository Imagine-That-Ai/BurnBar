from datetime import UTC, datetime, timedelta
import hashlib
import json
from pathlib import Path

from scripts.ci.check_cloudvault_at_rest_runtime import validate_cloudvault_at_rest_evidence


REQUIRED_ASSERTIONS = [
    "compiled_functions_imports_signal_at_rest_write",
    "admin_write_validator_accepts_strict_cloudvault_envelope",
    "admin_write_validator_derives_canonical_aad",
    "admin_write_validator_rejects_wrong_binding",
    "admin_write_validator_rejects_plaintext",
    "contract_sanitizer_rejects_gateway_transport_as_cloudvault",
    "sanitized_envelope_drops_plaintext_siblings",
    "signal_at_rest_policy_mirrors_registry",
    "signal_at_rest_policy_requires_enabled_collection",
    "cjs_runtime_import_validates_signal_at_rest_write",
]
EMPTY_SHA256 = hashlib.sha256(b"").hexdigest()


def generated_at_now():
    return datetime.now(UTC).isoformat().replace("+00:00", "Z")


def make_repo(tmp_path: Path, *, signal_enabled: bool) -> Path:
    repo = tmp_path / "repo"
    registry = repo / "packages/data-domains/registry.json"
    registry.parent.mkdir(parents=True)
    registry.write_text(
        json.dumps(
            {
                "domains": [
                    {
                        "id": "pensieve",
                        "encryptionTier": "end_to_end",
                        "sealingScheme": (
                            "signal-hpke-identity-seal-v1" if signal_enabled else "cloudvault-aesgcm-v2"
                        ),
                        "signalSealedCollections": ["cloud_search_knowledge"] if signal_enabled else [],
                    }
                ]
            }
        ),
        encoding="utf-8",
    )
    return repo


def sha256_file(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def enablement(*, enabled: bool, source_sha: str = "0" * 64):
    return {
        "scheme": "signal-hpke-identity-seal-v1",
        "enabledDomainCount": 1 if enabled else 0,
        "enabledDomains": ["pensieve"] if enabled else [],
        "requiredCollectionCount": 1 if enabled else 0,
        "requiredCollections": ["cloud_search_knowledge"] if enabled else [],
        "source": "packages/data-domains/registry.json sealingScheme + signalSealedCollections",
        "sourceSha256": source_sha,
    }


def valid_evidence(source_sha: str = "0" * 64):
    return {
        "schemaVersion": 1,
        "generatedAt": generated_at_now(),
        "generatedBy": "tests",
        "privacy": "proof_only_no_plaintext_keys_ciphertext_or_document_identifiers",
        "signalAtRestWritesEnabled": True,
        "signalAtRestEnablement": enablement(enabled=True, source_sha=source_sha),
        "commandEvidence": [
            {
                "command": "npm run build --prefix functions",
                "status": "pass",
                "exitCode": 0,
                "durationMs": 1,
                "stdoutSha256": EMPTY_SHA256,
                "stderrSha256": EMPTY_SHA256,
            },
            {
                "command": "node scripts/ci/check_functions_cloudvault_runtime.js",
                "status": "pass",
                "exitCode": 0,
                "durationMs": 1,
                "stdoutSha256": EMPTY_SHA256,
                "stderrSha256": EMPTY_SHA256,
                "assertions": REQUIRED_ASSERTIONS[:-1],
            },
            {
                "command": "python3 -m pytest tests/test_signal_envelope_contracts_cjs_exports.py -q",
                "status": "pass",
                "exitCode": 0,
                "durationMs": 1,
                "stdoutSha256": EMPTY_SHA256,
                "stderrSha256": EMPTY_SHA256,
                "assertions": [REQUIRED_ASSERTIONS[-1]],
            },
        ],
    }


def empty_output_runner(argv: list[str], repo_root: Path):
    return 0, "", ""


def test_validates_cloudvault_at_rest_runtime_evidence():
    assert validate_cloudvault_at_rest_evidence(valid_evidence()) == []


def test_rejects_command_evidence_that_only_names_a_command():
    evidence = valid_evidence()
    evidence["commandEvidence"][1].pop("status")

    errors = validate_cloudvault_at_rest_evidence(evidence)

    assert "missing passing command evidence for scripts/ci/check_functions_cloudvault_runtime.js" in errors


def test_rejects_command_evidence_without_hashes():
    evidence = valid_evidence()
    evidence["commandEvidence"][0].pop("stdoutSha256")

    errors = validate_cloudvault_at_rest_evidence(evidence)

    assert "command evidence stdoutSha256 must be a lowercase SHA-256 hex digest" in errors


def test_rejects_missing_required_assertion():
    evidence = valid_evidence()
    evidence["commandEvidence"][1]["assertions"].remove("admin_write_validator_rejects_plaintext")

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


def test_rejects_forged_signal_enablement_against_current_registry(tmp_path):
    repo = make_repo(tmp_path, signal_enabled=False)
    evidence = valid_evidence()

    errors = validate_cloudvault_at_rest_evidence(evidence, repo_root=repo)

    assert "signalAtRestEnablement must match packages/data-domains/registry.json" in errors


def test_replay_commands_accepts_exact_reproduced_command_hashes(tmp_path):
    repo = make_repo(tmp_path, signal_enabled=True)
    evidence = valid_evidence(source_sha=sha256_file(repo / "packages/data-domains/registry.json"))

    errors = validate_cloudvault_at_rest_evidence(
        evidence,
        repo_root=repo,
        replay_commands=True,
        command_runner=empty_output_runner,
    )

    assert errors == []


def test_replay_commands_rejects_forged_command_output_hash(tmp_path):
    repo = make_repo(tmp_path, signal_enabled=True)
    evidence = valid_evidence(source_sha=sha256_file(repo / "packages/data-domains/registry.json"))

    def forged_runner(argv: list[str], repo_root: Path):
        if argv[:2] == ["node", "scripts/ci/check_functions_cloudvault_runtime.js"]:
            return 0, "different runtime output\n", ""
        return 0, "", ""

    errors = validate_cloudvault_at_rest_evidence(
        evidence,
        repo_root=repo,
        replay_commands=True,
        command_runner=forged_runner,
    )

    assert any("replayed command stdoutSha256 mismatch for node scripts/ci/check_functions_cloudvault_runtime.js" in error for error in errors)


def test_replay_commands_rejects_unapproved_shell_command(tmp_path):
    repo = make_repo(tmp_path, signal_enabled=True)
    evidence = valid_evidence(source_sha=sha256_file(repo / "packages/data-domains/registry.json"))
    evidence["commandEvidence"][1]["command"] = "node scripts/ci/check_functions_cloudvault_runtime.js && echo forged"

    errors = validate_cloudvault_at_rest_evidence(
        evidence,
        repo_root=repo,
        replay_commands=True,
        command_runner=empty_output_runner,
    )

    assert any("command evidence command is not approved for replay" in error for error in errors)


def test_rejects_signal_enablement_boolean_that_disagrees_with_domains():
    evidence = valid_evidence()
    evidence["signalAtRestWritesEnabled"] = True
    evidence["signalAtRestEnablement"] = enablement(enabled=False)

    errors = validate_cloudvault_at_rest_evidence(evidence)

    assert "signalAtRestWritesEnabled must match signalAtRestEnablement.enabledDomainCount > 0" in errors
