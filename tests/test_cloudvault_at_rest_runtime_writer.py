import json
from datetime import UTC, datetime
from pathlib import Path

from scripts.ci.check_cloudvault_at_rest_runtime import validate_cloudvault_at_rest_evidence
from scripts.ci.write_cloudvault_at_rest_runtime_evidence import (
    build_cloudvault_at_rest_runtime_evidence,
    detect_signal_at_rest_enablement,
)


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
                    },
                    {"id": "usage_spend", "encryptionTier": "pseudonymous"},
                ]
            }
        ),
        encoding="utf-8",
    )
    return repo


def passing_runner(argv: list[str], repo_root: Path):
    return {
        "exitCode": 0,
        "durationMs": 1,
        "stdoutSha256": "0" * 64,
        "stderrSha256": "0" * 64,
    }


def failing_functions_runner(argv: list[str], repo_root: Path):
    if argv[:2] == ["node", "scripts/ci/check_functions_cloudvault_runtime.js"]:
        return {
            "exitCode": 9,
            "durationMs": 1,
            "stdoutSha256": "0" * 64,
            "stderrSha256": "f" * 64,
        }
    return passing_runner(argv, repo_root)


def generated_at_now() -> str:
    return datetime.now(UTC).isoformat().replace("+00:00", "Z")


def test_detects_signal_at_rest_enablement_from_registry(tmp_path):
    disabled_repo = make_repo(tmp_path / "disabled", signal_enabled=False)
    enabled_repo = make_repo(tmp_path / "enabled", signal_enabled=True)

    assert detect_signal_at_rest_enablement(disabled_repo)["enabledDomainCount"] == 0
    enabled = detect_signal_at_rest_enablement(enabled_repo)
    assert enabled["enabledDomainCount"] == 1
    assert enabled["enabledDomains"] == ["pensieve"]


def test_writer_generates_release_ready_shape_when_commands_pass_and_signal_is_enabled(tmp_path):
    repo = make_repo(tmp_path, signal_enabled=True)

    evidence = build_cloudvault_at_rest_runtime_evidence(
        repo_root=repo,
        command_runner=passing_runner,
        generated_at=generated_at_now(),
    )

    assert evidence["signalAtRestWritesEnabled"] is True
    assert validate_cloudvault_at_rest_evidence(evidence, repo_root=repo) == []
    assert evidence["signalAtRestEnablement"]["sourceSha256"]
    assert "stdoutSha256" in json.dumps(evidence)
    assert "stdoutText" not in json.dumps(evidence)
    assert "stderrText" not in json.dumps(evidence)


def test_writer_keeps_release_gate_closed_when_signal_is_not_enabled(tmp_path):
    repo = make_repo(tmp_path, signal_enabled=False)

    evidence = build_cloudvault_at_rest_runtime_evidence(
        repo_root=repo,
        command_runner=passing_runner,
        generated_at=generated_at_now(),
    )

    assert evidence["signalAtRestWritesEnabled"] is False
    errors = validate_cloudvault_at_rest_evidence(evidence, repo_root=repo)
    assert "signalAtRestWritesEnabled must be true for release-ready evidence" in errors


def test_writer_failed_command_does_not_count_assertions_as_proof(tmp_path):
    repo = make_repo(tmp_path, signal_enabled=True)

    evidence = build_cloudvault_at_rest_runtime_evidence(
        repo_root=repo,
        command_runner=failing_functions_runner,
        generated_at=generated_at_now(),
    )

    errors = validate_cloudvault_at_rest_evidence(evidence, repo_root=repo)
    assert "missing passing command evidence for scripts/ci/check_functions_cloudvault_runtime.js" in errors
    assert "missing proof assertion: admin_write_validator_rejects_plaintext" in errors
