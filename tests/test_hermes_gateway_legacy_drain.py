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
            "deployedCommit": "abc1234",
            "sourceLocation": "gcloud run latest ready revisions",
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
                },
                {
                    "service": "enqueuehermesgatewayevent",
                    "signalRequired": True,
                    "latestReadyRevision": "enqueuehermesgatewayevent-00001",
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
                "counts": COUNTS,
            },
        },
    }


def run_drain_checker(evidence):
    return subprocess.run(
        ["python3", "scripts/ci/check_hermes_gateway_migration_drain.py", str(evidence)],
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
    evidence.write_text(json.dumps(release_ready_drain_evidence()), encoding="utf-8")

    result = run_drain_checker(evidence)

    assert result.returncode == 0, result.stderr
    assert "release-ready" in result.stdout


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
            "abc1234",
            "--source-location",
            "fixture",
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
