"""Tests for the libsignal runtime-readiness consistency gate.

The manifest may honestly say "not_ready" (expected today) or "ready", but it
may never be internally dishonest: a ready status with incomplete gates, a
drifted pin, a missing required gate, or a gate marked complete without
completed evidence must all fail.
"""

import json
import re
from pathlib import Path

from scripts.ci.check_libsignal_runtime_readiness import (
    DEFAULT_MANIFEST,
    EXPECTED_PIN,
    REQUIRED_GATE_IDS,
    check_manifest,
    load_manifest,
)

REPO_ROOT = Path(__file__).resolve().parents[1]
RUST_CORE_BRIDGE_EVIDENCE = Path("launch-evidence/libsignal-rust-core-bridge-v1.0.30.json")


def _valid_manifest(*, status: str = "not_ready", complete_ids: tuple[str, ...] = ()) -> dict:
    gates = [
        {
            "id": gate_id,
            "status": "complete" if gate_id in complete_ids else "pending",
            "proof": f"proof for {gate_id}",
        }
        for gate_id in REQUIRED_GATE_IDS
    ]
    return {
        "status": status,
        "officialLibsignalPin": dict(EXPECTED_PIN),
        "requiredGates": gates,
        "completedEvidence": [
            {"id": gate_id, "status": "complete", "proof": "x", "command": "y"} for gate_id in complete_ids
        ],
    }


def _write(tmp_path: Path, data: dict) -> Path:
    path = tmp_path / "runtime-readiness.json"
    path.write_text(json.dumps(data), encoding="utf-8")
    return path


def test_tracked_manifest_is_internally_consistent() -> None:
    assert check_manifest(DEFAULT_MANIFEST, repo_root=REPO_ROOT) == []


def test_tracked_manifest_normalizes_gates() -> None:
    data = load_manifest(DEFAULT_MANIFEST, repo_root=REPO_ROOT)
    assert set(REQUIRED_GATE_IDS) <= set(data["gates"])


def test_tracked_rust_core_bridge_gate_has_commit_bound_cross_platform_evidence() -> None:
    manifest = load_manifest(DEFAULT_MANIFEST, repo_root=REPO_ROOT)
    assert manifest["gates"]["rust_core_bridge"]["status"] == "complete"

    completed = {
        item["id"]: item
        for item in manifest["completedEvidence"]
        if isinstance(item, dict) and isinstance(item.get("id"), str)
    }
    bridge_entry = completed["rust_core_bridge"]
    assert bridge_entry["status"] == "complete"
    assert bridge_entry["evidencePath"] == RUST_CORE_BRIDGE_EVIDENCE.as_posix()

    evidence = json.loads((REPO_ROOT / RUST_CORE_BRIDGE_EVIDENCE).read_text(encoding="utf-8"))
    assert evidence["schemaVersion"] == 1
    assert evidence["status"] == "passed"
    assert evidence["privacy"] == "proof_only_no_plaintext_keys_or_user_data"
    assert evidence["officialLibsignalPin"] == EXPECTED_PIN
    assert re.fullmatch(r"[0-9a-f]{40}", evidence["testedSourceCommit"])
    assert re.fullmatch(r"v\d+\.\d+\.\d+", evidence["candidateReleaseTag"])

    required_binding_artifacts = {
        "swift": {
            "Vendor/libsignal/rust/bridge/ffi/Cargo.toml",
            "Vendor/libsignal/swift/Package.swift",
            "OpenBurnBarCore/Package.swift",
        },
        "kotlinAndroid": {
            "Vendor/libsignal/rust/bridge/jni/Cargo.toml",
            "android/app/build.gradle.kts",
        },
        "node": {
            "Vendor/libsignal/rust/bridge/node/Cargo.toml",
            "packages/libsignal-bridge/package.json",
        },
    }
    assert set(evidence["bindings"]) == set(required_binding_artifacts)
    for binding_id, required_paths in required_binding_artifacts.items():
        binding = evidence["bindings"][binding_id]
        assert binding["status"] == "passed"
        assert binding["command"].strip()
        assert binding["result"].strip()
        artifact_paths = set(binding["artifactPaths"])
        assert "Vendor/libsignal/rust/bridge/shared/Cargo.toml" in artifact_paths
        assert required_paths <= artifact_paths
        assert all((REPO_ROOT / path).is_file() for path in artifact_paths)

    integrity_ids = {proof["id"] for proof in evidence["integrityProofs"] if proof["status"] == "passed"}
    assert integrity_ids == {"pin_metadata", "fork_delta"}
    assert all(
        (REPO_ROOT / path).is_file()
        for proof in evidence["integrityProofs"]
        for path in proof["artifactPaths"]
    )


def test_valid_not_ready_manifest_passes(tmp_path: Path) -> None:
    assert check_manifest(_write(tmp_path, _valid_manifest())) == []


def test_ready_with_incomplete_gates_fails(tmp_path: Path) -> None:
    errors = check_manifest(_write(tmp_path, _valid_manifest(status="ready")))
    assert any("says ready but gates are incomplete" in error for error in errors)


def test_ready_with_all_gates_complete_passes(tmp_path: Path) -> None:
    manifest = _valid_manifest(status="ready", complete_ids=REQUIRED_GATE_IDS)
    assert check_manifest(_write(tmp_path, manifest)) == []


def test_pin_drift_fails(tmp_path: Path) -> None:
    manifest = _valid_manifest()
    manifest["officialLibsignalPin"]["commit"] = "0" * 40
    errors = check_manifest(_write(tmp_path, manifest))
    assert any("pin commit drifted" in error for error in errors)


def test_missing_required_gate_fails(tmp_path: Path) -> None:
    manifest = _valid_manifest()
    manifest["requiredGates"] = [g for g in manifest["requiredGates"] if g["id"] != "store_and_counsel_approval"]
    errors = check_manifest(_write(tmp_path, manifest))
    assert any("missing libsignal runtime gates: store_and_counsel_approval" in error for error in errors)


def test_complete_gate_without_completed_evidence_fails(tmp_path: Path) -> None:
    manifest = _valid_manifest()
    manifest["requiredGates"][0]["status"] = "complete"  # no matching completedEvidence entry
    errors = check_manifest(_write(tmp_path, manifest))
    assert any("complete gates missing completed evidence" in error for error in errors)


def test_invalid_status_fails(tmp_path: Path) -> None:
    errors = check_manifest(_write(tmp_path, _valid_manifest(status="shipped")))
    assert any("invalid libsignal runtime status" in error for error in errors)


def test_gate_without_proof_fails(tmp_path: Path) -> None:
    manifest = _valid_manifest()
    manifest["requiredGates"][0]["proof"] = ""
    errors = check_manifest(_write(tmp_path, manifest))
    assert any("missing its proof description" in error for error in errors)


def test_missing_manifest_fails(tmp_path: Path) -> None:
    errors = check_manifest(tmp_path / "nope.json")
    assert errors and "missing libsignal runtime-readiness manifest" in errors[0]
