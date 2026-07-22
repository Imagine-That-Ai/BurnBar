from __future__ import annotations

import importlib.util
import io
import sys
import tempfile
import unittest
import zipfile
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
PATH = ROOT / "scripts/ci/scan-domain-core-final-artifact-legacy.py"
SPEC = importlib.util.spec_from_file_location("final_artifact_scan_test", PATH)
assert SPEC and SPEC.loader
SCAN = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = SCAN
SPEC.loader.exec_module(SCAN)


class FinalArtifactScanTests(unittest.TestCase):
    def archive(self, members: dict[str, bytes]) -> Path:
        root = Path(self.enterContext(tempfile.TemporaryDirectory()))
        path = root / "artifact.zip"
        with zipfile.ZipFile(path, "w") as archive:
            for name, data in members.items():
                archive.writestr(name, data)
        return path

    def test_accepts_exact_compiled_members_without_legacy_markers(self) -> None:
        report = SCAN.scan("windows", self.archive({"OpenBurnBar.exe": b"MZ\0rust-only"}))
        self.assertEqual(report["result"], "absent")
        self.assertEqual(report["inspectedMembers"][0]["path"], "OpenBurnBar.exe")

    def test_rejects_stale_artifact_with_legacy_symbol(self) -> None:
        with self.assertRaisesRegex(ValueError, "deleted legacy"):
            SCAN.scan("android", self.archive({"base/dex/classes.dex": b"dex\nCloudVaultLegacyCrypto"}))

    def test_rejects_legacy_marker_hidden_in_nested_archive_member(self) -> None:
        nested = io.BytesIO()
        with zipfile.ZipFile(nested, "w") as archive:
            archive.writestr("Payload/OpenBurnBarMobile.app/OpenBurnBarMobile", b"\xcf\xfa\xed\xfeHermesRelayLegacyCrypto")
        with self.assertRaisesRegex(ValueError, "deleted legacy"):
            SCAN.scan("ios", self.archive({"OpenBurnBarMobile.ipa": nested.getvalue()}))

    def test_rejects_artifact_with_no_inspectable_code(self) -> None:
        with self.assertRaisesRegex(ValueError, "no executable"):
            SCAN.scan("functions", self.archive({"README.txt": b"not deployed code"}))

    def test_rejects_stale_extracted_deploy_tree(self) -> None:
        root = Path(self.enterContext(tempfile.TemporaryDirectory()))
        artifact = root / "deployment.json"
        artifact.write_text("{}\n")
        deployed = root / "deployed"
        (deployed / "nested").mkdir(parents=True)
        (deployed / "nested/index.js").write_bytes(b"export const legacyTokenCost = () => 1")
        with self.assertRaisesRegex(ValueError, "deleted legacy"):
            SCAN.scan("functions", artifact, deployed)

    def test_scans_wasm_members(self) -> None:
        with self.assertRaisesRegex(ValueError, "deleted legacy"):
            SCAN.scan("console", self.archive({"assets/core.wasm": b"\0asmCloudVaultLegacySearch"}))


if __name__ == "__main__":
    unittest.main()
