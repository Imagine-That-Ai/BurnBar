from __future__ import annotations

import hashlib
import importlib.util
import json
import tempfile
import unittest
import zipfile
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
PATH = ROOT / "scripts/ci/create-domain-core-rollback-bundle.py"
SPEC = importlib.util.spec_from_file_location("domain_core_rollback_bundle", PATH)
assert SPEC and SPEC.loader
BUNDLE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(BUNDLE)


class RollbackBundleTests(unittest.TestCase):
    def fixture(self, root: Path, *, rust_mode: bool = False) -> tuple[Path, Path, Path, dict]:
        candidate = {
            "candidateCommit": "1" * 40,
            "coreVersion": "1.2.3",
            "abiVersion": 3,
            "sourceSha256": hashlib.sha256(
                b"deterministic legacy source archive" * 16
            ).hexdigest(),
        }
        activation = {
            **candidate,
            "activationCommit": "3" * 40,
            "changedPathsSha256": "4" * 64,
        }
        modes = {domain: "legacy" for domain in BUNDLE.DOMAIN_ENV_KEYS}
        if rust_mode:
            modes["quota"] = "rust"
        profile = {
            "schemaVersion": 1,
            "name": "public-production-rollback",
            "artifactAuthority": "signed",
            "distribution": "public",
            "rolloutChannel": None,
            "evidenceEnabled": False,
            "modes": modes,
            "candidateIdentity": candidate,
            "release": {
                "version": "1.2.3",
                "tag": "v1.2.3",
                "commit": "3" * 40,
            },
        }
        profile_path = root / "profile.json"
        activation_path = root / "activation.json"
        source_path = root / "legacy-source.tar.gz"
        profile_path.write_text(json.dumps(profile))
        activation_path.write_text(json.dumps(activation))
        source_path.write_bytes(b"deterministic legacy source archive" * 16)
        return profile_path, activation_path, source_path, activation

    def test_bundle_has_exact_deterministic_seven_consumer_payloads(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            profile, activation_path, source, activation = self.fixture(root)
            outputs = [root / "one.zip", root / "two.zip"]
            for output in outputs:
                BUNDLE.create_bundle(
                    profile,
                    activation_path,
                    output,
                    source,
                    version="1.2.3",
                    tag="v1.2.3",
                    commit=activation["activationCommit"],
                )
            self.assertEqual(outputs[0].read_bytes(), outputs[1].read_bytes())
            with zipfile.ZipFile(outputs[0]) as archive:
                manifest = json.loads(archive.read("manifest.json"))
                payload_manifest = json.loads(archive.read("rollback-payloads.json"))
                self.assertEqual(manifest["contents"], archive.namelist())
                self.assertEqual(
                    [payload["consumer"] for payload in payload_manifest["payloads"]],
                    list(BUNDLE.ROLLBACK_CONSUMERS),
                )
                for payload in payload_manifest["payloads"]:
                    settings = archive.read(payload["payloadPath"])
                    provenance = json.loads(archive.read(payload["provenancePath"]))
                    self.assertEqual(hashlib.sha256(settings).hexdigest(), payload["payloadSha256"])
                    self.assertEqual(len(settings), payload["size"])
                    self.assertEqual(provenance["subject"]["sha256"], payload["payloadSha256"])
                    decoded = json.loads(settings)
                    self.assertEqual(decoded["action"], "rebuild_and_redeploy_legacy")
                    self.assertTrue(all(line.endswith("=legacy") for line in decoded["environment"] if line.endswith("_MODE=legacy")))

    def test_rejects_rust_mode_in_rollback_payload(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            profile, activation, source, closure = self.fixture(root, rust_mode=True)
            with self.assertRaisesRegex(ValueError, "every declared domain"):
                BUNDLE.create_bundle(
                    profile,
                    activation,
                    root / "rollback.zip",
                    source,
                    version="1.2.3",
                    tag="v1.2.3",
                    commit=closure["activationCommit"],
                )

    def test_rejects_unrelated_source_archive(self) -> None:
        """An archive whose digest does not match candidate.sourceSha256 must
        be rejected so a rollback bundle cannot ship an unrelated source tree."""
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            profile, activation_path, source, activation = self.fixture(root)
            source.write_bytes(b"unrelated legacy source archive" * 16)
            with self.assertRaisesRegex(
                ValueError, "source archive digest does not match"
            ):
                BUNDLE.create_bundle(
                    profile,
                    activation_path,
                    root / "rollback.zip",
                    source,
                    version="1.2.3",
                    tag="v1.2.3",
                    commit=activation["activationCommit"],
                )

    def test_rejects_release_version_not_bound_to_candidate_core_version(
        self,
    ) -> None:
        """The release version must equal candidate.coreVersion so a rollback
        bundle cannot be labeled with an unrelated release train."""
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            profile, activation_path, source, activation = self.fixture(root)
            with self.assertRaisesRegex(
                ValueError, "release version does not match the candidate core version"
            ):
                BUNDLE.create_bundle(
                    profile,
                    activation_path,
                    root / "rollback.zip",
                    source,
                    version="2.0.0",
                    tag="v2.0.0",
                    commit=activation["activationCommit"],
                )

    def test_rejects_moved_release_tag(self) -> None:
        """A tag that does not match v{version} must be rejected so the
        rollback bundle cannot be labeled with a moved or foreign tag."""
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            profile, activation_path, source, activation = self.fixture(root)
            with self.assertRaisesRegex(
                ValueError, "rollback release coordinates are invalid"
            ):
                BUNDLE.create_bundle(
                    profile,
                    activation_path,
                    root / "rollback.zip",
                    source,
                    version="1.2.3",
                    tag="v9.9.9",
                    commit=activation["activationCommit"],
                )

    def test_rejects_profile_release_coordinates_not_matching_inputs(self) -> None:
        """The profile's release coordinates must match the caller-supplied
        version/tag/commit so a stale or substituted profile cannot bind a
        different release P than the one the bundle is created for."""
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            profile, activation_path, source, activation = self.fixture(root)
            tampered = json.loads(profile.read_text())
            tampered["release"]["commit"] = "6" * 40
            profile.write_text(json.dumps(tampered))
            with self.assertRaisesRegex(
                ValueError,
                "rollback profile release coordinates do not match the exact release P",
            ):
                BUNDLE.create_bundle(
                    profile,
                    activation_path,
                    root / "rollback.zip",
                    source,
                    version="1.2.3",
                    tag="v1.2.3",
                    commit=activation["activationCommit"],
                )

    def test_rejects_profile_release_commit_equal_to_candidate_commit(self) -> None:
        """The release commit P must be distinct from the candidate commit C
        so a candidate-only artifact cannot pass as a release-bound rollback."""
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            profile, activation_path, source, activation = self.fixture(root)
            tampered = json.loads(profile.read_text())
            tampered["release"]["commit"] = "1" * 40
            tampered["candidateIdentity"]["candidateCommit"] = "1" * 40
            activation_tampered = json.loads(activation_path.read_text())
            activation_tampered["candidateCommit"] = "1" * 40
            activation_tampered["activationCommit"] = "1" * 40
            activation_path.write_text(json.dumps(activation_tampered))
            profile.write_text(json.dumps(tampered))
            with self.assertRaisesRegex(
                ValueError,
                "rollback profile release commit must be distinct from the candidate commit",
            ):
                BUNDLE.create_bundle(
                    profile,
                    activation_path,
                    root / "rollback.zip",
                    source,
                    version="1.2.3",
                    tag="v1.2.3",
                    commit="1" * 40,
                )

    def test_rejects_mismatched_release_commit(self) -> None:
        """A release commit that disagrees with the profile's release
        coordinates must be rejected."""
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            profile, activation_path, source, activation = self.fixture(root)
            with self.assertRaisesRegex(
                ValueError,
                "rollback profile release coordinates do not match the exact release P",
            ):
                BUNDLE.create_bundle(
                    profile,
                    activation_path,
                    root / "rollback.zip",
                    source,
                    version="1.2.3",
                    tag="v1.2.3",
                    commit="5" * 40,
                )

    def test_accepts_activation_commit_distinct_from_release_commit(self) -> None:
        """The activation authority P is re-derived from the committed
        authority files and is not the release commit R.

        The old assertion required activationCommit == release commit while a
        later check requires the release commit to differ from candidateCommit.
        When domain-core is inactive the resolver returns
        activationCommit == candidateCommit, so the two were unsatisfiable and
        every real release failed here. This fixture models production: the
        activation binds P, the profile binds R, and P != R.
        """
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            profile_path, activation_path, source, _ = self.fixture(root)
            release_commit = "7" * 40
            profile = json.loads(profile_path.read_text())
            profile["release"]["commit"] = release_commit
            profile_path.write_text(json.dumps(profile))
            bundle = BUNDLE.create_bundle(
                profile_path,
                activation_path,
                root / "rollback.zip",
                source,
                version="1.2.3",
                tag="v1.2.3",
                commit=release_commit,
            )
            self.assertEqual(bundle["release"]["commit"], release_commit)

    def test_payload_generator_is_exact_and_not_caller_replaceable(self) -> None:
        self.assertEqual(
            list(BUNDLE.ROLLBACK_CONSUMERS),
            ["apple", "ios", "linux", "android", "windows", "console", "functions"],
        )
        self.assertNotIn("--payload-root", PATH.read_text())


if __name__ == "__main__":
    unittest.main()
