#!/usr/bin/env python3
"""Contract tests for append-only stable-release and rollback receipt writers."""

from __future__ import annotations

import importlib.util
import subprocess
import sys
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]


def load(name: str, path: Path):
    spec = importlib.util.spec_from_file_location(name, path)
    if spec is None or spec.loader is None:
        raise RuntimeError(f"cannot load {path}")
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module


STABLE = load(
    "domain_core_stable_receipt_writer",
    ROOT / "scripts/ops/create-domain-core-stable-receipt.py",
)


class LifecycleReceiptWriterTests(unittest.TestCase):
    def test_both_writers_expose_bounded_required_cli(self) -> None:
        for script in (
            "scripts/ops/create-domain-core-stable-receipt.py",
            "scripts/ops/create-domain-core-rollback-receipt.py",
        ):
            result = subprocess.run(
                [sys.executable, script, "--help"],
                cwd=ROOT,
                check=False,
                capture_output=True,
                text=True,
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn("--authority-generation", result.stdout)
            self.assertIn("--approved-at", result.stdout)

    def test_stable_writer_rejects_future_approval_before_reading_authority(
        self,
    ) -> None:
        with self.assertRaisesRegex(STABLE.GATE.GateError, "cannot be in the future"):
            STABLE.create_receipt(
                ROOT,
                row_id="quota.claude_statusline",
                generation=1,
                activation_commit="a" * 40,
                release_paths=[],
                rollback_path=ROOT / "missing.json",
                approved_by="@release-owner",
                approved_at="2999-01-01T00:00:00Z",
            )

    def test_writers_use_create_only_append_semantics(self) -> None:
        stable = (ROOT / "scripts/ops/create-domain-core-stable-receipt.py").read_text()
        rollback = (ROOT / "scripts/ops/create-domain-core-rollback-receipt.py").read_text()
        for source in (stable, rollback):
            self.assertIn("WRITER.append_only", source)
            self.assertIn("WRITER.serialized", source)


if __name__ == "__main__":
    unittest.main()
