import json
from datetime import UTC, datetime
from pathlib import Path

from scripts.ci.check_signal_envelope_contract_runtime import (
    validate_signal_envelope_contract_runtime_evidence,
)
from scripts.ci.write_signal_envelope_contract_runtime_evidence import (
    build_signal_envelope_contract_runtime_evidence,
)


def passing_runner(argv: list[str], cwd: Path):
    return {
        "exitCode": 0,
        "durationMs": 1,
        "stdoutSha256": "0" * 64,
        "stderrSha256": "0" * 64,
    }


def failing_package_runner(argv: list[str], cwd: Path):
    if argv[:3] == ["npm", "test", "--prefix"]:
        return {
            "exitCode": 8,
            "durationMs": 1,
            "stdoutSha256": "f" * 64,
            "stderrSha256": "e" * 64,
        }
    return passing_runner(argv, cwd)


def generated_at_now() -> str:
    return datetime.now(UTC).isoformat().replace("+00:00", "Z")


def test_writer_generates_release_ready_shape_when_commands_pass(tmp_path):
    evidence = build_signal_envelope_contract_runtime_evidence(
        repo_root=tmp_path,
        command_runner=passing_runner,
        generated_at=generated_at_now(),
    )

    assert validate_signal_envelope_contract_runtime_evidence(evidence) == []
    payload = json.dumps(evidence)
    assert "stdoutSha256" in payload
    assert "stdoutText" not in payload
    assert "stderrText" not in payload


def test_writer_failed_command_does_not_count_assertions_as_proof(tmp_path):
    evidence = build_signal_envelope_contract_runtime_evidence(
        repo_root=tmp_path,
        command_runner=failing_package_runner,
        generated_at=generated_at_now(),
    )

    errors = validate_signal_envelope_contract_runtime_evidence(evidence)

    assert "missing passing command evidence for npm test --prefix packages/signal-envelope-contracts" in errors
    assert "missing proof assertion: deterministic_binding_aad_vectors" in errors
