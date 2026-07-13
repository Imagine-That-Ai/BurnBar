#!/usr/bin/env python3

import importlib.util
import json
import os
from pathlib import Path
import tempfile
import unittest


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

    def test_required_swift_resource_bundle_resolution(self) -> None:
        with tempfile.TemporaryDirectory() as root:
            directory = Path(root)
            bundle = directory / MODULE.RESOURCE_BUNDLE_NAME
            bundle.mkdir()
            self.assertEqual(MODULE.find_resource_bundle([directory]), bundle)

    def test_stage_copies_and_hashes_resource_bundle(self) -> None:
        with tempfile.TemporaryDirectory() as root:
            source = Path(root) / "source"
            destination = Path(root) / "destination"
            source.mkdir()
            engine = source / "OpenBurnBarCoreCAbi.dll"
            engine.write_bytes(b"engine")
            bundle = source / MODULE.RESOURCE_BUNDLE_NAME
            bundle.mkdir()
            (bundle / "catalog.json").write_text("{\"ok\":true}\n", encoding="utf-8")

            dumpbin = Path(root) / "dumpbin"
            dumpbin.write_text("#!/usr/bin/env python3\nprint('')\n", encoding="utf-8")
            dumpbin.chmod(0o755)

            manifest = MODULE.stage(engine, destination, [source], str(dumpbin))
            self.assertEqual(
                (destination / MODULE.RESOURCE_BUNDLE_NAME / "catalog.json").read_text(encoding="utf-8"),
                "{\"ok\":true}\n",
            )
            names = {entry["fileName"] for entry in manifest["files"]}
            self.assertIn(f"{MODULE.RESOURCE_BUNDLE_NAME}/catalog.json", names)
            self.assertEqual(
                json.loads((destination / "native-engine-manifest.json").read_text(encoding="utf-8")),
                manifest,
            )


if __name__ == "__main__":
    unittest.main()
