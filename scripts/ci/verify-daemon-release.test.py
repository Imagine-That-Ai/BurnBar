#!/usr/bin/env python3
import os
from pathlib import Path
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[2]
VERIFY = ROOT / "scripts/ci/verify-daemon-release.sh"


class DaemonReleaseProofTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="daemon-release-proof-")
        self.addCleanup(self.temp.cleanup)
        self.work = Path(self.temp.name)
        self.binary = self.work / "release binary"
        self.env = os.environ.copy()
        self.write_binary()

    def write_binary(self, output="Usage: OpenBurnBarDaemon", code=0):
        self.binary.write_text(f"#!/bin/bash\nprintf '%s\\n' '{output}'\nexit {code}\n")
        self.binary.chmod(0o700)

    def fake_strings(self, body):
        directory = self.work / "bin"
        directory.mkdir()
        executable = directory / "strings"
        executable.write_text("#!/bin/bash\n" + body + "\n")
        executable.chmod(0o700)
        self.env["PATH"] = str(directory) + os.pathsep + self.env["PATH"]

    def run_verify(self, path=None):
        return subprocess.run(
            ["bash", str(VERIFY), str(path or self.binary)],
            env=self.env,
            capture_output=True,
            text=True,
            timeout=10,
        )

    def assert_rejected(self, path=None):
        result = self.run_verify(path)
        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertNotIn("PASS:", result.stdout)

    def test_real_inspection_accepts_executable_without_escape_hatches(self):
        result = self.run_verify()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("PASS:", result.stdout)

    def test_missing_binary_fails(self):
        self.assert_rejected(self.work / "missing")

    def test_directory_fails(self):
        self.assert_rejected(self.work)

    def test_non_executable_fails(self):
        self.binary.chmod(0o600)
        self.assert_rejected()

    def test_nonzero_help_fails_even_with_expected_text(self):
        self.write_binary(code=17)
        self.assert_rejected()

    def test_empty_help_fails(self):
        self.write_binary(output="")
        self.assert_rejected()

    def test_unrelated_help_fails(self):
        self.write_binary(output="Usage: another executable")
        self.assert_rejected()

    def test_unauthenticated_loopback_flag_fails(self):
        self.write_binary(output="Usage: OpenBurnBarDaemon --gateway-allow-unauthenticated-loopback")
        self.assert_rejected()

    def test_debug_argument_error_fails(self):
        self.write_binary(output="Usage: OpenBurnBarDaemon debugOnlyArgument")
        self.assert_rejected()

    def test_codec_override_in_actual_executable_fails(self):
        with self.binary.open("a") as stream:
            stream.write("OPENBURNBAR_DAEMON_FORCE_NO_CODEC\n")
        self.assert_rejected()

    def test_failed_strings_inspection_fails(self):
        self.fake_strings("exit 19")
        self.assert_rejected()

    def test_large_strings_output_cannot_hide_forbidden_prefix(self):
        self.fake_strings("printf '%s\\n' OPENBURNBAR_DAEMON_FORCE_NO_CODEC\nprintf '%0200000d\\n' 0")
        self.assert_rejected()

    def test_workflow_links_the_product_and_runs_the_verifier(self):
        workflow = (ROOT / ".github/workflows/daemon-pr-gate.yml").read_text()
        self.assertIn("--product OpenBurnBarDaemon", workflow)
        self.assertNotIn("--target OpenBurnBarDaemonExecutable", workflow)
        self.assertIn("--show-bin-path", workflow)
        self.assertIn('bash scripts/ci/verify-daemon-release.sh "$BINARY_DIRECTORY/OpenBurnBarDaemon"', workflow)
        self.assertIn("python3 scripts/ci/verify-daemon-release.test.py", workflow)


if __name__ == "__main__":
    unittest.main()
