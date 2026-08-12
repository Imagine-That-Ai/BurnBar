#!/usr/bin/env python3

from __future__ import annotations

import hashlib
import json
import os
import subprocess
import tempfile
import unittest
from pathlib import Path


SCRIPT = Path(__file__).with_name("create-openburnbar-direct-release-receipt.py")
COMMIT = "a" * 40
TREE = "b" * 40
TEAM = "4Y367DF25B"
APP_NOTARY_ID = "11111111-2222-3333-4444-555555555555"
DMG_NOTARY_ID = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"


class ReceiptWriterTests(unittest.TestCase):
    def setUp(self) -> None:
        self.tempdir = tempfile.TemporaryDirectory(prefix="openburnbar-direct-receipt-")
        self.root = Path(self.tempdir.name)
        self.output = self.root / "release-receipt.json"
        self.signing_receipt = self.root / "signing.json"
        self.app_notary = self.root / "app-notary.json"
        self.dmg_notary = self.root / "dmg-notary.json"
        self.dmg = self.root / "OpenBurnBar-1.0.34-macOS.dmg"
        self.zip = self.root / "OpenBurnBar-1.0.34-macOS.zip"
        self.app_submission = b"pre-staple app notary zip"
        self.dmg_submission = b"pre-staple dmg"
        self.signing_receipt.write_text(
            json.dumps(
                {
                    "schemaVersion": 1,
                    "distribution": "developer-id",
                    "teamId": TEAM,
                    "appGroup": "group.com.openburnbar.app",
                    "keychainGroup": f"{TEAM}.com.openburnbar.app",
                    "host": {
                        "bundleIdentifier": "com.openburnbar.app",
                        "profileExpiration": "2099-08-12T00:00:00Z",
                        "profileSha256": "c" * 64,
                        "signature": {
                            "authority": "Developer ID Application",
                            "hardenedRuntime": True,
                            "libraryValidation": True,
                            "secureTimestamp": True,
                        },
                    },
                    "safariExtension": {
                        "bundleIdentifier": "com.openburnbar.app.safari-extension",
                        "profileExpiration": "2099-08-12T00:00:00Z",
                        "profileSha256": "d" * 64,
                        "signature": {
                            "authority": "Developer ID Application",
                            "hardenedRuntime": True,
                            "libraryValidation": True,
                        },
                    },
                    "verification": {
                        "embeddedProfilesByteEqual": True,
                        "profileCertificateMembership": True,
                        "strictDeepNestedSignatures": True,
                        "getTaskAllow": False,
                        "platform": "OSX",
                    },
                    "secret": "PRIVATE KEY MUST NOT SURVIVE",
                }
            ),
            encoding="utf-8",
        )
        self.app_notary.write_text(
            json.dumps(
                {
                    "schemaVersion": 1,
                    "artifact": {
                        "fileName": "OpenBurnBar-1.0.34-app-notary.zip",
                        "sha256": hashlib.sha256(self.app_submission).hexdigest(),
                        "sizeBytes": len(self.app_submission),
                    },
                    "submission": {"id": APP_NOTARY_ID, "status": "Accepted"},
                    "secret": "PRIVATE KEY MUST NOT SURVIVE",
                }
            ),
            encoding="utf-8",
        )
        self.dmg_notary.write_text(
            json.dumps(
                {
                    "schemaVersion": 1,
                    "artifact": {
                        "fileName": self.dmg.name,
                        "sha256": hashlib.sha256(self.dmg_submission).hexdigest(),
                        "sizeBytes": len(self.dmg_submission),
                    },
                    "submission": {"id": DMG_NOTARY_ID, "status": "Accepted"},
                    "issuer": "secret issuer",
                }
            ),
            encoding="utf-8",
        )
        self.dmg.write_bytes(b"signed stapled dmg")
        self.zip.write_bytes(b"stapled app zip")

    def tearDown(self) -> None:
        self.tempdir.cleanup()

    def command(self) -> list[str]:
        return [
            "python3",
            str(SCRIPT),
            "--output",
            str(self.output),
            "--candidate-commit",
            COMMIT,
            "--candidate-tree",
            TREE,
            "--version",
            "1.0.34",
            "--build",
            "134",
            "--team-id",
            TEAM,
            "--signing-receipt",
            str(self.signing_receipt),
            "--app-notary-result",
            str(self.app_notary),
            "--app-notary-artifact-name",
            "OpenBurnBar-1.0.34-app-notary.zip",
            "--app-notary-artifact-sha256",
            hashlib.sha256(self.app_submission).hexdigest(),
            "--app-notary-artifact-size",
            str(len(self.app_submission)),
            "--dmg-notary-result",
            str(self.dmg_notary),
            "--dmg-notary-artifact-name",
            self.dmg.name,
            "--dmg-notary-artifact-sha256",
            hashlib.sha256(self.dmg_submission).hexdigest(),
            "--dmg-notary-artifact-size",
            str(len(self.dmg_submission)),
            "--artifact",
            "dmg",
            str(self.dmg),
            "--artifact",
            "zip",
            str(self.zip),
            "--smoke-script",
            "scripts/ci/smoke-openburnbar-release-dmg.sh",
        ]

    def run_writer(self, command: list[str] | None = None) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            command or self.command(),
            capture_output=True,
            text=True,
            check=False,
        )

    def test_writes_sanitized_candidate_and_artifact_bound_receipt(self) -> None:
        result = self.run_writer()
        self.assertEqual(result.returncode, 0, result.stderr)
        receipt = json.loads(self.output.read_text(encoding="utf-8"))
        self.assertEqual(receipt["candidate"], {"commit": COMMIT, "tree": TREE})
        self.assertEqual(receipt["artifacts"]["dmg"]["sha256"], hashlib.sha256(self.dmg.read_bytes()).hexdigest())
        self.assertEqual(
            receipt["notarization"]["app"]["submittedArtifact"]["sha256"],
            hashlib.sha256(self.app_submission).hexdigest(),
        )
        self.assertEqual(
            receipt["notarization"]["dmg"]["submittedArtifact"]["sha256"],
            hashlib.sha256(self.dmg_submission).hexdigest(),
        )
        self.assertEqual(
            receipt["mountedDmgSmoke"],
            {
                "artifactSha256": hashlib.sha256(self.dmg.read_bytes()).hexdigest(),
                "script": "scripts/ci/smoke-openburnbar-release-dmg.sh",
                "status": "passed",
            },
        )
        serialized = self.output.read_text(encoding="utf-8")
        self.assertNotIn("PRIVATE KEY", serialized)
        self.assertNotIn("secret issuer", serialized)
        self.assertEqual(os.stat(self.output).st_mode & 0o777, 0o600)

    def test_rejects_unaccepted_notarization(self) -> None:
        self.app_notary.write_text(
            json.dumps(
                {
                    "artifact": {
                        "fileName": "OpenBurnBar-1.0.34-app-notary.zip",
                        "sha256": hashlib.sha256(self.app_submission).hexdigest(),
                        "sizeBytes": len(self.app_submission),
                    },
                    "submission": {"id": APP_NOTARY_ID, "status": "Invalid"},
                }
            ),
            encoding="utf-8",
        )
        result = self.run_writer()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("status must be 'Accepted'", result.stderr)

    def test_rejects_candidate_identity_mismatch_shape(self) -> None:
        command = self.command()
        command[command.index(COMMIT)] = "short"
        result = self.run_writer(command)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("candidate commit must be a full lowercase Git SHA", result.stderr)

    def test_rejects_team_mismatch(self) -> None:
        signing = json.loads(self.signing_receipt.read_text(encoding="utf-8"))
        signing["teamId"] = "AAAAAAAAAA"
        self.signing_receipt.write_text(json.dumps(signing), encoding="utf-8")
        result = self.run_writer()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("signing receipt team ID does not match", result.stderr)

    def test_rejects_duplicate_artifact_kind(self) -> None:
        command = self.command() + ["--artifact", "dmg", str(self.zip)]
        result = self.run_writer(command)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("duplicate release artifact kind: dmg", result.stderr)

    def test_rejects_symlinked_artifact(self) -> None:
        link = self.root / "release-link.dmg"
        link.symlink_to(self.dmg)
        command = self.command()
        command[command.index(str(self.dmg))] = str(link)
        result = self.run_writer(command)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("release artifact must be a real file", result.stderr)

    def test_rejects_reused_artifact_path(self) -> None:
        command = self.command()
        zip_path_index = command.index(str(self.zip))
        command[zip_path_index] = str(self.dmg)
        result = self.run_writer(command)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("release artifact path is reused by multiple kinds", result.stderr)

    def test_rejects_invalid_submitted_artifact_digest(self) -> None:
        command = self.command()
        digest_index = command.index("--app-notary-artifact-sha256") + 1
        command[digest_index] = "invalid"
        result = self.run_writer(command)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("submitted artifact SHA-256 is invalid", result.stderr)

    def test_rejects_notary_receipt_artifact_binding_mismatch(self) -> None:
        receipt = json.loads(self.app_notary.read_text(encoding="utf-8"))
        receipt["artifact"]["sha256"] = "f" * 64
        self.app_notary.write_text(json.dumps(receipt), encoding="utf-8")
        result = self.run_writer()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("submitted artifact binding does not match", result.stderr)

    def test_rejects_noncanonical_smoke_script(self) -> None:
        command = self.command()
        command[command.index("scripts/ci/smoke-openburnbar-release-dmg.sh")] = "echo passed"
        result = self.run_writer(command)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("must be the canonical release smoke verifier", result.stderr)

    def test_refuses_preexisting_or_symlinked_output(self) -> None:
        self.output.write_text("preserve\n", encoding="utf-8")
        result = self.run_writer()
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.output.read_text(encoding="utf-8"), "preserve\n")

        self.output.unlink()
        protected = self.root / "protected.json"
        protected.write_text("protected\n", encoding="utf-8")
        self.output.symlink_to(protected)
        result = self.run_writer()
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(protected.read_text(encoding="utf-8"), "protected\n")


if __name__ == "__main__":
    unittest.main()
