import json
import subprocess
from datetime import UTC, datetime
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts/ci/verify-signal-activation-parity.sh"
CLOUDVAULT_EVIDENCE = ROOT / "launch-evidence/cloudvault-at-rest-runtime.json"


def run_parity(*args: str) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        ["bash", str(SCRIPT), *args],
        cwd=ROOT,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=False,
    )


def combined_output(result: subprocess.CompletedProcess[str]) -> str:
    return result.stdout + result.stderr


def fresh_cloudvault_evidence(tmp_path: Path) -> Path:
    data = json.loads(CLOUDVAULT_EVIDENCE.read_text(encoding="utf-8"))
    data["generatedAt"] = datetime.now(UTC).isoformat().replace("+00:00", "Z")
    evidence = tmp_path / "cloudvault-at-rest-runtime.json"
    evidence.write_text(json.dumps(data), encoding="utf-8")
    return evidence


def test_signal_activation_parity_default_mode_accepts_validated_cloudvault_activation(tmp_path: Path):
    evidence = fresh_cloudvault_evidence(tmp_path)
    result = run_parity("--cloudvault-evidence", str(evidence), "--skip-cloudvault-replay")

    assert result.returncode == 0, combined_output(result)
    output = combined_output(result)
    assert "HERMES_GATEWAY_PRODUCTION_SIGNAL_ENVELOPE_VERSIONS is empty" in output
    assert "Signal at-rest domains match validated CloudVault evidence: pensieve=signal-hpke-identity-seal-v1" in output
    assert "activation parity OK" in output


def test_signal_activation_parity_default_mode_rejects_unvalidated_cloudvault_activation(tmp_path: Path):
    evidence = tmp_path / "bad-cloudvault-evidence.json"
    evidence.write_text(json.dumps({"schemaVersion": 1, "generatedAt": datetime.now(UTC).isoformat()}), encoding="utf-8")

    result = run_parity("--cloudvault-evidence", str(evidence), "--skip-cloudvault-replay")

    assert result.returncode != 0
    assert "CloudVault at-rest evidence did not validate" in combined_output(result)


def test_signal_activation_parity_activation_mode_requires_evidence():
    result = run_parity("--mode", "activation")

    assert result.returncode != 0
    assert "--mode activation requires --activation-evidence" in combined_output(result)


def test_signal_activation_parity_rejects_invalid_activation_evidence(tmp_path: Path):
    evidence = tmp_path / "invalid-signal-activation-evidence.json"
    evidence.write_text(json.dumps({"schemaVersion": 1, "status": "blocked"}), encoding="utf-8")

    result = run_parity("--mode", "activation", "--activation-evidence", str(evidence))

    assert result.returncode != 0
    assert "activation evidence did not validate" in combined_output(result)
