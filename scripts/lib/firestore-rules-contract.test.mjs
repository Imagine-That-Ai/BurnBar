import assert from "node:assert/strict";
import test from "node:test";
import {
  assertConsolidatedNoClientUpsert,
  assertConsolidatedServerOnlyCollection,
  consolidatedCollectionOperations,
} from "./firestore-rules-contract.mjs";

const rules = `
match /users/{userId}/{collectionId}/{documentId} {
  allow read: if ownsUserNamespace(userId) && collectionId in [
    "server_only", "deletable"
  ];
  allow delete: if ownsUserNamespace(userId) && collectionId in ["deletable"];
  allow create, update: if collectionId in ["client_writable"]
    && ownerWritableNonSecret(userId);
}
match /users/{userId}/next/{documentId} {
  allow write: if true;
}
`;

test("parses operations from the consolidated user collection gate", () => {
  assert.deepEqual(
    [...consolidatedCollectionOperations(rules, "deletable")].sort(),
    ["delete", "read"],
  );
  assert.deepEqual(
    [...consolidatedCollectionOperations(rules, "client_writable")].sort(),
    ["create", "update"],
  );
});

test("server-only assertion rejects every mutation operation", () => {
  assert.doesNotThrow(() =>
    assertConsolidatedServerOnlyCollection(rules, "server_only"),
  );
  assert.throws(() =>
    assertConsolidatedServerOnlyCollection(rules, "deletable"),
  );
});

test("no-upsert assertion permits deletion but rejects client upserts", () => {
  assert.doesNotThrow(() =>
    assertConsolidatedNoClientUpsert(rules, "deletable"),
  );
  assert.throws(() =>
    assertConsolidatedNoClientUpsert(rules, "client_writable"),
  );
});
