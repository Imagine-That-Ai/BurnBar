import subprocess
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
DRAIN = ROOT / "scripts/ci/drain_hermes_gateway_legacy_records.js"


def test_gateway_legacy_drain_self_test_passes() -> None:
    result = subprocess.run(
        ["node", str(DRAIN), "--self-test"],
        cwd=ROOT,
        check=True,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )

    assert result.stdout.strip() == "PASS: Hermes Gateway legacy drain self-test passed"
    assert result.stderr == ""


def test_gateway_legacy_drain_execute_requires_runtime_mode_evidence() -> None:
    result = subprocess.run(
        [
            "node",
            str(DRAIN),
            "--execute",
            "--confirm",
            "delete-legacy-hermes-gateway-records",
        ],
        cwd=ROOT,
        check=False,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )

    assert result.returncode == 1
    assert "--runtime-mode-evidence is required when --execute is set" in result.stderr


def test_gateway_legacy_drain_execute_rejects_non_signal_required_evidence(tmp_path: Path) -> None:
    evidence = tmp_path / "runtime-mode.json"
    evidence.write_text(
        """
        {
          "writePath": {
            "signalRequired": false,
            "signalEnvelopeWritesEnabled": false,
            "legacyRelayWritesEnabled": true,
            "legacyRatchetWritesEnabled": true,
            "legacyPlaintextWritesEnabled": false,
            "services": [
              {"service": "burnbarhermesgateway", "signalRequired": false},
              {"service": "enqueuehermesgatewayevent", "signalRequired": false}
            ]
          }
        }
        """,
        encoding="utf-8",
    )

    result = subprocess.run(
        [
            "node",
            str(DRAIN),
            "--execute",
            "--confirm",
            "delete-legacy-hermes-gateway-records",
            "--runtime-mode-evidence",
            str(evidence),
        ],
        cwd=ROOT,
        check=False,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )

    assert result.returncode == 1
    assert "runtime mode evidence writePath.signalRequired must be true" in result.stderr
    assert "runtime mode evidence writePath.services.0.signalRequired must be true" in result.stderr
