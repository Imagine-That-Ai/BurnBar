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
    def test_bundle_has_exact_deterministic_legacy_content(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
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
            profile = {
                "schemaVersion": 1,
                "name": "public-production-rollback",
                "artifactAuthority": "signed",
                "distribution": "public",
                "rolloutChannel": None,
                "evidenceEnabled": False,
                "modes": {domain: "legacy" for domain in BUNDLE.DOMAIN_ENV_KEYS},
                "candidateIdentity": candidate,
            }
            profile_path = root / "profile.json"
            activation_path = root / "activation.json"
            profile_path.write_text(json.dumps(profile))
            activation_path.write_text(json.dumps(activation))
            source_archive = root / "legacy-source.tar.gz"
            source_archive.write_bytes(b"deterministic legacy source archive" * 16)
            outputs = [root / "one.zip", root / "two.zip"]
            for output in outputs:
                BUNDLE.create_bundle(
                    profile_path,
                    activation_path,
                    output,
                    source_archive,
                    version="1.2.3",
                    tag="v1.2.3",
                    commit=activation["activationCommit"],
                )
            self.assertEqual(
                hashlib.sha256(outputs[0].read_bytes()).digest(),
                hashlib.sha256(outputs[1].read_bytes()).digest(),
            )
            with zipfile.ZipFile(outputs[0]) as archive:
                self.assertEqual(tuple(archive.namelist()), BUNDLE.ENTRIES)
                embedded_profile = json.loads(archive.read(BUNDLE.ENTRIES[1]))
                manifest = json.loads(archive.read(BUNDLE.ENTRIES[0]))
                environment = archive.read("rollback.env").decode()
                embedded_source = archive.read("legacy-source.tar.gz")
            self.assertTrue(all(mode == "legacy" for mode in embedded_profile["modes"].values()))
            self.assertEqual(manifest["candidate"], candidate)
            self.assertEqual(manifest["activation"], activation)
            self.assertEqual(manifest["retentionPolicy"], "retain_until_legacy_deletion_complete")
            self.assertEqual(embedded_source, source_archive.read_bytes())
            self.assertIn("OPENBURNBAR_DOMAIN_CORE_BUILD_PROFILE=public-production-rollback\n", environment)
            self.assertIn("OPENBURNBAR_DOMAIN_CORE_QUOTA_MODE=legacy\n", environment)
            self.assertEqual(
                manifest["restoration"]["sourceArchive"]["sha256"],
                hashlib.sha256(embedded_source).hexdigest(),
            )

    def test_rejects_rust_mode_in_rollback_payload(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            candidate = {
                "candidateCommit": "1" * 40,
                "coreVersion": "0.3.0",
                "abiVersion": 3,
                "sourceSha256": "2" * 64,
            }
            profile = root / "profile.json"
            activation = root / "activation.json"
            profile.write_text(
                json.dumps(
                    {
                        "schemaVersion": 1,
                        "name": "public-production-rollback",
                        "artifactAuthority": "signed",
                        "distribution": "public",
                        "rolloutChannel": None,
                        "evidenceEnabled": False,
                        "modes": {"quota": "rust"},
                        "candidateIdentity": candidate,
                    }
                )
            )
            activation.write_text(
                json.dumps(
                    {
                        **candidate,
                        "activationCommit": "3" * 40,
                        "changedPathsSha256": "4" * 64,
                    }
                )
            )
            source_archive = root / "legacy-source.tar.gz"
            source_archive.write_bytes(b"legacy source" * 20)
            with self.assertRaisesRegex(ValueError, "every declared domain"):
                BUNDLE.create_bundle(
                    profile,
                    activation,
                    root / "rollback.zip",
                    source_archive,
                    version="1.2.3",
                    tag="v1.2.3",
                    commit="3" * 40,
                )


if __name__ == "__main__":
    unittest.main()
