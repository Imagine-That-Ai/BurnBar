#!/usr/bin/env node
/**
 * Self-test for scripts/ci/check-callable-validation.mjs.
 * Run: node --test scripts/ci/check-callable-validation.test.mjs
 */

import assert from "node:assert/strict";
import { test } from "node:test";

import {
  analyzeSource,
  diffBaseline,
  localValidatorNames,
  matchingParenEnd,
} from "./check-callable-validation.mjs";

const SAMPLE = `
import { onCall } from "firebase-functions/v2/https";

function parseThing(data) {
  return boundedTrimmedString(data.x, "x", 10, true);
}

function unrelatedHelper(x) {
  return x + 1;
}

export const schemaValidated = onCall(opts, wrapCallableHandler("schemaValidated", async (request) => {
  const { scope } = parseCallableInput("schemaValidated", SCHEMA, request.data);
  return scope;
}));

export const helperValidated = onCall(opts, wrapCallableHandler("helperValidated", async (request) => {
  return parseThing(request.data);
}));

export const inlineValidated = onCall(opts, wrapCallableHandler("inlineValidated", async (request) => {
  if (typeof request.data.x !== "string") throw new HttpsError("invalid-argument", "x is required");
  return request.data.x;
}));

export const unvalidated = onCall(opts, wrapCallableHandler("unvalidated", async (request) => {
  return request.data.foo;
}));

export const noInput = onCall(opts, wrapCallableHandler("noInput", async (request) => {
  return request.auth?.uid;
}));
`;

function findCallable(results, name) {
  const hit = results.find((r) => r.name === name);
  assert.ok(hit, `expected callable ${name} to be found`);
  return hit;
}

test("localValidatorNames picks up only validating helpers", () => {
  const names = localValidatorNames(SAMPLE);
  assert.equal(names.has("parseThing"), true);
  assert.equal(names.has("unrelatedHelper"), false);
});

test("analyzeSource recognizes schema, helper, and inline validation", () => {
  const results = analyzeSource("sample.ts", SAMPLE);
  assert.equal(findCallable(results, "schemaValidated").validated, true);
  assert.equal(findCallable(results, "helperValidated").validated, true);
  assert.equal(findCallable(results, "inlineValidated").validated, true);
});

test("analyzeSource flags an unvalidated payload reader", () => {
  const results = analyzeSource("sample.ts", SAMPLE);
  const bad = findCallable(results, "unvalidated");
  assert.equal(bad.readsInput, true);
  assert.equal(bad.validated, false);
  assert.equal(bad.key, "sample.ts::unvalidated");
});

test("analyzeSource treats a no-input callable as not reading input", () => {
  const results = analyzeSource("sample.ts", SAMPLE);
  assert.equal(findCallable(results, "noInput").readsInput, false);
});

test("analyzeSource resolves cross-file validator helpers via globalValidators", () => {
  const src =
    'export const delegated = onCall(opts, wrapCallableHandler("delegated", async (request) => {\n' +
    "  return parseGooglePlayTopUpInput(request.data);\n" +
    "}));";
  // Without the global set the cross-file helper is unknown → flagged.
  assert.equal(findCallable(analyzeSource("f.ts", src), "delegated").validated, false);
  // With it resolved from another file, the delegating callable is validated.
  const withGlobal = analyzeSource("f.ts", src, new Set(["parseGooglePlayTopUpInput"]));
  assert.equal(findCallable(withGlobal, "delegated").validated, true);
});

test("matchingParenEnd ignores parens inside string literals", () => {
  // `("(")` — the inner "(" is quoted and must not be counted.
  assert.equal(matchingParenEnd('("(")', 0), 5);
});

test("diffBaseline reports new offenders and stale entries", () => {
  const { added, stale } = diffBaseline(["a::new", "b::keep"], ["b::keep", "c::gone"]);
  assert.deepEqual(added, ["a::new"]);
  assert.deepEqual(stale, ["c::gone"]);
});

test("diffBaseline is clean when current matches baseline", () => {
  const { added, stale } = diffBaseline(["x::1"], ["x::1"]);
  assert.deepEqual(added, []);
  assert.deepEqual(stale, []);
});
