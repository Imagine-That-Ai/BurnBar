import json
import subprocess
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts/ci/verify-signal-activation-parity.sh"


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


def test_signal_activation_parity_default_mode_flags_intentional_pensieve_activation():
    result = run_parity()

    assert result.returncode != 0
    output = combined_output(result)
    assert "domains already on a signal sealingScheme: pensieve=signal-hpke-identity-seal-v1" in output
    assert "safe default" in output


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
