import json
import subprocess
from datetime import UTC, datetime
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
COUNTS = {
    "signalRead": 0,
    "knownLegacyRelay": 0,
    "knownLegacyRatchet": 0,
    "knownLegacyPlaintext": 0,
    "unreadable": 0,
    "malformed": 0,
    "unknownSchema": 0,
    "parserMisses": 0,
}
DEPLOYED_COMMIT = "0123456789abcdef0123456789abcdef01234567"
FIREBASE_FUNCTIONS_HASH = "89abcdef0123456789abcdef0123456789abcdef"
SOURCE_LOCATION = "https://burnbar.ai/legal/source"


def runtime_evidence_payload():
    return {
        "writePath": {
            "signalRequired": True,
            "signalEnvelopeWritesEnabled": True,
            "legacyRelayWritesEnabled": False,
            "legacyRatchetWritesEnabled": False,
            "legacyPlaintextWritesEnabled": False,
            "services": [
                {"service": "burnbarhermesgateway", "signalRequired": True},
                {"service": "enqueuehermesgatewayevent", "signalRequired": True},
            ],
        }
    }


def release_ready_drain_evidence(collections=None):
    return {
        "schemaVersion": 1,
        "generatedAt": datetime.now(UTC).isoformat(),
        "privacy": "aggregate_counts_only_no_document_values_or_identifiers",
        "release": {
            "deployedCommit": DEPLOYED_COMMIT,
            "sourceLocation": SOURCE_LOCATION,
            "dependencyLocks": ["functions/package-lock.json"],
        },
        "writePath": {
            "signalRequired": True,
            "signalEnvelopeWritesEnabled": True,
            "legacyRelayWritesEnabled": False,
            "legacyRatchetWritesEnabled": False,
            "legacyPlaintextWritesEnabled": False,
            "modeSource": "gcloud run services describe + gcloud run revisions describe",
            "services": [
                {
                    "service": "burnbarhermesgateway",
                    "signalRequired": True,
                    "latestReadyRevision": "burnbarhermesgateway-00001",
                    "firebaseFunctionsHash": FIREBASE_FUNCTIONS_HASH,
                    "functionVersion": "v2026.06.08",
                    "sourceCommit": DEPLOYED_COMMIT,
                    "correspondingSourceUrl": SOURCE_LOCATION,
                },
                {
                    "service": "enqueuehermesgatewayevent",
                    "signalRequired": True,
                    "latestReadyRevision": "enqueuehermesgatewayevent-00001",
                    "firebaseFunctionsHash": FIREBASE_FUNCTIONS_HASH,
                    "functionVersion": "v2026.06.08",
                    "sourceCommit": DEPLOYED_COMMIT,
                    "correspondingSourceUrl": SOURCE_LOCATION,
                },
            ],
        },
        "collections": collections
        or {
            "events": {
                "collectionGroup": "hermes_gateway_events",
                "sampleLimit": 50000,
                "sampled": 3,
                "truncated": False,
                "counts": {**COUNTS, "signalRead": 3},
            },
            "messages": {
                "collectionGroup": "hermes_gateway_messages",
                "sampleLimit": 50000,
                "sampled": 2,
                "truncated": False,
                "counts": {**COUNTS, "signalRead": 2},
            },
            "attachments": {
                "collectionGroup": "hermes_gateway_attachments",
                "sampleLimit": 50000,
                "sampled": 0,
                "truncated": False,
                "counts": {**COUNTS},
            },
        },
    }


def make_deployed_source_repo(tmp_path: Path, *, production_signal_enabled: bool = True):
    repo = tmp_path / "source-repo"
    (repo / "functions/src/callables").mkdir(parents=True)
    production_set = (
        "new Set([HERMES_GATEWAY_RELAY_KEY_VERSION_SIGNAL])"
        if production_signal_enabled
        else "new Set<number>()"
    )
    (repo / "functions/src/hermesGateway.ts").write_text(
        f"""
export const HERMES_GATEWAY_RELAY_KEY_VERSION_SIGNAL = 4;
export function signalEnvelopeV4DisabledFromEnv(raw = process.env.SIGNAL_ENVELOPE_V4_DISABLED) {{
  return ["1", "true", "yes", "on"].includes(String(raw ?? "").trim().toLowerCase());
}}
export const HERMES_GATEWAY_PRODUCTION_SIGNAL_ENVELOPE_VERSIONS = {production_set};
export function requireProductionGatewaySignalEnvelope(raw: unknown, fieldName: string) {{
  return {{ raw, fieldName }};
}}
""",
        encoding="utf-8",
    )
    (repo / "functions/src/callables/hermesGateway.ts").write_text(
        """
type RequestData = { signalEnvelope?: unknown };
function enqueue(request: { data: RequestData }) {
  return resolveGatewayWriteBody(
    undefined,
    undefined,
    request.data.signalEnvelope,
    undefined,
    {},
    "events",
  );
}
function resolveGatewayWriteBody() {}
""",
        encoding="utf-8",
    )
    subprocess.run(["git", "init"], cwd=repo, check=True, stdout=subprocess.DEVNULL)
    subprocess.run(["git", "add", "."], cwd=repo, check=True)
    subprocess.run(
        [
            "git",
            "-c",
            "user.name=Test",
            "-c",
            "user.email=test@example.com",
            "commit",
            "-m",
            "test deployed source",
        ],
        cwd=repo,
        check=True,
        stdout=subprocess.DEVNULL,
    )
    commit = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=repo, text=True).strip()
    return repo, commit


def run_drain_checker(evidence, *, repo_root=None):
    command = ["python3", "scripts/ci/check_hermes_gateway_migration_drain.py"]
    if repo_root is not None:
        command.extend(["--repo-root", str(repo_root)])
    command.append(str(evidence))
    return subprocess.run(
        command,
        cwd=ROOT,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=False,
    )


def test_legacy_drain_self_test_preserves_unreadable_records():
    result = subprocess.run(
        ["node", "scripts/ci/drain_hermes_gateway_legacy_records.js", "--self-test"],
        cwd=ROOT,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=False,
    )
    assert result.returncode == 0, result.stderr
    assert "PASS: Hermes Gateway legacy drain self-test passed" in result.stdout


def test_root_drain_wrapper_runs_the_self_test():
    result = subprocess.run(
        ["node", "scripts/drain_hermes_gateway_legacy_records.js", "--self-test"],
        cwd=ROOT,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=False,
    )
    assert result.returncode == 0, result.stderr
    assert "PASS: Hermes Gateway legacy drain self-test passed" in result.stdout


def test_migration_drain_evidence_accepts_full_live_zero_state(tmp_path):
    evidence = tmp_path / "drain-evidence.json"
    source_repo, deployed_commit = make_deployed_source_repo(tmp_path)
    data = release_ready_drain_evidence()
    data["release"]["deployedCommit"] = deployed_commit
    for service in data["writePath"]["services"]:
        service["sourceCommit"] = deployed_commit
    evidence.write_text(json.dumps(data), encoding="utf-8")

    result = run_drain_checker(evidence, repo_root=source_repo)

    assert result.returncode == 0, result.stderr
    assert "release-ready" in result.stdout


def test_migration_drain_evidence_rejects_source_commit_with_signal_writes_still_disabled(tmp_path):
    evidence = tmp_path / "drain-evidence.json"
    source_repo, deployed_commit = make_deployed_source_repo(tmp_path, production_signal_enabled=False)
    data = release_ready_drain_evidence()
    data["release"]["deployedCommit"] = deployed_commit
    for service in data["writePath"]["services"]:
        service["sourceCommit"] = deployed_commit
    evidence.write_text(json.dumps(data), encoding="utf-8")

    result = run_drain_checker(evidence, repo_root=source_repo)

    assert result.returncode != 0
    assert "must enable HERMES_GATEWAY_PRODUCTION_SIGNAL_ENVELOPE_VERSIONS for v4 Signal writes" in result.stderr


def test_migration_drain_evidence_requires_live_service_source_provenance(tmp_path):
    evidence = tmp_path / "drain-evidence.json"
    data = release_ready_drain_evidence()
    data["release"]["deployedCommit"] = "abc1234"
    data["release"]["sourceLocation"] = "gcloud run latest ready revisions"
    data["writePath"]["services"][0].pop("sourceCommit")
    data["writePath"]["services"][1]["correspondingSourceUrl"] = "https://example.invalid/source"
    evidence.write_text(json.dumps(data), encoding="utf-8")

    result = run_drain_checker(evidence)

    assert result.returncode != 0
    assert "release.deployedCommit must be the 40-character git commit deployed to the live services" in result.stderr
    assert "release.sourceLocation must be an https:// or git@ source URL" in result.stderr
    assert "writePath.services.burnbarhermesgateway.sourceCommit must match release.deployedCommit" in result.stderr
    assert (
        "writePath.services.enqueuehermesgatewayevent.correspondingSourceUrl must match release.sourceLocation"
        in result.stderr
    )


def test_migration_drain_evidence_reports_missing_file_without_traceback(tmp_path):
    result = run_drain_checker(tmp_path / "missing-drain-evidence.json")

    assert result.returncode != 0
    assert "FAIL: unreadable Hermes Gateway migration drain evidence:" in result.stderr
    assert "Traceback" not in result.stderr


def test_migration_drain_evidence_rejects_truncated_or_missing_collection(tmp_path):
    evidence = tmp_path / "drain-evidence.json"
    data = release_ready_drain_evidence()
    data["collections"]["events"]["truncated"] = True
    del data["collections"]["messages"]
    evidence.write_text(json.dumps(data), encoding="utf-8")

    result = run_drain_checker(evidence)

    assert result.returncode != 0
    assert "events.truncated must be false" in result.stderr
    assert "collections.messages is required" in result.stderr


def test_migration_drain_evidence_rejects_future_or_inconsistent_aggregates(tmp_path):
    evidence = tmp_path / "drain-evidence.json"
    data = release_ready_drain_evidence()
    data["generatedAt"] = "2999-01-01T00:00:00Z"
    data["collections"]["events"]["sampled"] = 37
    data["collections"]["messages"]["sampleLimit"] = 1
    data["collections"]["messages"]["sampled"] = 2
    data["collections"]["attachments"]["counts"]["mystery"] = 1
    evidence.write_text(json.dumps(data), encoding="utf-8")

    result = run_drain_checker(evidence)

    assert result.returncode != 0
    assert "generatedAt must not be in the future" in result.stderr
    assert "events.sampled must equal the sum of classification counts" in result.stderr
    assert "messages.sampled must be <= messages.sampleLimit" in result.stderr
    assert "attachments.counts has unknown classification(s): mystery" in result.stderr


def test_live_collectors_mark_truncated_when_scan_hits_cap():
    result = subprocess.run(
        [
            "node",
            "-e",
            r"""
const assert = require("node:assert/strict");
const writer = require("./scripts/ci/write_hermes_gateway_migration_drain_evidence.js");
const drain = require("./scripts/ci/drain_hermes_gateway_legacy_records.js");

class Query {
  constructor(rows, start = 0, queryLimit = rows.length) {
    this.rows = rows;
    this.start = start;
    this.queryLimit = queryLimit;
  }
  orderBy() { return this; }
  limit(n) { return new Query(this.rows, this.start, n); }
  startAfter(cursor) { return new Query(this.rows, cursor.__index + 1, this.queryLimit); }
  async get() {
    const docs = this.rows.slice(this.start, this.start + this.queryLimit).map((data, offset) => ({
      __index: this.start + offset,
      data: () => data,
      ref: { path: `users/u/hermes_gateway_events/doc-${this.start + offset}` },
    }));
    return { empty: docs.length === 0, size: docs.length, docs };
  }
}

const rows = [
  { relayEnvelope: { ciphertext: "a" } },
  { relayEnvelope: { ciphertext: "b" } },
  { relayEnvelope: { ciphertext: "c" } },
];
const db = { collectionGroup: () => new Query(rows) };
const admin = { firestore: { FieldPath: { documentId: () => "__name__" } } };
const collection = writer.COLLECTIONS[0];

(async () => {
  const evidenceSummary = await writer.collectCollection(db, admin, collection, {
    pageSize: 500,
    maxDocsPerCollection: 2,
  });
  assert.equal(evidenceSummary.sampled, 2);
  assert.equal(evidenceSummary.truncated, true);

  const drainSummary = await drain.drainCollection(db, admin, collection, {
    pageSize: 500,
    maxDocsPerCollection: 2,
  });
  assert.equal(drainSummary.scanned, 2);
  assert.equal(drainSummary.truncated, true);
})();
""",
        ],
        cwd=ROOT,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=False,
    )
    assert result.returncode == 0, result.stderr


def test_runtime_mode_parser_records_live_source_provenance():
    result = subprocess.run(
        [
            "node",
            "-e",
            rf"""
const assert = require("node:assert/strict");
const writer = require("./scripts/ci/write_hermes_gateway_migration_drain_evidence.js");

const mode = writer.serviceModeFromDescriptions(
  {{
    metadata: {{
      name: "burnbarhermesgateway",
      labels: {{ "firebase-functions-hash": "{FIREBASE_FUNCTIONS_HASH}" }},
    }},
    status: {{
      latestReadyRevisionName: "burnbarhermesgateway-00016-wiw",
      url: "https://burnbarhermesgateway.example",
      conditions: [{{ type: "Ready", status: "True" }}],
    }},
  }},
  {{
    spec: {{
      containers: [
        {{
          env: [
            {{ name: "OPENBURNBAR_GATEWAY_SIGNAL_REQUIRED", value: "true" }},
            {{ name: "FUNCTION_VERSION", value: "v2026.06.08" }},
            {{ name: "OPENBURNBAR_SOURCE_COMMIT", value: "{DEPLOYED_COMMIT}" }},
            {{ name: "OPENBURNBAR_CORRESPONDING_SOURCE_URL", value: "{SOURCE_LOCATION}" }},
          ],
        }},
      ],
    }},
  }},
);

assert.equal(mode.signalRequired, true);
assert.equal(mode.firebaseFunctionsHash, "{FIREBASE_FUNCTIONS_HASH}");
assert.equal(mode.functionVersion, "v2026.06.08");
assert.equal(mode.sourceCommit, "{DEPLOYED_COMMIT}");
assert.equal(mode.correspondingSourceUrl, "{SOURCE_LOCATION}");
""",
        ],
        cwd=ROOT,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=False,
    )
    assert result.returncode == 0, result.stderr


def test_signal_required_rollout_rejects_commit_with_signal_writes_disabled(tmp_path):
    source_repo, deployed_commit = make_deployed_source_repo(tmp_path, production_signal_enabled=False)

    result = subprocess.run(
        [
            "node",
            str(ROOT / "scripts/ci/rollout_hermes_gateway_signal_required.js"),
            "enable-hermes-gateway-signal-required",
            "--deployed-commit",
            deployed_commit,
            "--source-location",
            SOURCE_LOCATION,
            "--dry-run",
        ],
        cwd=source_repo,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=False,
    )

    assert result.returncode != 0
    assert "must enable HERMES_GATEWAY_PRODUCTION_SIGNAL_ENVELOPE_VERSIONS for v4 Signal writes" in result.stderr
    assert "[dry_run] gcloud" not in result.stdout


def test_signal_required_rollout_allows_commit_with_signal_writes_enabled(tmp_path):
    source_repo, deployed_commit = make_deployed_source_repo(tmp_path, production_signal_enabled=True)

    result = subprocess.run(
        [
            "node",
            str(ROOT / "scripts/ci/rollout_hermes_gateway_signal_required.js"),
            "enable-hermes-gateway-signal-required",
            "--deployed-commit",
            deployed_commit,
            "--source-location",
            SOURCE_LOCATION,
            "--dry-run",
        ],
        cwd=source_repo,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=False,
    )

    assert result.returncode == 0, result.stderr
    assert "OPENBURNBAR_GATEWAY_SIGNAL_REQUIRED=true" in result.stdout
    assert f"OPENBURNBAR_SOURCE_COMMIT={deployed_commit}" in result.stdout
    assert f"OPENBURNBAR_CORRESPONDING_SOURCE_URL={SOURCE_LOCATION}" in result.stdout


def test_live_execute_rejects_truncated_runtime_evidence_before_firestore(tmp_path):
    runtime = tmp_path / "runtime.json"
    predelete = tmp_path / "predelete.json"
    data = release_ready_drain_evidence()
    data["collections"]["events"]["truncated"] = True
    runtime.write_text(json.dumps(data), encoding="utf-8")
    result = subprocess.run(
        [
            "node",
            "scripts/ci/drain_hermes_gateway_legacy_records.js",
            "--execute",
            "--confirm",
            "delete-legacy-hermes-gateway-records",
            "--project-id",
            "burnbar",
            "--live-production-acknowledgement",
            "mutate-production-hermes-gateway-records-in-burnbar",
            "--runtime-mode-evidence",
            str(runtime),
            "--predelete-export",
            str(predelete),
        ],
        cwd=ROOT,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=False,
    )
    assert result.returncode != 0
    assert "events.truncated must be false" in result.stderr
    assert not predelete.exists()


def test_signal_shaped_but_invalid_records_are_blocking_malformed(tmp_path):
    fixture = tmp_path / "fixture.json"
    fixture.write_text(
        json.dumps({"events": [{"signalEnvelope": {}}, {"cryptoMode": "signal"}]}),
        encoding="utf-8",
    )

    result = subprocess.run(
        [
            "node",
            "scripts/ci/write_hermes_gateway_migration_drain_evidence.js",
            "--fixture",
            str(fixture),
            "--deployed-commit",
            DEPLOYED_COMMIT,
            "--source-location",
            SOURCE_LOCATION,
        ],
        cwd=ROOT,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=False,
    )

    assert result.returncode == 0, result.stderr
    evidence = json.loads(result.stdout)
    assert evidence["collections"]["events"]["counts"]["signalRead"] == 0
    assert evidence["collections"]["events"]["counts"]["malformed"] == 2


def test_versioned_plaintext_shaped_records_are_unknown_not_delete_eligible():
    result = subprocess.run(
        [
            "node",
            "-e",
            r"""
const assert = require("node:assert/strict");
const writer = require("./scripts/ci/write_hermes_gateway_migration_drain_evidence.js");
assert.equal(
  writer.classifyGatewayDocument({ schemaVersion: 99, threadId: "future-thread" }, writer.COLLECTIONS[0].plaintextFields),
  "unknownSchema",
);
assert.equal(
  writer.classifyGatewayDocument({ schemaVersion: 99, replyToEventId: "future-reply" }, writer.COLLECTIONS[1].plaintextFields),
  "unknownSchema",
);
assert.equal(
  writer.classifyGatewayDocument({ schemaVersion: 99, contentType: "image/png" }, writer.COLLECTIONS[2].plaintextFields),
  "unknownSchema",
);
assert.equal(
  writer.classifyGatewayDocument({ threadId: "legacy-thread" }, writer.COLLECTIONS[0].plaintextFields),
  "knownLegacyPlaintext",
);
""",
        ],
        cwd=ROOT,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=False,
    )
    assert result.returncode == 0, result.stderr


def test_live_collection_group_out_of_scope_paths_block_without_deleting():
    result = subprocess.run(
        [
            "node",
            "-e",
            r"""
const assert = require("node:assert/strict");
const writer = require("./scripts/ci/write_hermes_gateway_migration_drain_evidence.js");
const drain = require("./scripts/ci/drain_hermes_gateway_legacy_records.js");

class Query {
  constructor(done = false) { this.done = done; }
  orderBy() { return this; }
  limit() { return this; }
  startAfter() { return new Query(true); }
  async get() {
    if (this.done) return { empty: true, size: 0, docs: [] };
    return {
      empty: false,
      size: 1,
      docs: [{
        data: () => ({ relayEnvelope: { ciphertext: "legacy" } }),
        ref: { path: "tenants/t/hermes_gateway_events/doc-1" },
      }],
    };
  }
}

const db = { collectionGroup: () => new Query() };
const admin = { firestore: { FieldPath: { documentId: () => "__name__" } } };
const collection = writer.COLLECTIONS[0];

(async () => {
  const evidenceSummary = await writer.collectCollection(db, admin, collection, {
    pageSize: 500,
    maxDocsPerCollection: 10,
  });
  assert.equal(evidenceSummary.counts.unknownSchema, 1);
  assert.equal(evidenceSummary.counts.knownLegacyRelay, 0);

  const privateExport = { blockedRecords: [], predeleteRecords: [] };
  const deleteCandidates = [];
  const drainSummary = await drain.drainCollection(db, admin, collection, {
    pageSize: 500,
    maxDocsPerCollection: 10,
    privateExport,
    capturePredelete: true,
    deleteCandidates,
  });
  assert.equal(drainSummary.blocked, 1);
  assert.equal(drainSummary.eligible, 0);
  assert.equal(privateExport.blockedRecords[0].outOfScopePath, true);
  assert.equal(deleteCandidates.length, 0);
})();
""",
        ],
        cwd=ROOT,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=False,
    )
    assert result.returncode == 0, result.stderr


def test_execute_requires_predelete_export(tmp_path):
    fixture = tmp_path / "fixture.json"
    runtime = tmp_path / "runtime.json"
    fixture.write_text(json.dumps({"events": [{"relayEnvelope": {"ciphertext": "legacy"}}]}), encoding="utf-8")
    runtime.write_text(json.dumps(runtime_evidence_payload()), encoding="utf-8")
    result = subprocess.run(
        [
            "node",
            "scripts/ci/drain_hermes_gateway_legacy_records.js",
            "--fixture",
            str(fixture),
            "--execute",
            "--confirm",
            "delete-legacy-hermes-gateway-records",
            "--runtime-mode-evidence",
            str(runtime),
        ],
        cwd=ROOT,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=False,
    )
    assert result.returncode != 0
    assert "--predelete-export" in result.stderr


def test_live_execute_requires_quarantine_output_for_fresh_valid_runtime_evidence(tmp_path):
    runtime = tmp_path / "runtime.json"
    predelete = tmp_path / "predelete.json"
    runtime.write_text(json.dumps(release_ready_drain_evidence()), encoding="utf-8")
    result = subprocess.run(
        [
            "node",
            "scripts/ci/drain_hermes_gateway_legacy_records.js",
            "--execute",
            "--confirm",
            "delete-legacy-hermes-gateway-records",
            "--project-id",
            "burnbar",
            "--live-production-acknowledgement",
            "mutate-production-hermes-gateway-records-in-burnbar",
            "--runtime-mode-evidence",
            str(runtime),
            "--predelete-export",
            str(predelete),
        ],
        cwd=ROOT,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=False,
    )
    assert result.returncode != 0
    assert "--quarantine-output" in result.stderr


def test_live_execute_requires_project_id_before_firestore(tmp_path):
    runtime = tmp_path / "runtime.json"
    predelete = tmp_path / "predelete.json"
    runtime.write_text(json.dumps(runtime_evidence_payload()), encoding="utf-8")
    result = subprocess.run(
        [
            "node",
            "scripts/ci/drain_hermes_gateway_legacy_records.js",
            "--execute",
            "--confirm",
            "delete-legacy-hermes-gateway-records",
            "--runtime-mode-evidence",
            str(runtime),
            "--predelete-export",
            str(predelete),
        ],
        cwd=ROOT,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=False,
    )
    assert result.returncode != 0
    assert "--project-id" in result.stderr
    assert not predelete.exists()


def test_live_execute_rejects_weak_runtime_evidence_before_firestore(tmp_path):
    runtime = tmp_path / "runtime.json"
    predelete = tmp_path / "predelete.json"
    runtime.write_text(json.dumps(runtime_evidence_payload()), encoding="utf-8")
    result = subprocess.run(
        [
            "node",
            "scripts/ci/drain_hermes_gateway_legacy_records.js",
            "--execute",
            "--confirm",
            "delete-legacy-hermes-gateway-records",
            "--project-id",
            "burnbar",
            "--live-production-acknowledgement",
            "mutate-production-hermes-gateway-records-in-burnbar",
            "--runtime-mode-evidence",
            str(runtime),
            "--predelete-export",
            str(predelete),
        ],
        cwd=ROOT,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=False,
    )
    assert result.returncode != 0
    assert "privacy must be aggregate_counts_only" in result.stderr
    assert "release.deployedCommit" in result.stderr
    assert "modeSource" in result.stderr
    assert not predelete.exists()


def test_execute_blocks_unknown_records_before_delete_and_quarantines(tmp_path):
    fixture = tmp_path / "fixture.json"
    runtime = tmp_path / "runtime.json"
    quarantine = tmp_path / "quarantine.json"
    predelete = tmp_path / "predelete.json"
    output = tmp_path / "evidence.json"
    fixture.write_text(
        json.dumps(
            {
                "events": [
                    {"relayEnvelope": {"ciphertext": "legacy"}},
                    {"schemaVersion": 99, "futureEnvelope": {"ciphertext": "unknown"}},
                    {"__unreadable": True},
                ]
            }
        ),
        encoding="utf-8",
    )
    runtime.write_text(json.dumps(runtime_evidence_payload()), encoding="utf-8")
    result = subprocess.run(
        [
            "node",
            "scripts/ci/drain_hermes_gateway_legacy_records.js",
            "--fixture",
            str(fixture),
            "--execute",
            "--confirm",
            "delete-legacy-hermes-gateway-records",
            "--runtime-mode-evidence",
            str(runtime),
            "--predelete-export",
            str(predelete),
            "--quarantine-output",
            str(quarantine),
            "--output",
            str(output),
        ],
        cwd=ROOT,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=False,
    )
    assert result.returncode != 0
    assert "refusing --execute" in result.stderr
    assert quarantine.exists()
    assert not predelete.exists()
    assert not output.exists()
    private_export = json.loads(quarantine.read_text(encoding="utf-8"))
    assert private_export["privacy"] == "private_export_contains_document_values_do_not_commit"
    assert {record["classification"] for record in private_export["blockedRecords"]} == {
        "unknownSchema",
        "unreadable",
    }


def test_execute_exports_predelete_records_before_fixture_delete(tmp_path):
    fixture = tmp_path / "fixture.json"
    runtime = tmp_path / "runtime.json"
    predelete = tmp_path / "predelete.json"
    output = tmp_path / "evidence.json"
    fixture.write_text(
        json.dumps(
            {
                "events": [{"relayEnvelope": {"ciphertext": "legacy"}}],
                "messages": [{"text": "legacy cleartext"}],
            }
        ),
        encoding="utf-8",
    )
    runtime.write_text(json.dumps(runtime_evidence_payload()), encoding="utf-8")

    result = subprocess.run(
        [
            "node",
            "scripts/ci/drain_hermes_gateway_legacy_records.js",
            "--fixture",
            str(fixture),
            "--execute",
            "--confirm",
            "delete-legacy-hermes-gateway-records",
            "--runtime-mode-evidence",
            str(runtime),
            "--predelete-export",
            str(predelete),
            "--output",
            str(output),
        ],
        cwd=ROOT,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=False,
    )

    assert result.returncode == 0, result.stderr
    private_export = json.loads(predelete.read_text(encoding="utf-8"))
    assert private_export["privacy"] == "private_export_contains_document_values_do_not_commit"
    assert [record["classification"] for record in private_export["predeleteRecords"]] == [
        "knownLegacyRelay",
        "knownLegacyPlaintext",
    ]
    public_evidence = json.loads(output.read_text(encoding="utf-8"))
    assert public_evidence["mode"] == "execute"
    assert public_evidence["collections"]["events"]["deleted"] == 1
    assert public_evidence["collections"]["messages"]["deleted"] == 1


def test_execute_refuses_to_overwrite_existing_private_predelete_export(tmp_path):
    fixture = tmp_path / "fixture.json"
    runtime = tmp_path / "runtime.json"
    predelete = tmp_path / "predelete.json"
    output = tmp_path / "evidence.json"
    fixture.write_text(json.dumps({"events": [{"relayEnvelope": {"ciphertext": "legacy"}}]}), encoding="utf-8")
    runtime.write_text(json.dumps(runtime_evidence_payload()), encoding="utf-8")
    predelete.write_text("existing recovery artifact\n", encoding="utf-8")

    result = subprocess.run(
        [
            "node",
            "scripts/ci/drain_hermes_gateway_legacy_records.js",
            "--fixture",
            str(fixture),
            "--execute",
            "--confirm",
            "delete-legacy-hermes-gateway-records",
            "--runtime-mode-evidence",
            str(runtime),
            "--predelete-export",
            str(predelete),
            "--output",
            str(output),
        ],
        cwd=ROOT,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=False,
    )

    assert result.returncode != 0
    assert "EEXIST" in result.stderr
    assert predelete.read_text(encoding="utf-8") == "existing recovery artifact\n"
    assert not output.exists()


def test_restore_utility_dry_run_requires_private_export(tmp_path):
    export = tmp_path / "predelete.json"
    export.write_text(
        json.dumps(
            {
                "privacy": "private_export_contains_document_values_do_not_commit",
                "predeleteRecords": [
                    {
                        "collection": "events",
                        "collectionGroup": "hermes_gateway_events",
                        "path": "users/u/hermes_gateway_events/e1",
                        "classification": "knownLegacyRelay",
                        "data": {"relayEnvelope": {"ciphertext": "legacy"}},
                    }
                ],
                "blockedRecords": [],
            }
        ),
        encoding="utf-8",
    )
    result = subprocess.run(
        [
            "node",
            "scripts/ci/restore_hermes_gateway_legacy_records.js",
            "--export",
            str(export),
            "--project-id",
            "burnbar",
        ],
        cwd=ROOT,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=False,
    )
    assert result.returncode == 0, result.stderr
    output = json.loads(result.stdout)
    assert output["mode"] == "dry_run"
    assert output["wouldRestore"] == 1
    assert output["executeCommandRequires"]["confirm"] == "restore-hermes-gateway-predelete-export"


def test_restore_utility_rejects_non_gateway_paths(tmp_path):
    export = tmp_path / "predelete.json"
    export.write_text(
        json.dumps(
            {
                "privacy": "private_export_contains_document_values_do_not_commit",
                "predeleteRecords": [
                    {
                        "collection": "events",
                        "collectionGroup": "hermes_gateway_events",
                        "path": "users/u/provider_accounts/a",
                        "classification": "knownLegacyRelay",
                        "data": {"relayEnvelope": {"ciphertext": "legacy"}},
                    }
                ],
            }
        ),
        encoding="utf-8",
    )
    result = subprocess.run(
        [
            "node",
            "scripts/ci/restore_hermes_gateway_legacy_records.js",
            "--export",
            str(export),
            "--project-id",
            "burnbar",
        ],
        cwd=ROOT,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=False,
    )

    assert result.returncode != 0
    assert "not an allowed Hermes Gateway document path" in result.stderr


def test_restore_utility_rejects_nested_or_tenant_gateway_paths(tmp_path):
    for document_path in (
        "tenants/t/hermes_gateway_events/e1",
        "users/u/sessions/s1/hermes_gateway_events/e1",
    ):
        export = tmp_path / f"{document_path.replace('/', '_')}.json"
        export.write_text(
            json.dumps(
                {
                    "privacy": "private_export_contains_document_values_do_not_commit",
                    "predeleteRecords": [
                        {
                            "collection": "events",
                            "collectionGroup": "hermes_gateway_events",
                            "path": document_path,
                            "classification": "knownLegacyRelay",
                            "data": {"relayEnvelope": {"ciphertext": "legacy"}},
                        }
                    ],
                }
            ),
            encoding="utf-8",
        )
        result = subprocess.run(
            [
                "node",
                "scripts/ci/restore_hermes_gateway_legacy_records.js",
                "--export",
                str(export),
                "--project-id",
                "burnbar",
            ],
            cwd=ROOT,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=False,
        )
        assert result.returncode != 0
        assert "not an allowed Hermes Gateway document path" in result.stderr


def test_restore_utility_execute_requires_project_ack(tmp_path):
    export = tmp_path / "predelete.json"
    export.write_text(
        json.dumps(
            {
                "privacy": "private_export_contains_document_values_do_not_commit",
                "predeleteRecords": [
                    {
                        "collection": "messages",
                        "collectionGroup": "hermes_gateway_messages",
                        "path": "users/u/hermes_gateway_messages/m1",
                        "classification": "knownLegacyRelay",
                        "data": {"relayEnvelope": {"ciphertext": "legacy"}},
                    }
                ],
            }
        ),
        encoding="utf-8",
    )
    result = subprocess.run(
        [
            "node",
            "scripts/ci/restore_hermes_gateway_legacy_records.js",
            "--export",
            str(export),
            "--project-id",
            "burnbar",
            "--execute",
            "--confirm",
            "restore-hermes-gateway-predelete-export",
        ],
        cwd=ROOT,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=False,
    )
    assert result.returncode != 0
    assert "--live-production-acknowledgement" in result.stderr


def test_restore_utility_queues_create_not_overwrite():
    result = subprocess.run(
        [
            "node",
            "-e",
            r"""
const assert = require("node:assert/strict");
const restore = require("./scripts/ci/restore_hermes_gateway_legacy_records.js");
const calls = [];
const writer = {
  create: (doc, data) => calls.push({ method: "create", path: doc.path, data }),
  set: () => calls.push({ method: "set" }),
};
const db = { doc: (path) => ({ path }) };
restore.queueRestoreRecord(writer, db, {
  path: "users/u/hermes_gateway_messages/m1",
  data: { relayEnvelope: { ciphertext: "legacy" } },
});
assert.deepEqual(calls, [{
  method: "create",
  path: "users/u/hermes_gateway_messages/m1",
  data: { relayEnvelope: { ciphertext: "legacy" } },
}]);
""",
        ],
        cwd=ROOT,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=False,
    )
    assert result.returncode == 0, result.stderr


def test_bulk_delete_failure_is_reported_before_execute_success():
    result = subprocess.run(
        [
            "node",
            "-e",
            r"""
const assert = require("node:assert/strict");
const Module = require("node:module");
const originalLoad = Module._load;
Module._load = function(request, parent, isMain) {
  if (request.endsWith("functions/node_modules/firebase-admin")) {
    return {
      apps: [{}],
      firestore: () => ({
        doc: (path) => ({ path }),
        bulkWriter: () => ({
          onWriteError: () => {},
          delete: () => Promise.reject(new Error("permission denied")),
          close: async () => {},
        }),
      }),
    };
  }
  return originalLoad.apply(this, arguments);
};
const drain = require("./scripts/ci/drain_hermes_gateway_legacy_records.js");
(async () => {
  await assert.rejects(
    () => drain.deleteCapturedCandidates({ projectId: "burnbar" }, [{ path: "users/u/hermes_gateway_events/e1" }]),
    /bulk delete failed/,
  );
})();
""",
        ],
        cwd=ROOT,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=False,
    )
    assert result.returncode == 0, result.stderr


def test_restore_queue_returns_create_promise_so_failures_can_be_counted():
    result = subprocess.run(
        [
            "node",
            "-e",
            r"""
const assert = require("node:assert/strict");
const restore = require("./scripts/ci/restore_hermes_gateway_legacy_records.js");
const writer = { create: () => Promise.reject(new Error("already exists")) };
const db = { doc: (path) => ({ path }) };
(async () => {
  const write = restore.queueRestoreRecord(writer, db, {
    path: "users/u/hermes_gateway_messages/m1",
    data: { relayEnvelope: { ciphertext: "legacy" } },
  });
  assert.equal(typeof write.then, "function");
  const settled = await Promise.allSettled([write]);
  assert.equal(settled[0].status, "rejected");
})();
""",
        ],
        cwd=ROOT,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=False,
    )
    assert result.returncode == 0, result.stderr
