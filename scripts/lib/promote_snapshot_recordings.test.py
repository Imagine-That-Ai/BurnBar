#!/usr/bin/env python3
"""Regression tests for fail-closed snapshot recording promotion."""

from __future__ import annotations

import importlib.util
import os
import plistlib
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock


REPO_ROOT = Path(__file__).resolve().parents[2]
MODULE_PATH = REPO_ROOT / "scripts" / "lib" / "promote_snapshot_recordings.py"
SPEC = importlib.util.spec_from_file_location("promote_snapshot_recordings", MODULE_PATH)
assert SPEC is not None and SPEC.loader is not None
PROMOTE = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = PROMOTE
SPEC.loader.exec_module(PROMOTE)


class SnapshotRecordingPromotionTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name)
        self.source = self.root / "SnapshotTests" / "__Snapshots__"
        self.bundle = self.root / "OpenBurnBarTests.xctest"
        self.resources = self.bundle / "Contents" / "Resources"
        self.resources.mkdir(parents=True)
        self.write_bundle_info(record_mode="never")

    def tearDown(self) -> None:
        self.temporary.cleanup()

    def write_source(self, relative_path: str, payload: bytes) -> Path:
        path = self.source / relative_path
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(payload)
        return path

    def write_bundle(self, relative_path: str, payload: bytes) -> Path:
        path = self.resources / relative_path
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(payload)
        return path

    def write_bundle_info(self, *, record_mode: object = "never") -> Path:
        info_plist = self.bundle / "Contents" / "Info.plist"
        info_plist.parent.mkdir(parents=True, exist_ok=True)
        with info_plist.open("wb") as handle:
            plistlib.dump(
                {PROMOTE.SNAPSHOT_RECORD_MODE_INFO_KEY: record_mode},
                handle,
            )
        return info_plist

    def promote(self, *, expected_record_mode: str = "never"):
        return PROMOTE.promote_snapshot_recordings(
            self.source,
            self.bundle,
            expected_record_mode,
        )

    def test_promotes_only_changed_allowlisted_basenames(self) -> None:
        changed = self.write_source("ColorTests/test_color.dark.png", b"old-dark")
        unchanged = self.write_source("ColorTests/test_color.light.png", b"same-light")
        self.write_bundle("test_color.dark.png", b"new-dark")
        self.write_bundle("test_color.light.png", b"same-light")
        unrelated = self.write_bundle("app-icon.png", b"not-a-snapshot")
        self.write_bundle_info(record_mode="all")

        result = self.promote(expected_record_mode="all")

        self.assertEqual(result.total, 2)
        self.assertEqual(result.changed, ("test_color.dark.png",))
        self.assertEqual(result.unchanged, 1)
        self.assertEqual(changed.read_bytes(), b"new-dark")
        self.assertEqual(unchanged.read_bytes(), b"same-light")
        self.assertEqual(unrelated.read_bytes(), b"not-a-snapshot")

    def test_never_mode_rejects_changed_bundle_before_transaction(self) -> None:
        source = self.write_source("Tests/test_changed.png", b"canonical")
        self.write_bundle("test_changed.png", b"unexpected")

        with mock.patch.object(PROMOTE, "_transactionally_replace") as replace:
            with self.assertRaisesRegex(
                PROMOTE.SnapshotPromotionError,
                "record mode is 'never': test_changed.png",
            ):
                self.promote()

        replace.assert_not_called()
        self.assertEqual(source.read_bytes(), b"canonical")
        leftovers = [
            path
            for path in self.source.parent.iterdir()
            if path.name.startswith(".snapshot-promotion-")
        ]
        self.assertEqual(leftovers, [])

    def test_rejects_duplicate_source_basenames_before_mutation(self) -> None:
        first = self.write_source("One/test_duplicate.png", b"one")
        second = self.write_source("Two/test_duplicate.png", b"two")
        self.write_bundle("test_duplicate.png", b"new")

        with self.assertRaisesRegex(
            PROMOTE.SnapshotPromotionError,
            "source snapshot basenames are ambiguous",
        ):
            self.promote()

        self.assertEqual(first.read_bytes(), b"one")
        self.assertEqual(second.read_bytes(), b"two")

    def test_rejects_missing_bundle_reference_before_mutation(self) -> None:
        present = self.write_source("Tests/test_present.png", b"old-present")
        missing = self.write_source("Tests/test_missing.png", b"old-missing")
        self.write_bundle("test_present.png", b"new-present")

        with self.assertRaisesRegex(
            PROMOTE.SnapshotPromotionError,
            "missing allowlisted snapshot references: test_missing.png",
        ):
            self.promote()

        self.assertEqual(present.read_bytes(), b"old-present")
        self.assertEqual(missing.read_bytes(), b"old-missing")

    def test_rejects_duplicate_bundle_reference_before_mutation(self) -> None:
        source = self.write_source("Tests/test_duplicate.png", b"old")
        self.write_bundle("One/test_duplicate.png", b"new-one")
        self.write_bundle("Two/test_duplicate.png", b"new-two")

        with self.assertRaisesRegex(
            PROMOTE.SnapshotPromotionError,
            "bundled snapshot basenames are ambiguous",
        ):
            self.promote()

        self.assertEqual(source.read_bytes(), b"old")

    def test_rejects_symlinked_source_reference(self) -> None:
        target = self.root / "outside.png"
        target.write_bytes(b"outside")
        symlink = self.source / "Tests" / "test_symlink.png"
        symlink.parent.mkdir(parents=True)
        os.symlink(target, symlink)
        self.write_bundle("test_symlink.png", b"new")

        with self.assertRaisesRegex(
            PROMOTE.SnapshotPromotionError,
            "must not be a symlink",
        ):
            self.promote()

        self.assertEqual(target.read_bytes(), b"outside")

    def test_rolls_back_every_installed_file_when_a_later_replace_fails(self) -> None:
        first = self.write_source("Tests/test_a.png", b"old-a")
        second = self.write_source("Tests/test_b.png", b"old-b")
        self.write_bundle("test_a.png", b"new-a")
        self.write_bundle("test_b.png", b"new-b")
        self.write_bundle_info(record_mode="all")
        real_replace = os.replace
        replacements = 0

        def fail_second_install(
            source_path: os.PathLike[str],
            destination_path: os.PathLike[str],
        ) -> None:
            nonlocal replacements
            replacements += 1
            if replacements == 2:
                raise OSError("simulated second install failure")
            real_replace(source_path, destination_path)

        with mock.patch.object(PROMOTE.os, "replace", side_effect=fail_second_install):
            with self.assertRaisesRegex(
                PROMOTE.SnapshotPromotionError,
                "every installed file was rolled back",
            ):
                self.promote(expected_record_mode="all")

        self.assertEqual(first.read_bytes(), b"old-a")
        self.assertEqual(second.read_bytes(), b"old-b")
        leftovers = [
            path
            for path in self.source.parent.iterdir()
            if path.name.startswith(".snapshot-promotion-")
        ]
        self.assertEqual(leftovers, [])

    def test_rejects_missing_bundle_record_mode_before_mutation(self) -> None:
        source = self.write_source("Tests/test_mode.png", b"old")
        self.write_bundle("test_mode.png", b"new")
        self.write_bundle_info(record_mode=42)

        with self.assertRaisesRegex(
            PROMOTE.SnapshotPromotionError,
            "missing string key OpenBurnBarSnapshotRecordMode",
        ):
            self.promote()

        self.assertEqual(source.read_bytes(), b"old")

    def test_rejects_mismatched_bundle_record_mode_before_mutation(self) -> None:
        source = self.write_source("Tests/test_mode.png", b"old")
        self.write_bundle("test_mode.png", b"new")
        self.write_bundle_info(record_mode="all")

        with self.assertRaisesRegex(
            PROMOTE.SnapshotPromotionError,
            "does not match the requested mode",
        ):
            self.promote(expected_record_mode="never")

        self.assertEqual(source.read_bytes(), b"old")

    def test_rejects_unsupported_expected_record_mode_before_mutation(self) -> None:
        source = self.write_source("Tests/test_mode.png", b"old")
        self.write_bundle("test_mode.png", b"new")

        with self.assertRaisesRegex(
            PROMOTE.SnapshotPromotionError,
            "expected snapshot record mode must be one of",
        ):
            self.promote(expected_record_mode="sometimes")

        self.assertEqual(source.read_bytes(), b"old")


if __name__ == "__main__":
    unittest.main()
