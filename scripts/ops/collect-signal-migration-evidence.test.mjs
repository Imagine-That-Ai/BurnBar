import assert from "node:assert/strict";
import test from "node:test";

import {
  REQUIRED_COLLECTIONS,
  aggregateCounterDocuments,
  buildEvidence,
} from "./collect-signal-migration-evidence.mjs";

const fields = {
  totalWrites: 4,
  createWrites: 2,
  updateWrites: 1,
  deleteWrites: 1,
  signalSealedWrites: 3,
  legacySealedWrites: 0,
  mixedEnvelopeWrites: 0,
  plaintextOnlyWrites: 0,
};

function fixtureDocuments() {
  const producers = ["ios", "macos", "android", "unknown"];
  return REQUIRED_COLLECTIONS.map((collection, index) => ({
    schemaVersion: 1,
    day: "2026-08-04",
    collection,
    producer: producers[index % producers.length],
    ...fields,
    uid: "must-not-survive",
    documentPath: "users/secret/private/path",
    payload: "must-not-survive",
  }));
}

test("aggregateCounterDocuments emits fixed counters and drops every raw extra field", () => {
  const aggregate = aggregateCounterDocuments(fixtureDocuments());
  assert.equal(aggregate.counterDocuments, 10);
  assert.deepEqual(aggregate.totals, {
    totalWrites: 40,
    createWrites: 20,
    updateWrites: 10,
    deleteWrites: 10,
    signalSealedWrites: 30,
    legacySealedWrites: 0,
    mixedEnvelopeWrites: 0,
    plaintextOnlyWrites: 0,
  });
  const serialized = JSON.stringify(aggregate);
  assert.doesNotMatch(serialized, /must-not-survive|users\/secret|documentPath|payload/u);
  assert.deepEqual(Object.keys(aggregate.byCollection).sort(), [...REQUIRED_COLLECTIONS].sort());
  assert.deepEqual(Object.keys(aggregate.byProducer).sort(), ["android", "ios", "macos", "unknown"]);
});

test("buildEvidence carries only aggregate privacy metadata and release binding", () => {
  const evidence = buildEvidence({
    projectId: "burnbar",
    release: "v1.0.30",
    sourceCommit: "a".repeat(40),
    start: "2026-08-01",
    end: "2026-08-04",
    capturedAt: "2026-08-04T12:00:00.000Z",
    documents: fixtureDocuments(),
  });
  assert.equal(evidence.privacy.classification, "aggregate_only_no_user_or_content_data");
  assert.equal(evidence.privacy.containsUserIdentifiers, false);
  assert.equal(evidence.privacy.containsDocumentIdentifiersOrPaths, false);
  assert.equal(evidence.privacy.containsPayloadCiphertextOrKeys, false);
  assert.equal(evidence.sourceCommit, "a".repeat(40));
});

test("collector rejects unknown collection/platform buckets and invalid counters", () => {
  assert.throws(
    () => aggregateCounterDocuments([{ ...fixtureDocuments()[0], collection: "private_new_collection" }]),
    /Unexpected migration collection/u,
  );
  assert.throws(
    () => aggregateCounterDocuments([{ ...fixtureDocuments()[0], producer: "customer-name" }]),
    /Unexpected producer bucket/u,
  );
  assert.throws(
    () => aggregateCounterDocuments([{ ...fixtureDocuments()[0], totalWrites: -1 }]),
    /non-negative integer/u,
  );
});
