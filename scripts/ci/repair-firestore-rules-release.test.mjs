#!/usr/bin/env node
/**
 * Unit tests for scripts/ci/repair-firestore-rules-release.mjs.
 *
 * Mocks the Firebase Rules REST API (fetch) so the repair logic can be verified
 * without hitting the network. Follows the repo pattern of plain assert-based
 * scripts that exit non-zero on failure (compatible with `node --test`).
 */
import assert from "node:assert/strict";

import {
  is409ReleaseError,
  repairFirestoreRelease,
} from "./repair-firestore-rules-release.mjs";

const PROJECT = "burnbar";
const TOKEN = "test-token";
const OLD_RULESET = "projects/burnbar/rulesets/old-111";
const NEW_RULESET = "projects/burnbar/rulesets/new-222";
const API = "https://firebaserules.googleapis.com/v1";
const RELEASE_URL = `${API}/projects/${PROJECT}/releases/cloud.firestore`;
const RULESETS_URL = `${API}/projects/${PROJECT}/rulesets`;
const NEW_RULESET_URL = `${API}/${NEW_RULESET}`;
const RULES_CONTENT = "match /databases/{database}/documents { allow read: if true; }\n";

let passed = 0;
let failed = 0;

function ok(label) {
  console.log(`  \u2713 ${label}`);
  passed += 1;
}

function fail(label, err) {
  console.error(`  \u2717 ${label}: ${err?.message ?? err}`);
  failed += 1;
}

/**
 * Build a fetch mock backed by a handler function. The handler receives
 * { url, method, body } and returns { status, json } or throws.
 *
 * The returned mock has a `.calls` array recording all invocations.
 */
function makeFetchMock(handler) {
  const calls = [];
  const fn = async (url, init = {}) => {
    const method = init.method || "GET";
    const parsedBody = init.body ? JSON.parse(init.body) : undefined;
    calls.push({ url, method, body: parsedBody });
    const result = handler({ url, method, body: parsedBody });
    return {
      ok: result.status >= 200 && result.status < 300,
      status: result.status,
      text: async () => JSON.stringify(result.json ?? {}),
    };
  };
  fn.calls = calls;
  return fn;
}

function rulesetEntry(name, createTime) {
  return { name, createTime };
}

function rulesetSource(content) {
  return { source: { files: [{ name: "firestore.rules", content }] } };
}

// ─── Test 1: 409 on existing release -> repair PATCHes release ────────────

async function test409Repair() {
  const label = "409 repair: PATCHes release to new ruleset, verifies";
  let releaseRuleset = OLD_RULESET;

  const fetchMock = makeFetchMock(({ url, method, body }) => {
    if (url === RULESETS_URL && method === "GET") {
      return {
        status: 200,
        json: {
          rulesets: [
            rulesetEntry(NEW_RULESET, "2026-07-12T18:00:00.000Z"),
            rulesetEntry(OLD_RULESET, "2026-07-01T10:00:00.000Z"),
          ],
        },
      };
    }
    if (url === NEW_RULESET_URL && method === "GET") {
      return { status: 200, json: rulesetSource(RULES_CONTENT) };
    }
    if (url === RELEASE_URL && method === "GET") {
      return {
        status: 200,
        json: { name: `projects/${PROJECT}/releases/cloud.firestore`, rulesetName: releaseRuleset },
      };
    }
    if (url === RELEASE_URL && method === "PATCH") {
      assert.equal(
        body.rulesetName,
        NEW_RULESET,
        "PATCH body must set rulesetName to the new ruleset",
      );
      releaseRuleset = body.rulesetName;
      return {
        status: 200,
        json: { name: `projects/${PROJECT}/releases/cloud.firestore`, rulesetName: body.rulesetName },
      };
    }
    throw new Error(`unexpected ${method} ${url}`);
  });

  const result = await repairFirestoreRelease({
    project: PROJECT,
    token: TOKEN,
    fetchImpl: fetchMock,
    expectedRulesContent: RULES_CONTENT,
  });

  assert.equal(result.repaired, true, "repair should report repaired=true");
  assert.equal(result.oldRuleset, OLD_RULESET);
  assert.equal(result.newRuleset, NEW_RULESET);

  const methods = fetchMock.calls.map((c) => `${c.method}:${c.url.replace(/.*\/v1\//, "")}`);
  assert.ok(methods.includes("GET:projects/burnbar/rulesets"), "must list rulesets");
  assert.ok(methods.includes("PATCH:projects/burnbar/releases/cloud.firestore"), "must PATCH the release");
  const getCalls = methods.filter((m) => m === "GET:projects/burnbar/releases/cloud.firestore");
  assert.equal(getCalls.length, 2, "must GET the release twice (initial + verification)");

  ok(label);
}

// ─── Test 2: newest unrelated ruleset must not be selected ───────────────

async function testSkipsNewerUnrelatedRuleset() {
  const label = "matching source: skips newer unrelated ruleset";
  const unrelated = "projects/burnbar/rulesets/unrelated-333";
  const unrelatedUrl = `${API}/${unrelated}`;
  let releaseRuleset = OLD_RULESET;

  const fetchMock = makeFetchMock(({ url, method, body }) => {
    if (url === RULESETS_URL && method === "GET") {
      return {
        status: 200,
        json: {
          rulesets: [
            rulesetEntry(unrelated, "2026-07-12T19:00:00.000Z"),
            rulesetEntry(NEW_RULESET, "2026-07-12T18:00:00.000Z"),
          ],
        },
      };
    }
    if (url === unrelatedUrl && method === "GET") {
      return {
        status: 200,
        json: {
          source: {
            files: [{ name: "storage.rules", content: "match /b/{bucket}/o { }\n" }],
          },
        },
      };
    }
    if (url === NEW_RULESET_URL && method === "GET") {
      return { status: 200, json: rulesetSource(RULES_CONTENT) };
    }
    if (url === RELEASE_URL && method === "GET") {
      return {
        status: 200,
        json: { name: RELEASE_URL.replace(API, ""), rulesetName: releaseRuleset },
      };
    }
    if (url === RELEASE_URL && method === "PATCH") {
      assert.equal(body.rulesetName, NEW_RULESET);
      releaseRuleset = body.rulesetName;
      return { status: 200, json: { name: RELEASE_URL.replace(API, ""), rulesetName: releaseRuleset } };
    }
    throw new Error(`unexpected ${method} ${url}`);
  });

  const result = await repairFirestoreRelease({
    project: PROJECT,
    token: TOKEN,
    fetchImpl: fetchMock,
    expectedRulesContent: RULES_CONTENT,
  });
  assert.equal(result.newRuleset, NEW_RULESET);
  ok(label);
}

// ─── Test 2: release already points to matching ruleset -> no-op ──────────

async function testAlreadyCurrent() {
  const label = "idempotent no-op: release already points to matching ruleset";

  const fetchMock = makeFetchMock(({ url, method }) => {
    if (url === RULESETS_URL && method === "GET") {
      return {
        status: 200,
        json: { rulesets: [rulesetEntry(NEW_RULESET, "2026-07-12T18:00:00.000Z")] },
      };
    }
    if (url === NEW_RULESET_URL && method === "GET") {
      return { status: 200, json: rulesetSource(RULES_CONTENT) };
    }
    if (url === RELEASE_URL && method === "GET") {
      return {
        status: 200,
        json: { name: `projects/${PROJECT}/releases/cloud.firestore`, rulesetName: NEW_RULESET },
      };
    }
    throw new Error(`unexpected ${method} ${url}`);
  });

  const result = await repairFirestoreRelease({
    project: PROJECT,
    token: TOKEN,
    fetchImpl: fetchMock,
    expectedRulesContent: RULES_CONTENT,
  });

  assert.equal(result.repaired, false, "should not repair when already current");
  assert.equal(result.newRuleset, NEW_RULESET);
  const hasPatch = fetchMock.calls.some((c) => c.method === "PATCH");
  assert.equal(hasPatch, false, "must NOT PATCH when release is already current");

  ok(label);
}

// ─── Test 3: non-409 error -> is409ReleaseError returns false ─────────────

function testNon409Detection() {
  const label = "non-409 error: is409ReleaseError returns false";

  assert.equal(is409ReleaseError("HTTP 400 Bad Request: invalid rules"), false, "400 must not be 409");
  assert.equal(is409ReleaseError("Error: 500 Internal Server Error"), false, "500 must not be 409");
  assert.equal(is409ReleaseError("Permission denied (403)"), false, "403 must not be 409");
  assert.equal(is409ReleaseError(""), false, "empty string must not be 409");
  assert.equal(is409ReleaseError(null), false, "null must not be 409");
  assert.equal(is409ReleaseError(undefined), false, "undefined must not be 409");

  // Positive: actual 409 with the right message
  assert.equal(
    is409ReleaseError(
      'HTTP 409: {"error":{"message":"Requested entity already exists","status":"ALREADY_EXISTS"}}',
    ),
    true,
    "409 with 'Requested entity already exists' must be detected",
  );

  ok(label);
}

// ─── Test 4: PATCH fails -> exits non-zero (repairFirestoreRelease throws) ─

async function testPatchFails() {
  const label = "PATCH fails: repairFirestoreRelease throws (fail-closed)";

  const fetchMock = makeFetchMock(({ url, method }) => {
    if (url === RULESETS_URL && method === "GET") {
      return {
        status: 200,
        json: { rulesets: [rulesetEntry(NEW_RULESET, "2026-07-12T18:00:00.000Z")] },
      };
    }
    if (url === NEW_RULESET_URL && method === "GET") {
      return { status: 200, json: rulesetSource(RULES_CONTENT) };
    }
    if (url === RELEASE_URL && method === "GET") {
      return {
        status: 200,
        json: { name: `projects/${PROJECT}/releases/cloud.firestore`, rulesetName: OLD_RULESET },
      };
    }
    if (url === RELEASE_URL && method === "PATCH") {
      return {
        status: 403,
        json: { error: { message: "Permission denied on release update", status: "PERMISSION_DENIED" } },
      };
    }
    throw new Error(`unexpected ${method} ${url}`);
  });

  let threw = false;
  let errorMsg = "";
  try {
    await repairFirestoreRelease({
      project: PROJECT,
      token: TOKEN,
      fetchImpl: fetchMock,
      expectedRulesContent: RULES_CONTENT,
    });
  } catch (err) {
    threw = true;
    errorMsg = err.message;
  }

  assert.equal(threw, true, "must throw when PATCH fails");
  assert.match(errorMsg, /403/, "error message must include the failing status code");

  ok(label);
}

// ─── Test 5: idempotent — running twice produces the same state ───────────

async function testIdempotent() {
  const label = "idempotent: running twice produces the same state";

  let releaseRuleset = OLD_RULESET;

  const fetchMock = makeFetchMock(({ url, method, body }) => {
    if (url === RULESETS_URL && method === "GET") {
      return {
        status: 200,
        json: { rulesets: [rulesetEntry(NEW_RULESET, "2026-07-12T18:00:00.000Z")] },
      };
    }
    if (url === NEW_RULESET_URL && method === "GET") {
      return { status: 200, json: rulesetSource(RULES_CONTENT) };
    }
    if (url === RELEASE_URL && method === "GET") {
      return {
        status: 200,
        json: { name: `projects/${PROJECT}/releases/cloud.firestore`, rulesetName: releaseRuleset },
      };
    }
    if (url === RELEASE_URL && method === "PATCH") {
      releaseRuleset = body.rulesetName;
      return {
        status: 200,
        json: { name: `projects/${PROJECT}/releases/cloud.firestore`, rulesetName: body.rulesetName },
      };
    }
    throw new Error(`unexpected ${method} ${url}`);
  });

  // First run: should repair (PATCH)
  const result1 = await repairFirestoreRelease({
    project: PROJECT,
    token: TOKEN,
    fetchImpl: fetchMock,
    expectedRulesContent: RULES_CONTENT,
  });
  assert.equal(result1.repaired, true, "first run must repair");

  // Second run: release now points to new ruleset, should be a no-op
  const result2 = await repairFirestoreRelease({
    project: PROJECT,
    token: TOKEN,
    fetchImpl: fetchMock,
    expectedRulesContent: RULES_CONTENT,
  });
  assert.equal(result2.repaired, false, "second run must be no-op");

  // Verify only one PATCH was made across both runs
  const patchCount = fetchMock.calls.filter((c) => c.method === "PATCH").length;
  assert.equal(patchCount, 1, "exactly one PATCH across two runs");

  // State is identical: both runs agree on the new ruleset
  assert.equal(result1.newRuleset, result2.newRuleset, "both runs agree on the target ruleset");

  ok(label);
}

// ─── Run all tests ────────────────────────────────────────────────────────

async function run() {
  console.log("Self-test: repair-firestore-rules-release.mjs\n");

  testNon409Detection();

  for (const [name, fn] of [
    ["test409Repair", test409Repair],
    ["testSkipsNewerUnrelatedRuleset", testSkipsNewerUnrelatedRuleset],
    ["testAlreadyCurrent", testAlreadyCurrent],
    ["testPatchFails", testPatchFails],
    ["testIdempotent", testIdempotent],
  ]) {
    try {
      await fn();
    } catch (err) {
      fail(name, err);
    }
  }

  console.log(`\n${failed === 0 ? "PASS" : "FAIL"}: ${passed} passed, ${failed} failed`);
  process.exit(failed === 0 ? 0 : 1);
}

run();
