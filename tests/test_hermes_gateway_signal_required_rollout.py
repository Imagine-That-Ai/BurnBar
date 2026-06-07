import json
import subprocess
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
ROLLOUT = ROOT / "scripts/ci/rollout_hermes_gateway_signal_required.js"


def test_signal_required_rollout_self_test_passes() -> None:
    result = subprocess.run(
        ["node", str(ROLLOUT), "--self-test"],
        cwd=ROOT,
        check=True,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )

    assert result.stdout.strip() == "PASS: Hermes Gateway Signal-required rollout self-test passed"
    assert result.stderr == ""


def test_signal_required_rollout_default_is_dry_run_json_plan(tmp_path: Path) -> None:
    output = tmp_path / "rollout-plan.json"

    subprocess.run(
        ["node", str(ROLLOUT), "--output", str(output)],
        cwd=ROOT,
        check=True,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )

    data = json.loads(output.read_text(encoding="utf-8"))

    assert data["mode"] == "dry_run"
    assert data["action"] == "enable"
    assert data["safety"]["mutatesCloudRun"] is False
    assert data["privacy"] == "aggregate_counts_only_no_document_values_or_identifiers"
    assert {service["service"] for service in data["services"]} == {
        "burnbarhermesgateway",
        "enqueuehermesgatewayevent",
    }
    assert data["services"][0]["command"][-2:] == [
        "--update-env-vars",
        "OPENBURNBAR_GATEWAY_SIGNAL_REQUIRED=true",
    ]
    assert data["followUpEvidence"]["runtimeModeFlag"] == "--runtime-mode-from-gcloud"


def test_signal_required_rollout_execute_requires_exact_confirmation() -> None:
    result = subprocess.run(
        ["node", str(ROLLOUT), "--execute", "--confirm", "rollback-hermes-gateway-signal-required"],
        cwd=ROOT,
        check=False,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )

    assert result.returncode == 1
    assert "--execute enable requires --confirm enable-hermes-gateway-signal-required" in result.stderr


def test_signal_required_rollout_rollback_plan_is_guarded(tmp_path: Path) -> None:
    output = tmp_path / "rollback-plan.json"

    subprocess.run(
        ["node", str(ROLLOUT), "--rollback", "--output", str(output)],
        cwd=ROOT,
        check=True,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )

    data = json.loads(output.read_text(encoding="utf-8"))

    assert data["mode"] == "dry_run"
    assert data["action"] == "rollback"
    assert data["safety"]["mutatesCloudRun"] is False
    assert data["services"][0]["command"][-2:] == [
        "--remove-env-vars",
        "OPENBURNBAR_GATEWAY_SIGNAL_REQUIRED",
    ]
