#!/usr/bin/env python3
"""Contract tests for append-only stable-release and rollback receipt writers."""

from __future__ import annotations

import importlib.util
import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock


ROOT = Path(__file__).resolve().parents[1]


def load(name: str, path: Path):
    spec = importlib.util.spec_from_file_location(name, path)
    if spec is None or spec.loader is None:
        raise RuntimeError(f"cannot load {path}")
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module


STABLE = load(
    "domain_core_stable_receipt_writer",
    ROOT / "scripts/ops/create-domain-core-stable-receipt.py",
)


class LifecycleReceiptWriterTests(unittest.TestCase):
    def test_both_writers_expose_bounded_required_cli(self) -> None:
        for script in (
            "scripts/ops/create-domain-core-stable-receipt.py",
            "scripts/ops/create-domain-core-rollback-receipt.py",
        ):
            result = subprocess.run(
                [sys.executable, script, "--help"],
                cwd=ROOT,
                check=False,
                capture_output=True,
                text=True,
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn("--authority-generation", result.stdout)
            self.assertIn("--approved-at", result.stdout)

    def test_stable_writer_rejects_future_approval_before_reading_authority(
        self,
    ) -> None:
        with self.assertRaisesRegex(STABLE.GATE.GateError, "cannot be in the future"):
            STABLE.create_receipt(
                ROOT,
                row_id="quota.claude_statusline",
                generation=1,
                activation_commit="a" * 40,
                release_paths=[],
                rollback_path=ROOT / "missing.json",
                approved_by="@release-owner",
                approved_at="2999-01-01T00:00:00Z",
            )

    def test_writers_use_create_only_append_semantics(self) -> None:
        stable = (ROOT / "scripts/ops/create-domain-core-stable-receipt.py").read_text()
        rollback = (ROOT / "scripts/ops/create-domain-core-rollback-receipt.py").read_text()
        for source in (stable, rollback):
            self.assertIn("WRITER.append_only", source)
            self.assertIn("WRITER.serialized", source)

    def test_stable_writer_reuses_full_gate_before_immutable_append(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            repo = Path(directory).resolve()
            row_id = "quota.claude_statusline"
            promotion_relative = f"{STABLE.GATE.RECEIPT_ROOT}/{row_id}/1/promotion.json"
            attestation_relative = f"{STABLE.GATE.ATTESTATION_ROOT}/quota/1.json"
            promotion = repo / promotion_relative
            attestation = repo / attestation_relative
            promotion.parent.mkdir(parents=True)
            attestation.parent.mkdir(parents=True)
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
            promotion.write_text(json.dumps({"promotionAttestation": {"path": attestation_relative}}))
            attestation.write_text(json.dumps({"candidate": candidate}))
            release_paths = []
            for consumer in ("apple", "linux", "windows"):
                path = repo / f"{consumer}.json"
                path.write_text(
                    json.dumps(
                        {
                            "consumer": consumer,
                            "candidate": candidate,
                            "activation": activation,
                            "commit": activation["activationCommit"],
                            "artifactUri": f"https://example.com/{consumer}",
                        }
                    )
                )
                release_paths.append(path)
            rollback = repo / "rollback.json"
            rollback.write_text(
                json.dumps(
                    {
                        "candidate": candidate,
                        "activation": activation,
                        "commit": activation["activationCommit"],
                        "artifactUri": "https://example.com/rollback",
                    }
                )
            )
            promotion_receipt = STABLE.GATE.Receipt(
                path=promotion_relative,
                transition="promotion",
                generation=1,
                approved_at=STABLE.GATE.parse_rfc3339_utc("2026-07-14T00:00:00Z", "approved"),
                commit=candidate["candidateCommit"],
                digest="5" * 64,
                evidence=("https://example.com/promotion",),
                payload={},
            )
            verifier = object()
            with (
                mock.patch.object(STABLE.GATE, "validate_activation_closure", return_value=activation),
                mock.patch.object(
                    STABLE.GATE,
                    "public_production_profile",
                    return_value=({"quota": "rust"}, {"quota": "6" * 64}),
                ),
                mock.patch.object(STABLE.GATE, "validate_receipt", return_value=promotion_receipt),
                mock.patch.object(STABLE.GATE, "validate_receipt_chain") as validate_chain,
            ):
                STABLE.create_receipt(
                    repo,
                    row_id=row_id,
                    generation=1,
                    activation_commit=activation["activationCommit"],
                    release_paths=release_paths,
                    rollback_path=rollback,
                    approved_by="@release-owner",
                    approved_at="2026-07-15T00:00:00Z",
                    evidence_verifier=verifier,
                )
            validate_chain.assert_called_once()
            self.assertIs(validate_chain.call_args.args[5], verifier)


if __name__ == "__main__":
    unittest.main()
