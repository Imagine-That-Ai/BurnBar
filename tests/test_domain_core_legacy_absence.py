#!/usr/bin/env python3
"""Adversarial tests for source, build-graph, and final-artifact deletion proof."""

from __future__ import annotations

import importlib.util
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
            ABSENCE.verify_final_artifacts(ROOT, fragments, artifacts)


if __name__ == "__main__":
    unittest.main()
