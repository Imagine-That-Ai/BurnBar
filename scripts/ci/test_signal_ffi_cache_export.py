#!/usr/bin/env python3
"""Exercise the exact inline exporter with synthetic files, never native binaries.

Run: python3 scripts/ci/test_signal_ffi_cache_export.py
These tests prove packaging/rejection behavior; only the hosted run can prove
that the real cached Mach-O exports the required symbols.
"""

import hashlib
import json
import os
import plistlib
import subprocess
import sys
import tarfile
import tempfile
import unittest
from pathlib import Path


REPO = Path(__file__).resolve().parents[2]
WORKFLOW = (REPO / ".github/workflows/headless-app-build.yml").read_text()
EXPORT_JOB = WORKFLOW.split("  export-signal-ffi:\n", 1)[1]
PROGRAM = EXPORT_JOB.split("          python3 - <<'PY'\n", 1)[1].split("          PY\n", 1)[0]
PROGRAM = "\n".join(line[10:] for line in PROGRAM.splitlines()) + "\n"
SLICE = "macos-arm64_x86_64"
FRAMEWORK = "OpenBurnBarSignalFfiMac.xcframework"
TARGETS = "aarch64-apple-darwin x86_64-apple-darwin aarch64-apple-ios aarch64-apple-ios-sim x86_64-apple-ios"
SYMBOLS = [f"signal_example_{index}" for index in range(678)]


class CacheExportTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.framework = self.root / "Vendor" / FRAMEWORK
        self.slice = self.framework / SLICE
        (self.slice / "Headers").mkdir(parents=True)
        (self.slice / "libsignal_ffi.dylib").write_bytes(b"synthetic native data, not executable")
        (self.slice / "Headers/OpenBurnBarSignalFfi.h").write_text("void OpenBurnBarSignalFfiLinkAnchor(void);\n")
        self.info = {
            "CFBundlePackageType": "XFWK",
            "XCFrameworkFormatVersion": "1.0",
            "AvailableLibraries": [
                {
                    "LibraryIdentifier": SLICE,
                    "LibraryPath": "libsignal_ffi.dylib",
                    "HeadersPath": "Headers",
                    "SupportedPlatform": "macos",
                    "SupportedArchitectures": ["arm64", "x86_64"],
                }
            ],
        }
        self.write_info()
        (self.framework / ".openburnbar-signal-ffi-build.env").write_text(f"profile=debug\ntargets={TARGETS}\n")
        (self.framework / ".openburnbar-signal-ffi-warm-provenance.env").write_text(
            "image_version=20260907.0351.1\n"
            "rustc=rustc 1.96.0 (ac68faa20 2026-05-25)\n"
            "xcode=Xcode 27.0 Build version 18A123\n"
        )
        self.libsignal = self.root / "Vendor/libsignal"
        self.header = self.libsignal / "swift/Sources/SignalFfi/signal_ffi.h"
        self.header.parent.mkdir(parents=True)
        self.header.write_text("\n".join(f"void {name}(void);" for name in SYMBOLS))
        (self.libsignal / "LICENSE").write_text("Public license fixture\n")
        self.bin = self.root / "bin"
        self.bin.mkdir()
        self.fake_tool("lipo", "printf 'arm64 x86_64\\n'")
        self.fake_nm(SYMBOLS)
        self.temp = self.root / "runner-temp"
        self.temp.mkdir()
        self.env = {
            **os.environ,
            "PATH": str(self.bin) + os.pathsep + os.environ["PATH"],
            "RUNNER_TEMP": str(self.temp),
            "CACHE_HIT": "true",
            "SOURCE_COMMIT": "970a2f6b3b551f6def1967046974ed74ae3d6fa2",
            "SIGNAL_COMMIT": "2c39c2601ce5e8c73326db037007fd294121e239",
            "SIGNAL_CACHE_KEY": "public exact-key fixture",
            "GITHUB_RUN_ID": "123456",
            "GITHUB_SHA": "a" * 40,
        }

    def write_info(self):
        (self.framework / "Info.plist").write_bytes(plistlib.dumps(self.info))

    def fake_tool(self, name, body):
        path = self.bin / name
        path.write_text("#!/bin/sh\n" + body + "\n")
        path.chmod(0o755)

    def fake_nm(self, names):
        self.fake_tool("nm", "cat <<'SYMBOLS'\n" + "\n".join("00000001 T _" + name for name in names) + "\nSYMBOLS")

    def run_export(self):
        return subprocess.run(
            [sys.executable, "-c", PROGRAM], cwd=self.root, env=self.env, capture_output=True, text=True, check=False
        )

    def reject(self, reason):
        result = self.run_export()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn(reason, result.stdout + result.stderr)
        self.assertFalse((self.temp / "signal-ffi-export").exists())

    def test_exact_payload_receipt_and_checksums(self):
        # An unrelated workspace secret must never be included.
        (self.root / ".private-env").write_text("never-export-this")
        result = self.run_export()
        self.assertEqual(result.returncode, 0, result.stderr)
        output = self.temp / "signal-ffi-export"
        archive = output / "signal-ffi-2c39c260-macos-debug.tar.gz"
        self.assertEqual(
            (output / "SHA256SUMS").read_text(),
            hashlib.sha256(archive.read_bytes()).hexdigest() + "  " + archive.name + "\n",
        )
        expected = {
            FRAMEWORK + "/Info.plist",
            FRAMEWORK + "/" + SLICE + "/libsignal_ffi.dylib",
            FRAMEWORK + "/" + SLICE + "/Headers/OpenBurnBarSignalFfi.h",
            FRAMEWORK + "/.openburnbar-signal-ffi-build.env",
            FRAMEWORK + "/.openburnbar-signal-ffi-warm-provenance.env",
            "LICENSE-libsignal.txt",
            "provenance.json",
            "SOURCE.txt",
        }
        with tarfile.open(archive) as bundle:
            self.assertEqual(set(bundle.getnames()), expected)
            for member in bundle.getmembers():
                self.assertTrue(member.isfile())
                self.assertEqual(member.uid, 0)
                self.assertEqual(member.gid, 0)
            receipt = json.load(bundle.extractfile("provenance.json"))
            self.assertEqual(receipt["verified_arm64_header_functions"], 678)
            self.assertEqual(receipt["libsignal_commit"], self.env["SIGNAL_COMMIT"])
            for name, digest in receipt["sha256"].items():
                self.assertEqual(hashlib.sha256(bundle.extractfile(name).read()).hexdigest(), digest)
            self.assertEqual(bundle.getmember(FRAMEWORK + "/" + SLICE + "/libsignal_ffi.dylib").mode, 0o755)

    def test_cache_miss_and_partial_hit_fail_closed(self):
        for value in ("", "false"):
            with self.subTest(value=value):
                self.env["CACHE_HIT"] = value
                self.reject("Exact cache hit required")

    def test_missing_ffi_symbol_rejected(self):
        self.fake_nm(SYMBOLS[:-1])
        self.reject("Missing required arm64 FFI exports: signal_example_677")

    def test_header_inventory_drift_rejected(self):
        self.header.write_text("void signal_one(void);")
        self.reject("Pinned header function inventory changed")

    def test_wrong_architecture_rejected(self):
        self.fake_tool("lipo", "printf 'x86_64\\n'")
        self.reject("Binary architecture mismatch")

    def test_native_inspection_failure_rejected(self):
        self.fake_tool("nm", "exit 42")
        self.reject("returned non-zero exit status 42")

    def test_unknown_cached_file_rejected(self):
        (self.framework / ".private-env").write_text("never-export-this")
        self.reject("Unexpected framework file")

    def test_symlink_rejected(self):
        path = self.slice / "libsignal_ffi.dylib"
        path.unlink()
        path.symlink_to(self.libsignal / "LICENSE")
        self.reject("Links and special files are forbidden")

    def test_hardlink_rejected(self):
        os.link(self.slice / "libsignal_ffi.dylib", self.root / "hardlink")
        self.reject("Links and special files are forbidden")

    def test_missing_metadata_rejected(self):
        (self.framework / ".openburnbar-signal-ffi-build.env").unlink()
        self.reject("Incomplete framework")

    def test_wrong_profile_rejected(self):
        (self.framework / ".openburnbar-signal-ffi-build.env").write_text(f"profile=release\ntargets={TARGETS}\n")
        self.reject("Wrong profile or targets")

    def test_extra_metadata_cannot_exfiltrate(self):
        path = self.framework / ".openburnbar-signal-ffi-build.env"
        path.write_text(path.read_text() + "token=never-export-this\n")
        self.reject("Unexpected metadata fields")

    def test_unreviewed_image_rejected(self):
        path = self.framework / ".openburnbar-signal-ffi-warm-provenance.env"
        path.write_text(path.read_text().replace("20260907.0351.1", "unknown"))
        self.reject("Unreviewed build image")

    def test_extra_plist_data_rejected(self):
        self.info["private_data"] = "never-export-this"
        self.write_info()
        self.reject("Unexpected framework metadata")

    def test_path_traversal_in_plist_rejected(self):
        self.info["AvailableLibraries"][0]["LibraryPath"] = "../../private-env"
        self.write_info()
        self.reject("Unexpected XCFramework layout")

    def test_workflow_guardrails(self):
        self.assertIn("if: github.event_name == 'workflow_dispatch' && inputs.export_signal_ffi", EXPORT_JOB)
        self.assertIn("if: github.event_name != 'workflow_dispatch' || !inputs.export_signal_ffi", WORKFLOW)
        self.assertIn("        type: boolean\n        default: false", WORKFLOW)
        self.assertIn("    runs-on: macos-26\n", EXPORT_JOB)
        self.assertIn("    timeout-minutes: 15\n", EXPORT_JOB)
        self.assertIn("    permissions:\n      contents: read\n", EXPORT_JOB)
        self.assertIn("          persist-credentials: false", EXPORT_JOB)
        self.assertIn("          ref: " + self.env["SOURCE_COMMIT"], EXPORT_JOB)
        self.assertIn("          fail-on-cache-miss: true", EXPORT_JOB)
        self.assertIn("          retention-days: 1", EXPORT_JOB)
        self.assertNotRegex(EXPORT_JOB, r"secrets\.|id-token:|actions: write|cache/save@|restore-keys:")
        self.assertNotRegex(EXPORT_JOB, r"run:.*(?:cargo|rustup|xcodebuild|prepare-signal-ffi)")
        self.assertNotIn("if: always()", EXPORT_JOB)
        self.assertEqual(EXPORT_JOB.count("uses: actions/cache/restore@"), 1)
        self.assertEqual(EXPORT_JOB.count("uses: actions/upload-artifact@"), 1)


if __name__ == "__main__":
    unittest.main()
