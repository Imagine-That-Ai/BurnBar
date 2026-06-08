from datetime import UTC, datetime
import json
from pathlib import Path

from scripts.ci.check_native_signal_runtime_evidence import validate_native_signal_runtime_evidence
from scripts.ci.write_native_signal_runtime_evidence import build_native_signal_runtime_evidence


def passing_runner(argv: list[str], cwd: Path):
    return {
        "exitCode": 0,
        "durationMs": 1,
        "stdoutSha256": "0" * 64,
        "stderrSha256": "0" * 64,
    }


def failing_runner(argv: list[str], cwd: Path):
    return {
        "exitCode": 9,
        "durationMs": 1,
        "stdoutSha256": "0" * 64,
        "stderrSha256": "f" * 64,
    }


def generated_at_now() -> str:
    return datetime.now(UTC).isoformat().replace("+00:00", "Z")


def test_swift_writer_generates_release_ready_shape_when_commands_pass(tmp_path):
    evidence = build_native_signal_runtime_evidence(
        gate="swift_round_trips",
        repo_root=tmp_path,
        command_runner=passing_runner,
        generated_at=generated_at_now(),
    )

    assert validate_native_signal_runtime_evidence(evidence, gate="swift_round_trips") == []
    payload = json.dumps(evidence)
    assert "stdoutSha256" in payload
    assert "stdoutText" not in payload
    assert "stderrText" not in payload


def test_kotlin_writer_generates_release_ready_shape_when_commands_pass(tmp_path):
    evidence = build_native_signal_runtime_evidence(
        gate="kotlin_round_trips",
        repo_root=tmp_path,
        command_runner=passing_runner,
        generated_at=generated_at_now(),
    )

    assert validate_native_signal_runtime_evidence(evidence, gate="kotlin_round_trips") == []


def test_rust_writer_failed_command_does_not_count_assertions_as_proof(tmp_path):
    evidence = build_native_signal_runtime_evidence(
        gate="rust_core_bridge",
        repo_root=tmp_path,
        command_runner=failing_runner,
        generated_at=generated_at_now(),
    )

    errors = validate_native_signal_runtime_evidence(evidence, gate="rust_core_bridge")
    assert "missing passing command evidence for rust runtime" in errors
    assert any("rust runtime evidence is missing assertions" in error for error in errors)


def test_rust_writer_targets_real_vendored_libsignal_bridge_crates(tmp_path):
    evidence = build_native_signal_runtime_evidence(
        gate="rust_core_bridge",
        repo_root=tmp_path,
        command_runner=passing_runner,
        generated_at=generated_at_now(),
    )

    entries = evidence["platforms"]["rust"]["commandEvidence"]
    command = entries[0]["command"]
    assert "Vendor/libsignal/Cargo.toml" in command
    assert "openburnbar-libsignal-ffi" not in command
    assert "libsignal-ffi" in command
    assert "libsignal-ffi-native_swift" in command
    assert "libsignal-jni-impl" in command
    assert "libsignal-jni-native_kt" in command
    assert "libsignal-node" in command
    assert "libsignal-node-native_ts" in command
    assert validate_native_signal_runtime_evidence(evidence, gate="rust_core_bridge") == []
