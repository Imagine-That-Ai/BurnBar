#!/usr/bin/env python3

from __future__ import annotations

import importlib.util
import plistlib
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path


SCRIPT = Path(__file__).with_name("verify-signing-profile-certificate.py")
SPEC = importlib.util.spec_from_file_location("verify_signing_profile_certificate", SCRIPT)
if SPEC is None or SPEC.loader is None:
    raise RuntimeError(f"Unable to load verifier module at {SCRIPT}")
VERIFIER = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(VERIFIER)


class SigningProfileCertificateTests(unittest.TestCase):
    def run_gate(
        self,
        certificates: list[bytes],
        signer: bytes,
        *extra_args: str,
    ) -> subprocess.CompletedProcess[str]:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            profile = root / "profile.plist"
            signer_path = root / "signer.der"
            with profile.open("wb") as file:
                plistlib.dump({"DeveloperCertificates": certificates}, file)
            signer_path.write_bytes(signer)
            return subprocess.run(
                [sys.executable, str(SCRIPT), str(profile), str(signer_path), *extra_args],
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

    def test_legacy_v1029_exception_requires_the_exact_tuple(self) -> None:
        exact = {
            "release_version": "1.0.29",
            "artifact_sha256": VERIFIER.LEGACY_V1029_DMG_SHA256,
            "signer_sha256": VERIFIER.LEGACY_V1029_SIGNER_SHA256,
            "allowed_sha256": (VERIFIER.LEGACY_V1029_PROFILE_CERTIFICATE_SHA256,),
        }

        self.assertTrue(VERIFIER.allows_legacy_v1029_profile_membership_exception(**exact))

        mutations = (
            {**exact, "release_version": "1.0.30"},
            {**exact, "artifact_sha256": "0" * 64},
            {**exact, "signer_sha256": "0" * 64},
            {**exact, "allowed_sha256": ("0" * 64,)},
            {
                **exact,
                "allowed_sha256": (
                    VERIFIER.LEGACY_V1029_PROFILE_CERTIFICATE_SHA256,
                    "0" * 64,
                ),
            },
            {**exact, "artifact_sha256": None},
        )
        for mutation in mutations:
            with self.subTest(mutation=mutation):
                self.assertFalse(
                    VERIFIER.allows_legacy_v1029_profile_membership_exception(**mutation)
                )

    def test_rejects_partial_legacy_context(self) -> None:
        result = self.run_gate(
            [b"different-certificate"],
            b"active-certificate",
            "--artifact-sha256",
            VERIFIER.LEGACY_V1029_DMG_SHA256,
        )

        self.assertEqual(result.returncode, 2)
        self.assertIn("must be provided together", result.stderr)


if __name__ == "__main__":
    unittest.main()
