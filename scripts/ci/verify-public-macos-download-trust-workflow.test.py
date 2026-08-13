#!/usr/bin/env python3

from __future__ import annotations

import re
import unittest
from pathlib import Path


WORKFLOW = Path(__file__).resolve().parents[2] / ".github" / "workflows" / "public-macos-download-trust.yml"
ENTITLEMENTS = "OpenBurnBarSafariExtension/Resources/OpenBurnBarSafariExtension.entitlements"
DETECTOR_TEST = "scripts/ci/verify-public-macos-download-trust-workflow.test.py"
GOVERNED_PATHS = (
    ENTITLEMENTS,
    ".github/workflows/public-macos-download-trust.yml",
    "scripts/ci/verify-public-macos-download-trust.sh",
    "scripts/ci/verify-public-macos-download-trust.test.sh",
    "scripts/ci/verify-public-macos-download-trust-workflow.test.py",
    "scripts/ci/verify-openburnbar-development-signing.sh",
    "scripts/ci/verify-openburnbar-development-signing.test.sh",
    "scripts/ci/sign-openburnbar-safari-extension.sh",
    "scripts/ci/verify-openburnbar-safari-extension.sh",
    "scripts/ci/verify-openburnbar-safari-extension.test.sh",
    "scripts/ci/verify-openburnbar-safari-extension-layout.py",
    "scripts/ci/verify-signing-profile-certificate.sh",
    "scripts/ci/verify-signing-profile-certificate.py",
    "scripts/ci/verify-signing-profile-certificate.test.py",
    "scripts/ci/verify-apple-release-firebase-config.sh",
    "scripts/ci/verify-apple-release-firebase-config.test.sh",
    "scripts/ci/verify-apple-appcheck-release-artifact.sh",
    "scripts/lib/parse-macos-provisioning-udid.py",
    "scripts/lib/parse-macos-provisioning-udid.test.py",
    "scripts/test-openburnbar-safari-extension.sh",
    DETECTOR_TEST,
    "tools/safari-certification-fixtures/manifest.json",
    "tools/safari-certification-fixtures/server.mjs",
    "tools/safari-certification-fixtures/server.test.mjs",
    "tools/safari-certification-fixtures/verify.mjs",
    "tools/safari-certification-fixtures/verify.test.mjs",
    "tools/safari-certification-fixtures/fixtures/mixed.html",
)


class PublicMacOSDownloadTrustWorkflowTests(unittest.TestCase):
    def test_every_governed_path_triggers_the_shared_detector(self) -> None:
        source = WORKFLOW.read_text(encoding="utf-8")

        detector_patterns = re.findall(
            r"grep -Eq '([^']+)' \"\$changed_paths\"",
            source,
        )

        self.assertEqual(
            len(detector_patterns),
            1,
            "Expected exactly one shared public macOS trust-gate path policy.",
        )
        pattern = detector_patterns[0]
        for path in GOVERNED_PATHS:
            with self.subTest(path=path):
                self.assertIsNotNone(
                    re.fullmatch(pattern, path),
                    f"A {path}-only change must activate trust-gate tests.",
                )
        self.assertEqual(
            source.count("if trust_gate_changed; then"),
            2,
            "PR/merge-group and push detection must both use the shared policy.",
        )

    def test_fixture_verifier_and_transport_suite_are_ci_wired(self) -> None:
        source = WORKFLOW.read_text(encoding="utf-8")

        for command in (
            "node tools/safari-certification-fixtures/verify.mjs",
            "node --test tools/safari-certification-fixtures/*.test.mjs",
        ):
            with self.subTest(command=command):
                self.assertIn(command, source)


if __name__ == "__main__":
    unittest.main()
