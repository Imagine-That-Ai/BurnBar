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
    @staticmethod
    def allow_ancestry(_ancestor: str, _descendant: str) -> None:
        return None

    def fixture(self, root: Path, *, rust_mode: bool = False) -> tuple[Path, Path, Path, dict]:
        candidate = {
            "candidateCommit": "1" * 40,
            "coreVersion": "0.3.0",
            "abiVersion": 3,
            "sourceSha256": "2" * 64,
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
                    commit="5" * 40,
                    ancestry_verifier=self.allow_ancestry,
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
                    self.assertTrue(
                        all(
                            line.endswith("=legacy") for line in decoded["environment"] if line.endswith("_MODE=legacy")
                        )
                    )

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
                    ancestry_verifier=self.allow_ancestry,
                )

    def test_accepts_distinct_candidate_activation_and_release_commits(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            profile, activation_path, source, activation = self.fixture(root)
            release_commit = "5" * 40
            edges: list[tuple[str, str]] = []

            manifest = BUNDLE.create_bundle(
                profile,
                activation_path,
                root / "rollback.zip",
                source,
                version="1.2.3",
                tag="v1.2.3",
                commit=release_commit,
                ancestry_verifier=lambda ancestor, descendant: edges.append((ancestor, descendant)),
            )

            self.assertEqual(
                edges,
                [
                    (activation["candidateCommit"], activation["activationCommit"]),
                    (activation["activationCommit"], release_commit),
                ],
            )
            self.assertEqual(manifest["activation"]["activationCommit"], activation["activationCommit"])
            self.assertEqual(manifest["release"]["commit"], release_commit)

    def test_rejects_release_outside_activation_ancestry(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            profile, activation_path, source, activation = self.fixture(root)

            def verify(ancestor: str, descendant: str) -> None:
                if ancestor == activation["activationCommit"]:
                    raise ValueError("not an ancestor")

            with self.assertRaisesRegex(ValueError, "activation P must be an ancestor of release D"):
                BUNDLE.create_bundle(
                    profile,
                    activation_path,
                    root / "rollback.zip",
                    source,
                    version="1.2.3",
                    tag="v1.2.3",
                    commit="5" * 40,
                    ancestry_verifier=verify,
                )

    def test_payload_generator_is_exact_and_not_caller_replaceable(self) -> None:
        self.assertEqual(
            list(BUNDLE.ROLLBACK_CONSUMERS),
            ["apple", "ios", "linux", "android", "windows", "console", "functions"],
        )
        self.assertNotIn("--payload-root", PATH.read_text())


if __name__ == "__main__":
    unittest.main()
