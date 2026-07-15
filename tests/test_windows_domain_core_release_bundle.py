import hashlib
import importlib.util
import json
import tempfile
import unittest
import zipfile
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
MODULE_PATH = ROOT / "scripts/ci/create-windows-domain-core-release-bundle.py"
SPEC = importlib.util.spec_from_file_location("windows_domain_core_bundle", MODULE_PATH)
assert SPEC and SPEC.loader
BUNDLE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(BUNDLE)


VERSION = "1.2.3"
COMMIT = "a" * 40


def sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


class WindowsDomainCoreReleaseBundleTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name)
        self.artifacts = self.root / "artifacts"
        self.artifacts.mkdir()
        self.packages = {
            "win-x64": f"OpenBurnBar-{VERSION}-win-x64.zip",
            "win-arm64": f"OpenBurnBar-{VERSION}-win-arm64.zip",
            "x64": f"OpenBurnBar-{VERSION}-x64.msix",
            "arm64": f"OpenBurnBar-{VERSION}-arm64.msix",
        }
        for name, filename in self.packages.items():
            (self.artifacts / filename).write_bytes((f"signed-{name}-bytes\n" * 8).encode())
        checksum_path = self.artifacts / f"checksums-windows-v{VERSION}.txt"
        checksum_path.write_text(
            "".join(f"{sha256(self.artifacts / filename)}  {filename}\n" for filename in self.packages.values()),
            encoding="utf-8",
        )
        entries = []
        for platform in ("win-x64", "win-arm64"):
            artifact = self.artifacts / self.packages[platform]
            entries.append(
                {
                    "version": VERSION,
                    "platform": platform,
                    "channel": "stable",
                    "url": f"https://dl.openburnbar.dev/{artifact.name}",
                    "sizeBytes": artifact.stat().st_size,
                    "sha256": sha256(artifact),
                    "minOsBuild": 17763,
                    "critical": False,
                    "publishedAtUtc": "2026-07-14T00:00:00Z",
                    "releaseNotesUrl": "",
                    "ed25519Signature": "signed-entry",
                }
            )
        (self.artifacts / f"windows-update-feed-v{VERSION}.json").write_text(
            json.dumps(
                {
                    "schemaVersion": 1,
                    "feed": "openburnbar-windows",
                    "generatedAtUtc": "2026-07-14T00:00:00Z",
                    "entries": entries,
                }
            ),
            encoding="utf-8",
        )
        x64_msix = self.artifacts / self.packages["x64"]
        (self.artifacts / "latest-windows.json").write_text(
            json.dumps(
                {
                    "version": VERSION,
                    "commit": COMMIT,
                    "package": x64_msix.name,
                    "downloadUrl": f"https://dl.openburnbar.app/windows/{x64_msix.name}",
                    "length": x64_msix.stat().st_size,
                    "sha256": sha256(x64_msix),
                    "edSignature": "signed-package",
                    "descriptorSignature": "signed-descriptor",
                }
            ),
            encoding="utf-8",
        )
        (self.artifacts / "appcast-windows.xml").write_text(
            f'''<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel><item>
    <sparkle:shortVersionString>{VERSION}</sparkle:shortVersionString>
    <enclosure url="https://dl.openburnbar.app/windows/{x64_msix.name}"
      length="{x64_msix.stat().st_size}" type="application/msix"
      sparkle:sha256="{sha256(x64_msix)}" sparkle:edSignature="signed-package"
      sparkle:edDescriptorSignature="signed-descriptor" />
  </item></channel>
</rss>
''',
            encoding="utf-8",
        )

    def tearDown(self) -> None:
        self.temporary.cleanup()

    def output(self, suffix: str = "") -> Path:
        directory = self.root / suffix if suffix else self.root
        directory.mkdir(exist_ok=True)
        return directory / f"OpenBurnBar-{VERSION}-windows-release.zip"

    def test_creates_deterministic_exact_dual_architecture_bundle(self) -> None:
        first = self.output("first")
        second = self.output("second")
        manifest = BUNDLE.create_bundle(self.artifacts, first, VERSION, COMMIT)
        BUNDLE.create_bundle(self.artifacts, second, VERSION, COMMIT)
        self.assertEqual(first.read_bytes(), second.read_bytes())
        self.assertEqual(manifest["artifactKind"], "windows-release-bundle")
        self.assertEqual(manifest["target"], "windows-x64-arm64")
        self.assertEqual(set(manifest["architectures"]), {"x64", "arm64"})

        expected_members = [
            "manifest.json",
            self.packages["win-x64"],
            self.packages["x64"],
            self.packages["win-arm64"],
            self.packages["arm64"],
            f"checksums-windows-v{VERSION}.txt",
            f"windows-update-feed-v{VERSION}.json",
            "appcast-windows.xml",
            "latest-windows.json",
        ]
        with zipfile.ZipFile(first) as archive:
            self.assertEqual(archive.namelist(), expected_members)
            self.assertTrue(all(item.date_time == BUNDLE.FIXED_ZIP_TIME for item in archive.infolist()))
            archived_manifest = json.loads(archive.read("manifest.json"))
        self.assertEqual(archived_manifest, manifest)
        self.assertEqual(
            archived_manifest["release"],
            {"version": VERSION, "tag": f"windows-v{VERSION}", "commit": COMMIT},
        )

    def test_rejects_tampered_checksum(self) -> None:
        checksum = self.artifacts / f"checksums-windows-v{VERSION}.txt"
        checksum.write_text(checksum.read_text().replace(checksum.read_text()[:64], "0" * 64))
        with self.assertRaisesRegex(BUNDLE.BundleError, "checksum does not match"):
            BUNDLE.create_bundle(self.artifacts, self.output(), VERSION, COMMIT)

    def test_rejects_feed_without_both_architectures(self) -> None:
        feed = self.artifacts / f"windows-update-feed-v{VERSION}.json"
        value = json.loads(feed.read_text())
        value["entries"] = value["entries"][:1]
        feed.write_text(json.dumps(value))
        with self.assertRaisesRegex(BUNDLE.BundleError, "exactly x64 and ARM64"):
            BUNDLE.create_bundle(self.artifacts, self.output(), VERSION, COMMIT)

    def test_rejects_metadata_from_another_commit(self) -> None:
        latest = self.artifacts / "latest-windows.json"
        value = json.loads(latest.read_text())
        value["commit"] = "b" * 40
        latest.write_text(json.dumps(value))
        with self.assertRaisesRegex(BUNDLE.BundleError, "exact signed x64 MSIX"):
            BUNDLE.create_bundle(self.artifacts, self.output(), VERSION, COMMIT)

    def test_requires_canonical_output_name(self) -> None:
        with self.assertRaisesRegex(BUNDLE.BundleError, "output filename"):
            BUNDLE.create_bundle(self.artifacts, self.root / "windows.zip", VERSION, COMMIT)


if __name__ == "__main__":
    unittest.main()

