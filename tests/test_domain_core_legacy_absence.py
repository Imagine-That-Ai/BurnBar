#!/usr/bin/env python3
"""Adversarial tests for source, build-graph, and final-artifact deletion proof."""

from __future__ import annotations

import importlib.util
import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
MODULE_PATH = ROOT / "scripts/ci/verify-domain-core-legacy-absence.py"
SPEC = importlib.util.spec_from_file_location("domain_core_legacy_absence", MODULE_PATH)
if SPEC is None or SPEC.loader is None:
    raise RuntimeError(f"cannot load {MODULE_PATH}")
ABSENCE = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = ABSENCE
SPEC.loader.exec_module(ABSENCE)


class LegacyAbsenceTests(unittest.TestCase):
    class FakeVerifier:
        def verify_release(self, *_args) -> None:
            pass

        def verify_rollback_artifact(self, *_args) -> None:
            pass

    def fixture(self) -> Path:
        root = Path(self.enterContext(tempfile.TemporaryDirectory()))
        (root / "src").mkdir()
        subprocess.run(["git", "init", "-q"], cwd=root, check=True)
        subprocess.run(
            ["git", "config", "user.email", "test@openburnbar.invalid"],
            cwd=root,
            check=True,
        )
        subprocess.run(["git", "config", "user.name", "OpenBurnBar Test"], cwd=root, check=True)
        return root

    @staticmethod
    def manifest(target: dict[str, str]) -> dict:
        return {
            "sourceRoots": {"swift": "src"},
            "rows": [{"id": "quota.test", "state": "legacy_deleted", "targets": [target]}],
        }

    def commit(self, root: Path) -> None:
        subprocess.run(["git", "add", "."], cwd=root, check=True)
        subprocess.run(["git", "commit", "-qm", "fixture"], cwd=root, check=True)

    def test_rejects_deleted_symbol_moved_elsewhere_in_source_root(self) -> None:
        root = self.fixture()
        (root / "src/Other.swift").write_text("func legacyBuckets() {}\n")
        self.commit(root)
        target = {
            "kind": "source_symbol",
            "role": "legacy_implementation",
            "root": "swift",
            "path": "src/Deleted.swift",
            "symbol": "legacyBuckets",
        }
        with self.assertRaisesRegex(ABSENCE.GATE.GateError, "remains elsewhere"):
            ABSENCE.verify_source_and_build_graph(root, self.manifest(target))

    def test_rejects_deleted_path_retained_in_build_graph(self) -> None:
        root = self.fixture()
        (root / "App.csproj").write_text('<Compile Include="src/Deleted.swift" />\n')
        self.commit(root)
        target = {
            "kind": "path",
            "role": "legacy_implementation",
            "root": "swift",
            "path": "src/Deleted.swift",
        }
        with self.assertRaisesRegex(ABSENCE.GATE.GateError, "build graph still references"):
            ABSENCE.verify_source_and_build_graph(root, self.manifest(target))

    def test_rejects_incomplete_final_binary_proof_set(self) -> None:
        fragments = Path(self.enterContext(tempfile.TemporaryDirectory()))
        artifacts = Path(self.enterContext(tempfile.TemporaryDirectory()))
        with self.assertRaisesRegex(ABSENCE.GATE.GateError, "final artifact proof set mismatch"):
            ABSENCE.verify_final_artifacts(
                fragments,
                artifacts,
                {
                    "candidateCommit": "1" * 40,
                    "coreVersion": "0.3.0",
                    "abiVersion": 3,
                    "sourceSha256": "2" * 64,
                },
            )

    def test_rejects_deletion_head_that_drifted_from_stable_rust_authority(self) -> None:
        root = self.fixture().resolve()
        core = root / "crates/openburnbar-domain-core"
        core.mkdir(parents=True)
        identity = {
            "schemaVersion": 1,
            "coreVersion": "0.3.0",
            "abiVersion": 3,
            "sourceSha256": "2" * 64,
        }
        (core / "union-abi-manifest.json").write_text(json.dumps(identity))
        (core / "Cargo.toml").write_text(
            '[workspace]\n[workspace.package]\nversion = "0.3.0"\n'
        )
        self.commit(root)
        activation_commit = subprocess.check_output(
            ["git", "rev-parse", "HEAD"], cwd=root, text=True
        ).strip()
        candidate = {
            "candidateCommit": activation_commit,
            "coreVersion": identity["coreVersion"],
            "abiVersion": identity["abiVersion"],
            "sourceSha256": identity["sourceSha256"],
        }
        activation = {
            **candidate,
            "activationCommit": activation_commit,
            "changedPathsSha256": "3" * 64,
        }
        row_id = "quota.claude_statusline"
        receipt_relative = (
            f"{ABSENCE.GATE.RECEIPT_ROOT}/{row_id}/1/stable_release.json"
        )
        receipt = root / receipt_relative
        receipt.parent.mkdir(parents=True)
        provenance_relative = "config/domain-core-release-provenance/quota.claude_statusline/1/apple.json"
        rollback_provenance_relative = "config/domain-core-release-provenance/quota.claude_statusline/1/rollback.json"
        for relative in (provenance_relative, rollback_provenance_relative):
            path = root / relative
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text("{}\n")
        receipt.write_text(
            json.dumps(
                {
                    "schemaVersion": 2,
                    "rowId": row_id,
                    "authorityGeneration": 1,
                    "transition": "stable_release",
                    "status": "active",
                    "release": {
                        "candidate": candidate,
                        "activation": activation,
                        "consumerReleases": [
                            {
                                "consumer": "apple",
                                "artifactUri": "https://github.com/Imagine-That-Ai/BurnBar/releases/download/v1.2.3/OpenBurnBar-1.2.3-macOS.dmg",
                                "artifactSha256": "8" * 64,
                                "provenancePath": provenance_relative,
                            }
                        ],
                        "rollbackArtifact": {
                            "artifactSha256": "9" * 64,
                            "provenancePath": rollback_provenance_relative,
                        },
                    },
                }
            )
        )
        manifest = {
            "rows": [
                {
                    "id": row_id,
                    "state": "legacy_deleted",
                    "authorityGeneration": 1,
                    "receipts": {"stableRelease": receipt_relative},
                    "targets": [],
                }
            ]
        }
        self.commit(root)
        authority = ABSENCE.stable_authority_for_deleted_rows(root, manifest, self.FakeVerifier())
        self.assertEqual(authority["candidate"], candidate)
        identity["sourceSha256"] = "4" * 64
        (core / "union-abi-manifest.json").write_text(json.dumps(identity))
        self.commit(root)
        with self.assertRaisesRegex(ABSENCE.GATE.GateError, "changed stable Rust authority"):
            ABSENCE.stable_authority_for_deleted_rows(root, manifest, self.FakeVerifier())
        epoch_two_commit = subprocess.check_output(
            ["git", "rev-parse", "HEAD"], cwd=root, text=True
        ).strip()
        epoch_two_candidate = {
            "candidateCommit": epoch_two_commit,
            "coreVersion": identity["coreVersion"],
            "abiVersion": identity["abiVersion"],
            "sourceSha256": identity["sourceSha256"],
        }
        epoch_two_activation = {
            **epoch_two_candidate,
            "activationCommit": epoch_two_commit,
            "changedPathsSha256": "5" * 64,
        }
        epoch_two_relative = (
            f"{ABSENCE.GATE.RECEIPT_ROOT}/{row_id}/2/stable_release.json"
        )
        epoch_two_receipt = root / epoch_two_relative
        epoch_two_receipt.parent.mkdir(parents=True)
        epoch_two_provenance_relative = "config/domain-core-release-provenance/quota.claude_statusline/2/apple.json"
        epoch_two_rollback_provenance_relative = "config/domain-core-release-provenance/quota.claude_statusline/2/rollback.json"
        for relative in (epoch_two_provenance_relative, epoch_two_rollback_provenance_relative):
            path = root / relative
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text("{}\n")
        epoch_two_receipt.write_text(
            json.dumps(
                {
                    "schemaVersion": 2,
                    "rowId": row_id,
                    "authorityGeneration": 2,
                    "transition": "stable_release",
                    "status": "active",
                    "release": {
                        "candidate": epoch_two_candidate,
                        "activation": epoch_two_activation,
                        "consumerReleases": [
                            {
                                "consumer": "apple",
                                "artifactUri": "https://github.com/Imagine-That-Ai/BurnBar/releases/download/v1.2.4/OpenBurnBar-1.2.4-macOS.dmg",
                                "artifactSha256": "a" * 64,
                                "provenancePath": epoch_two_provenance_relative,
                            }
                        ],
                        "rollbackArtifact": {
                            "artifactSha256": "b" * 64,
                            "provenancePath": epoch_two_rollback_provenance_relative,
                        },
                    },
                }
            )
        )
        self.commit(root)
        manifest["rows"][0]["authorityGeneration"] = 2
        manifest["rows"][0]["receipts"]["stableRelease"] = epoch_two_relative
        authority = ABSENCE.stable_authority_for_deleted_rows(root, manifest, self.FakeVerifier())
        self.assertEqual(authority["candidate"], epoch_two_candidate)


if __name__ == "__main__":
    unittest.main()
