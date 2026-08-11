#!/usr/bin/env python3
"""Platform-neutral regression tests for SQLCipher framework staging."""

from __future__ import annotations

import importlib.util
import json
import os
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock


REPO_ROOT = Path(__file__).resolve().parents[2]
MODULE_PATH = REPO_ROOT / "scripts" / "lib" / "stage_sqlcipher_framework.py"
SPEC = importlib.util.spec_from_file_location("stage_sqlcipher_framework", MODULE_PATH)
assert SPEC is not None and SPEC.loader is not None
STAGE = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = STAGE
SPEC.loader.exec_module(STAGE)


class SQLCipherFrameworkStagingTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name)

    def tearDown(self) -> None:
        self.temporary.cleanup()

    def write_json(self, relative: str, value: object) -> Path:
        path = self.root / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(json.dumps(value), encoding="utf-8")
        return path

    def framework_fixture(self, relative: str, payload: bytes = b"new") -> Path:
        framework = self.root / relative / "SQLCipher.framework"
        version = framework / "Versions" / "A"
        resources = version / "Resources"
        resources.mkdir(parents=True)
        (version / "SQLCipher").write_bytes(payload)
        os.symlink("A", framework / "Versions" / "Current")
        os.symlink("Versions/Current/SQLCipher", framework / "SQLCipher")
        os.symlink("Versions/Current/Resources", framework / "Resources")
        return framework

    def test_resolved_pin_requires_exact_identity_version_and_revision(self) -> None:
        path = self.write_json(
            "Package.resolved",
            {
                "pins": [
                    {
                        "identity": STAGE.EXPECTED_PACKAGE_IDENTITY,
                        "kind": "remoteSourceControl",
                        "location": STAGE.EXPECTED_PACKAGE_LOCATION,
                        "state": {
                            "revision": STAGE.EXPECTED_PACKAGE_REVISION,
                            "version": STAGE.EXPECTED_PACKAGE_VERSION,
                        },
                    }
                ]
            },
        )
        identity = STAGE.validate_resolved_pin(path)
        self.assertEqual(identity.version, STAGE.EXPECTED_PACKAGE_VERSION)
        self.assertEqual(identity.revision, STAGE.EXPECTED_PACKAGE_REVISION)

        document = json.loads(path.read_text(encoding="utf-8"))
        document["pins"][0]["state"]["version"] = "4.15.0"
        path.write_text(json.dumps(document), encoding="utf-8")
        with self.assertRaisesRegex(STAGE.StageError, "unexpected SQLCipher package version"):
            STAGE.validate_resolved_pin(path)

    def test_workspace_dependency_rejects_ambiguity(self) -> None:
        dependency = {
            "packageRef": {
                "identity": STAGE.EXPECTED_PACKAGE_IDENTITY,
                "kind": "remoteSourceControl",
                "location": STAGE.EXPECTED_PACKAGE_LOCATION,
                "name": "SQLCipher",
            },
            "state": {
                "checkoutState": {
                    "revision": STAGE.EXPECTED_PACKAGE_REVISION,
                    "version": STAGE.EXPECTED_PACKAGE_VERSION,
                },
                "name": "sourceControlCheckout",
            },
            "subpath": "SQLCipher.swift",
        }
        path = self.write_json(
            "workspace-state.json",
            {"object": {"dependencies": [dependency, dependency]}},
        )
        with self.assertRaisesRegex(STAGE.StageError, "exactly one"):
            STAGE.validate_workspace_dependency(path)

    def test_discovery_rejects_multiple_matching_artifacts(self) -> None:
        scratch = self.root / "scratch"
        for namespace in ("one", "two"):
            framework = (
                scratch
                / "artifacts"
                / namespace
                / "sqlcipher.swift"
                / "SQLCipher"
                / "SQLCipher.xcframework"
                / "macos-arm64_x86_64"
                / "SQLCipher.framework"
            )
            framework.mkdir(parents=True)
        with self.assertRaisesRegex(STAGE.StageError, "found 2"):
            STAGE.discover_framework(scratch)

    def test_destination_must_remain_inside_scratch(self) -> None:
        scratch = self.root / "scratch"
        scratch.mkdir()
        accepted = scratch / "out" / "PackageFrameworks" / "SQLCipher.framework"
        self.assertEqual(
            STAGE.ensure_destination_within_scratch(accepted, scratch),
            accepted.resolve(strict=False),
        )
        escaped = self.root / "elsewhere" / "SQLCipher.framework"
        with self.assertRaisesRegex(STAGE.StageError, "escapes SwiftPM scratch path"):
            STAGE.ensure_destination_within_scratch(escaped, scratch)

    def test_atomic_replace_preserves_framework_symlinks_and_removes_old_tree(self) -> None:
        source = self.framework_fixture("source", payload=b"new-framework")
        destination = self.framework_fixture("scratch/out", payload=b"old-framework")

        STAGE.atomic_replace_tree(source, destination)

        self.assertEqual(
            (destination / "Versions" / "A" / "SQLCipher").read_bytes(),
            b"new-framework",
        )
        self.assertTrue((destination / "SQLCipher").is_symlink())
        self.assertEqual(os.readlink(destination / "SQLCipher"), "Versions/Current/SQLCipher")
        leftovers = [
            path.name
            for path in destination.parent.iterdir()
            if path.name.startswith((".sqlcipher-stage-", ".sqlcipher-previous-"))
        ]
        self.assertEqual(leftovers, [])

    def test_atomic_replace_restores_old_tree_if_install_rename_fails(self) -> None:
        source = self.framework_fixture("source", payload=b"new-framework")
        destination = self.framework_fixture("scratch/out", payload=b"old-framework")
        real_replace = os.replace
        replacements = 0

        def fail_install(source_path: os.PathLike[str], destination_path: os.PathLike[str]) -> None:
            nonlocal replacements
            replacements += 1
            if replacements == 2:
                raise OSError("simulated install rename failure")
            real_replace(source_path, destination_path)

        with mock.patch.object(STAGE.os, "replace", side_effect=fail_install):
            with self.assertRaisesRegex(OSError, "simulated install rename failure"):
                STAGE.atomic_replace_tree(source, destination)

        self.assertEqual(
            (destination / "Versions" / "A" / "SQLCipher").read_bytes(),
            b"old-framework",
        )

    def test_stage_retains_identical_verified_destination_without_replacement(self) -> None:
        source = self.framework_fixture("source", payload=b"same-framework")
        destination = self.framework_fixture(
            "scratch/out",
            payload=b"same-framework",
        )
        identity = self.framework_identity("same")

        with mock.patch.object(STAGE, "atomic_replace_tree") as replace:
            staged, disposition = STAGE.stage_verified_framework(
                source,
                destination,
                identity,
                validate=lambda _: identity,
                replace=replace,
            )

        self.assertEqual(staged, identity)
        self.assertEqual(disposition, "retained")
        replace.assert_not_called()

    def test_stage_replaces_a_different_destination_and_verifies_the_result(self) -> None:
        source = self.framework_fixture("source", payload=b"new-framework")
        destination = self.framework_fixture(
            "scratch/out",
            payload=b"old-framework",
        )
        source_identity = self.framework_identity("new")
        old_identity = self.framework_identity("old")

        def validate(path: Path) -> STAGE.FrameworkIdentity:
            payload = (path / "Versions" / "A" / "SQLCipher").read_bytes()
            return source_identity if payload == b"new-framework" else old_identity

        staged, disposition = STAGE.stage_verified_framework(
            source,
            destination,
            source_identity,
            validate=validate,
        )

        self.assertEqual(staged, source_identity)
        self.assertEqual(disposition, "installed")
        self.assertEqual(
            (destination / "Versions" / "A" / "SQLCipher").read_bytes(),
            b"new-framework",
        )

    def test_plan_retains_only_an_identical_verified_destination(self) -> None:
        destination = self.framework_fixture(
            "scratch/out",
            payload=b"same-framework",
        )
        source_identity = self.framework_identity("same")

        retained = STAGE.planned_staging_disposition(
            destination,
            source_identity,
            validate=lambda _: source_identity,
        )
        install_required = STAGE.planned_staging_disposition(
            destination,
            source_identity,
            validate=lambda _: self.framework_identity("different"),
        )

        self.assertEqual(retained, "retained")
        self.assertEqual(install_required, "install-required")

    def test_plan_requires_install_for_missing_or_invalid_destination(self) -> None:
        destination = self.root / "scratch/out/SQLCipher.framework"
        identity = self.framework_identity("source")

        self.assertEqual(
            STAGE.planned_staging_disposition(destination, identity),
            "install-required",
        )

        self.framework_fixture("scratch/out", payload=b"invalid")

        def reject(_: Path) -> STAGE.FrameworkIdentity:
            raise STAGE.StageError("invalid framework")

        self.assertEqual(
            STAGE.planned_staging_disposition(
                destination,
                identity,
                validate=reject,
            ),
            "install-required",
        )

    def test_tree_hash_changes_when_payload_changes(self) -> None:
        framework = self.framework_fixture("source", payload=b"one")
        first = STAGE.tree_sha256(framework)
        (framework / "Versions" / "A" / "SQLCipher").write_bytes(b"two")
        second = STAGE.tree_sha256(framework)
        self.assertNotEqual(first, second)

    @staticmethod
    def framework_identity(label: str) -> STAGE.FrameworkIdentity:
        return STAGE.FrameworkIdentity(
            bundle_identifier=f"bundle-{label}",
            architectures=("arm64", "x86_64"),
            executable_sha256=f"executable-{label}",
            tree_sha256=f"tree-{label}",
            team_identifier=f"team-{label}",
            authority=f"authority-{label}",
            cdhash=f"cdhash-{label}",
        )


if __name__ == "__main__":
    unittest.main(verbosity=2)
