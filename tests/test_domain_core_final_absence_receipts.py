from __future__ import annotations

import hashlib
import importlib.util
import json
import sys
import tempfile
import unittest
import zipfile
from unittest import mock
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
PATH = ROOT / "scripts/ci/verify-domain-core-final-absence-receipts.py"
SPEC = importlib.util.spec_from_file_location("final_absence_verify_test", PATH)
assert SPEC and SPEC.loader
VERIFY = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = VERIFY
SPEC.loader.exec_module(VERIFY)
CREATE_PATH = ROOT / "scripts/ci/create-domain-core-final-absence-receipt.py"
CREATE_SPEC = importlib.util.spec_from_file_location("final_absence_create_test", CREATE_PATH)
assert CREATE_SPEC and CREATE_SPEC.loader
CREATE = importlib.util.module_from_spec(CREATE_SPEC)
sys.modules[CREATE_SPEC.name] = CREATE
CREATE_SPEC.loader.exec_module(CREATE)


class FakeVerifier:
    def __init__(self) -> None:
        self.predicates: dict[tuple[str, str], dict] = {}

    def _verify_bundle(self, artifact: Path, bundle: Path, **_kwargs):
        key = (artifact.parent.name, bundle.name.removesuffix(".predicate.sigstore.json"))
        return [{"verificationResult": {"statement": {"predicate": self.predicates[key]}}}]


class FinalAbsenceReceiptTests(unittest.TestCase):
    def creator_fixture(self):
        root = Path(self.enterContext(tempfile.TemporaryDirectory()))
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
        paths = {}
        for name, value in (
            ("candidate", candidate), ("activation", activation),
            ("identity", {"observed": candidate}), ("manifest", {"sourceRoots": {}, "rows": []}),
        ):
            path = root / f"{name}.json"
            path.write_text(json.dumps(value))
            paths[name] = path
        artifact = root / "artifact.zip"
        with zipfile.ZipFile(artifact, "w") as archive:
            archive.writestr("bin/app.exe", b"MZ\0rust-only")
        return root, paths, artifact, candidate, activation

    def test_creator_accepts_p_ancestor_of_later_d(self) -> None:
        root, paths, artifact, _candidate, _activation = self.creator_fixture()
        with (
            mock.patch.object(CREATE, "absent_rows", return_value=["quota.claude_statusline"]),
            mock.patch.object(CREATE.GATE, "require_ancestor") as ancestor,
        ):
            receipt = CREATE.create(
                root, paths["manifest"], "apple", artifact, paths["identity"],
                paths["candidate"], paths["activation"], version="1.2.3", tag="v1.2.3", commit="6" * 40,
            )
        ancestor.assert_called_once_with(root, "3" * 40, "6" * 40, mock.ANY)
        self.assertEqual(receipt["release"]["commit"], "6" * 40)
        self.assertEqual(receipt["activation"]["activationCommit"], "3" * 40)

    def test_creator_rejects_d_equal_p(self) -> None:
        root, paths, artifact, _candidate, _activation = self.creator_fixture()
        with mock.patch.object(CREATE, "absent_rows", return_value=["quota.claude_statusline"]), self.assertRaisesRegex(ValueError, "not activation P"):
            CREATE.create(
                root, paths["manifest"], "apple", artifact, paths["identity"],
                paths["candidate"], paths["activation"], version="1.2.3", tag="v1.2.3", commit="3" * 40,
            )

    def test_creator_rejects_nonancestor_p(self) -> None:
        root, paths, artifact, _candidate, _activation = self.creator_fixture()
        with (
            mock.patch.object(CREATE, "absent_rows", return_value=["quota.claude_statusline"]),
            mock.patch.object(CREATE.GATE, "require_ancestor", side_effect=CREATE.GATE.GateError("not ancestor")),
            self.assertRaisesRegex(ValueError, "not ancestor"),
        ):
            CREATE.create(
                root, paths["manifest"], "apple", artifact, paths["identity"],
                paths["candidate"], paths["activation"], version="1.2.3", tag="v1.2.3", commit="6" * 40,
            )

    def test_creator_rejects_changed_core_tuple(self) -> None:
        root, paths, artifact, _candidate, activation = self.creator_fixture()
        paths["activation"].write_text(json.dumps({**activation, "coreVersion": "0.4.0"}))
        with mock.patch.object(CREATE, "absent_rows", return_value=["quota.claude_statusline"]), self.assertRaisesRegex(ValueError, "unchanged candidate tuple"):
            CREATE.create(
                root, paths["manifest"], "apple", artifact, paths["identity"],
                paths["candidate"], paths["activation"], version="1.2.3", tag="v1.2.3", commit="6" * 40,
            )

    def evidence(self) -> tuple[Path, FakeVerifier]:
        root = Path(self.enterContext(tempfile.TemporaryDirectory()))
        verifier = FakeVerifier()
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
        for consumer in VERIFY.CONSUMERS:
            directory = root / consumer
            directory.mkdir()
            artifact = directory / "artifact"
            with zipfile.ZipFile(artifact, "w") as archive:
                suffix = ".js" if consumer in {"console", "functions"} else ".exe"
                archive.writestr(f"bin/runtime{suffix}", b"MZ\0rust-only")
            scan_report = VERIFY.SCANNER.scan(consumer, artifact)
            if consumer == "ios":
                (directory / "ipa").write_bytes(b"exact processed ipa")
            for domain in VERIFY.GATE.PROFILE_DOMAIN_ROWS:
                rows = VERIFY.expected_rows(consumer, domain)
                if not rows:
                    continue
                predicate = {
                    "schemaVersion": 2,
                    "predicateType": VERIFY.GATE.RELEASE_PREDICATE_TYPES[consumer],
                    "consumer": consumer,
                    "domain": domain,
                    "artifact": {
                        "fileName": f"OpenBurnBar-{consumer}",
                        "sha256": hashlib.sha256(artifact.read_bytes()).hexdigest(),
                    },
                    "release": {
                        "version": "1.2.3",
                        "tag": (
                            "windows-v1.2.3" if consumer == "windows" else
                            "linux-v1.2.3" if consumer == "linux" else
                            "v1.2.3"
                        ),
                        "commit": "6" * 40,
                    },
                    "candidate": candidate,
                    "activation": activation,
                    "legacyAbsence": {
                        "schemaVersion": 1,
                        "predicateType": VERIFY.ABSENCE_TYPE,
                        "releaseCommit": "6" * 40,
                        "authorityActivationCommit": activation["activationCommit"],
                        "deletionInventorySha256": "5" * 64,
                        "rowIds": rows,
                        "artifactScan": {
                            "reportSha256": VERIFY.GATE.canonical_json_sha256(scan_report),
                            "artifactSha256": hashlib.sha256(artifact.read_bytes()).hexdigest(),
                            "ruleSetSha256": scan_report["ruleSetSha256"],
                            "inspectedMemberCount": len(scan_report["inspectedMembers"]),
                            "report": scan_report,
                        },
                    },
                }
                if consumer == "ios":
                    predicate["appStoreConnectReceipt"] = {
                        "ipaSha256": hashlib.sha256((directory / "ipa").read_bytes()).hexdigest()
                    }
                (directory / f"{domain}.predicate.sigstore.json").write_text("{}\n")
                verifier.predicates[(consumer, domain)] = predicate
        return root, verifier

    def test_accepts_release_b_exact_seven_surfaces(self) -> None:
        root, verifier = self.evidence()
        result = VERIFY.run(root, verifier, "6" * 40, "1.2.3", lambda _p, _d: None)
        self.assertEqual(result["consumers"], list(VERIFY.CONSUMERS))
        self.assertEqual(result["coveredRows"], sorted(VERIFY.GATE.ROW_IDS))

    def test_rejects_missing_consumer(self) -> None:
        root, verifier = self.evidence()
        for child in (root / "ios").iterdir():
            child.unlink()
        (root / "ios").rmdir()
        with self.assertRaisesRegex(VERIFY.GATE.GateError, "consumer set mismatch"):
            VERIFY.run(root, verifier, "6" * 40, "1.2.3", lambda _p, _d: None)

    def test_rejects_exact_ipa_drift(self) -> None:
        root, verifier = self.evidence()
        (root / "ios/ipa").write_bytes(b"different ipa")
        with self.assertRaisesRegex(VERIFY.GATE.GateError, "does not bind the staged IPA"):
            VERIFY.run(root, verifier, "6" * 40, "1.2.3", lambda _p, _d: None)

    def test_rejects_activation_drift(self) -> None:
        root, verifier = self.evidence()
        predicate = verifier.predicates[("windows", "cloudVault")]
        predicate["activation"]["activationCommit"] = "9" * 40
        verifier.predicates[("windows", "cloudVault")] = predicate
        with self.assertRaisesRegex(VERIFY.GATE.GateError, "identity is invalid"):
            VERIFY.run(root, verifier, "6" * 40, "1.2.3", lambda _p, _d: None)

    def test_rejects_release_b_built_from_activation_p(self) -> None:
        root, verifier = self.evidence()
        with self.assertRaisesRegex(VERIFY.GATE.GateError, "identity is invalid"):
            VERIFY.run(root, verifier, "3" * 40, "1.2.3", lambda _p, _d: None)

    def test_rejects_nonancestor_activation(self) -> None:
        root, verifier = self.evidence()
        def reject(_ancestor, _descendant):
            raise VERIFY.GATE.GateError("not an ancestor")
        with self.assertRaisesRegex(VERIFY.GATE.GateError, "not an ancestor"):
            VERIFY.run(root, verifier, "6" * 40, "1.2.3", reject)

    def test_rejects_changed_candidate_fingerprint(self) -> None:
        root, verifier = self.evidence()
        predicate = verifier.predicates[("linux", "pricing")]
        predicate["candidate"] = {**predicate["candidate"], "sourceSha256": "9" * 64}
        verifier.predicates[("linux", "pricing")] = predicate
        with self.assertRaisesRegex(VERIFY.GATE.GateError, "identity is invalid"):
            VERIFY.run(root, verifier, "6" * 40, "1.2.3", lambda _p, _d: None)


if __name__ == "__main__":
    unittest.main()
