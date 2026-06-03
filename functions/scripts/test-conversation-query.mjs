/**
 * Unit tests for the pure `queryConversations` cockpit query shaping helpers.
 *
 * These exercise the side-effect-free planner module compiled to
 * `lib/callables/conversationQuery.js`: sort resolution, the single-`in`-clause facet limit,
 * Firestore filter/order clause shaping (recorded by a fake chainable query), and the manifest
 * row projection (which must surface plaintext facets + sealed envelopes while keeping bodies
 * out). The callable itself stays thin and composes these, so this proves the contract without
 * the Firestore emulator or Admin SDK initialization.
 */

import assert from "node:assert/strict";
import test from "node:test";

import { Timestamp } from "firebase-admin/firestore";

import {
  CONVERSATION_IN_CLAUSE_LIMIT,
  QUERY_CONVERSATION_SORT_FIELDS,
  applyConversationFacetFilters,
  assertConversationFacetCombination,
  buildConversationPageQuery,
  manifestFieldToISO,
  mapSessionLogManifestRow,
  resolveConversationSort,
} from "../lib/callables/conversationQuery.js";

/**
 * Chainable stand-in for a Firestore `Query`. Every `where`/`orderBy` records its arguments and
 * returns `this`, so accumulated `.calls` mirror the exact clauses the planner would issue.
 */
class FakeQuery {
  constructor() {
    this.calls = [];
  }

  where(field, op, value) {
    this.calls.push({ method: "where", field, op, value });
    return this;
  }

  orderBy(field, direction) {
    this.calls.push({ method: "orderBy", field, direction });
    return this;
  }
}

function whereClauses(query) {
  return query.calls.filter((call) => call.method === "where");
}

function orderClauses(query) {
  return query.calls.filter((call) => call.method === "orderBy");
}

function assertHttpsError(fn, code) {
  assert.throws(fn, (err) => err?.code === code);
}

test("sort fields are the documented closed set", () => {
  assert.deepEqual(
    [...QUERY_CONVERSATION_SORT_FIELDS],
    ["updatedAt", "startTime", "endTime", "costUSD", "totalTokens"]
  );
});

test("resolveConversationSort defaults to updatedAt desc and honors valid requests", () => {
  assert.deepEqual(resolveConversationSort(undefined, false, undefined), {
    sortField: "updatedAt",
    direction: "desc",
  });
  assert.deepEqual(resolveConversationSort("totalTokens", false, "asc"), {
    sortField: "totalTokens",
    direction: "asc",
  });
  assert.deepEqual(resolveConversationSort("costUSD", false, "desc"), {
    sortField: "costUSD",
    direction: "desc",
  });
});

test("resolveConversationSort rejects unknown sort fields by falling back to updatedAt", () => {
  assert.deepEqual(resolveConversationSort("bogus", false, undefined), {
    sortField: "updatedAt",
    direction: "desc",
  });
  // Only "asc" flips direction; any other value stays desc.
  assert.equal(resolveConversationSort("startTime", false, "sideways").direction, "desc");
});

test("resolveConversationSort pins a date window to a startTime sort", () => {
  // A range filter must lead the order-by, so a requested sort is overridden when a window exists.
  assert.equal(resolveConversationSort("costUSD", true, undefined).sortField, "startTime");
  assert.deepEqual(resolveConversationSort(undefined, true, "asc"), {
    sortField: "startTime",
    direction: "asc",
  });
});

test("assertConversationFacetCombination allows single-multi but blocks multi-multi", () => {
  assert.deepEqual(assertConversationFacetCombination([], []), {
    providerInClause: false,
    modelInClause: false,
  });
  assert.deepEqual(assertConversationFacetCombination(["codex"], ["gpt-5"]), {
    providerInClause: false,
    modelInClause: false,
  });
  assert.deepEqual(assertConversationFacetCombination(["codex", "claude"], []), {
    providerInClause: true,
    modelInClause: false,
  });
  assert.deepEqual(assertConversationFacetCombination(["codex"], ["gpt-5", "opus"]), {
    providerInClause: false,
    modelInClause: true,
  });
  assertHttpsError(
    () => assertConversationFacetCombination(["codex", "claude"], ["gpt-5", "opus"]),
    "invalid-argument"
  );
});

test("applyConversationFacetFilters uses == for a single provider and skips empty facets", () => {
  const query = applyConversationFacetFilters(new FakeQuery(), {
    providers: ["codex"],
    models: [],
    providerInClause: false,
    modelInClause: false,
  });
  assert.deepEqual(whereClauses(query), [
    { method: "where", field: "provider", op: "==", value: "codex" },
  ]);
});

test("applyConversationFacetFilters passes a validated multi-provider selection through as an in clause without truncation", () => {
  // The handler caps the array at 20 entries, well under Firestore's 30-value `in` limit, so a
  // realistic 13-provider selection must reach the query intact — no silent drop of providers 11+.
  const providers = Array.from({ length: 13 }, (_, index) => `provider-${index}`);
  const query = applyConversationFacetFilters(new FakeQuery(), {
    providers,
    models: [],
    providerInClause: true,
    modelInClause: false,
  });
  const clauses = whereClauses(query);
  assert.equal(clauses.length, 1);
  assert.equal(clauses[0].op, "in");
  assert.equal(clauses[0].field, "provider");
  assert.deepEqual(clauses[0].value, providers, "every selected provider must reach the in clause");
});

test("applyConversationFacetFilters defends against an over-limit in clause by capping at Firestore's 30", () => {
  assert.equal(CONVERSATION_IN_CLAUSE_LIMIT, 30);
  const models = Array.from({ length: 42 }, (_, index) => `model-${index}`);
  const query = applyConversationFacetFilters(new FakeQuery(), {
    providers: [],
    models,
    providerInClause: false,
    modelInClause: true,
  });
  const clauses = whereClauses(query);
  assert.equal(clauses.length, 1);
  assert.equal(clauses[0].op, "in");
  assert.equal(clauses[0].field, "model");
  assert.equal(clauses[0].value.length, 30);
  assert.deepEqual(clauses[0].value, models.slice(0, 30));
});

test("applyConversationFacetFilters maps every equality facet to a == clause", () => {
  // projectName is intentionally NOT a server-side facet: project/path text is
  // device-only (sealed), so the server can never filter conversations by it.
  const query = applyConversationFacetFilters(new FakeQuery(), {
    providers: [],
    models: ["gpt-5-codex"],
    providerInClause: false,
    modelInClause: false,
    deviceId: "mac-1",
    sourceType: "cli_session",
  });
  assert.deepEqual(whereClauses(query), [
    { method: "where", field: "model", op: "==", value: "gpt-5-codex" },
    { method: "where", field: "deviceId", op: "==", value: "mac-1" },
    { method: "where", field: "sourceType", op: "==", value: "cli_session" },
  ]);
});

test("applyConversationFacetFilters turns a date window into startTime range bounds", () => {
  const dateFrom = "2026-05-01T00:00:00.000Z";
  const dateTo = "2026-05-28T00:00:00.000Z";
  const query = applyConversationFacetFilters(new FakeQuery(), {
    providers: [],
    models: [],
    providerInClause: false,
    modelInClause: false,
    dateFrom,
    dateTo,
  });
  const clauses = whereClauses(query);
  assert.equal(clauses.length, 2);
  assert.equal(clauses[0].field, "startTime");
  assert.equal(clauses[0].op, ">=");
  assert.ok(clauses[0].value instanceof Timestamp);
  assert.equal(clauses[0].value.toDate().toISOString(), dateFrom);
  assert.equal(clauses[1].field, "startTime");
  assert.equal(clauses[1].op, "<=");
  assert.ok(clauses[1].value instanceof Timestamp);
  assert.equal(clauses[1].value.toDate().toISOString(), dateTo);
});

test("buildConversationPageQuery emits exactly one explicit order key for every sort", () => {
  // Firestore appends an implicit `__name__` tiebreaker, so a snapshot cursor stays stable
  // without a second explicit order key. Emitting one would change the required composite index
  // from `(facet, sortField)` to `(facet, sortField, tiebreaker)` and break the documented
  // cockpit indexes, so the planner must never add it — for the default sort or any other.
  for (const sortField of QUERY_CONVERSATION_SORT_FIELDS) {
    for (const direction of ["asc", "desc"]) {
      const query = buildConversationPageQuery(new FakeQuery(), { sortField, direction });
      assert.deepEqual(
        orderClauses(query),
        [{ method: "orderBy", field: sortField, direction }],
        `expected a single orderBy for ${sortField} ${direction}`
      );
    }
  }
});

test("manifestFieldToISO normalizes timestamps and stored strings, rejects junk", () => {
  const ts = Timestamp.fromDate(new Date("2026-05-20T11:00:00.000Z"));
  assert.equal(manifestFieldToISO(ts), "2026-05-20T11:00:00.000Z");
  assert.equal(manifestFieldToISO("2026-05-20T11:00:00Z"), "2026-05-20T11:00:00.000Z");
  assert.equal(manifestFieldToISO(undefined), undefined);
  assert.equal(manifestFieldToISO(null), undefined);
  assert.equal(manifestFieldToISO("not a date"), undefined);
  assert.equal(manifestFieldToISO(12345), undefined);
});

test("mapSessionLogManifestRow surfaces facets and sealed envelopes but never bodies", () => {
  const sealedTitle = {
    algorithm: "AES-256-GCM",
    keyVersion: 1,
    nonce: "bm9uY2U=",
    ciphertext: "Y2lwaGVy",
    tag: "dGFn",
  };
  const row = mapSessionLogManifestRow("log-1", {
    provider: "codex",
    projectName: "BurnBar",
    sourceType: "cli_session",
    deviceId: "mac-1",
    model: "gpt-5-codex",
    facetSchemaVersion: 1,
    messageCount: 12,
    totalTokens: 25200,
    costUSD: 0.42,
    workingDirectory: "/Users/dev/project",
    toolTags: ["bash", "edit"],
    sealedTitle,
    sealedBodyPreview: sealedTitle,
    storagePath: "users/u/session_logs/log-1/bodies/abc.json.aesgcm",
    bodyHash: "abc",
    startTime: Timestamp.fromDate(new Date("2026-05-20T11:00:00.000Z")),
    updatedAt: "2026-05-20T12:00:00Z",
    // Adversarial: a plaintext body must never be projected into the cockpit row.
    body: "full private transcript",
    text: "more private text",
  });

  assert.equal(row.id, "log-1");
  assert.equal(row.provider, "codex");
  assert.equal(row.model, "gpt-5-codex");
  assert.equal(row.totalTokens, 25200);
  assert.equal(row.costUSD, 0.42);
  assert.deepEqual(row.toolTags, ["bash", "edit"]);
  assert.deepEqual(row.sealedTitle, sealedTitle);
  assert.equal(row.startTime, "2026-05-20T11:00:00.000Z");
  assert.equal(row.updatedAt, "2026-05-20T12:00:00.000Z");

  // Plaintext content fields are not part of the projection.
  assert.ok(!("body" in row), "row must not carry a plaintext body");
  assert.ok(!("text" in row), "row must not carry plaintext text");

  // Absent facets are stripped rather than serialized as undefined/null.
  assert.ok(!("endTime" in row), "missing endTime should be stripped");
  assert.ok(!("inputTokens" in row), "missing inputTokens should be stripped");
});
