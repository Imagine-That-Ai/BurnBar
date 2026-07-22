#!/usr/bin/env python3

from __future__ import annotations

import importlib.util
import json
import pathlib
import tempfile
import unittest
import zipfile


SCRIPT = pathlib.Path(__file__).with_name("verify-burnbar-remote-android-aar.py")
SPEC = importlib.util.spec_from_file_location("remote_aar", SCRIPT)
assert SPEC is not None and SPEC.loader is not None
remote_aar = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(remote_aar)


class RemoteAarGateTests(unittest.TestCase):
    def test_committed_artifact_passes_portable_checks(self) -> None:
        remote_aar.verify()

    def test_source_fingerprint_changes_with_relevant_source(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            root = pathlib.Path(temp)
            (root / "burnbar-remote-ffi" / "src").mkdir(parents=True)
            source = root / "burnbar-remote-ffi" / "src" / "lib.rs"
            source.write_text("pub fn one() {}\n")
            first = remote_aar.source_fingerprint(root)
            source.write_text("pub fn two() {}\n")
            self.assertNotEqual(first, remote_aar.source_fingerprint(root))

    def test_metadata_tampering_fails(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            mutated = pathlib.Path(temp) / "mutated.aar"
            with zipfile.ZipFile(remote_aar.AAR_PATH) as source, zipfile.ZipFile(mutated, "w") as output:
                for info in source.infolist():
                    contents = source.read(info.filename)
                    if info.filename == remote_aar.METADATA_ENTRY:
                        metadata = json.loads(contents)
                        metadata["source_sha256"] = "0" * 64
                        contents = (json.dumps(metadata, sort_keys=True) + "\n").encode()
                    output.writestr(info, contents)
            with self.assertRaises(remote_aar.VerificationError):
                remote_aar.verify(mutated)

    def test_missing_abi_fails(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            mutated = pathlib.Path(temp) / "mutated.aar"
            with zipfile.ZipFile(remote_aar.AAR_PATH) as source, zipfile.ZipFile(mutated, "w") as output:
                for info in source.infolist():
                    if not info.filename.startswith("jni/x86/"):
                        output.writestr(info, source.read(info.filename))
            with self.assertRaises(remote_aar.VerificationError):
                remote_aar.verify(mutated)


if __name__ == "__main__":
    unittest.main()
