#!/usr/bin/env python3

from __future__ import annotations

import hashlib
import json
import os
import plistlib
import subprocess
import sys
import tempfile
import unittest
from datetime import UTC, datetime, timedelta
from pathlib import Path


SCRIPT = Path(__file__).with_name("create-openburnbar-development-receipt.py")
COMMIT = "a" * 40
TREE = "b" * 40
TEAM = "A1B2C3D4E5"
IDENTITY = "Apple Development: OpenBurnBar Fixture (CERT123456)"
CERTIFICATE = b"openburnbar-development-certificate"
CERTIFICATE_SHA256 = hashlib.sha256(CERTIFICATE).hexdigest().upper()
CURRENT_MAC_UDID = "AAAAAAAA-BBBBBBBB"


def write_profile(
    path: Path,
    *,
    bundle_identifier: str,
    uuid: str,
    certificate: bytes = CERTIFICATE,
    devices: list[str] | None = None,
    get_task_allow: bool | None = None,
) -> None:
    entitlements: dict[str, object] = {
        "com.apple.application-identifier": f"{TEAM}.{bundle_identifier}",
        "com.apple.developer.team-identifier": TEAM,
        "com.apple.security.application-groups": [f"{TEAM}.*"],
        "keychain-access-groups": [f"{TEAM}.*"],
    }
    if get_task_allow is not None:
        entitlements["com.apple.security.get-task-allow"] = get_task_allow
    with path.open("wb") as file:
        plistlib.dump(
            {
                "UUID": uuid,
                "Name": f"Fixture {bundle_identifier}",
                "TeamIdentifier": [TEAM],
                "Platform": ["OSX"],
                "ProvisionedDevices": devices or [CURRENT_MAC_UDID],
                "ExpirationDate": datetime.now(UTC) + timedelta(days=30),
                "DeveloperCertificates": [certificate],
                "Entitlements": entitlements,
            },
            file,
        )


class DevelopmentReceiptTests(unittest.TestCase):
    def run_receipt(
        self,
        root: Path,
        *,
        identity: str = IDENTITY,
        candidate_commit: str = COMMIT,
    ) -> subprocess.CompletedProcess[str]:
        app = root / "OpenBurnBar.app"
        host_profile = root / "host.provisionprofile"
        safari_profile = root / "safari.provisionprofile"
        output = root / "receipt.json"
        (app / "Contents" / "MacOS").mkdir(parents=True)
        (app / "Contents" / "MacOS" / "OpenBurnBar").write_bytes(b"binary\n")
        write_profile(
            host_profile,
            bundle_identifier="com.openburnbar.app",
            uuid="HOST-PROFILE-UUID",
        )
        write_profile(
            safari_profile,
            bundle_identifier="com.openburnbar.app.safari-extension",
            uuid="SAFARI-PROFILE-UUID",
            get_task_allow=True,
        )
        embedded_host_profile = app / "Contents" / "embedded.provisionprofile"
        embedded_safari_profile = (
            app / "Contents" / "PlugIns" / "OpenBurnBarSafariExtension.appex" / "Contents" / "embedded.provisionprofile"
        )
        embedded_safari_profile.parent.mkdir(parents=True)
        embedded_host_profile.write_bytes(host_profile.read_bytes())
        embedded_safari_profile.write_bytes(safari_profile.read_bytes())
        return subprocess.run(
            [
                sys.executable,
                str(SCRIPT),
                "--output",
                str(output),
                "--candidate-commit",
                candidate_commit,
                "--candidate-tree",
                TREE,
                "--app",
                str(app),
                "--host-profile",
                str(host_profile),
                "--safari-profile",
                str(safari_profile),
                "--team-id",
                TEAM,
                "--signing-identity",
                identity,
                "--signing-certificate-sha256",
                CERTIFICATE_SHA256,
                "--current-mac-provisioning-udid",
                CURRENT_MAC_UDID,
                "--version",
                "1.2.3",
                "--build",
                "42",
            ],
            check=False,
            capture_output=True,
            text=True,
        )

    def test_writes_candidate_artifact_and_profile_bound_receipt(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            result = self.run_receipt(root)
            self.assertEqual(result.returncode, 0, result.stderr)
            receipt = json.loads((root / "receipt.json").read_text())
            self.assertEqual(receipt["schemaVersion"], 2)
            self.assertEqual(receipt["candidate"], {"commit": COMMIT, "tree": TREE})
            self.assertEqual(receipt["artifact"]["regularFileCount"], 3)
            self.assertEqual(receipt["artifact"]["symlinkCount"], 0)
            self.assertRegex(receipt["artifact"]["treeSha256"], r"^[0-9a-f]{64}$")
            self.assertEqual(receipt["signing"]["identity"], IDENTITY)
            self.assertEqual(
                receipt["signing"]["certificateSha256"],
                CERTIFICATE_SHA256,
            )
            self.assertRegex(
                receipt["signing"]["hostProfileSha256"],
                r"^[0-9a-f]{64}$",
            )
            self.assertEqual(
                receipt["profiles"]["host"],
                {
                    "bundleIdentifier": "com.openburnbar.app",
                    "currentMacAuthorized": True,
                    "expirationDate": receipt["profiles"]["host"]["expirationDate"],
                    "name": "Fixture com.openburnbar.app",
                    "profileGetTaskAllow": "absent",
                    "provisionedDeviceCount": 1,
                    "sha256": receipt["signing"]["hostProfileSha256"],
                    "signingCertificateMember": True,
                    "uuid": "HOST-PROFILE-UUID",
                },
            )
            self.assertEqual(
                receipt["profiles"]["safari"]["bundleIdentifier"],
                "com.openburnbar.app.safari-extension",
            )
            self.assertEqual(
                receipt["profiles"]["safari"]["profileGetTaskAllow"],
                "enabled",
            )
            serialized = (root / "receipt.json").read_text()
            self.assertNotIn(str(root), serialized)
            self.assertNotIn("host-profile", serialized)
            self.assertNotIn("safari-profile", serialized)
            self.assertEqual(os.stat(root / "receipt.json").st_mode & 0o777, 0o600)

    def test_rejects_wrong_candidate_or_identity(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            result = self.run_receipt(Path(directory), candidate_commit="short")
            self.assertEqual(result.returncode, 1)
            self.assertIn("candidate commit", result.stderr)
        with tempfile.TemporaryDirectory() as directory:
            result = self.run_receipt(
                Path(directory),
                identity=f"Developer ID Application: Fixture ({TEAM})",
            )
            self.assertEqual(result.returncode, 1)
            self.assertIn("Apple Development identity", result.stderr)

    def test_accepts_internal_bundle_symlink_and_hashes_target_text(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            app = root / "OpenBurnBar.app"
            frameworks = app / "Contents" / "Frameworks" / "Fixture.framework"
            version = frameworks / "Versions" / "A"
            version.mkdir(parents=True)
            (version / "Fixture").write_bytes(b"framework\n")
            (frameworks / "Versions" / "Current").symlink_to("A")
            (frameworks / "Fixture").symlink_to("Versions/Current/Fixture")
            result = self.run_receipt(root)
            self.assertEqual(result.returncode, 0, result.stderr)
            receipt = json.loads((root / "receipt.json").read_text())
            self.assertEqual(receipt["artifact"]["symlinkCount"], 2)

    def test_rejects_escaping_symlinked_artifact_entries(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            app = root / "OpenBurnBar.app" / "Contents"
            app.mkdir(parents=True)
            target = root / "outside"
            target.write_text("outside")
            (app / "link").symlink_to(target)
            write_profile(
                root / "host.provisionprofile",
                bundle_identifier="com.openburnbar.app",
                uuid="HOST-PROFILE-UUID",
            )
            write_profile(
                root / "safari.provisionprofile",
                bundle_identifier="com.openburnbar.app.safari-extension",
                uuid="SAFARI-PROFILE-UUID",
            )
            result = subprocess.run(
                [
                    sys.executable,
                    str(SCRIPT),
                    "--output",
                    str(root / "receipt.json"),
                    "--candidate-commit",
                    COMMIT,
                    "--candidate-tree",
                    TREE,
                    "--app",
                    str(root / "OpenBurnBar.app"),
                    "--host-profile",
                    str(root / "host.provisionprofile"),
                    "--safari-profile",
                    str(root / "safari.provisionprofile"),
                    "--team-id",
                    TEAM,
                    "--signing-identity",
                    IDENTITY,
                    "--signing-certificate-sha256",
                    CERTIFICATE_SHA256,
                    "--current-mac-provisioning-udid",
                    CURRENT_MAC_UDID,
                    "--version",
                    "1.2.3",
                    "--build",
                    "42",
                ],
                check=False,
                capture_output=True,
                text=True,
            )
            self.assertEqual(result.returncode, 1)
            self.assertIn("absolute symlink", result.stderr)

    def test_rejects_profile_without_current_mac_or_signing_certificate(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            app = root / "OpenBurnBar.app"
            (app / "Contents" / "MacOS").mkdir(parents=True)
            (app / "Contents" / "MacOS" / "OpenBurnBar").write_bytes(b"binary\n")
            write_profile(
                root / "host.provisionprofile",
                bundle_identifier="com.openburnbar.app",
                uuid="HOST-PROFILE-UUID",
                devices=["DIFFERENT-MAC"],
            )
            write_profile(
                root / "safari.provisionprofile",
                bundle_identifier="com.openburnbar.app.safari-extension",
                uuid="SAFARI-PROFILE-UUID",
            )
            (app / "Contents" / "embedded.provisionprofile").write_bytes((root / "host.provisionprofile").read_bytes())
            embedded_safari_profile = (
                app
                / "Contents"
                / "PlugIns"
                / "OpenBurnBarSafariExtension.appex"
                / "Contents"
                / "embedded.provisionprofile"
            )
            embedded_safari_profile.parent.mkdir(parents=True)
            embedded_safari_profile.write_bytes((root / "safari.provisionprofile").read_bytes())
            result = subprocess.run(
                [
                    sys.executable,
                    str(SCRIPT),
                    "--output",
                    str(root / "receipt.json"),
                    "--candidate-commit",
                    COMMIT,
                    "--candidate-tree",
                    TREE,
                    "--app",
                    str(app),
                    "--host-profile",
                    str(root / "host.provisionprofile"),
                    "--safari-profile",
                    str(root / "safari.provisionprofile"),
                    "--team-id",
                    TEAM,
                    "--signing-identity",
                    IDENTITY,
                    "--signing-certificate-sha256",
                    CERTIFICATE_SHA256,
                    "--current-mac-provisioning-udid",
                    CURRENT_MAC_UDID,
                    "--version",
                    "1.2.3",
                    "--build",
                    "42",
                ],
                check=False,
                capture_output=True,
                text=True,
            )
            self.assertEqual(result.returncode, 1)
            self.assertIn("does not authorize the current Mac", result.stderr)

        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            app = root / "OpenBurnBar.app"
            (app / "Contents" / "MacOS").mkdir(parents=True)
            (app / "Contents" / "MacOS" / "OpenBurnBar").write_bytes(b"binary\n")
            write_profile(
                root / "host.provisionprofile",
                bundle_identifier="com.openburnbar.app",
                uuid="HOST-PROFILE-UUID",
                certificate=b"different-certificate",
            )
            write_profile(
                root / "safari.provisionprofile",
                bundle_identifier="com.openburnbar.app.safari-extension",
                uuid="SAFARI-PROFILE-UUID",
            )
            (app / "Contents" / "embedded.provisionprofile").write_bytes((root / "host.provisionprofile").read_bytes())
            embedded_safari_profile = (
                app
                / "Contents"
                / "PlugIns"
                / "OpenBurnBarSafariExtension.appex"
                / "Contents"
                / "embedded.provisionprofile"
            )
            embedded_safari_profile.parent.mkdir(parents=True)
            embedded_safari_profile.write_bytes((root / "safari.provisionprofile").read_bytes())
            result = subprocess.run(
                [
                    sys.executable,
                    str(SCRIPT),
                    "--output",
                    str(root / "receipt.json"),
                    "--candidate-commit",
                    COMMIT,
                    "--candidate-tree",
                    TREE,
                    "--app",
                    str(app),
                    "--host-profile",
                    str(root / "host.provisionprofile"),
                    "--safari-profile",
                    str(root / "safari.provisionprofile"),
                    "--team-id",
                    TEAM,
                    "--signing-identity",
                    IDENTITY,
                    "--signing-certificate-sha256",
                    CERTIFICATE_SHA256,
                    "--current-mac-provisioning-udid",
                    CURRENT_MAC_UDID,
                    "--version",
                    "1.2.3",
                    "--build",
                    "42",
                ],
                check=False,
                capture_output=True,
                text=True,
            )
            self.assertEqual(result.returncode, 1)
            self.assertIn("does not authorize the signing certificate", result.stderr)

    def test_refuses_preexisting_or_symlinked_output(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            output = root / "receipt.json"
            output.write_text("preserve\n", encoding="utf-8")
            result = self.run_receipt(root)
            self.assertNotEqual(result.returncode, 0)
            self.assertEqual(output.read_text(encoding="utf-8"), "preserve\n")

        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            protected = root / "protected.json"
            protected.write_text("protected\n", encoding="utf-8")
            (root / "receipt.json").symlink_to(protected)
            result = self.run_receipt(root)
            self.assertNotEqual(result.returncode, 0)
            self.assertEqual(protected.read_text(encoding="utf-8"), "protected\n")


if __name__ == "__main__":
    unittest.main()
