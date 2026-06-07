import json
import subprocess
from pathlib import Path

from scripts.ci.check_hermes_gateway_migration_drain import validate_drain_evidence


ROOT = Path(__file__).resolve().parents[1]
COLLECTOR = ROOT / "scripts/ci/write_hermes_gateway_migration_drain_evidence.js"


def test_gateway_drain_collector_self_test_passes() -> None:
    result = subprocess.run(
        ["node", str(COLLECTOR), "--self-test"],
        cwd=ROOT,
        check=True,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )

    assert result.stdout.strip() == "PASS: Hermes Gateway migration-drain collector self-test passed"
    assert result.stderr == ""


def test_gateway_drain_collector_self_test_output_validates(tmp_path: Path) -> None:
    output = tmp_path / "gateway-drain.json"
    subprocess.run(
        ["node", str(COLLECTOR), "--self-test", "--output", str(output)],
        cwd=ROOT,
        check=True,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )

    data = json.loads(output.read_text(encoding="utf-8"))

    assert validate_drain_evidence(data, repo_root=ROOT) == []
    assert data["privacy"] == "aggregate_counts_only_no_document_values_or_identifiers"
    assert data["writePath"]["signalRequired"] is True
    assert data["writePath"]["legacyRelayWritesEnabled"] is False
    assert {service["service"] for service in data["writePath"]["services"]} == {
        "burnbarhermesgateway",
        "enqueuehermesgatewayevent",
    }
    assert data["collections"]["events"]["counts"]["signalRead"] == 2
    assert "legacy body" not in json.dumps(data)


def test_gateway_drain_collector_sanitizes_cloud_run_mode_readback() -> None:
    script = r"""
    const assert = require("node:assert/strict");
    const { serviceModeFromDescription, buildWritePathEvidenceFromServices } = require("./scripts/ci/write_hermes_gateway_migration_drain_evidence.js");

    const service = serviceModeFromDescription({
      metadata: { name: "burnbarhermesgateway" },
      status: {
        latestReadyRevisionName: "burnbarhermesgateway-00015-test",
        url: "https://burnbarhermesgateway.example.com",
        conditions: [{ type: "Ready", status: "True" }],
      },
      spec: {
        template: {
          spec: {
            containers: [
              {
                env: [
                  { name: "SENTRY_DSN", value: "https://secret.example.invalid/1" },
                  { name: "OPENBURNBAR_GATEWAY_SIGNAL_REQUIRED", value: "true" },
                ],
              },
            ],
          },
        },
      },
      readyRevision: {
        spec: {
          containers: [
            {
              env: [
                { name: "SENTRY_DSN", value: "https://secret.example.invalid/1" },
                { name: "OPENBURNBAR_GATEWAY_SIGNAL_REQUIRED", value: "true" },
              ],
            },
          ],
        },
      },
    });

    assert.deepEqual(service, {
      service: "burnbarhermesgateway",
      latestReadyRevision: "burnbarhermesgateway-00015-test",
      url: "https://burnbarhermesgateway.example.com",
      signalRequired: true,
    });

    const writePath = buildWritePathEvidenceFromServices([service], { modeSource: "fixture" });
    assert.equal(writePath.signalRequired, true);
    assert.equal(JSON.stringify(writePath).includes("secret.example"), false);
    """

    subprocess.run(["node", "-e", script], cwd=ROOT, check=True)


def test_gateway_drain_collector_ignores_failed_cloud_run_template_env() -> None:
    script = r"""
    const assert = require("node:assert/strict");
    const { serviceModeFromDescription } = require("./scripts/ci/write_hermes_gateway_migration_drain_evidence.js");

    const service = serviceModeFromDescription({
      metadata: { name: "burnbarhermesgateway" },
      status: {
        latestReadyRevisionName: "burnbarhermesgateway-00014-ready",
        latestCreatedRevisionName: "burnbarhermesgateway-00015-failed",
        url: "https://burnbarhermesgateway.example.com",
        conditions: [{ type: "Ready", status: "False", reason: "RevisionFailed" }],
      },
      spec: {
        template: {
          spec: {
            containers: [
              {
                env: [{ name: "OPENBURNBAR_GATEWAY_SIGNAL_REQUIRED", value: "true" }],
              },
            ],
          },
        },
      },
      readyRevision: {
        spec: {
          containers: [
            {
              env: [],
            },
          ],
        },
      },
    });

    assert.deepEqual(service, {
      service: "burnbarhermesgateway",
      latestReadyRevision: "burnbarhermesgateway-00014-ready",
      url: "https://burnbarhermesgateway.example.com",
      signalRequired: false,
    });
    """

    subprocess.run(["node", "-e", script], cwd=ROOT, check=True)
