#!/usr/bin/env python3

import importlib.util
import hashlib
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch


SCRIPT = Path(__file__).with_name("stage-swift-runtime.py")
SPEC = importlib.util.spec_from_file_location("stage_swift_runtime", SCRIPT)
assert SPEC is not None and SPEC.loader is not None
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


class StageSwiftRuntimeTests(unittest.TestCase):
    def test_parse_dependencies_deduplicates_case_insensitively(self) -> None:
        output = """
          Image has the following dependencies:

            swiftCore.dll
            Foundation.dll
            SWIFTCORE.DLL
            KERNEL32.dll
        """
        self.assertEqual(
            MODULE.parse_dependencies(output),
            ["swiftCore.dll", "Foundation.dll", "KERNEL32.dll"],
        )

    def test_system_library_classification_is_fail_closed_for_runtime_dlls(self) -> None:
        self.assertTrue(MODULE.is_system_library("KERNEL32.dll"))
        self.assertTrue(MODULE.is_system_library("api-ms-win-core-file-l1-1-0.dll"))
        self.assertFalse(MODULE.is_system_library("swiftCore.dll"))
        self.assertFalse(MODULE.is_system_library("Foundation.dll"))

    def test_case_insensitive_resolution(self) -> None:
        with tempfile.TemporaryDirectory() as root:
            directory = Path(root)
            expected = directory / "swiftCore.DLL"
            expected.write_bytes(b"runtime")
            self.assertEqual(
                MODULE.find_case_insensitive("SWIFTCORE.dll", [directory]),
                expected,
            )

    def test_stage_copies_resource_bundle_and_hashes_manifest_entries(self) -> None:
        with tempfile.TemporaryDirectory() as root:
            directory = Path(root)
            engine = directory / "OpenBurnBarCoreCAbi.dll"
            engine.write_bytes(b"engine")
            bundle = directory / "OpenBurnBarCore_OpenBurnBarCore.resources"
            bundle.mkdir()
            resource = bundle / "catalog.json"
            resource.write_bytes(b'{"schemaVersion":1}\n')
            destination = directory / "stage"

            with patch.object(
                MODULE.subprocess,
                "run",
                return_value=type("Completed", (), {"stdout": "", "stderr": ""})(),
            ):
                manifest = MODULE.stage(engine, destination, [directory], "dumpbin")

            staged_resource = destination / bundle.name / resource.name
            self.assertTrue(staged_resource.is_file())
            manifest_entry = next(
                item for item in manifest["files"] if item["fileName"] == f"{bundle.name}/catalog.json"
            )
            self.assertEqual(
                manifest_entry["sha256"],
                hashlib.sha256(resource.read_bytes()).hexdigest(),
            )
            persisted = json.loads((destination / "native-engine-manifest.json").read_text())
            self.assertEqual(persisted, manifest)

    def test_stage_fails_when_resource_bundle_is_missing(self) -> None:
        with tempfile.TemporaryDirectory() as root:
            directory = Path(root)
            engine = directory / "OpenBurnBarCoreCAbi.dll"
            engine.write_bytes(b"engine")
            with patch.object(
                MODULE.subprocess,
                "run",
                return_value=type("Completed", (), {"stdout": "", "stderr": ""})(),
            ):
                with self.assertRaisesRegex(ValueError, "required Swift resource bundle"):
                    MODULE.stage(engine, directory / "stage", [directory], "dumpbin")


if __name__ == "__main__":
    unittest.main()
