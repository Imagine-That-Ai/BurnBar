#!/usr/bin/env python3

from __future__ import annotations

import hashlib
import importlib.util
import json
import os
import shutil
import stat
import subprocess
import tempfile
import unittest
from pathlib import Path


SCRIPT = Path(__file__).with_name("verify-openburnbar-r2-publication.py")
REPO_ROOT = SCRIPT.parents[2]
UPLOADER = REPO_ROOT / "scripts" / "upload-macos-downloads-r2.sh"
COMMIT = "a" * 40
TREE = "b" * 40
TEAM = "4Y367DF25B"
VERSION = "1.2.3"
BUILD = "123"
BASE_URL = "https://downloads.example.test/releases"
SPARKLE_NAMESPACE = "http://www.andymatuschak.org/xml-namespaces/sparkle"

spec = importlib.util.spec_from_file_location("r2_publication", SCRIPT)
assert spec and spec.loader
r2 = importlib.util.module_from_spec(spec)
spec.loader.exec_module(r2)


def digest(payload: bytes) -> str:
    return hashlib.sha256(payload).hexdigest()


def write_bytes(path: Path, payload: bytes, mode: int = 0o644) -> dict[str, object]:
    path.write_bytes(payload)
    path.chmod(mode)
    return {
        "fileName": path.name,
        "sha256": digest(payload),
        "sizeBytes": len(payload),
    }


class ReleaseFixture:
    def __init__(self, root: Path) -> None:
        self.root = root
        self.downloads = root / "downloads"
        self.public = root / "public"
        self.downloads.mkdir(mode=0o700, parents=True)
        self.public.mkdir(mode=0o700)
        self.release_receipt = self.downloads / "developer-id-release-receipt.json"
        self.preflight = root / "preflight.json"
        self.publication_receipt = root / "publication.json"

        self.names = {
            "dmg": f"OpenBurnBar-{VERSION}-macOS.dmg",
            "zip": f"OpenBurnBar-{VERSION}-macOS.zip",
            "correspondingSource": (
                f"OpenBurnBar-{VERSION}-corresponding-source.tar.gz"
            ),
            "sbom": f"sbom-v{VERSION}.spdx.json",
            "latestMetadata": "latest-macos.json",
            "appcast": "appcast.xml",
            "checksums": f"checksums-v{VERSION}.txt",
            "releaseMetadata": "release-metadata.json",
        }
        self.artifacts: dict[str, dict[str, object]] = {}
        self._create()

    def _write_artifact(
        self,
        kind: str,
        payload: bytes,
        mode: int = 0o644,
    ) -> None:
        self.artifacts[kind] = write_bytes(
            self.downloads / self.names[kind],
            payload,
            mode,
        )

    def _create(self) -> None:
        self._write_artifact("dmg", b"signed notarized stapled dmg\n")
        self._write_artifact("zip", b"signed notarized app zip\n")
        self._write_artifact("correspondingSource", b"corresponding source\n")
        self._write_artifact("sbom", b'{"spdxVersion":"SPDX-2.3"}\n')

        dmg = self.artifacts["dmg"]
        latest = {
            "version": VERSION,
            "build": BUILD,
            "bundleId": "com.openburnbar.app",
            "channel": "direct-download",
            "commit": COMMIT,
            "correspondingSource": self.names["correspondingSource"],
            "dmg": self.names["dmg"],
            "zip": self.names["zip"],
            "downloadUrl": f"{BASE_URL}/{self.names['dmg']}",
            "appcastUrl": f"{BASE_URL}/{self.names['appcast']}",
            "length": dmg["sizeBytes"],
            "sha256": dmg["sha256"],
            "sparkleEdSignature": "fixture-signature",
        }
        self._write_artifact(
            "latestMetadata",
            (json.dumps(latest, sort_keys=True) + "\n").encode(),
        )

        appcast = f"""<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="{SPARKLE_NAMESPACE}">
  <channel>
    <item>
      <sparkle:shortVersionString>{VERSION}</sparkle:shortVersionString>
      <sparkle:version>{BUILD}</sparkle:version>
      <enclosure
        url="{BASE_URL}/{self.names['dmg']}"
        length="{dmg['sizeBytes']}"
        sparkle:edSignature="fixture-signature"
      />
    </item>
  </channel>
</rss>
"""
        self._write_artifact("appcast", appcast.encode())

        checksums = "".join(
            f"{self.artifacts[kind]['sha256']}  {self.names[kind]}\n"
            for kind in (
                "appcast",
                "correspondingSource",
                "dmg",
                "latestMetadata",
                "sbom",
                "zip",
            )
        )
        self._write_artifact("checksums", checksums.encode())

        metadata = {
            "version": VERSION,
            "build": BUILD,
            "bundleId": "com.openburnbar.app",
            "channel": "direct-download",
            "dmg": self.names["dmg"],
            "zip": self.names["zip"],
            "appcast": self.names["appcast"],
            "latestMetadata": self.names["latestMetadata"],
            "developerIdReceipt": self.release_receipt.name,
            "updateBaseUrl": BASE_URL,
            "correspondingSource": self.names["correspondingSource"],
            "sparkleEdSignaturePresent": True,
            "commit": COMMIT,
            "tree": TREE,
        }
        self._write_artifact(
            "releaseMetadata",
            (json.dumps(metadata, sort_keys=True) + "\n").encode(),
        )

        receipt = {
            "schemaVersion": 1,
            "candidate": {"commit": COMMIT, "tree": TREE},
            "release": {
                "version": VERSION,
                "build": BUILD,
                "channel": "direct-download",
                "teamId": TEAM,
            },
            "signing": {
                "schemaVersion": 1,
                "distribution": "developer-id",
                "teamId": TEAM,
                "verification": {
                    "embeddedProfilesByteEqual": True,
                    "profileCertificateMembership": True,
                    "strictDeepNestedSignatures": True,
                    "getTaskAllow": False,
                    "platform": "OSX",
                },
            },
            "notarization": {
                "app": {
                    "id": "11111111-2222-3333-4444-555555555555",
                    "status": "Accepted",
                    "submittedArtifact": {
                        "fileName": "OpenBurnBar-app-notary.zip",
                        "sha256": "c" * 64,
                        "sizeBytes": 10,
                    },
                },
                "dmg": {
                    "id": "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee",
                    "status": "Accepted",
                    "submittedArtifact": {
                        "fileName": self.names["dmg"],
                        "sha256": "d" * 64,
                        "sizeBytes": 20,
                    },
                },
            },
            "artifacts": self.artifacts,
            "mountedDmgSmoke": {
                "status": "passed",
                "script": "scripts/ci/smoke-openburnbar-release-dmg.sh",
                "artifactSha256": self.artifacts["dmg"]["sha256"],
            },
        }
        self.release_receipt.write_text(
            json.dumps(receipt, sort_keys=True) + "\n",
            encoding="utf-8",
        )
        self.release_receipt.chmod(0o600)

    def build_preflight(self) -> dict[str, object]:
        return r2.build_preflight(
            release_receipt_path=self.release_receipt,
            downloads_dir=self.downloads,
            candidate_commit=COMMIT,
            candidate_tree=TREE,
            bucket="openburnbar-downloads",
            public_base_url=BASE_URL,
        )

    def write_preflight(self) -> dict[str, object]:
        value = self.build_preflight()
        self.preflight.write_text(
            json.dumps(value, sort_keys=True) + "\n",
            encoding="utf-8",
        )
        self.preflight.chmod(0o600)
        return value

    def copy_public_objects(self, preflight: dict[str, object]) -> None:
        for artifact in preflight["artifacts"]:
            source = self.downloads / artifact["fileName"]
            shutil.copy2(source, self.public / artifact["fileName"])

    def refresh_artifact_binding(self, kind: str) -> None:
        path = self.downloads / self.names[kind]
        artifact = {
            "fileName": path.name,
            "sha256": digest(path.read_bytes()),
            "sizeBytes": path.stat().st_size,
        }
        self.artifacts[kind] = artifact
        receipt = json.loads(self.release_receipt.read_text(encoding="utf-8"))
        receipt["artifacts"][kind] = artifact
        self.release_receipt.write_text(
            json.dumps(receipt, sort_keys=True) + "\n",
            encoding="utf-8",
        )
        self.release_receipt.chmod(0o600)


class R2PublicationTests(unittest.TestCase):
    def setUp(self) -> None:
        self.tempdir = tempfile.TemporaryDirectory(
            prefix="openburnbar-r2-publication-"
        )
        self.root = Path(self.tempdir.name)
        self.fixture = ReleaseFixture(self.root)

    def tearDown(self) -> None:
        self.tempdir.cleanup()

    def test_valid_preflight_includes_release_receipt_as_ninth_object(self) -> None:
        preflight = self.fixture.build_preflight()
        artifacts = preflight["artifacts"]
        self.assertEqual(len(artifacts), 9)
        receipt_artifact = next(
            item for item in artifacts if item["kind"] == "releaseReceipt"
        )
        self.assertEqual(
            receipt_artifact,
            {
                "kind": "releaseReceipt",
                "fileName": self.fixture.release_receipt.name,
                "sha256": digest(self.fixture.release_receipt.read_bytes()),
                "sizeBytes": self.fixture.release_receipt.stat().st_size,
                "publicUrl": (
                    f"{BASE_URL}/{self.fixture.release_receipt.name}"
                ),
                "contentType": "application/json; charset=utf-8",
                "cacheControl": "public, max-age=31536000, immutable",
            },
        )
        self.assertEqual(
            preflight["sourceReleaseReceipt"]["publicUrl"],
            receipt_artifact["publicUrl"],
        )

    def test_receipt_proves_all_public_bytes_but_not_test_apple_trust(self) -> None:
        preflight = self.fixture.write_preflight()
        self.fixture.copy_public_objects(preflight)
        receipt = r2.build_publication_receipt(
            preflight_path=self.fixture.preflight,
            release_receipt_path=self.fixture.release_receipt,
            downloads_dir=self.fixture.downloads,
            public_download_dir=self.fixture.public,
            platform_trust_verifier="/tmp/test-trust-verifier",
            platform_trust_mode="test-override",
        )
        self.assertEqual(len(receipt["artifacts"]), 9)
        self.assertTrue(receipt["verification"]["publicBytesDigestEqual"])
        self.assertFalse(
            receipt["verification"]["publicDmgAppleTrustVerified"]
        )

    def test_rejects_candidate_and_local_artifact_mismatch(self) -> None:
        with self.assertRaisesRegex(ValueError, "candidate commit"):
            r2.build_preflight(
                release_receipt_path=self.fixture.release_receipt,
                downloads_dir=self.fixture.downloads,
                candidate_commit="f" * 40,
                candidate_tree=TREE,
                bucket="openburnbar-downloads",
                public_base_url=BASE_URL,
            )
        (self.fixture.downloads / self.fixture.names["dmg"]).write_bytes(
            b"tampered dmg"
        )
        with self.assertRaisesRegex(ValueError, "does not match"):
            self.fixture.build_preflight()

    def test_rejects_public_digest_mismatch(self) -> None:
        preflight = self.fixture.write_preflight()
        self.fixture.copy_public_objects(preflight)
        (self.fixture.public / self.fixture.names["zip"]).write_bytes(
            b"tampered public zip"
        )
        with self.assertRaisesRegex(ValueError, "exact local release bytes"):
            r2.build_publication_receipt(
                preflight_path=self.fixture.preflight,
                release_receipt_path=self.fixture.release_receipt,
                downloads_dir=self.fixture.downloads,
                public_download_dir=self.fixture.public,
                platform_trust_verifier="/tmp/test-trust-verifier",
                platform_trust_mode="test-override",
            )

    def test_rejects_malformed_metadata_appcast_and_missing_signature(self) -> None:
        metadata = self.fixture.downloads / self.fixture.names["releaseMetadata"]
        metadata.write_text("{", encoding="utf-8")
        self.fixture.refresh_artifact_binding("releaseMetadata")
        with self.assertRaisesRegex(ValueError, "invalid JSON"):
            self.fixture.build_preflight()

        self.fixture = ReleaseFixture(self.root / "appcast-fixture")
        appcast = self.fixture.downloads / self.fixture.names["appcast"]
        appcast.write_text("<rss>", encoding="utf-8")
        self.fixture.refresh_artifact_binding("appcast")
        with self.assertRaisesRegex(ValueError, "malformed"):
            self.fixture.build_preflight()

        self.fixture = ReleaseFixture(self.root / "signature-fixture")
        latest = self.fixture.downloads / self.fixture.names["latestMetadata"]
        value = json.loads(latest.read_text(encoding="utf-8"))
        value["sparkleEdSignature"] = ""
        latest.write_text(json.dumps(value), encoding="utf-8")
        self.fixture.refresh_artifact_binding("latestMetadata")
        with self.assertRaisesRegex(ValueError, "Sparkle EdDSA signature"):
            self.fixture.build_preflight()

    def test_rejects_unsafe_bucket_url_symlink_hardlink_and_receipt_mode(self) -> None:
        with self.assertRaisesRegex(ValueError, "bucket"):
            r2.build_preflight(
                release_receipt_path=self.fixture.release_receipt,
                downloads_dir=self.fixture.downloads,
                candidate_commit=COMMIT,
                candidate_tree=TREE,
                bucket="../unsafe",
                public_base_url=BASE_URL,
            )
        with self.assertRaisesRegex(ValueError, "HTTPS"):
            r2.build_preflight(
                release_receipt_path=self.fixture.release_receipt,
                downloads_dir=self.fixture.downloads,
                candidate_commit=COMMIT,
                candidate_tree=TREE,
                bucket="openburnbar-downloads",
                public_base_url="http://downloads.example.test",
            )

        zip_path = self.fixture.downloads / self.fixture.names["zip"]
        zip_payload = zip_path.read_bytes()
        zip_path.unlink()
        zip_path.symlink_to(self.fixture.downloads / self.fixture.names["dmg"])
        with self.assertRaisesRegex(ValueError, "unsafe|regular file"):
            self.fixture.build_preflight()

        self.fixture = ReleaseFixture(self.root / "hardlink-fixture")
        zip_path = self.fixture.downloads / self.fixture.names["zip"]
        alias = self.fixture.downloads / "zip-hardlink"
        os.link(zip_path, alias)
        with self.assertRaisesRegex(ValueError, "exactly one hard link"):
            self.fixture.build_preflight()
        alias.unlink()
        self.assertEqual(zip_path.read_bytes(), zip_payload)

        self.fixture.release_receipt.chmod(0o644)
        with self.assertRaisesRegex(ValueError, "mode must be 0600"):
            self.fixture.build_preflight()

    def test_exclusive_output_rejects_existing_file_and_symlink(self) -> None:
        output = self.root / "exclusive.json"
        command = [
            "python3",
            str(SCRIPT),
            "preflight",
            "--release-receipt",
            str(self.fixture.release_receipt),
            "--downloads-dir",
            str(self.fixture.downloads),
            "--candidate-commit",
            COMMIT,
            "--candidate-tree",
            TREE,
            "--bucket",
            "openburnbar-downloads",
            "--public-base-url",
            BASE_URL,
            "--output",
            str(output),
        ]
        first = subprocess.run(command, capture_output=True, text=True)
        self.assertEqual(first.returncode, 0, first.stderr)
        self.assertEqual(stat.S_IMODE(output.stat().st_mode), 0o600)
        second = subprocess.run(command, capture_output=True, text=True)
        self.assertNotEqual(second.returncode, 0)

        output.unlink()
        target = self.root / "target.json"
        target.write_text("owner data", encoding="utf-8")
        output.symlink_to(target)
        linked = subprocess.run(command, capture_output=True, text=True)
        self.assertNotEqual(linked.returncode, 0)
        self.assertEqual(target.read_text(encoding="utf-8"), "owner data")

    def test_canonical_mode_rejects_noncanonical_verifier(self) -> None:
        preflight = self.fixture.write_preflight()
        self.fixture.copy_public_objects(preflight)
        with self.assertRaisesRegex(ValueError, "canonical public platform trust"):
            r2.build_publication_receipt(
                preflight_path=self.fixture.preflight,
                release_receipt_path=self.fixture.release_receipt,
                downloads_dir=self.fixture.downloads,
                public_download_dir=self.fixture.public,
                platform_trust_verifier="/tmp/not-canonical",
                platform_trust_mode="canonical",
            )


class R2UploaderIntegrationTests(unittest.TestCase):
    def setUp(self) -> None:
        self.tempdir = tempfile.TemporaryDirectory(
            prefix="openburnbar-r2-uploader-"
        )
        self.root = Path(self.tempdir.name)
        self.repo = self.root / "repo"
        self.repo.mkdir()
        for relative in (
            "scripts/ci",
            "scripts/lib",
        ):
            (self.repo / relative).mkdir(parents=True, exist_ok=True)
        shutil.copy2(UPLOADER, self.repo / "scripts/upload-macos-downloads-r2.sh")
        shutil.copy2(SCRIPT, self.repo / "scripts/ci" / SCRIPT.name)
        shutil.copy2(
            REPO_ROOT / "scripts/lib/exclusive_json.py",
            self.repo / "scripts/lib/exclusive_json.py",
        )
        shutil.copy2(
            REPO_ROOT / "scripts/lib/exact-candidate-git.sh",
            self.repo / "scripts/lib/exact-candidate-git.sh",
        )
        (self.repo / "scripts/ci/verify-public-macos-download-trust.sh").write_text(
            "#!/usr/bin/env bash\nexit 99\n",
            encoding="utf-8",
        )
        (self.repo / "scripts/upload-macos-downloads-r2.sh").chmod(0o755)
        subprocess.run(["git", "init", "-q"], cwd=self.repo, check=True)
        subprocess.run(
            ["git", "config", "user.email", "fixture@example.test"],
            cwd=self.repo,
            check=True,
        )
        subprocess.run(
            ["git", "config", "user.name", "Fixture"],
            cwd=self.repo,
            check=True,
        )
        subprocess.run(["git", "add", "."], cwd=self.repo, check=True)
        subprocess.run(
            ["git", "commit", "-qm", "fixture"],
            cwd=self.repo,
            check=True,
        )
        self.commit = subprocess.check_output(
            ["git", "rev-parse", "HEAD"],
            cwd=self.repo,
            text=True,
        ).strip()
        self.tree = subprocess.check_output(
            ["git", "rev-parse", "HEAD^{tree}"],
            cwd=self.repo,
            text=True,
        ).strip()

        self.fixture = ReleaseFixture(self.root / "release")
        receipt = json.loads(
            self.fixture.release_receipt.read_text(encoding="utf-8")
        )
        receipt["candidate"] = {"commit": self.commit, "tree": self.tree}
        for metadata_name in ("releaseMetadata",):
            path = self.fixture.downloads / self.fixture.names[metadata_name]
            value = json.loads(path.read_text(encoding="utf-8"))
            value["commit"] = self.commit
            value["tree"] = self.tree
            path.write_text(json.dumps(value, sort_keys=True) + "\n")
            self.fixture.artifacts[metadata_name] = {
                "fileName": path.name,
                "sha256": digest(path.read_bytes()),
                "sizeBytes": path.stat().st_size,
            }
        latest_path = (
            self.fixture.downloads / self.fixture.names["latestMetadata"]
        )
        latest = json.loads(latest_path.read_text(encoding="utf-8"))
        latest["commit"] = self.commit
        latest_path.write_text(json.dumps(latest, sort_keys=True) + "\n")
        self.fixture.artifacts["latestMetadata"] = {
            "fileName": latest_path.name,
            "sha256": digest(latest_path.read_bytes()),
            "sizeBytes": latest_path.stat().st_size,
        }
        checksums_path = (
            self.fixture.downloads / self.fixture.names["checksums"]
        )
        checksums = "".join(
            f"{self.fixture.artifacts[kind]['sha256']}  "
            f"{self.fixture.names[kind]}\n"
            for kind in (
                "appcast",
                "correspondingSource",
                "dmg",
                "latestMetadata",
                "sbom",
                "zip",
            )
        )
        checksums_path.write_text(checksums, encoding="utf-8")
        self.fixture.artifacts["checksums"] = {
            "fileName": checksums_path.name,
            "sha256": digest(checksums_path.read_bytes()),
            "sizeBytes": checksums_path.stat().st_size,
        }
        receipt["artifacts"] = self.fixture.artifacts
        self.fixture.release_receipt.write_text(
            json.dumps(receipt, sort_keys=True) + "\n",
            encoding="utf-8",
        )
        self.fixture.release_receipt.chmod(0o600)

        self.mock_bin = self.root / "mock-bin"
        self.mock_bin.mkdir()
        self.command_log = self.root / "commands.log"
        self.site_log = self.root / "site.ts"
        self._write_mock(
            "wrangler",
            """#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >>"$TEST_COMMAND_LOG"
[[ "$1 $2 $3" == "r2 object put" ]]
""",
        )
        self._write_mock(
            "curl",
            """#!/usr/bin/env bash
set -euo pipefail
destination=""
url=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --output) destination="$2"; shift 2 ;;
    http*) url="$1"; shift ;;
    *) shift ;;
  esac
done
[[ -n "$destination" && -n "$url" ]]
cp "$TEST_DOWNLOADS_DIR/${url##*/}" "$destination"
printf '%s\n' "$url" >>"$TEST_COMMAND_LOG"
""",
        )
        self._write_mock(
            "trust",
            """#!/usr/bin/env bash
set -euo pipefail
[[ $# -eq 1 ]]
cp "$1" "$TEST_SITE_LOG"
grep -Fq '"macReleaseLatest": "1.2.3"' "$1"
grep -Fq '"macReleaseFile": "OpenBurnBar-1.2.3-macOS.dmg"' "$1"
grep -Fq '"macDownloadBaseUrl": "https://downloads.example.test/releases"' "$1"
""",
        )

    def tearDown(self) -> None:
        self.tempdir.cleanup()

    def _write_mock(self, name: str, source: str) -> None:
        path = self.mock_bin / name
        path.write_text(source, encoding="utf-8")
        path.chmod(0o755)

    def test_uploader_verifies_candidate_specific_nine_object_publication(self) -> None:
        publication_receipt = self.root / "r2-publication.json"
        environment = os.environ.copy()
        environment.update(
            {
                "OPENBURNBAR_CANDIDATE_COMMIT": self.commit,
                "OPENBURNBAR_CANDIDATE_TREE": self.tree,
                "OPENBURNBAR_DOWNLOADS_DIR": str(self.fixture.downloads),
                "OPENBURNBAR_DIRECT_RELEASE_RECEIPT": str(
                    self.fixture.release_receipt
                ),
                "OPENBURNBAR_R2_PUBLICATION_RECEIPT": str(
                    publication_receipt
                ),
                "OPENBURNBAR_R2_PUBLIC_BASE_URL": BASE_URL,
                "WRANGLER_BIN": str(self.mock_bin / "wrangler"),
                "OPENBURNBAR_R2_CURL_BIN": str(self.mock_bin / "curl"),
                "OPENBURNBAR_R2_PUBLIC_TRUST_VERIFIER": str(
                    self.mock_bin / "trust"
                ),
                "OPENBURNBAR_R2_ALLOW_TEST_TRUST_VERIFIER": "1",
                "TEST_COMMAND_LOG": str(self.command_log),
                "TEST_DOWNLOADS_DIR": str(self.fixture.downloads),
                "TEST_SITE_LOG": str(self.site_log),
            }
        )
        result = subprocess.run(
            [str(self.repo / "scripts/upload-macos-downloads-r2.sh")],
            cwd=self.repo,
            env=environment,
            capture_output=True,
            text=True,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        log = self.command_log.read_text(encoding="utf-8").splitlines()
        self.assertEqual(
            sum(line.startswith("r2 object put ") for line in log),
            9,
        )
        self.assertEqual(sum(line.startswith("https://") for line in log), 9)
        self.assertIn(
            self.fixture.release_receipt.name,
            "\n".join(log),
        )
        self.assertIn(
            '"macReleaseLatest": "1.2.3"',
            self.site_log.read_text(encoding="utf-8"),
        )
        receipt = json.loads(publication_receipt.read_text(encoding="utf-8"))
        self.assertEqual(receipt["candidate"]["commit"], self.commit)
        self.assertEqual(len(receipt["artifacts"]), 9)
        self.assertFalse(
            receipt["verification"]["publicDmgAppleTrustVerified"]
        )
        self.assertEqual(
            stat.S_IMODE(publication_receipt.stat().st_mode),
            0o600,
        )


if __name__ == "__main__":
    unittest.main()
