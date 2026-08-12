#!/usr/bin/env python3

from __future__ import annotations

import importlib.util
import os
import tempfile
import unittest
from pathlib import Path
from unittest import mock


SCRIPT = Path(__file__).with_name("exclusive_json.py")
SPEC = importlib.util.spec_from_file_location("exclusive_json", SCRIPT)
if SPEC is None or SPEC.loader is None:
    raise RuntimeError(f"cannot load {SCRIPT}")
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


class ExclusiveJSONTests(unittest.TestCase):
    def root(self) -> Path:
        return Path(self.enterContext(tempfile.TemporaryDirectory()))

    def test_writes_owner_only_json(self) -> None:
        output = self.root() / "receipt.json"
        MODULE.write_exclusive_json(output, {"status": "passed"})
        self.assertEqual(output.read_text(), '{\n  "status": "passed"\n}\n')
        self.assertEqual(os.stat(output).st_mode & 0o777, 0o600)

    def test_refuses_existing_file_and_symlink(self) -> None:
        root = self.root()
        output = root / "receipt.json"
        output.write_text("preserve\n")
        with self.assertRaises(FileExistsError):
            MODULE.write_exclusive_json(output, {"overwrite": True})
        self.assertEqual(output.read_text(), "preserve\n")

        link = root / "link.json"
        link.symlink_to(output)
        with self.assertRaises(OSError):
            MODULE.write_exclusive_json(link, {"follow": True})
        self.assertEqual(output.read_text(), "preserve\n")

    def test_refuses_symlinked_parent(self) -> None:
        root = self.root()
        target = root / "real"
        target.mkdir()
        linked = root / "linked"
        linked.symlink_to(target, target_is_directory=True)
        with self.assertRaisesRegex(ValueError, "parent must be a real"):
            MODULE.write_exclusive_json(linked / "receipt.json", {"unsafe": True})
        self.assertFalse((target / "receipt.json").exists())

    def test_cleans_only_created_inode_after_partial_failure(self) -> None:
        output = self.root() / "receipt.json"
        real_fsync = MODULE.os.fsync
        calls = 0

        def fail_first_fsync(descriptor: int) -> None:
            nonlocal calls
            calls += 1
            if calls == 1:
                raise OSError("injected fsync failure")
            real_fsync(descriptor)

        with mock.patch.object(MODULE.os, "fsync", side_effect=fail_first_fsync):
            with self.assertRaisesRegex(OSError, "injected fsync failure"):
                MODULE.write_exclusive_json(output, {"partial": True})
        self.assertFalse(output.exists())


if __name__ == "__main__":
    unittest.main()
