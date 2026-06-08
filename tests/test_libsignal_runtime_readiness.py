import hashlib
import json
from pathlib import Path

from scripts.ci.check_libsignal_runtime_readiness import check_manifest


GATES = (
    "rust_core_bridge",
    "swift_round_trips",
    "kotlin_round_trips",
    "node_contracts",
    "hermes_gateway_writes",
    "hermes_attachment_writes",
    "cloudvault_private_domains",
    "migration_telemetry",
    "store_and_counsel_approval",
)


def _ready_manifest(evidence):
    return {
        "status": "ready",
        "runtimeCryptoCore": "official_libsignal",
        "officialLibsignalPin": {
            "tag": "v0.94.4",
            "tagObject": "03c449017b57eccbda715b8b018dce5dff603ac6",
            "commit": "46d867c986f66201e34e7ae20ce423eec742bf3f",
        },
        "blockingReason": "all gates complete",
        "requiredGates": [
            {"id": gate_id, "status": "complete", "proof": f"{gate_id} proof"}
            for gate_id in GATES
        ],
        "completedEvidence": evidence,
    }


def _hashed_artifact(tmp_path, rel_path="launch-evidence/proof.json"):
    artifact = tmp_path / rel_path
    artifact.parent.mkdir(parents=True, exist_ok=True)
    artifact.write_text('{"ok": true}\n', encoding="utf-8")
    return rel_path, hashlib.sha256(artifact.read_bytes()).hexdigest()


def _complete_evidence(rel_path, digest, command_by_gate=None):
    command_by_gate = command_by_gate or {}
    return [
        {
            "id": gate_id,
            "status": "complete",
            "artifactPath": rel_path,
            "artifactType": "validator_report_json",
            "sha256": digest,
            "validatorCommand": command_by_gate.get(
                gate_id,
                f"python3 scripts/ci/check_native_signal_runtime_evidence.py {rel_path}",
            ),
            "validatorResult": "pass",
        }
        for gate_id in GATES
    ]


def test_ready_manifest_rejects_arbitrary_hash_matching_artifacts(tmp_path):
    artifact = tmp_path / "README.md"
    artifact.write_text("hash-matching but semantically unrelated proof\n", encoding="utf-8")
    digest = hashlib.sha256(artifact.read_bytes()).hexdigest()
    evidence = [
        {
            "id": gate_id,
            "status": "complete",
            "artifactPath": "README.md",
            "artifactType": "test_log",
            "sha256": digest,
            "validatorCommand": "python3 scripts/ci/check_native_signal_runtime_evidence.py",
            "validatorResult": "pass",
        }
        for gate_id in GATES
    ]
    manifest = tmp_path / "runtime-readiness.json"
    manifest.write_text(json.dumps(_ready_manifest(evidence)), encoding="utf-8")

    errors = check_manifest(manifest, repo_root=tmp_path)

    assert any("artifactPath must live under" in error for error in errors)


def test_ready_manifest_always_replays_validators(tmp_path):
    launch_evidence = tmp_path / "launch-evidence"
    launch_evidence.mkdir()
    artifact = launch_evidence / "proof.json"
    artifact.write_text('{"ok": true}\n', encoding="utf-8")
    digest = hashlib.sha256(artifact.read_bytes()).hexdigest()
    failing_script = tmp_path / "scripts" / "ci" / "check_native_signal_runtime_evidence.py"
    failing_script.parent.mkdir(parents=True)
    failing_script.write_text("import sys\nsys.exit(7)\n", encoding="utf-8")
    evidence = [
        {
            "id": gate_id,
            "status": "complete",
            "artifactPath": "launch-evidence/proof.json",
            "artifactType": "validator_report_json",
            "sha256": digest,
            "validatorCommand": "python3 scripts/ci/check_native_signal_runtime_evidence.py",
            "validatorResult": "pass",
        }
        for gate_id in GATES
    ]
    manifest = tmp_path / "runtime-readiness.json"
    manifest.write_text(json.dumps(_ready_manifest(evidence)), encoding="utf-8")

    errors = check_manifest(manifest, repo_root=tmp_path, run_validators=False)

    assert any("validatorCommand failed" in error for error in errors)


def test_ready_manifest_rejects_legal_allow_pending_validator(tmp_path):
    rel_path, digest = _hashed_artifact(tmp_path)
    evidence = _complete_evidence(
        rel_path,
        digest,
        {
            "store_and_counsel_approval": (
                f"python3 scripts/ci/check_agpl_legal_release_review.py --evidence {rel_path} --allow-pending"
            )
        },
    )
    manifest = tmp_path / "runtime-readiness.json"
    manifest.write_text(json.dumps(_ready_manifest(evidence)), encoding="utf-8")

    errors = check_manifest(manifest, repo_root=tmp_path, run_validators=False)

    assert any("must not use --allow-pending" in error for error in errors)


def test_ready_manifest_rejects_validator_command_for_different_artifact(tmp_path):
    rel_path, digest = _hashed_artifact(tmp_path)
    evidence = _complete_evidence(
        rel_path,
        digest,
        {
            "hermes_gateway_writes": (
                "python3 scripts/ci/check_hermes_gateway_migration_drain.py launch-evidence/other.json"
            )
        },
    )
    manifest = tmp_path / "runtime-readiness.json"
    manifest.write_text(json.dumps(_ready_manifest(evidence)), encoding="utf-8")

    errors = check_manifest(manifest, repo_root=tmp_path, run_validators=False)

    assert any(
        "ready gate hermes_gateway_writes validatorCommand must validate its artifactPath" in error
        for error in errors
    )


def test_ready_manifest_rust_gate_requires_gate_specific_native_validator(tmp_path):
    rel_path, digest = _hashed_artifact(tmp_path)
    evidence = _complete_evidence(
        rel_path,
        digest,
        {
            "rust_core_bridge": f"python3 scripts/ci/check_native_signal_runtime_evidence.py {rel_path}",
        },
    )
    manifest = tmp_path / "runtime-readiness.json"
    manifest.write_text(json.dumps(_ready_manifest(evidence)), encoding="utf-8")

    errors = check_manifest(manifest, repo_root=tmp_path, run_validators=False)

    assert any("ready gate rust_core_bridge validatorCommand must include --gate rust_core_bridge" in error for error in errors)
