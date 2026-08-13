from __future__ import annotations

import importlib.util
import json
import os
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock


ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "scripts/ci/verify-openburnbar-mas-app-store-connect.py"
SPEC = importlib.util.spec_from_file_location("verify_openburnbar_mas_asc", SCRIPT)
if SPEC is None or SPEC.loader is None:
    raise RuntimeError(f"cannot load {SCRIPT}")
MODULE = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = MODULE
SPEC.loader.exec_module(MODULE)


class VerifyOpenBurnBarMASAppStoreConnectTests(unittest.TestCase):
    def root(self) -> Path:
        return Path(self.enterContext(tempfile.TemporaryDirectory()))

    def response(self, root: Path, name: str, value: object) -> Path:
        path = root / name
        path.write_text(json.dumps(value) + "\n")
        return path

    def receipt_args(self, root: Path):
        archive = root / "OpenBurnBar.xcarchive"
        app = archive / "Products" / "Applications" / "OpenBurnBar.app"
        app.mkdir(parents=True)
        (app / "binary").write_bytes(b"app")
        appex = app / "Contents" / "PlugIns" / "OpenBurnBarSafariExtension.appex"
        appex.mkdir(parents=True)
        (appex / "extension-binary").write_bytes(b"appex")
        pkg = root / "OpenBurnBar.pkg"
        pkg.write_bytes(b"package")
        artifact_receipt = root / "mas-archive-export-receipt.json"
        artifact_receipt.write_text(
            json.dumps(
                {
                    "schemaVersion": 1,
                    "platform": "MAC_OS",
                    "status": "archive-export-verified",
                    "candidate": {"commit": "1" * 40, "tree": "2" * 40},
                    "release": {
                        "channel": "mac-app-store",
                        "teamId": "4Y367DF25B",
                        "version": "1.2.3",
                        "build": "456",
                    },
                    "artifacts": {
                        "archiveTreeSha256": MODULE.sha256_tree(archive),
                        "archiveHostAppTreeSha256": MODULE.sha256_tree(app),
                        "archiveSafariExtensionTreeSha256": MODULE.sha256_tree(appex),
                        "exportedHostAppTreeSha256": MODULE.sha256_tree(app),
                        "exportedSafariExtensionTreeSha256": MODULE.sha256_tree(appex),
                        "packageSha256": MODULE.sha256_file(pkg),
                        "packageSize": pkg.stat().st_size,
                    },
                }
            )
            + "\n"
        )
        artifact_receipt.chmod(0o600)
        upload = self.response(
            root,
            "upload.json",
            {"data": {"deliveryId": "DELIVERY-1", "requestId": "REQUEST-1"}},
        )
        validation = self.response(root, "validation.json", {"status": "success"})
        delivery = self.response(root, "delivery.json", {"data": {"status": "Complete"}})
        readback = self.response(
            root,
            "readback.json",
            {
                "data": {
                    "attributes": {
                        "appAppleId": "1234567890",
                        "bundleId": "com.openburnbar.app",
                        "bundleShortVersionString": "1.2.3",
                        "bundleVersion": "456",
                        "platform": "MAC_OS",
                        "processingState": "VALID",
                    }
                }
            },
        )
        return type(
            "Args",
            (),
            {
                "upload_response": upload,
                "validation_response": validation,
                "delivery_status": delivery,
                "build_readback": readback,
                "delivery_id": "DELIVERY-1",
                "app_apple_id": "1234567890",
                "version": "1.2.3",
                "build": "456",
                "candidate_commit": "1" * 40,
                "candidate_tree": "2" * 40,
                "team_id": "4Y367DF25B",
                "artifact_receipt": artifact_receipt,
                "archive": archive,
                "app": app,
                "pkg": pkg,
            },
        )()

    def test_extracts_unique_delivery_and_request_ids(self) -> None:
        root = self.root()
        response = self.response(
            root,
            "upload.json",
            {"data": {"delivery-id": "DELIVERY-1"}, "request-id": "REQUEST-1"},
        )
        result = MODULE.validate_upload(response)
        self.assertEqual(result["deliveryId"], "DELIVERY-1")
        self.assertEqual(result["requestId"], "REQUEST-1")

    def test_rejects_ambiguous_delivery_ids(self) -> None:
        root = self.root()
        response = self.response(
            root,
            "upload.json",
            {"deliveryId": "ONE", "nested": {"delivery-id": "TWO"}},
        )
        with self.assertRaisesRegex(ValueError, "ambiguous delivery ID"):
            MODULE.validate_upload(response)

    def test_rejects_nonterminal_or_failed_status(self) -> None:
        root = self.root()
        processing = self.response(root, "processing.json", {"status": "processing"})
        with self.assertRaisesRegex(ValueError, "accepted/processed"):
            MODULE.validate_terminal_status(processing, "delivery status")
        failed = self.response(root, "failed.json", {"status": "failed"})
        with self.assertRaisesRegex(ValueError, "accepted/processed"):
            MODULE.validate_terminal_status(failed, "delivery status")

    def test_validation_requires_json_without_errors(self) -> None:
        root = self.root()
        good = self.response(root, "good.json", {"success-message": "No errors"})
        result = MODULE.validate_submission_response(good, "validation")
        self.assertIn("responseSha256", result)
        bad = self.response(root, "bad.json", {"errors": [{"message": "invalid"}]})
        with self.assertRaisesRegex(ValueError, "contains errors"):
            MODULE.validate_submission_response(bad, "validation")

    def test_creates_sanitized_candidate_and_artifact_bound_receipt(self) -> None:
        root = self.root()
        args = self.receipt_args(root / "ambiguous")
        result = MODULE.create_receipt(args)
        self.assertEqual(result["platform"], "MAC_OS")
        self.assertEqual(result["status"], "processed")
        self.assertEqual(result["candidate"]["commit"], "1" * 40)
        self.assertEqual(result["artifacts"]["packageSize"], len(b"package"))
        self.assertEqual(len(result["artifacts"]["hostAppTreeSha256"]), 64)
        self.assertEqual(len(result["artifacts"]["safariExtensionTreeSha256"]), 64)
        serialized = json.dumps(result)
        self.assertNotIn("PRIVATE KEY", serialized)
        self.assertNotIn("apiKey", serialized)
        self.assertEqual(result["readbackQuery"]["platform"], "macos")
        self.assertEqual(
            result["readbackIdentity"],
            {
                "appAppleId": "1234567890",
                "bundleIdentifier": "com.openburnbar.app",
                "version": "1.2.3",
                "build": "456",
                "platform": "MAC_OS",
            },
        )

    def test_creates_verified_archive_export_receipt_without_upload(self) -> None:
        root = self.root()
        archive = root / "OpenBurnBar.xcarchive"
        archive_app = archive / "Products" / "Applications" / "OpenBurnBar.app"
        archive_appex = archive_app / "Contents" / "PlugIns" / "OpenBurnBarSafariExtension.appex"
        archive_appex.mkdir(parents=True)
        (archive_app / "archive-binary").write_bytes(b"archive")
        (archive_appex / "extension-binary").write_bytes(b"archive-appex")

        exported_app = root / "export" / "OpenBurnBar.app"
        exported_appex = exported_app / "Contents" / "PlugIns" / "OpenBurnBarSafariExtension.appex"
        exported_appex.mkdir(parents=True)
        (exported_app / "exported-binary").write_bytes(b"exported")
        (exported_appex / "extension-binary").write_bytes(b"exported-appex")
        pkg = root / "OpenBurnBar.pkg"
        pkg.write_bytes(b"package")
        verifier = ROOT / "scripts/ci/verify-openburnbar-mas-artifact.sh"
        args = type(
            "Args",
            (),
            {
                "candidate_commit": "1" * 40,
                "candidate_tree": "2" * 40,
                "team_id": "4Y367DF25B",
                "version": "1.2.3",
                "build": "456",
                "archive": archive,
                "archive_app": archive_app,
                "export_inspection": root / "export",
                "exported_app": exported_app,
                "pkg": pkg,
                "artifact_verifier": verifier,
            },
        )()

        with mock.patch.object(
            MODULE.subprocess,
            "run",
            return_value=type(
                "Completed",
                (),
                {"returncode": 0, "stdout": "PASS", "stderr": ""},
            )(),
        ) as run:
            receipt = MODULE.create_artifact_receipt(args)

        self.assertEqual(run.call_count, 2)
        self.assertEqual(receipt["status"], "archive-export-verified")
        self.assertEqual(
            receipt["candidate"],
            {"commit": "1" * 40, "tree": "2" * 40},
        )
        self.assertEqual(receipt["release"]["channel"], "mac-app-store")
        self.assertEqual(receipt["release"]["teamId"], "4Y367DF25B")
        self.assertEqual(receipt["artifacts"]["packageSize"], len(b"package"))
        self.assertRegex(receipt["artifacts"]["archiveTreeSha256"], r"^[0-9a-f]{64}$")
        self.assertRegex(
            receipt["artifacts"]["exportedSafariExtensionTreeSha256"],
            r"^[0-9a-f]{64}$",
        )
        self.assertEqual(
            receipt["verification"]["artifactVerifier"],
            "scripts/ci/verify-openburnbar-mas-artifact.sh",
        )
        self.assertTrue(receipt["verification"]["gatekeeperInstallAssessment"])

    def test_archive_export_receipt_fails_when_canonical_verifier_fails(self) -> None:
        root = self.root()
        args = self.receipt_args(root)
        args.archive_app = args.app
        args.export_inspection = args.archive
        args.exported_app = args.app
        args.team_id = "4Y367DF25B"
        args.artifact_verifier = ROOT / "scripts/ci/verify-openburnbar-mas-artifact.sh"
        with mock.patch.object(
            MODULE.subprocess,
            "run",
            return_value=type(
                "Completed",
                (),
                {"returncode": 1, "stdout": "", "stderr": "signature mismatch"},
            )(),
        ):
            with self.assertRaisesRegex(ValueError, "signature mismatch"):
                MODULE.create_artifact_receipt(args)

    def test_archive_export_receipt_rejects_unrelated_apps(self) -> None:
        root = self.root()
        args = self.receipt_args(root)
        args.team_id = "4Y367DF25B"
        args.artifact_verifier = ROOT / "scripts/ci/verify-openburnbar-mas-artifact.sh"
        args.archive_app = root / "unrelated" / "OpenBurnBar.app"
        args.export_inspection = args.archive
        args.exported_app = args.app
        args.archive_app.mkdir(parents=True)
        with self.assertRaisesRegex(ValueError, "canonical OpenBurnBar.app"):
            MODULE.create_artifact_receipt(args)

        args = self.receipt_args(root / "export-mismatch")
        args.team_id = "4Y367DF25B"
        args.artifact_verifier = ROOT / "scripts/ci/verify-openburnbar-mas-artifact.sh"
        args.archive_app = args.app
        args.export_inspection = root / "different-export"
        args.export_inspection.mkdir()
        args.exported_app = args.app
        with self.assertRaisesRegex(ValueError, "must be contained"):
            MODULE.create_artifact_receipt(args)

    def test_readback_requires_exact_returned_build_identity(self) -> None:
        root = self.root()
        args = self.receipt_args(root)
        args.build_readback.write_text(
            json.dumps(
                {
                    "data": {
                        "attributes": {
                            "appAppleId": "1234567890",
                            "bundleId": "com.openburnbar.app",
                            "bundleShortVersionString": "9.9.9",
                            "bundleVersion": "456",
                            "platform": "MAC_OS",
                            "processingState": "VALID",
                        }
                    }
                }
            )
            + "\n"
        )
        with self.assertRaisesRegex(ValueError, "identity does not match"):
            MODULE.create_receipt(args)

    def test_readback_rejects_missing_or_ambiguous_identity(self) -> None:
        root = self.root()
        args = self.receipt_args(root)
        args.build_readback.write_text(json.dumps({"data": {"processingState": "VALID"}}) + "\n")
        with self.assertRaisesRegex(ValueError, "no app Apple ID"):
            MODULE.create_receipt(args)

        args = self.receipt_args(root / "ambiguous")
        args.build_readback.write_text(
            json.dumps(
                {
                    "data": {
                        "attributes": {
                            "appAppleId": "1234567890",
                            "appleId": "9999999999",
                            "bundleId": "com.openburnbar.app",
                            "bundleShortVersionString": "1.2.3",
                            "bundleVersion": "456",
                            "platform": "macos",
                            "processingState": "VALID",
                        }
                    }
                }
            )
            + "\n"
        )
        with self.assertRaisesRegex(ValueError, "ambiguous app Apple ID"):
            MODULE.create_receipt(args)

    def test_rejects_delivery_query_mismatch(self) -> None:
        root = self.root()
        args = self.receipt_args(root)
        args.delivery_id = "DIFFERENT"
        with self.assertRaisesRegex(ValueError, "does not match queried delivery ID"):
            MODULE.create_receipt(args)

    def test_output_is_owner_only(self) -> None:
        root = self.root()
        output = root / "output.json"
        MODULE.write_json(output, {"ok": True})
        self.assertEqual(os.stat(output).st_mode & 0o777, 0o600)

    def test_output_writer_refuses_overwrite_and_symlink(self) -> None:
        root = self.root()
        output = root / "output.json"
        output.write_text("preserve\n")
        with self.assertRaises(FileExistsError):
            MODULE.write_json(output, {"overwrite": True})
        self.assertEqual(output.read_text(), "preserve\n")
        link = root / "link.json"
        link.symlink_to(output)
        with self.assertRaises(OSError):
            MODULE.write_json(link, {"follow": True})
        self.assertEqual(output.read_text(), "preserve\n")

    def test_rejects_missing_safari_extension_from_exported_app(self) -> None:
        root = self.root()
        args = self.receipt_args(root)
        appex = args.app / "Contents" / "PlugIns" / "OpenBurnBarSafariExtension.appex"
        for child in appex.iterdir():
            child.unlink()
        appex.rmdir()
        with self.assertRaisesRegex(ValueError, "missing a real Safari extension"):
            MODULE.create_receipt(args)


if __name__ == "__main__":
    unittest.main()
