#!/usr/bin/env python3

from __future__ import annotations

import plistlib
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path


SCRIPT = Path(__file__).with_name("verify-signing-profile-certificate.py")


class SigningProfileCertificateTests(unittest.TestCase):
    def run_gate(self, certificates: list[bytes], signer: bytes) -> subprocess.CompletedProcess[str]:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            profile = root / "profile.plist"
            signer_path = root / "signer.der"
            with profile.open("wb") as file:
                plistlib.dump({"DeveloperCertificates": certificates}, file)
            signer_path.write_bytes(signer)
            return subprocess.run(
                [sys.executable, str(SCRIPT), str(profile), str(signer_path)],
                check=False,
                capture_output=True,
                text=True,
            )

    def test_accepts_signer_present_in_profile(self) -> None:
        result = self.run_gate([b"older-certificate", b"active-certificate"], b"active-certificate")

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("PASS", result.stdout)

    def test_rejects_signer_missing_from_profile(self) -> None:
        result = self.run_gate([b"different-certificate"], b"active-certificate")

        self.assertEqual(result.returncode, 1)
        self.assertIn("does not authorize", result.stderr)
        self.assertIn("signerSHA256=", result.stderr)
        self.assertIn("allowedSHA256=", result.stderr)

    def test_rejects_profile_without_certificate_allowlist(self) -> None:
        result = self.run_gate([], b"active-certificate")

        self.assertEqual(result.returncode, 1)
        self.assertIn("no DeveloperCertificates", result.stderr)


if __name__ == "__main__":
    unittest.main()
