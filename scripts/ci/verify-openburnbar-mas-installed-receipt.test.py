from __future__ import annotations

import importlib.util
import json
import os
import plistlib
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "scripts/ci/verify-openburnbar-mas-installed-receipt.py"
SPEC = importlib.util.spec_from_file_location("verify_openburnbar_mas_receipt", SCRIPT)
if SPEC is None or SPEC.loader is None:
    raise RuntimeError(f"cannot load {SCRIPT}")
MODULE = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = MODULE
SPEC.loader.exec_module(MODULE)


class VerifyInstalledMASReceiptTests(unittest.TestCase):
    commit = "1" * 40
    tree = "2" * 40

    def app(self) -> tuple[Path, Path]:
        root = Path(self.enterContext(tempfile.TemporaryDirectory()))
        app = root / "OpenBurnBar.app"
        info = app / "Contents" / "Info.plist"
        receipt = app / "Contents" / "_MASReceipt" / "receipt"
        receipt.parent.mkdir(parents=True)
        with info.open("wb") as file:
            plistlib.dump(
                {
                    "CFBundleIdentifier": "com.openburnbar.app",
                    "CFBundleShortVersionString": "1.2.3",
                    "CFBundleVersion": "456",
                },
                file,
            )
        receipt.write_bytes(b"opaque-app-store-receipt")
        return app, receipt

    def processing_receipt(self, root: Path) -> Path:
        path = root / "processing.json"
        path.write_text(
            json.dumps(
                {
                    "schemaVersion": 1,
                    "platform": "MAC_OS",
                    "status": "processed",
                    "processedStatus": "complete",
                    "readbackStatus": "valid",
                    "deliveryId": "DELIVERY-1",
                    "appAppleId": "1234567890",
                    "bundleIdentifier": "com.openburnbar.app",
                    "version": "1.2.3",
                    "build": "456",
                    "candidate": {"commit": self.commit, "tree": self.tree},
                    "artifacts": {
                        "archiveTreeSha256": "a" * 64,
                        "hostAppTreeSha256": "b" * 64,
                        "safariExtensionTreeSha256": "c" * 64,
                        "packageSha256": "d" * 64,
                    },
                    "responses": {
                        "validationSha256": "e" * 64,
                        "uploadSha256": "f" * 64,
                        "deliveryStatusSha256": "1" * 64,
                        "exactBuildReadbackSha256": "2" * 64,
                    },
                    "readbackIdentity": {
                        "platform": "MAC_OS",
                        "appAppleId": "1234567890",
                        "bundleIdentifier": "com.openburnbar.app",
                        "version": "1.2.3",
                        "build": "456",
                    },
                }
            )
            + "\n"
        )
        path.chmod(0o600)
        return path

    def test_binds_real_receipt_to_candidate_and_metadata(self) -> None:
        app, _ = self.app()
        result = MODULE.verify(
            app,
            expected_version="1.2.3",
            expected_build="456",
            candidate_commit=self.commit,
            candidate_tree=self.tree,
        )
        self.assertEqual(result["platform"], "MAC_OS")
        self.assertEqual(result["candidateCommit"], self.commit)
        self.assertEqual(
            result["receiptFileSize"],
            len(b"opaque-app-store-receipt"),
        )
        self.assertEqual(result["status"], "installed-receipt-file-observed")
        self.assertTrue(result["receiptFilePresent"])
        self.assertEqual(result["storeReceiptCertification"], "HOLD")
        self.assertEqual(
            result["receiptCryptographicVerification"],
            "HOLD-unavailable",
        )

    def test_rejects_empty_receipt(self) -> None:
        app, receipt = self.app()
        receipt.write_bytes(b"")
        with self.assertRaisesRegex(ValueError, "empty"):
            MODULE.verify(
                app,
                expected_version="1.2.3",
                expected_build="456",
                candidate_commit=self.commit,
                candidate_tree=self.tree,
            )

    def test_rejects_symlink_receipt(self) -> None:
        app, receipt = self.app()
        receipt.unlink()
        target = receipt.parent / "other"
        target.write_bytes(b"receipt")
        receipt.symlink_to(target)
        with self.assertRaisesRegex(ValueError, "real regular file"):
            MODULE.verify(
                app,
                expected_version="1.2.3",
                expected_build="456",
                candidate_commit=self.commit,
                candidate_tree=self.tree,
            )

    def test_rejects_wrong_candidate_binding(self) -> None:
        app, _ = self.app()
        with self.assertRaisesRegex(ValueError, "candidate commit"):
            MODULE.verify(
                app,
                expected_version="1.2.3",
                expected_build="456",
                candidate_commit="not-a-commit",
                candidate_tree=self.tree,
            )

    def test_cli_writes_owner_only_evidence(self) -> None:
        app, _ = self.app()
        output = app.parent / "receipt-evidence.json"
        processing = self.processing_receipt(app.parent)
        subprocess.run(
            [
                sys.executable,
                str(SCRIPT),
                "--app",
                str(app),
                "--processing-receipt",
                str(processing),
                "--output",
                str(output),
            ],
            check=True,
        )
        self.assertEqual(os.stat(output).st_mode & 0o777, 0o600)
        result = json.loads(output.read_text())
        self.assertEqual(result["candidateCommit"], self.commit)
        self.assertEqual(
            result["appStoreConnectProcessingEvidence"]["processingReceiptSha256"],
            MODULE.sha256(processing),
        )

    def test_rejects_tampered_processing_identity(self) -> None:
        app, _ = self.app()
        processing = self.processing_receipt(app.parent)
        value = json.loads(processing.read_text())
        value["readbackIdentity"]["build"] = "999"
        processing.write_text(json.dumps(value) + "\n")
        processing.chmod(0o600)
        with self.assertRaisesRegex(ValueError, "returned build identity"):
            MODULE.verify_processed_install(app, processing)

    def test_rejects_group_readable_processing_receipt(self) -> None:
        app, _ = self.app()
        processing = self.processing_receipt(app.parent)
        processing.chmod(0o640)
        with self.assertRaisesRegex(ValueError, "group/world"):
            MODULE.verify_processed_install(app, processing)

    def test_evidence_writer_refuses_overwrite_and_symlink(self) -> None:
        root = Path(self.enterContext(tempfile.TemporaryDirectory()))
        output = root / "receipt.json"
        output.write_text("preserve\n")
        with self.assertRaises(FileExistsError):
            MODULE.write_owner_only_json(output, {"overwrite": True})
        self.assertEqual(output.read_text(), "preserve\n")
        link = root / "link.json"
        link.symlink_to(output)
        with self.assertRaises(OSError):
            MODULE.write_owner_only_json(link, {"follow": True})
        self.assertEqual(output.read_text(), "preserve\n")


if __name__ == "__main__":
    unittest.main()
