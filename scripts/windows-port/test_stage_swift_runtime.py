#!/usr/bin/env python3

import importlib.util
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


if __name__ == "__main__":
    unittest.main()
