from __future__ import annotations

import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]


class VerifyOpenBurnBarMASReleaseWiringTests(unittest.TestCase):
    def test_release_builder_uses_exact_selectors_and_unified_artifact_verifier(self) -> None:
        script = (ROOT / "scripts/build-macos-app-store-release.sh").read_text()
        self.assertGreaterEqual(script.count("select-openburnbar-mas-artifact.py"), 4)
        self.assertGreaterEqual(script.count("verify-openburnbar-mas-artifact.sh"), 2)
        self.assertNotIn('find "$export_path"', script)
        self.assertNotIn('find "$export_inspection"', script)
        self.assertIn("OPENBURNBAR_CANDIDATE_COMMIT", script)
        self.assertIn("OPENBURNBAR_CANDIDATE_TREE", script)
        self.assertIn(
            "Mac App Store archive/export requires full lowercase "
            "OPENBURNBAR_CANDIDATE_COMMIT and OPENBURNBAR_CANDIDATE_TREE",
            script,
        )
        self.assertIn(
            "Mac App Store archive/export requires a clean exact-candidate checkout",
            script,
        )
        safari_ci = (
            "openburnbar_without_candidate_git_environment \\\n  bash scripts/test-openburnbar-safari-extension.sh"
        )
        self.assertEqual(script.count("verify_exact_candidate_state"), 3)
        self.assertLess(
            script.index("verify_exact_candidate_state\n"),
            script.index(safari_ci),
        )
        self.assertLess(
            script.index(safari_ci),
            script.index(
                "verify_exact_candidate_state",
                script.index(safari_ci),
            ),
        )
        self.assertLess(
            script.index("OPENBURNBAR_CANDIDATE_COMMIT"),
            script.index("xcodebuild archive"),
        )
        self.assertIn("upload-openburnbar-mas-and-verify.sh", script)
        self.assertIn("artifact-receipt", script)
        self.assertIn("mas-archive-export-receipt.json", script)
        self.assertIn("resolve_fresh_release_output_dir", script)
        self.assertIn("create_fresh_release_output_dir", script)
        self.assertIn('"Mac App Store release directory"', script)
        self.assertNotIn('mkdir -p "$release_dir"', script)
        self.assertNotIn('chmod 700 "$release_dir"', script)
        self.assertNotIn('rm -rf "$release_dir"', script)
        self.assertNotIn('rm -rf "$export_inspection"', script)
        self.assertIn(
            "Mac App Store export inspection path must be fresh",
            script,
        )
        self.assertIn('--archive-app "$app_path"', script)
        self.assertIn('--export-inspection "$export_inspection"', script)
        self.assertIn('--exported-app "$exported_app_path"', script)
        self.assertLess(
            script.index("artifact-receipt"),
            script.rindex('if [[ "$upload" == "1" ]]'),
        )
        self.assertIn("unset APP_STORE_ASC_KEY_PATH", script)
        self.assertIn('APP_STORE_ASC_KEY_P8="$asc_key_payload"', script)
        self.assertIn("App Store upload requires an App Store Connect key ID", script)
        self.assertIn("App Store upload requires numeric OPENBURNBAR_ASC_APPLE_ID", script)
        for command in (
            "bash scripts/test-openburnbar-safari-extension.sh",
            "bash scripts/prepare-openburnbar-app-swiftpm.sh",
            "xcodebuild archive",
            "xcodebuild -exportArchive",
        ):
            self.assertIn(
                "openburnbar_without_candidate_git_environment \\\n  " + command,
                script,
            )

        swiftpm = (ROOT / "scripts/prepare-openburnbar-app-swiftpm.sh").read_text(encoding="utf-8")
        self.assertIn("unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE", swiftpm)

    def test_readiness_uses_same_locked_source_preparation_lifecycle(self) -> None:
        script = (ROOT / "scripts/verify-macos-app-store-readiness.sh").read_text()
        required = (
            "libsignal-swift-compat.sh",
            "openburnbar_prepare_libsignal_swift_compat",
            "openburnbar_restore_libsignal_swift_compat",
            "prepare-openburnbar-app-swiftpm.sh",
            "openburnbar_prepare_google_sign_in_macos_compat",
            "openburnbar_restore_google_sign_in_macos_compat",
            "-disableAutomaticPackageResolution",
            "-onlyUsePackageVersionsFromResolvedFile",
            "select-openburnbar-mas-artifact.py",
        )
        for value in required:
            self.assertIn(value, script)

    def test_upload_helper_waits_for_delivery_and_exact_mac_build_readback(self) -> None:
        script = (ROOT / "scripts/ci/upload-openburnbar-mas-and-verify.sh").read_text()
        self.assertIn("--delivery-id", script)
        self.assertIn("--apple-id", script)
        self.assertIn("--bundle-version", script)
        self.assertIn("--bundle-short-version-string", script)
        self.assertIn("--platform macos", script)
        self.assertGreaterEqual(script.count("--wait"), 2)
        self.assertIn("API_PRIVATE_KEYS_DIR", script)
        self.assertIn("chmod 700", script)
        self.assertIn("chmod 600", script)
        self.assertIn("evidence directory must not already exist", script)
        self.assertIn("evidence directory must be an absolute fresh path", script)
        self.assertIn("capture_exclusive_response", script)

    def test_artifact_verifier_checks_host_appex_profiles_and_installer(self) -> None:
        script = (ROOT / "scripts/ci/verify-openburnbar-mas-artifact.sh").read_text()
        required = (
            "--deep --strict",
            "Apple Distribution",
            "TeamIdentifier",
            '["OSX"]',
            "ExpirationDate",
            "com.openburnbar.app.safari-extension",
            "group.com.openburnbar.app",
            "keychain-access-groups",
            "get-task-allow",
            "verify-signing-profile-certificate.sh",
            "verify-openburnbar-safari-extension.sh",
            "pkgutil --check-signature",
            "spctl -a -vv -t install",
        )
        for value in required:
            self.assertIn(value, script)

    def test_installed_receipt_verifier_is_candidate_bound(self) -> None:
        script = (ROOT / "scripts/ci/verify-openburnbar-mas-installed-receipt.py").read_text()
        self.assertIn("_MASReceipt", script)
        self.assertIn("candidateCommit", script)
        self.assertIn("candidateTree", script)
        self.assertIn("receiptFileSha256", script)
        self.assertIn('"storeReceiptCertification": "HOLD"', script)
        self.assertIn(
            '"receiptCryptographicVerification": "HOLD-unavailable"',
            script,
        )
        self.assertIn('"platform": "MAC_OS"', script)
        self.assertIn("processingReceiptSha256", script)
        self.assertIn("load_processing_receipt", script)

        lifecycle = (ROOT / "scripts/ci/verify-openburnbar-mas-installed-candidate.sh").read_text()
        self.assertIn("verify-openburnbar-mas-artifact.sh", lifecycle)
        self.assertIn("verify-openburnbar-mas-installed-receipt.py", lifecycle)
        self.assertIn("--processing-receipt", lifecycle)
        self.assertIn("must not already exist", lifecycle)


if __name__ == "__main__":
    unittest.main()
