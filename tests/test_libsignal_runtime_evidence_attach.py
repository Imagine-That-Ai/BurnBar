import hashlib
import json
import subprocess
from pathlib import Path

from scripts.ci.attach_libsignal_runtime_evidence import (
    AttachError,
    ValidatorRun,
    attach_runtime_evidence,
)
from scripts.ci.check_libsignal_runtime_readiness import EXPECTED_PIN, REQUIRED_GATE_IDS, check_manifest


def _write_manifest(repo_root: Path) -> Path:
    manifest = {
        "status": "not_ready",
        "runtimeCryptoCore": "official_libsignal_pending_release_evidence",
        "officialLibsignalPin": dict(EXPECTED_PIN),
        "blockingReason": "release evidence pending",
        "completedEvidence": [
            {
                "id": "swift_round_trips",
                "status": "complete",
                "proof": "legacy self-report that must be replaced",
                "command": "swift test",
            }
        ],
        "requiredGates": [
            {"id": gate_id, "status": "pending", "proof": f"{gate_id} proof"}
            for gate_id in REQUIRED_GATE_IDS
        ],
        "generatedAt": "2026-06-06T16:47:17.942Z",
    }
    path = repo_root / "third_party/libsignal/runtime-readiness.json"
    path.parent.mkdir(parents=True)
    path.write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")
    return path


def _write_artifact(repo_root: Path, rel_path: str = "launch-evidence/native-swift.json") -> Path:
    artifact = repo_root / rel_path
    artifact.parent.mkdir(parents=True, exist_ok=True)
    artifact.write_text('{"schemaVersion":1,"privacy":"proof_only"}\n', encoding="utf-8")
    return artifact


def _passing_runner(command: list[str], repo_root: Path) -> ValidatorRun:
    return ValidatorRun(command=command, exit_code=0, duration_ms=7, stdout="validator ok\n", stderr="")


def test_attach_replaces_legacy_self_reported_gate_with_typed_evidence(tmp_path):
    manifest = _write_manifest(tmp_path)
    artifact = _write_artifact(tmp_path)

    updated = attach_runtime_evidence(
        gate_id="swift_round_trips",
        artifact=Path("launch-evidence/native-swift.json"),
        manifest=manifest,
        repo_root=tmp_path,
        replay_native_commands=True,
        postcheck_validators=False,
        runner=_passing_runner,
    )

    assert updated["status"] == "not_ready"
    gates = {gate["id"]: gate for gate in updated["requiredGates"]}
    assert gates["swift_round_trips"]["status"] == "complete"
    matching = [
        item for item in updated["completedEvidence"]
        if isinstance(item, dict) and item.get("id") == "swift_round_trips"
    ]
    assert len(matching) == 1
    evidence = matching[0]
    assert evidence["artifactPath"] == "launch-evidence/native-swift.json"
    assert evidence["artifactType"] == "native_signal_runtime_evidence"
    assert evidence["sha256"] == hashlib.sha256(artifact.read_bytes()).hexdigest()
    assert "--gate swift_round_trips" in evidence["validatorCommand"]
    assert "--repo-root ." in evidence["validatorCommand"]
    assert "--replay-commands" in evidence["validatorCommand"]
    assert evidence["validatorResult"]["status"] == "pass"
    assert "validator ok" not in json.dumps(evidence)
    assert check_manifest(manifest, repo_root=tmp_path) == []


def test_attach_refuses_failed_validator_without_mutating_manifest(tmp_path):
    manifest = _write_manifest(tmp_path)
    _write_artifact(tmp_path)
    before = manifest.read_text(encoding="utf-8")

    def failing_runner(command: list[str], repo_root: Path) -> ValidatorRun:
        return ValidatorRun(command=command, exit_code=9, duration_ms=3, stdout="", stderr="nope")

    try:
        attach_runtime_evidence(
            gate_id="swift_round_trips",
            artifact=Path("launch-evidence/native-swift.json"),
            manifest=manifest,
            repo_root=tmp_path,
            postcheck_validators=False,
            runner=failing_runner,
        )
    except AttachError as exc:
        assert "validator failed with exit 9" in str(exc)
    else:
        raise AssertionError("failed validator should block evidence attachment")

    assert manifest.read_text(encoding="utf-8") == before


def test_attach_rejects_legal_allow_pending_validator_before_running(tmp_path):
    manifest = _write_manifest(tmp_path)
    _write_artifact(tmp_path, "launch-evidence/legal.json")

    def should_not_run(command: list[str], repo_root: Path) -> ValidatorRun:
        raise AssertionError("validator should not run")

    try:
        attach_runtime_evidence(
            gate_id="store_and_counsel_approval",
            artifact=Path("launch-evidence/legal.json"),
            manifest=manifest,
            repo_root=tmp_path,
            validator_command=(
                "python3 scripts/ci/check_agpl_legal_release_review.py "
                "--evidence launch-evidence/legal.json --allow-pending"
            ),
            runner=should_not_run,
        )
    except AttachError as exc:
        assert "must not be validated with --allow-pending" in str(exc)
    else:
        raise AssertionError("legal --allow-pending command should be rejected")


def test_attach_rejects_artifacts_outside_allowed_gate_prefix(tmp_path):
    manifest = _write_manifest(tmp_path)
    _write_artifact(tmp_path, "docs/fake-runtime-proof.json")

    try:
        attach_runtime_evidence(
            gate_id="cloudvault_private_domains",
            artifact=Path("docs/fake-runtime-proof.json"),
            manifest=manifest,
            repo_root=tmp_path,
            postcheck_validators=False,
            runner=_passing_runner,
        )
    except AttachError as exc:
        assert "artifact must live under one of" in str(exc)
    else:
        raise AssertionError("bad artifact prefix should be rejected")


def test_attach_rejects_absolute_paths_and_symlink_escapes(tmp_path):
    manifest = _write_manifest(tmp_path)
    artifact = _write_artifact(tmp_path, "launch-evidence/native-swift.json")

    try:
        attach_runtime_evidence(
            gate_id="swift_round_trips",
            artifact=artifact,
            manifest=manifest,
            repo_root=tmp_path,
            postcheck_validators=False,
            runner=_passing_runner,
        )
    except AttachError as exc:
        assert "artifact path must be repo-relative" in str(exc)
    else:
        raise AssertionError("absolute artifact paths should be rejected")

    outside = tmp_path.parent / "outside-runtime-proof.json"
    outside.write_text("outside\n", encoding="utf-8")
    link = tmp_path / "launch-evidence/linked-outside.json"
    link.symlink_to(outside)

    try:
        attach_runtime_evidence(
            gate_id="swift_round_trips",
            artifact=Path("launch-evidence/linked-outside.json"),
            manifest=manifest,
            repo_root=tmp_path,
            postcheck_validators=False,
            runner=_passing_runner,
        )
    except AttachError as exc:
        assert "artifact must live under repo root" in str(exc)
    else:
        raise AssertionError("symlink escape should be rejected")


def test_attach_rejects_shell_control_in_custom_validator(tmp_path):
    manifest = _write_manifest(tmp_path)
    _write_artifact(tmp_path, "launch-evidence/hermes-drain.json")

    try:
        attach_runtime_evidence(
            gate_id="hermes_gateway_writes",
            artifact=Path("launch-evidence/hermes-drain.json"),
            manifest=manifest,
            repo_root=tmp_path,
            validator_command=(
                "python3 scripts/ci/check_hermes_gateway_migration_drain.py "
                "launch-evidence/hermes-drain.json && echo forged"
            ),
            runner=_passing_runner,
        )
    except AttachError as exc:
        assert "shell control tokens" in str(exc)
    else:
        raise AssertionError("custom validator shell control should be rejected")


def test_attach_cli_runs_validator_and_writes_manifest(tmp_path):
    manifest = _write_manifest(tmp_path)
    _write_artifact(tmp_path, "launch-evidence/hermes-drain.json")
    fake_validator = tmp_path / "scripts/ci/check_hermes_gateway_migration_drain.py"
    fake_validator.parent.mkdir(parents=True)
    fake_validator.write_text("print('fake validator pass')\n", encoding="utf-8")

    result = subprocess.run(
        [
            "python3",
            "scripts/ci/attach_libsignal_runtime_evidence.py",
            "--repo-root",
            str(tmp_path),
            "--manifest",
            "third_party/libsignal/runtime-readiness.json",
            "--gate",
            "hermes_gateway_writes",
            "--artifact",
            "launch-evidence/hermes-drain.json",
        ],
        cwd=Path(__file__).resolve().parents[1],
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=False,
    )

    assert result.returncode == 0, result.stderr
    assert "PASS: attached validated evidence for hermes_gateway_writes" in result.stdout
    written = json.loads(manifest.read_text(encoding="utf-8"))
    evidence = next(item for item in written["completedEvidence"] if item.get("id") == "hermes_gateway_writes")
    assert evidence["validatorResult"]["status"] == "pass"
    assert evidence["artifactPath"] == "launch-evidence/hermes-drain.json"


def test_attach_node_contracts_uses_dedicated_artifact_validator(tmp_path):
    manifest = _write_manifest(tmp_path)
    artifact = _write_artifact(tmp_path, "launch-evidence/node-contracts.json")

    updated = attach_runtime_evidence(
        gate_id="node_contracts",
        artifact=Path("launch-evidence/node-contracts.json"),
        manifest=manifest,
        repo_root=tmp_path,
        postcheck_validators=False,
        runner=_passing_runner,
    )

    evidence = next(item for item in updated["completedEvidence"] if item.get("id") == "node_contracts")
    assert evidence["artifactType"] == "signal_envelope_contract_test_report"
    assert evidence["sha256"] == hashlib.sha256(artifact.read_bytes()).hexdigest()
    assert "check_signal_envelope_contract_runtime.py launch-evidence/node-contracts.json" in evidence["validatorCommand"]
