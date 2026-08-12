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
        self.headers = root / "headers"
        self.downloads.mkdir(mode=0o700, parents=True)
        self.public.mkdir(mode=0o700)
        self.headers.mkdir(mode=0o700)
        self.release_receipt = self.downloads / "developer-id-release-receipt.json"
        self.preflight = root / "preflight.json"
        self.discovery_snapshot = root / "discovery-snapshot.json"
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
            (self.headers / f"{artifact['fileName']}.headers").write_text(
                "HTTP/2 200\r\n"
                f"Content-Type: {artifact['contentType']}\r\n"
                f"Cache-Control: {artifact['cacheControl']}\r\n"
                "\r\n",
                encoding="iso-8859-1",
            )

    def write_discovery_snapshot(
        self,
        preflight: dict[str, object],
    ) -> None:
        snapshot = r2.build_discovery_snapshot(
            preflight_path=self.preflight,
            public_download_dir=self.public,
            public_header_dir=self.headers,
        )
        self.discovery_snapshot.write_text(
            json.dumps(snapshot, sort_keys=True) + "\n",
            encoding="utf-8",
        )
        self.discovery_snapshot.chmod(0o600)

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
                "cacheControl": "public, max-age=300",
                "publicationPhase": "supporting-metadata",
                "discoveryCommitSetMember": False,
            },
        )
        self.assertEqual(
            [item["kind"] for item in artifacts],
            [
                "correspondingSource",
                "dmg",
                "sbom",
                "zip",
                "checksums",
                "releaseReceipt",
                "releaseMetadata",
                "appcast",
                "latestMetadata",
            ],
        )
        self.assertEqual(
            [
                item["kind"]
                for item in artifacts
                if item["discoveryCommitSetMember"]
            ],
            ["appcast", "latestMetadata"],
        )
        self.assertEqual(
            preflight["sourceReleaseReceipt"]["publicUrl"],
            receipt_artifact["publicUrl"],
        )

    def test_receipt_proves_all_public_bytes_but_not_test_apple_trust(self) -> None:
        preflight = self.fixture.write_preflight()
        self.fixture.copy_public_objects(preflight)
        self.fixture.write_discovery_snapshot(preflight)
        receipt = r2.build_publication_receipt(
            preflight_path=self.fixture.preflight,
            release_receipt_path=self.fixture.release_receipt,
            downloads_dir=self.fixture.downloads,
            public_download_dir=self.fixture.public,
            public_header_dir=self.fixture.headers,
            discovery_snapshot_path=self.fixture.discovery_snapshot,
            platform_trust_verifier="/tmp/test-trust-verifier",
            platform_trust_mode="test-override",
        )
        self.assertEqual(len(receipt["artifacts"]), 9)
        self.assertTrue(receipt["verification"]["publicBytesDigestEqual"])
        self.assertTrue(receipt["verification"]["publicContentTypesMatch"])
        self.assertTrue(receipt["verification"]["publicCacheControlsMatch"])
        self.assertEqual(
            receipt["verification"]["discoveryCommitSet"],
            ["appcast", "latestMetadata"],
        )
        self.assertTrue(
            all(
                artifact["observedResponse"]["statusCode"] == 200
                for artifact in receipt["artifacts"]
            )
        )
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
        self.fixture.write_discovery_snapshot(preflight)
        (self.fixture.public / self.fixture.names["zip"]).write_bytes(
            b"tampered public zip"
        )
        with self.assertRaisesRegex(ValueError, "exact local release bytes"):
            r2.build_publication_receipt(
                preflight_path=self.fixture.preflight,
                release_receipt_path=self.fixture.release_receipt,
                downloads_dir=self.fixture.downloads,
                public_download_dir=self.fixture.public,
                public_header_dir=self.fixture.headers,
                discovery_snapshot_path=self.fixture.discovery_snapshot,
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
        self.fixture.write_discovery_snapshot(preflight)
        with self.assertRaisesRegex(ValueError, "canonical public platform trust"):
            r2.build_publication_receipt(
                preflight_path=self.fixture.preflight,
                release_receipt_path=self.fixture.release_receipt,
                downloads_dir=self.fixture.downloads,
                public_download_dir=self.fixture.public,
                public_header_dir=self.fixture.headers,
                discovery_snapshot_path=self.fixture.discovery_snapshot,
                platform_trust_verifier="/tmp/not-canonical",
                platform_trust_mode="canonical",
            )


class R2UploaderIntegrationTests(unittest.TestCase):
    WRANGLER_VERSION = "3.114.0"

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
        self.remote_objects = self.root / "remote-objects"
        self.remote_headers = self.root / "remote-headers"
        self.remote_objects.mkdir()
        self.remote_headers.mkdir()
        self.command_log = self.root / "commands.log"
        self.failure_marker = self.root / "wrangler-failure.marker"
        self.site_log = self.root / "site.ts"
        self._write_mock(
            "wrangler",
            """#!/usr/bin/env bash
set -euo pipefail

if [[ "${1:-}" == "--version" && $# -eq 1 ]]; then
  printf 'wrangler %s\\n' "$TEST_WRANGLER_VERSION"
  exit 0
fi

printf '%s\n' "$*" >>"$TEST_COMMAND_LOG"
[[ $# -ge 4 && "$1 $2" == "r2 object" ]]
operation="$3"
object="$4"
file_name="${object#*/}"
shift 4

case "$operation" in
  put)
    source_path=""
    content_type=""
    cache_control=""
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --remote) shift ;;
        --file) source_path="$2"; shift 2 ;;
        --content-type) content_type="$2"; shift 2 ;;
        --cache-control) cache_control="$2"; shift 2 ;;
        *) exit 64 ;;
      esac
    done
    [[ -f "$source_path" && -n "$content_type" && -n "$cache_control" ]]
    if [[ "${TEST_FAIL_PUT_FILE:-}" == "$file_name" \
      && ! -e "$TEST_FAILURE_MARKER" ]]; then
      : >"$TEST_FAILURE_MARKER"
      exit 42
    fi
    cp "$source_path" "$TEST_REMOTE_OBJECTS/$file_name"
    printf '%s' "$content_type" >"$TEST_REMOTE_HEADERS/$file_name.content-type"
    printf '%s' "$cache_control" >"$TEST_REMOTE_HEADERS/$file_name.cache-control"
    ;;
  delete)
    [[ $# -eq 1 && "$1" == "--remote" ]]
    rm -f \
      "$TEST_REMOTE_OBJECTS/$file_name" \
      "$TEST_REMOTE_HEADERS/$file_name.content-type" \
      "$TEST_REMOTE_HEADERS/$file_name.cache-control"
    ;;
  *)
    exit 64
    ;;
esac
""",
        )
        self._write_mock(
            "curl",
            """#!/usr/bin/env bash
set -euo pipefail
destination=""
header_path=""
write_out=""
url=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --output) destination="$2"; shift 2 ;;
    --dump-header) header_path="$2"; shift 2 ;;
    --write-out) write_out="$2"; shift 2 ;;
    --retry|--connect-timeout|--max-time|--proto) shift 2 ;;
    http*) url="$1"; shift ;;
    *) shift ;;
  esac
done
[[ -n "$destination" && -n "$header_path" && -n "$url" ]]
file_name="${url##*/}"
if [[ -f "$TEST_REMOTE_OBJECTS/$file_name" ]]; then
  status=200
  cp "$TEST_REMOTE_OBJECTS/$file_name" "$destination"
  content_type="$(<"$TEST_REMOTE_HEADERS/$file_name.content-type")"
  cache_control="$(<"$TEST_REMOTE_HEADERS/$file_name.cache-control")"
  if [[ "${TEST_HEADER_MISMATCH_FILE:-}" == "$file_name" ]]; then
    content_type="application/x-openburnbar-test-mismatch"
  fi
  if [[ "${TEST_CACHE_CONTROL_MISMATCH_FILE:-}" == "$file_name" ]]; then
    cache_control="private, no-store"
  fi
  {
    printf 'HTTP/2 200\\r\\n'
    printf 'Content-Type: %s\\r\\n' "$content_type"
    printf 'Cache-Control: %s\\r\\n' "$cache_control"
    printf '\\r\\n'
  } >"$header_path"
else
  status=404
  : >"$destination"
  printf 'HTTP/2 404\\r\\n\\r\\n' >"$header_path"
fi
printf 'curl %s %s\\n' "$status" "$url" >>"$TEST_COMMAND_LOG"
if [[ -n "$write_out" ]]; then
  [[ "$write_out" == "%{http_code}" ]]
  printf '%s' "$status"
fi
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
        self.wrangler = self.mock_bin / "wrangler"
        self.wrangler_sha256 = digest(self.wrangler.read_bytes())
        self.preflight = r2.build_preflight(
            release_receipt_path=self.fixture.release_receipt,
            downloads_dir=self.fixture.downloads,
            candidate_commit=self.commit,
            candidate_tree=self.tree,
            bucket="openburnbar-downloads",
            public_base_url=BASE_URL,
        )
        self.artifacts_by_kind = {
            artifact["kind"]: artifact
            for artifact in self.preflight["artifacts"]
        }

    def tearDown(self) -> None:
        self.tempdir.cleanup()

    def _write_mock(self, name: str, source: str) -> None:
        path = self.mock_bin / name
        path.write_text(source, encoding="utf-8")
        path.chmod(0o755)

    def _environment(
        self,
        publication_receipt: Path,
        *,
        overrides: dict[str, str] | None = None,
        omitted: tuple[str, ...] = (),
    ) -> dict[str, str]:
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
                "WRANGLER_BIN": str(self.wrangler),
                "OPENBURNBAR_WRANGLER_VERSION": self.WRANGLER_VERSION,
                "OPENBURNBAR_WRANGLER_SHA256": self.wrangler_sha256,
                "OPENBURNBAR_R2_CURL_BIN": str(self.mock_bin / "curl"),
                "OPENBURNBAR_R2_PUBLIC_TRUST_VERIFIER": str(
                    self.mock_bin / "trust"
                ),
                "OPENBURNBAR_R2_ALLOW_TEST_TRUST_VERIFIER": "1",
                "PYTHONDONTWRITEBYTECODE": "1",
                "TEST_COMMAND_LOG": str(self.command_log),
                "TEST_FAILURE_MARKER": str(self.failure_marker),
                "TEST_REMOTE_OBJECTS": str(self.remote_objects),
                "TEST_REMOTE_HEADERS": str(self.remote_headers),
                "TEST_SITE_LOG": str(self.site_log),
                "TEST_WRANGLER_VERSION": self.WRANGLER_VERSION,
            }
        )
        environment.update(overrides or {})
        for name in omitted:
            environment.pop(name, None)
        return environment

    def _run_uploader(
        self,
        *,
        overrides: dict[str, str] | None = None,
        omitted: tuple[str, ...] = (),
    ) -> tuple[subprocess.CompletedProcess[str], Path]:
        publication_receipt = self.root / "r2-publication.json"
        result = subprocess.run(
            [str(self.repo / "scripts/upload-macos-downloads-r2.sh")],
            cwd=self.repo,
            env=self._environment(
                publication_receipt,
                overrides=overrides,
                omitted=omitted,
            ),
            capture_output=True,
            text=True,
        )
        return result, publication_receipt

    def _commands(self) -> list[str]:
        if not self.command_log.exists():
            return []
        return self.command_log.read_text(encoding="utf-8").splitlines()

    def _put_names(self) -> list[str]:
        return [
            line.split()[3].split("/", 1)[1]
            for line in self._commands()
            if line.startswith("r2 object put ")
        ]

    def _delete_names(self) -> list[str]:
        return [
            line.split()[3].split("/", 1)[1]
            for line in self._commands()
            if line.startswith("r2 object delete ")
        ]

    def _seed_remote(
        self,
        kind: str,
        payload: bytes,
        *,
        content_type: str,
        cache_control: str,
    ) -> None:
        file_name = self.artifacts_by_kind[kind]["fileName"]
        (self.remote_objects / file_name).write_bytes(payload)
        (self.remote_headers / f"{file_name}.content-type").write_text(
            content_type,
            encoding="utf-8",
        )
        (self.remote_headers / f"{file_name}.cache-control").write_text(
            cache_control,
            encoding="utf-8",
        )

    def _remote_state(self, kind: str) -> tuple[bytes, str, str]:
        file_name = self.artifacts_by_kind[kind]["fileName"]
        return (
            (self.remote_objects / file_name).read_bytes(),
            (
                self.remote_headers / f"{file_name}.content-type"
            ).read_text(encoding="utf-8"),
            (
                self.remote_headers / f"{file_name}.cache-control"
            ).read_text(encoding="utf-8"),
        )

    def _seed_existing_discovery(self) -> dict[str, tuple[bytes, str, str]]:
        states = {
            "appcast": (
                b"old appcast bytes\n",
                "text/xml; charset=utf-8",
                "public, max-age=41",
            ),
            "latestMetadata": (
                b'{"old":"latest"}\n',
                "application/vnd.openburnbar.previous+json",
                "public, max-age=73",
            ),
        }
        for kind, (payload, content_type, cache_control) in states.items():
            self._seed_remote(
                kind,
                payload,
                content_type=content_type,
                cache_control=cache_control,
            )
        return states

    def test_uploader_verifies_candidate_specific_nine_object_publication(self) -> None:
        result, publication_receipt = self._run_uploader()
        self.assertEqual(result.returncode, 0, result.stderr)
        put_names = self._put_names()
        self.assertEqual(len(put_names), 9)
        self.assertEqual(
            put_names,
            [
                self.artifacts_by_kind[kind]["fileName"]
                for kind, _ in r2.PUBLICATION_PLAN
            ],
        )
        self.assertEqual(
            put_names[-2:],
            [
                self.artifacts_by_kind["appcast"]["fileName"],
                self.artifacts_by_kind["latestMetadata"]["fileName"],
            ],
        )
        self.assertEqual(
            sum(line.startswith("curl ") for line in self._commands()),
            11,
        )
        self.assertIn(
            self.fixture.release_receipt.name,
            "\n".join(self._commands()),
        )
        self.assertIn(
            '"macReleaseLatest": "1.2.3"',
            self.site_log.read_text(encoding="utf-8"),
        )
        receipt = json.loads(publication_receipt.read_text(encoding="utf-8"))
        self.assertEqual(receipt["candidate"]["commit"], self.commit)
        self.assertEqual(len(receipt["artifacts"]), 9)
        self.assertEqual(
            receipt["verification"]["discoveryCommitSet"],
            ["appcast", "latestMetadata"],
        )
        self.assertTrue(
            receipt["verification"]["discoveryCommitSetVerified"]
        )
        self.assertEqual(
            [item["state"] for item in receipt["prePublicationDiscovery"]],
            ["absent", "absent"],
        )
        self.assertTrue(
            all(
                item["observedResponse"]["statusCode"] == 200
                for item in receipt["artifacts"]
            )
        )
        self.assertFalse(
            receipt["verification"]["publicDmgAppleTrustVerified"]
        )
        self.assertEqual(
            stat.S_IMODE(publication_receipt.stat().st_mode),
            0o600,
        )
        uploader_source = (
            self.repo / "scripts/upload-macos-downloads-r2.sh"
        ).read_text(encoding="utf-8")
        self.assertNotIn("wrangler@latest", uploader_source)
        self.assertNotIn("npm exec", uploader_source)

    def test_immutable_failure_preserves_existing_discovery(self) -> None:
        old_states = self._seed_existing_discovery()

        result, publication_receipt = self._run_uploader(
            overrides={
                "TEST_FAIL_PUT_FILE": self.artifacts_by_kind["dmg"]["fileName"]
            }
        )

        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(publication_receipt.exists())
        self.assertNotIn(
            self.artifacts_by_kind["appcast"]["fileName"],
            self._put_names(),
        )
        self.assertNotIn(
            self.artifacts_by_kind["latestMetadata"]["fileName"],
            self._put_names(),
        )
        for kind, expected in old_states.items():
            self.assertEqual(self._remote_state(kind), expected)

    def test_partial_discovery_failure_restores_existing_commit_set(self) -> None:
        old_states = self._seed_existing_discovery()

        result, publication_receipt = self._run_uploader(
            overrides={
                "TEST_FAIL_PUT_FILE": self.artifacts_by_kind[
                    "latestMetadata"
                ]["fileName"]
            }
        )

        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(publication_receipt.exists())
        for kind, expected in old_states.items():
            self.assertEqual(self._remote_state(kind), expected)
        self.assertEqual(
            self._put_names()[-2:],
            [
                self.artifacts_by_kind["latestMetadata"]["fileName"],
                self.artifacts_by_kind["appcast"]["fileName"],
            ],
        )
        self.assertEqual(self._delete_names(), [])

    def test_partial_discovery_failure_restores_first_release_absence(self) -> None:
        result, publication_receipt = self._run_uploader(
            overrides={
                "TEST_FAIL_PUT_FILE": self.artifacts_by_kind[
                    "latestMetadata"
                ]["fileName"]
            }
        )

        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(publication_receipt.exists())
        expected_deletes = [
            self.artifacts_by_kind["latestMetadata"]["fileName"],
            self.artifacts_by_kind["appcast"]["fileName"],
        ]
        self.assertEqual(self._delete_names(), expected_deletes)
        for file_name in expected_deletes:
            self.assertFalse((self.remote_objects / file_name).exists())
            self.assertFalse(
                (self.remote_headers / f"{file_name}.content-type").exists()
            )
            self.assertFalse(
                (self.remote_headers / f"{file_name}.cache-control").exists()
            )

    def test_public_header_mismatch_fails_before_discovery(self) -> None:
        file_name = self.artifacts_by_kind["dmg"]["fileName"]
        cases = (
            (
                "Content-Type",
                {"TEST_HEADER_MISMATCH_FILE": file_name},
                "public Content-Type for dmg",
            ),
            (
                "Cache-Control",
                {"TEST_CACHE_CONTROL_MISMATCH_FILE": file_name},
                "public Cache-Control for dmg",
            ),
        )
        discovery_names = {
            self.artifacts_by_kind["appcast"]["fileName"],
            self.artifacts_by_kind["latestMetadata"]["fileName"],
        }
        for label, overrides, expected_error in cases:
            with self.subTest(header=label):
                self.command_log.unlink(missing_ok=True)
                result, publication_receipt = self._run_uploader(
                    overrides=overrides
                )
                self.assertNotEqual(result.returncode, 0)
                self.assertFalse(publication_receipt.exists())
                self.assertIn(expected_error, result.stderr)
                self.assertTrue(
                    discovery_names.isdisjoint(self._put_names())
                )

    def test_wrangler_pin_is_required_and_verified_before_upload(self) -> None:
        cases = (
            (
                "missing binary",
                {},
                ("WRANGLER_BIN",),
                "Required environment is missing: wrangler_bin",
            ),
            (
                "missing version",
                {},
                ("OPENBURNBAR_WRANGLER_VERSION",),
                "Required environment is missing: wrangler_version",
            ),
            (
                "missing digest",
                {},
                ("OPENBURNBAR_WRANGLER_SHA256",),
                "Required environment is missing: wrangler_sha256",
            ),
            (
                "wrong digest",
                {"OPENBURNBAR_WRANGLER_SHA256": "0" * 64},
                (),
                "WRANGLER_BIN SHA-256 does not match",
            ),
            (
                "wrong version",
                {"OPENBURNBAR_WRANGLER_VERSION": "3.113.0"},
                (),
                "version output does not uniquely match",
            ),
        )
        for label, overrides, omitted, expected_error in cases:
            with self.subTest(label=label):
                self.command_log.unlink(missing_ok=True)
                self.failure_marker.unlink(missing_ok=True)
                result, publication_receipt = self._run_uploader(
                    overrides=overrides,
                    omitted=omitted,
                )
                self.assertNotEqual(result.returncode, 0)
                self.assertIn(expected_error, result.stderr)
                self.assertFalse(publication_receipt.exists())
                self.assertEqual(self._put_names(), [])


if __name__ == "__main__":
    unittest.main()
