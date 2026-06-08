import hashlib
import json
import shutil
import subprocess
import sys
from pathlib import Path

from scripts.ci.write_burnbar_source_provenance import (
    REQUIRED_SOURCE_FILES,
    build_source_provenance_manifest,
    release_preflight_blockers,
)


def test_source_provenance_manifest_covers_agpl_signal_release_inputs():
    manifest = build_source_provenance_manifest(repo_root=Path(__file__).resolve().parents[1])
    paths = {entry["path"] for entry in manifest["requiredSourceFiles"]}
    assert "third_party/libsignal/runtime-readiness.json" in paths
    assert "scripts/ci/attach_libsignal_runtime_evidence.py" in paths
    assert "tests/test_libsignal_runtime_evidence_attach.py" in paths
    assert "docs/legal/AGPL_RELEASE_REVIEW_PACKET.md" in paths
    assert manifest["runtimeReadiness"]["status"] in {"ready", "not_ready"}
    assert manifest["runtimeReadiness"]["validatorErrors"] == []


def test_source_provenance_rejects_forged_ready_runtime_manifest(tmp_path):
    repo = tmp_path / "repo"
    source = Path(__file__).resolve().parents[1]
    shutil.copytree(source / "scripts", repo / "scripts", ignore=shutil.ignore_patterns("__pycache__"))
    (repo / "third_party/libsignal").mkdir(parents=True)
    for rel_path in REQUIRED_SOURCE_FILES:
        if rel_path == "third_party/libsignal/runtime-readiness.json":
            continue
        path = repo / rel_path
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(f"placeholder for {rel_path}\n", encoding="utf-8")
    subprocess.run(["git", "init"], cwd=repo, check=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    subprocess.run(["git", "add", "."], cwd=repo, check=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    subprocess.run(
        ["git", "-c", "user.name=Test", "-c", "user.email=test@example.com", "commit", "-m", "fixture"],
        cwd=repo,
        check=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )

    artifact = repo / "README.md"
    artifact.write_text("hash-matching fake evidence\n", encoding="utf-8")
    digest = hashlib.sha256(artifact.read_bytes()).hexdigest()
    gates = (
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
    manifest = {
        "status": "ready",
        "runtimeCryptoCore": "forged",
        "officialLibsignalPin": {
            "tag": "v0.94.4",
            "tagObject": "03c449017b57eccbda715b8b018dce5dff603ac6",
            "commit": "46d867c986f66201e34e7ae20ce423eec742bf3f",
        },
        "blockingReason": "forged",
        "requiredGates": [{"id": gate_id, "status": "complete", "proof": "forged"} for gate_id in gates],
        "completedEvidence": [
            {
                "id": gate_id,
                "status": "complete",
                "artifactPath": "README.md",
                "artifactType": "test_log",
                "sha256": digest,
                "validatorCommand": "echo forged",
                "validatorResult": "pass",
            }
            for gate_id in gates
        ],
    }
    (repo / "third_party/libsignal/runtime-readiness.json").write_text(json.dumps(manifest), encoding="utf-8")
    sys.path.insert(0, str(repo))
    try:
        forged = build_source_provenance_manifest(repo_root=repo)
    finally:
        sys.path.pop(0)

    blockers = release_preflight_blockers(forged)

    assert any("runtimeReadiness validator failed" in blocker for blocker in blockers)
