import assert from "node:assert/strict";

const CONSOLIDATED_MATCH =
  "match /users/{userId}/{collectionId}/{documentId} {";

function consolidatedBlock(rules) {
  const start = rules.indexOf(CONSOLIDATED_MATCH);
  assert.notEqual(
    start,
    -1,
    "consolidated user collection rules block must exist",
  );
  const next = rules.indexOf(
    "\n    match /",
    start + CONSOLIDATED_MATCH.length,
  );
  return rules.slice(start, next < 0 ? rules.length : next);
}

export function consolidatedCollectionOperations(rules, collection) {
  const operations = new Set();
  const block = consolidatedBlock(rules);
  const allowlist =
    /allow\s+([^:]+):\s+if\s+[^;]*?\bcollectionId\s+in\s+\[([\s\S]*?)\]\s*(?:&&|;)/g;

  for (const match of block.matchAll(allowlist)) {
    const collections = [...match[2].matchAll(/"([A-Za-z0-9_]+)"/g)].map(
      (entry) => entry[1],
    );
    if (!collections.includes(collection)) continue;
    for (const operation of match[1].split(",")) {
      operations.add(operation.trim());
    }
  }
  return operations;
}

export function assertConsolidatedServerOnlyCollection(rules, collection) {
  const operations = consolidatedCollectionOperations(rules, collection);
  assert.equal(
    operations.has("read"),
    true,
    `${collection} must remain owner-readable through the consolidated gate`,
  );
  for (const operation of ["create", "update", "delete", "write"]) {
    assert.equal(
      operations.has(operation),
      false,
      `${collection} must remain server-only for ${operation}`,
    );
  }
}

export function assertConsolidatedNoClientUpsert(rules, collection) {
  const operations = consolidatedCollectionOperations(rules, collection);
  assert.equal(
    operations.has("read"),
    true,
    `${collection} must remain owner-readable through the consolidated gate`,
  );
  for (const operation of ["create", "update", "write"]) {
    assert.equal(
      operations.has(operation),
      false,
      `${collection} must reject client ${operation}`,
    );
  }
}
