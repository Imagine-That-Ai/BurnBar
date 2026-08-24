from __future__ import annotations

import hashlib
import importlib.util
import io
import json
import tarfile
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

# These fixtures deliberately mirror the shape of a real release rather than a
# tidy set of matching constants. Earlier fixtures set the release version, the
# core version and every commit to the same value, which let a family of
# unsatisfiable assertions pass here and fail every production release:
#   * the release train (1.0.40+repair.N) is not the domain-core version (0.1.0)
#   * the activation authority P is not the release commit R
#   * neither is the candidate commit C
CANDIDATE_COMMIT = "1" * 40   # C
ACTIVATION_COMMIT = "2" * 40  # P, re-derived from the committed authority files
RELEASE_COMMIT = "3" * 40     # R
CORE_VERSION = "0.1.0"
RELEASE_VERSION = "1.0.40+repair.25"
RELEASE_TAG = f"v{RELEASE_VERSION}"
SOURCE_ROOT = f"OpenBurnBar-{RELEASE_VERSION}-legacy-source"


def source_archive_bytes(root: str = SOURCE_ROOT, *, body: bytes = b"legacy tree") -> bytes:
    """Build a `git archive`-shaped tar.gz rooted at ``root``."""
    buffer = io.BytesIO()
    with tarfile.open(fileobj=buffer, mode="w:gz") as archive:
        directory = tarfile.TarInfo(root)
        directory.type = tarfile.DIRTYPE
        archive.addfile(directory)
        entry = tarfile.TarInfo(f"{root}/README")
        entry.size = len(body)
        archive.addfile(entry, io.BytesIO(body))
    return buffer.getvalue()


class RollbackBundleTests(unittest.TestCase):
    def fixture(self, root: Path, *, rust_mode: bool = False) -> tuple[Path, Path, Path, dict]:
        candidate = {
            "candidateCommit": CANDIDATE_COMMIT,
            "coreVersion": CORE_VERSION,
            "abiVersion": 3,
            "sourceSha256": "5" * 64,
        }
        activation = {
            **candidate,
            "activationCommit": ACTIVATION_COMMIT,
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
                "version": RELEASE_VERSION,
                "tag": RELEASE_TAG,
                "commit": RELEASE_COMMIT,
            },
        }
        profile_path = root / "profile.json"
        activation_path = root / "activation.json"
        source_path = root / "legacy-source.tar.gz"
        profile_path.write_text(json.dumps(profile))
        activation_path.write_text(json.dumps(activation))
        source_path.write_bytes(source_archive_bytes())
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
                    version=RELEASE_VERSION,
                    tag=RELEASE_TAG,
                    commit=RELEASE_COMMIT,
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
                    version=RELEASE_VERSION,
                    tag=RELEASE_TAG,
                    commit=RELEASE_COMMIT,
                )

    def test_rejects_source_archive_that_is_not_a_gzip_stream(self) -> None:
        """A source archive that is not a gzip stream must be rejected so a
        rollback bundle cannot ship an unreadable source tree."""
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            profile, activation_path, source, activation = self.fixture(root)
            source.write_bytes(b"unrelated legacy source archive" * 16)
            with self.assertRaisesRegex(ValueError, "must be a gzip stream"):
                BUNDLE.create_bundle(
                    profile,
                    activation_path,
                    root / "rollback.zip",
                    source,
                    version=RELEASE_VERSION,
                    tag=RELEASE_TAG,
                    commit=RELEASE_COMMIT,
                )

    def test_rejects_source_archive_not_rooted_at_release_prefix(self) -> None:
        """A well-formed archive exported for a different release must be
        rejected so a rollback bundle cannot ship a foreign source tree."""
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            profile, activation_path, source, activation = self.fixture(root)
            source.write_bytes(source_archive_bytes("OpenBurnBar-9.9.9-legacy-source"))
            with self.assertRaisesRegex(
                ValueError, "not rooted at the release source prefix"
            ):
                BUNDLE.create_bundle(
                    profile,
                    activation_path,
                    root / "rollback.zip",
                    source,
                    version=RELEASE_VERSION,
                    tag=RELEASE_TAG,
                    commit=RELEASE_COMMIT,
                )
    def test_accepts_release_version_distinct_from_core_version(self) -> None:
        """The release train and the domain-core version are independent.

        The old assertion required version == candidate.coreVersion. Every real
        release ships a release version (1.0.40+repair.N) that differs from the
        domain-core version (0.1.0), so that check could never hold in
        production and failed the release at its final step. It only passed
        here because the fixtures set both to the same string.
        """
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            profile, activation_path, source, activation = self.fixture(root)
            self.assertNotEqual(RELEASE_VERSION, CORE_VERSION)
            bundle = BUNDLE.create_bundle(
                profile,
                activation_path,
                root / "rollback.zip",
                source,
                version=RELEASE_VERSION,
                tag=RELEASE_TAG,
                commit=RELEASE_COMMIT,
            )
            self.assertEqual(bundle["release"]["version"], RELEASE_VERSION)
            self.assertEqual(bundle["candidate"]["coreVersion"], CORE_VERSION)

    def test_rejects_malformed_candidate_core_version(self) -> None:
        """The candidate core version must still be a real version string."""
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            profile_path, activation_path, source, _ = self.fixture(root)
            for path in (profile_path, activation_path):
                document = json.loads(path.read_text())
                target = document.get("candidateIdentity", document)
                target["coreVersion"] = "not-a-version"
                path.write_text(json.dumps(document))
            with self.assertRaisesRegex(ValueError, "core version is invalid"):
                BUNDLE.create_bundle(
                    profile_path,
                    activation_path,
                    root / "rollback.zip",
                    source,
                    version=RELEASE_VERSION,
                    tag=RELEASE_TAG,
                    commit=RELEASE_COMMIT,
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
                    version=RELEASE_VERSION,
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
                    version=RELEASE_VERSION,
                    tag=RELEASE_TAG,
                    commit=RELEASE_COMMIT,
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
                    version=RELEASE_VERSION,
                    tag=RELEASE_TAG,
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
                    version=RELEASE_VERSION,
                    tag=RELEASE_TAG,
                    commit="5" * 40,
                )

    def test_accepts_activation_commit_distinct_from_release_commit(self) -> None:
        """The activation authority P is re-derived from the committed
        authority files and is not the release commit R.

        The old assertion required activationCommit == release commit while a
        later check requires the release commit to differ from candidateCommit.
        When domain-core is inactive the resolver returns
        activationCommit == candidateCommit, so the two were unsatisfiable and
        every real release failed here.
        """
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            profile_path, activation_path, source, activation = self.fixture(root)
            self.assertNotEqual(activation["activationCommit"], RELEASE_COMMIT)
            bundle = BUNDLE.create_bundle(
                profile_path,
                activation_path,
                root / "rollback.zip",
                source,
                version=RELEASE_VERSION,
                tag=RELEASE_TAG,
                commit=RELEASE_COMMIT,
            )
            self.assertEqual(bundle["release"]["commit"], RELEASE_COMMIT)
            self.assertEqual(bundle["activation"]["activationCommit"], ACTIVATION_COMMIT)
    def test_rejects_truncated_source_archive(self) -> None:
        """Validation must consume the whole stream: a truncated archive is
        only detectable past its first entry."""
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            profile, activation_path, source, _ = self.fixture(root)
            # Incompressible body, so the truncated half stays well above the
            # minimum-size floor and the stream walk is what rejects it.
            body = b"".join(
                hashlib.sha256(index.to_bytes(4, "big")).digest() for index in range(4096)
            )
            whole = source_archive_bytes(body=body)
            source.write_bytes(whole[: len(whole) // 2])
            with self.assertRaisesRegex(ValueError, "not a readable tar.gz"):
                BUNDLE.create_bundle(
                    profile,
                    activation_path,
                    root / "rollback.zip",
                    source,
                    version=RELEASE_VERSION,
                    tag=RELEASE_TAG,
                    commit=RELEASE_COMMIT,
                )

    def test_rejects_source_archive_member_escaping_the_release_root(self) -> None:
        """A later member that escapes the release root must be rejected, not
        skipped because the first entry looked correct."""
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            profile, activation_path, source, _ = self.fixture(root)
            buffer = io.BytesIO()
            with tarfile.open(fileobj=buffer, mode="w:gz") as archive:
                good = tarfile.TarInfo(SOURCE_ROOT)
                good.type = tarfile.DIRTYPE
                archive.addfile(good)
                escape = tarfile.TarInfo(f"{SOURCE_ROOT}/../../etc/passwd")
                escape.size = 1
                archive.addfile(escape, io.BytesIO(b"x"))
            source.write_bytes(buffer.getvalue())
            with self.assertRaisesRegex(ValueError, "unsafe member path"):
                BUNDLE.create_bundle(
                    profile,
                    activation_path,
                    root / "rollback.zip",
                    source,
                    version=RELEASE_VERSION,
                    tag=RELEASE_TAG,
                    commit=RELEASE_COMMIT,
                )

    def test_accepts_canonical_semver_core_version_variants(self) -> None:
        """coreVersion must accept the prerelease and build-qualified forms the
        committed domain-core schemas allow."""
        for core_version in ("0.1.0", "0.2.0-rc.1", "0.2.0+build.7"):
            with self.subTest(core_version=core_version):
                self.assertTrue(BUNDLE.CORE_VERSION.fullmatch(core_version))
        for invalid in ("not-a-version", "01.2.3", "1.2"):
            with self.subTest(invalid=invalid):
                self.assertIsNone(BUNDLE.CORE_VERSION.fullmatch(invalid))

    def test_payload_generator_is_exact_and_not_caller_replaceable(self) -> None:
        self.assertEqual(
            list(BUNDLE.ROLLBACK_CONSUMERS),
            ["apple", "ios", "linux", "android", "windows", "console", "functions"],
        )
        self.assertNotIn("--payload-root", PATH.read_text())


if __name__ == "__main__":
    unittest.main()
