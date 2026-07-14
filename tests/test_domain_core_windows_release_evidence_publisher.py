import argparse
import importlib.util
import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock


ROOT = Path(__file__).resolve().parents[1]
MODULE_PATH = ROOT / "scripts/ci/publish-windows-domain-core-release-evidence.py"
SPEC = importlib.util.spec_from_file_location("windows_domain_core_publisher", MODULE_PATH)
assert SPEC and SPEC.loader
PUBLISHER = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = PUBLISHER
SPEC.loader.exec_module(PUBLISHER)


VERSION = "1.2.3"
TAG = f"windows-v{VERSION}"
COMMIT = "a" * 40


class FakeReleaseClient:
    def __init__(self, predicates, *, release=None, assets=None, race_assets=None):
        self.predicates = predicates
        self.release = release
        self.assets = dict(assets or {})
        self.race_assets = dict(race_assets or {})
        self.created = 0
        self.uploads = []
        self.verifications = []

    def get_release(self, tag):
        if self.release is None:
            return None
        return {
            **self.release,
            "assets": [{"name": name} for name in sorted(self.assets)],
        }

    def create_release(self, tag, version):
        self.created += 1
        self.release = {"tag_name": tag, "draft": False, "prerelease": False}

    def download_asset(self, tag, name, destination):
        if name not in self.assets:
            raise PUBLISHER.PublishError(f"missing fake asset {name}")
        destination.mkdir(parents=True, exist_ok=True)
        path = destination / name
        path.write_bytes(self.assets[name])
        return path

    def upload_asset(self, tag, path):
        self.uploads.append(path.name)
        if path.name in self.race_assets:
            self.assets[path.name] = self.race_assets.pop(path.name)
            return False
        if path.name in self.assets:
            return False
        self.assets[path.name] = path.read_bytes()
        return True

    def verify_attestation(self, artifact, bundle, *, tag, commit):
        domain = bundle.read_text(encoding="utf-8")
        self.verifications.append((domain, artifact.name, tag, commit))
        return [{"verificationResult": {"statement": {"predicate": self.predicates[domain]}}}]


class WindowsDomainCoreReleaseEvidencePublisherTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name)
        self.artifact = self.root / f"OpenBurnBar-{VERSION}-windows-release.zip"
        self.artifact.write_bytes(b"canonical signed x64 and arm64 bundle")
        self.entries = []
        self.predicates = {}
        for domain, slug in (("quota", "quota"), ("cloudVault", "cloudvault")):
            predicate = self.root / f"{slug}.predicate.json"
            bundle = self.root / f"{slug}.bundle.json"
            expected = {
                "schemaVersion": 1,
                "consumer": "windows",
                "artifactKind": "windows-release-bundle",
                "target": "windows-x64-arm64",
                "artifact": {
                    "fileName": self.artifact.name,
                    "sha256": PUBLISHER.sha256_path(self.artifact),
                },
                "release": {
                    "version": VERSION,
                    "tag": TAG,
                    "commit": COMMIT,
                    "publicProfileSha256": PUBLISHER.expected_profile_digest(domain),
                },
            }
            predicate.write_text(json.dumps(expected), encoding="utf-8")
            bundle.write_text(domain, encoding="utf-8")
            asset_name = f"OpenBurnBar-{VERSION}-windows-release-{slug}.sigstore.json"
            self.entries.append([domain, str(predicate), str(bundle), asset_name])
            self.predicates[domain] = expected

    def tearDown(self) -> None:
        self.temporary.cleanup()

    def arguments(self):
        return argparse.Namespace(
            repository="Imagine-That-Ai/BurnBar",
            tag=TAG,
            commit=COMMIT,
            artifact=self.artifact,
            evidence=self.entries,
        )

    def test_creates_release_and_uploads_all_bundles_before_artifact(self) -> None:
        publication = PUBLISHER.build_publication(self.arguments())
        client = FakeReleaseClient(self.predicates)
        PUBLISHER.publish(publication, client)
        self.assertEqual(client.created, 1)
        self.assertEqual(
            client.uploads,
            [
                f"OpenBurnBar-{VERSION}-windows-release-cloudvault.sigstore.json",
                f"OpenBurnBar-{VERSION}-windows-release-quota.sigstore.json",
                self.artifact.name,
            ],
        )
        self.assertGreaterEqual(len(client.verifications), 4)
        self.assertEqual(client.assets[self.artifact.name], self.artifact.read_bytes())

    def test_existing_identical_assets_are_verified_without_upload(self) -> None:
        publication = PUBLISHER.build_publication(self.arguments())
        assets = {self.artifact.name: self.artifact.read_bytes()}
        for _domain, _, bundle, asset_name in self.entries:
            assets[asset_name] = Path(bundle).read_bytes()
        client = FakeReleaseClient(
            self.predicates,
            release={"tag_name": TAG, "draft": False, "prerelease": False},
            assets=assets,
        )
        PUBLISHER.publish(publication, client)
        self.assertEqual(client.created, 0)
        self.assertEqual(client.uploads, [])

    def test_refuses_to_replace_non_identical_artifact(self) -> None:
        publication = PUBLISHER.build_publication(self.arguments())
        client = FakeReleaseClient(
            self.predicates,
            release={"tag_name": TAG, "draft": False, "prerelease": False},
            assets={self.artifact.name: b"different bytes"},
        )
        with self.assertRaisesRegex(PUBLISHER.PublishError, "refusing to replace"):
            PUBLISHER.publish(publication, client)
        self.assertEqual(client.uploads, [])

    def test_refuses_draft_and_prerelease_targets(self) -> None:
        publication = PUBLISHER.build_publication(self.arguments())
        for field in ("draft", "prerelease"):
            release = {"tag_name": TAG, "draft": False, "prerelease": False}
            release[field] = True
            client = FakeReleaseClient(self.predicates, release=release)
            with self.subTest(field=field):
                with self.assertRaisesRegex(PUBLISHER.PublishError, field):
                    PUBLISHER.publish(publication, client)

    def test_concurrent_upload_must_have_identical_and_valid_bytes(self) -> None:
        publication = PUBLISHER.build_publication(self.arguments())
        quota_asset = f"OpenBurnBar-{VERSION}-windows-release-quota.sigstore.json"
        quota_bundle = next(Path(item[2]) for item in self.entries if item[0] == "quota")
        client = FakeReleaseClient(
            self.predicates,
            release={"tag_name": TAG, "draft": False, "prerelease": False},
            race_assets={quota_asset: quota_bundle.read_bytes()},
        )
        PUBLISHER.publish(publication, client)
        self.assertIn(quota_asset, client.assets)

    def test_rejects_domain_predicate_substitution(self) -> None:
        arguments = self.arguments()
        cloud = Path(arguments.evidence[1][1])
        cloud.write_text(json.dumps(self.predicates["quota"]), encoding="utf-8")
        with self.assertRaisesRegex(PUBLISHER.PublishError, "cloudVault predicate"):
            PUBLISHER.build_publication(arguments)

    def test_gh_verifier_pins_workflow_tag_sha_oidc_and_predicate(self) -> None:
        expected = [{"verificationResult": {"statement": {"predicate": {}}}}]
        completed = subprocess.CompletedProcess(args=[], returncode=0, stdout=json.dumps(expected), stderr="")
        with mock.patch.object(PUBLISHER.subprocess, "run", return_value=completed) as run:
            result = PUBLISHER.GhReleaseClient("Imagine-That-Ai/BurnBar").verify_attestation(
                self.artifact,
                Path(self.entries[0][2]),
                tag=TAG,
                commit=COMMIT,
            )
        self.assertEqual(result, expected)
        command = run.call_args.args[0]
        self.assertEqual(command[:3], ["gh", "attestation", "verify"])
        self.assertNotIn("--clobber", command)
        self.assertEqual(
            command[command.index("--signer-workflow") + 1],
            "Imagine-That-Ai/BurnBar/.github/workflows/openburnbar-release-windows.yml",
        )
        self.assertEqual(command[command.index("--source-digest") + 1], COMMIT)
        self.assertEqual(command[command.index("--source-ref") + 1], f"refs/tags/{TAG}")
        self.assertEqual(command[command.index("--signer-digest") + 1], COMMIT)
        self.assertIn("--deny-self-hosted-runners", command)
        self.assertEqual(command[command.index("--predicate-type") + 1], PUBLISHER.PREDICATE_TYPE)


if __name__ == "__main__":
    unittest.main()
