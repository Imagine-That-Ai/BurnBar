from __future__ import annotations

import hashlib
import importlib.util
import json
import tarfile
import tempfile
import unittest
import zipfile
from pathlib import Path

try:
    from tests.support.domain_core_rollback_archive import (
        ArchiveMember,
        create_candidate_repository,
        source_archive_members,
        write_git_source_archive,
        write_pax_source_archive,
    )
except ModuleNotFoundError:
    from support.domain_core_rollback_archive import (
        ArchiveMember,
        create_candidate_repository,
        source_archive_members,
        write_git_source_archive,
        write_pax_source_archive,
    )


ROOT = Path(__file__).resolve().parents[1]
PATH = ROOT / "scripts/ci/create-domain-core-rollback-bundle.py"
SPEC = importlib.util.spec_from_file_location("domain_core_rollback_bundle", PATH)
assert SPEC and SPEC.loader
BUNDLE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(BUNDLE)
GATE_PATH = ROOT / "scripts/ci/domain-core-union-gate.py"
GATE_SPEC = importlib.util.spec_from_file_location("domain_core_union_gate", GATE_PATH)
assert GATE_SPEC and GATE_SPEC.loader
GATE = importlib.util.module_from_spec(GATE_SPEC)
GATE_SPEC.loader.exec_module(GATE)


class RollbackBundleTests(unittest.TestCase):
    def source_files(self) -> dict[str, bytes]:
        return {
            "Cargo.toml": b"[workspace]\nresolver = \"2\"\n",
            "domain-core/src/lib.rs": (
                b"pub const DOMAIN_CORE_ABI_VERSION: u32 = 3;\n"
            ),
        }

    def write_source_archive(
        self,
        path: Path,
        candidate: dict,
        *,
        source_files: dict[str, bytes] | None = None,
        archive_commit: str | None = None,
        prefix_version: str = "1.2.3",
    ) -> None:
        files = self.source_files() if source_files is None else source_files
        members = source_archive_members(
            candidate,
            version=prefix_version,
            source_files=files,
            extra_repository_files={"README.md": b"retained candidate source\n"},
        )
        write_pax_source_archive(
            path,
            candidate_commit=(
                candidate["candidateCommit"]
                if archive_commit is None
                else archive_commit
            ),
            members=members,
        )

    def source_archive_members(
        self,
        candidate: dict,
        *,
        source_files: dict[str, bytes] | None = None,
        prefix_version: str = "1.2.3",
    ) -> list[ArchiveMember]:
        return source_archive_members(
            candidate,
            version=prefix_version,
            source_files=(
                self.source_files() if source_files is None else source_files
            ),
            extra_repository_files={"README.md": b"retained candidate source\n"},
        )

    def write_members(
        self,
        path: Path,
        candidate: dict,
        members: list[ArchiveMember],
        *,
        archive_commit: str | None = None,
    ) -> None:
        write_pax_source_archive(
            path,
            candidate_commit=(
                candidate["candidateCommit"]
                if archive_commit is None
                else archive_commit
            ),
            members=members,
        )

    def assert_archive_rejected(
        self,
        root: Path,
        profile: Path,
        activation_path: Path,
        source: Path,
        activation: dict,
        message: str,
    ) -> None:
        with self.assertRaisesRegex(ValueError, message):
            BUNDLE.create_bundle(
                profile,
                activation_path,
                root / "rollback.zip",
                source,
                version="1.2.3",
                tag="v1.2.3",
                commit=activation["activationCommit"],
                repository_root=root / "candidate-repo",
            )

    def fixture(self, root: Path, *, rust_mode: bool = False) -> tuple[Path, Path, Path, dict]:
        source_files = self.source_files()
        source_sha256 = BUNDLE.source_fingerprint(source_files)
        repository, candidate_commit = create_candidate_repository(
            root,
            source_files=source_files,
            core_version="0.1.0",
            abi_version=3,
            source_sha256=source_sha256,
        )
        candidate = {
            "candidateCommit": candidate_commit,
            "coreVersion": "0.1.0",
            "abiVersion": 3,
            "sourceSha256": source_sha256,
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
        write_git_source_archive(
            repository,
            source_path,
            candidate_commit=candidate_commit,
            version="1.2.3",
        )
        return profile_path, activation_path, source_path, activation

    def test_source_fingerprint_matches_golden_vector_and_canonical_gate(
        self,
    ) -> None:
        files = self.source_files()
        expected = "778907b134906842f57af55faf0eb6225c3b59d0b0ee3f3eceeea3cc189096d6"
        self.assertEqual(BUNDLE.source_fingerprint(files), expected)
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            crate_root = root / "crates/openburnbar-domain-core"
            for name, contents in files.items():
                path = crate_root / name
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_bytes(contents)
            manifest = {
                "sourceRoots": ["Cargo.toml", "domain-core/src"],
                "sourceSha256": expected,
            }
            self.assertEqual(
                GATE.calculate_source_fingerprint(root, manifest),
                expected,
            )

    def test_archive_path_normalization_rejects_every_unsafe_form(self) -> None:
        for name in (
            "",
            "/absolute",
            "relative\\windows",
            "relative//double",
            "relative/./dot",
            "relative/../traversal",
        ):
            with self.subTest(name=name):
                with self.assertRaisesRegex(ValueError, "unsafe path"):
                    BUNDLE.normalized_archive_path(name)
        self.assertEqual(
            BUNDLE.normalized_archive_path("relative/canonical").as_posix(),
            "relative/canonical",
        )

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
                    repository_root=root / "candidate-repo",
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
                    repository_root=root / "candidate-repo",
                )

    def test_rejects_unrelated_source_archive(self) -> None:
        """An archive whose embedded source fingerprint differs from the
        candidate must be rejected as unrelated retained source."""
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            profile, activation_path, source, activation = self.fixture(root)
            unrelated = self.source_files()
            unrelated["domain-core/src/lib.rs"] = b"pub fn unrelated() {}\n"
            self.write_source_archive(
                source,
                activation,
                source_files=unrelated,
            )
            with self.assertRaisesRegex(
                ValueError, "domain-core fingerprint does not match"
            ):
                BUNDLE.create_bundle(
                    profile,
                    activation_path,
                    root / "rollback.zip",
                    source,
                    version="1.2.3",
                    tag="v1.2.3",
                    commit=activation["activationCommit"],
                    repository_root=root / "candidate-repo",
                )

    def test_exact_candidate_archive_binding_rejects_omission_and_injection(
        self,
    ) -> None:
        for mutation in ("omit", "inject"):
            with self.subTest(mutation=mutation):
                with tempfile.TemporaryDirectory() as directory:
                    root = Path(directory)
                    _, _, source, activation = self.fixture(root)
                    expected = source.read_bytes()
                    members = self.source_archive_members(activation)
                    if mutation == "omit":
                        members = [
                            member
                            for member in members
                            if not member.name.endswith("/README.md")
                        ]
                    else:
                        root_name = "OpenBurnBar-1.2.3-legacy-source"
                        members.extend(
                            (
                                ArchiveMember(
                                    name=f"{root_name}/scripts",
                                    kind=tarfile.DIRTYPE,
                                ),
                                ArchiveMember(
                                    name=f"{root_name}/scripts/injected.sh",
                                    contents=b"#!/bin/sh\nexit 0\n",
                                ),
                            )
                        )
                    self.write_members(source, activation, members)
                    mutated = source.read_bytes()
                    BUNDLE.verify_source_archive(
                        mutated,
                        candidate=activation,
                        version="1.2.3",
                        expected_source_bytes=mutated,
                    )
                    with self.assertRaisesRegex(
                        ValueError,
                        "not the exact complete candidate git archive",
                    ):
                        BUNDLE.verify_source_archive(
                            mutated,
                            candidate=activation,
                            version="1.2.3",
                            expected_source_bytes=expected,
                        )

    def test_rejects_source_archive_from_another_candidate(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            profile, activation_path, source, activation = self.fixture(root)
            self.write_source_archive(
                source,
                activation,
                archive_commit="9" * 40,
            )
            with self.assertRaisesRegex(
                ValueError, "does not bind the candidate commit"
            ):
                BUNDLE.create_bundle(
                    profile,
                    activation_path,
                    root / "rollback.zip",
                    source,
                    version="1.2.3",
                    tag="v1.2.3",
                    commit=activation["activationCommit"],
                    repository_root=root / "candidate-repo",
                )

    def test_rejects_source_archive_with_foreign_release_prefix(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            profile, activation_path, source, activation = self.fixture(root)
            self.write_source_archive(
                source,
                activation,
                prefix_version="9.9.9",
            )
            with self.assertRaisesRegex(ValueError, "exact release prefix"):
                BUNDLE.create_bundle(
                    profile,
                    activation_path,
                    root / "rollback.zip",
                    source,
                    version="1.2.3",
                    tag="v1.2.3",
                    commit=activation["activationCommit"],
                    repository_root=root / "candidate-repo",
                )

    def test_rejects_unsafe_paths_inside_pax_archive(self) -> None:
        for unsafe_name in (
            "/absolute",
            "OpenBurnBar-1.2.3-legacy-source/../escape",
            "OpenBurnBar-1.2.3-legacy-source\\windows",
            "OpenBurnBar-1.2.3-legacy-source//double",
            "OpenBurnBar-1.2.3-legacy-source/./dot",
        ):
            with self.subTest(unsafe_name=unsafe_name):
                with tempfile.TemporaryDirectory() as directory:
                    root = Path(directory)
                    profile, activation_path, source, activation = self.fixture(root)
                    members = self.source_archive_members(activation)
                    members.insert(
                        0,
                        ArchiveMember(
                            name=unsafe_name,
                            contents=b"must never be accepted\n",
                        ),
                    )
                    self.write_members(source, activation, members)
                    self.assert_archive_rejected(
                        root,
                        profile,
                        activation_path,
                        source,
                        activation,
                        "unsafe path",
                    )

    def test_rejects_duplicate_archive_member(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            profile, activation_path, source, activation = self.fixture(root)
            members = self.source_archive_members(activation)
            duplicate = next(member for member in members if member.contents)
            members.append(
                ArchiveMember(
                    name=duplicate.name,
                    contents=duplicate.contents,
                    kind=duplicate.kind,
                )
            )
            self.write_members(source, activation, members)
            self.assert_archive_rejected(
                root,
                profile,
                activation_path,
                source,
                activation,
                "duplicate path",
            )

    def test_rejects_linked_and_special_archive_members(self) -> None:
        root_name = "OpenBurnBar-1.2.3-legacy-source"
        for kind, linkname in (
            (tarfile.SYMTYPE, "README.md"),
            (tarfile.LNKTYPE, f"{root_name}/README.md"),
            (tarfile.FIFOTYPE, ""),
        ):
            with self.subTest(kind=kind):
                with tempfile.TemporaryDirectory() as directory:
                    root = Path(directory)
                    profile, activation_path, source, activation = self.fixture(root)
                    members = self.source_archive_members(activation)
                    members.insert(
                        1,
                        ArchiveMember(
                            name=f"{root_name}/unsafe-entry",
                            kind=kind,
                            linkname=linkname,
                        ),
                    )
                    self.write_members(source, activation, members)
                    self.assert_archive_rejected(
                        root,
                        profile,
                        activation_path,
                        source,
                        activation,
                        "linked or special entry",
                    )

    def test_rejects_member_level_candidate_substitution(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            profile, activation_path, source, activation = self.fixture(root)
            members = self.source_archive_members(activation)
            member = next(item for item in members if item.contents)
            member.pax_headers["comment"] = "9" * 40
            self.write_members(source, activation, members)
            self.assert_archive_rejected(
                root,
                profile,
                activation_path,
                source,
                activation,
                "member does not bind the candidate commit",
            )

    def test_rejects_malformed_tar_gzip(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            profile, activation_path, source, activation = self.fixture(root)
            source.write_bytes(b"not a tar.gz archive" * 16)
            self.assert_archive_rejected(
                root,
                profile,
                activation_path,
                source,
                activation,
                "not a valid tar.gz",
            )

    def test_rejects_missing_or_invalid_union_manifest(self) -> None:
        cases = (
            ("missing", None),
            ("invalid-json", b"{"),
            ("wrong-type", b"[]\n"),
            ("wrong-schema", b'{"schemaVersion":2}\n'),
        )
        for label, contents in cases:
            with self.subTest(label=label):
                with tempfile.TemporaryDirectory() as directory:
                    root = Path(directory)
                    profile, activation_path, source, activation = self.fixture(root)
                    members = self.source_archive_members(activation)
                    manifest = next(
                        member
                        for member in members
                        if member.name.endswith("/union-abi-manifest.json")
                    )
                    if contents is None:
                        members.remove(manifest)
                    else:
                        manifest.contents = contents
                    self.write_members(source, activation, members)
                    self.assert_archive_rejected(
                        root,
                        profile,
                        activation_path,
                        source,
                        activation,
                        (
                            "omits the union ABI manifest"
                            if contents is None
                            else "invalid union ABI manifest"
                        ),
                    )

    def test_rejects_union_manifest_identity_substitution(self) -> None:
        for field, value in (
            ("coreVersion", "9.9.9"),
            ("abiVersion", 99),
            ("sourceSha256", "9" * 64),
        ):
            with self.subTest(field=field):
                with tempfile.TemporaryDirectory() as directory:
                    root = Path(directory)
                    profile, activation_path, source, activation = self.fixture(root)
                    members = self.source_archive_members(activation)
                    manifest_member = next(
                        member
                        for member in members
                        if member.name.endswith("/union-abi-manifest.json")
                    )
                    manifest = json.loads(manifest_member.contents)
                    manifest[field] = value
                    manifest_member.contents = (
                        json.dumps(manifest, sort_keys=True).encode() + b"\n"
                    )
                    self.write_members(source, activation, members)
                    self.assert_archive_rejected(
                        root,
                        profile,
                        activation_path,
                        source,
                        activation,
                        "union ABI identity does not match the candidate",
                    )

    def test_rejects_invalid_or_missing_source_roots(self) -> None:
        cases = (
            ("not-a-list", "Cargo.toml", "sourceRoots are invalid"),
            ("empty-list", [], "sourceRoots are invalid"),
            ("non-string", [1], "sourceRoots are invalid"),
            ("empty-string", [""], "unsafe path"),
            ("traversal", ["../outside"], "unsafe path"),
            ("missing", ["missing"], "omits required source root"),
        )
        for label, source_roots, message in cases:
            with self.subTest(label=label):
                with tempfile.TemporaryDirectory() as directory:
                    root = Path(directory)
                    profile, activation_path, source, activation = self.fixture(root)
                    members = self.source_archive_members(activation)
                    manifest_member = next(
                        member
                        for member in members
                        if member.name.endswith("/union-abi-manifest.json")
                    )
                    manifest = json.loads(manifest_member.contents)
                    manifest["sourceRoots"] = source_roots
                    manifest_member.contents = (
                        json.dumps(manifest, sort_keys=True).encode() + b"\n"
                    )
                    self.write_members(source, activation, members)
                    self.assert_archive_rejected(
                        root,
                        profile,
                        activation_path,
                        source,
                        activation,
                        message,
                    )

    def test_rejects_source_roots_that_resolve_only_to_ignored_target_files(
        self,
    ) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            profile, activation_path, source, activation = self.fixture(root)
            members = self.source_archive_members(activation)
            manifest_member = next(
                member
                for member in members
                if member.name.endswith("/union-abi-manifest.json")
            )
            manifest = json.loads(manifest_member.contents)
            manifest["sourceRoots"] = ["domain-core"]
            manifest_member.contents = (
                json.dumps(manifest, sort_keys=True).encode() + b"\n"
            )
            members = [
                member
                for member in members
                if not member.name.endswith("/domain-core/src/lib.rs")
            ]
            root_name = "OpenBurnBar-1.2.3-legacy-source"
            members.extend(
                (
                    ArchiveMember(
                        name=(
                            f"{root_name}/crates/openburnbar-domain-core/"
                            "domain-core/target"
                        ),
                        kind=tarfile.DIRTYPE,
                    ),
                    ArchiveMember(
                        name=(
                            f"{root_name}/crates/openburnbar-domain-core/"
                            "domain-core/target/generated.rs"
                        ),
                        contents=b"ignored build output\n",
                    ),
                )
            )
            self.write_members(source, activation, members)
            self.assert_archive_rejected(
                root,
                profile,
                activation_path,
                source,
                activation,
                "sourceRoots resolve to no files",
            )

    def test_target_directory_is_excluded_from_source_fingerprint(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            _, _, source, activation = self.fixture(root)
            members = self.source_archive_members(activation)
            manifest_member = next(
                member
                for member in members
                if member.name.endswith("/union-abi-manifest.json")
            )
            manifest = json.loads(manifest_member.contents)
            manifest["sourceRoots"] = ["Cargo.toml", "domain-core"]
            manifest_member.contents = (
                json.dumps(manifest, sort_keys=True).encode() + b"\n"
            )
            root_name = "OpenBurnBar-1.2.3-legacy-source"
            members.extend(
                (
                    ArchiveMember(
                        name=(
                            f"{root_name}/crates/openburnbar-domain-core/"
                            "domain-core/target"
                        ),
                        kind=tarfile.DIRTYPE,
                    ),
                    ArchiveMember(
                        name=(
                            f"{root_name}/crates/openburnbar-domain-core/"
                            "domain-core/target/generated.rs"
                        ),
                        contents=b"not part of the canonical fingerprint\n",
                    ),
                )
            )
            self.write_members(source, activation, members)
            source_bytes = source.read_bytes()
            BUNDLE.verify_source_archive(
                source_bytes,
                candidate=activation,
                version="1.2.3",
                expected_source_bytes=source_bytes,
            )

    def test_rejects_malformed_candidate_commit_before_git_archive(self) -> None:
        for candidate_commit in (None, "1" * 39, "A" * 40):
            with self.subTest(candidate_commit=candidate_commit):
                with tempfile.TemporaryDirectory() as directory:
                    root = Path(directory)
                    profile_path, activation_path, source, _ = self.fixture(root)
                    profile = json.loads(profile_path.read_text())
                    profile["candidateIdentity"]["candidateCommit"] = candidate_commit
                    profile_path.write_text(json.dumps(profile))
                    with self.assertRaisesRegex(
                        ValueError,
                        "candidate commit must be a full lowercase Git SHA-1",
                    ):
                        BUNDLE.create_bundle(
                            profile_path,
                            activation_path,
                            root / "rollback.zip",
                            source,
                            version="1.2.3",
                            tag="v1.2.3",
                            commit="3" * 40,
                            repository_root=root / "candidate-repo",
                        )

    def test_rejects_release_version_not_bound_to_profile_release(self) -> None:
        """The app release version is independent of candidate.coreVersion,
        but it must still match the exact release coordinates in the profile."""
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
                    version="2.0.0",
                    tag="v2.0.0",
                    commit=activation["activationCommit"],
                    repository_root=root / "candidate-repo",
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
                    repository_root=root / "candidate-repo",
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
                    repository_root=root / "candidate-repo",
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
                    repository_root=root / "candidate-repo",
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
                    repository_root=root / "candidate-repo",
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
                repository_root=root / "candidate-repo",
            )
            self.assertEqual(bundle["release"]["commit"], release_commit)

    def test_accepts_app_release_version_distinct_from_candidate_core_version(
        self,
    ) -> None:
        """The rollback bundle binds both identities without conflating them:
        the app release train labels the artifact while candidate.coreVersion
        identifies the retained shared Rust source."""
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            profile_path, activation_path, source, activation = self.fixture(root)
            bundle = BUNDLE.create_bundle(
                profile_path,
                activation_path,
                root / "rollback.zip",
                source,
                version="1.2.3",
                tag="v1.2.3",
                commit=activation["activationCommit"],
                repository_root=root / "candidate-repo",
            )
            self.assertEqual(bundle["release"]["version"], "1.2.3")
            self.assertEqual(bundle["candidate"]["coreVersion"], "0.1.0")

    def test_payload_generator_is_exact_and_not_caller_replaceable(self) -> None:
        self.assertEqual(
            list(BUNDLE.ROLLBACK_CONSUMERS),
            ["apple", "ios", "linux", "android", "windows", "console", "functions"],
        )
        self.assertNotIn("--payload-root", PATH.read_text())


if __name__ == "__main__":
    unittest.main()
