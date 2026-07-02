#!/usr/bin/env node
/**
 * Self-test for scripts/ci/check-callable-validation.mjs.
 * Run: node --test scripts/ci/check-callable-validation.test.mjs
 */

import assert from "node:assert/strict";
import { test } from "node:test";

import {
  analyzeSource,
  controllingGuard,
  destructuredDataAliases,
  diffBaseline,
  hasPayloadTiedInvalidArg,
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

test("analyzeSource does not count validator calls on unrelated non-payload values", () => {
  const src =
    'export const badToken = onCall(opts, wrapCallableHandler("badToken", async (request) => {\n' +
    '  const receiptID = requiredIdentifier("server-side-id", "receiptID");\n' +
    "  return { receiptID, raw: request.data.foo };\n" +
    "}));";
  const bad = findCallable(analyzeSource("f.ts", src), "badToken");
  assert.equal(bad.readsInput, true);
  assert.equal(bad.validated, false);
});

test("analyzeSource does not count local validators called with non-payload values", () => {
  const src =
    "function parseReceipt(raw) { return requiredIdentifier(raw, 'receiptID'); }\n" +
    'export const badHelper = onCall(opts, wrapCallableHandler("badHelper", async (request) => {\n' +
    '  const receiptID = parseReceipt("server-side-id");\n' +
    "  return { receiptID, raw: request.data.foo };\n" +
    "}));";
  const bad = findCallable(analyzeSource("f.ts", src), "badHelper");
  assert.equal(bad.readsInput, true);
  assert.equal(bad.validated, false);
});

test("analyzeSource recognizes lowercase httpsError wrappers for payload validation", () => {
  const src =
    'export const lowerWrapper = onCall(opts, wrapCallableHandler("lowerWrapper", async (request) => {\n' +
    "  const token = String(request.data.token ?? '').trim();\n" +
    '  if (!token) throw httpsError("invalid-argument", "token is required");\n' +
    "  return token;\n" +
    "}));";
  const ok = findCallable(analyzeSource("f.ts", src), "lowerWrapper");
  assert.equal(ok.readsInput, true);
  assert.equal(ok.validated, true);
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

// R-S1 P2 (check-callable-validation.mjs:144) — an inline invalid-argument for an
// unrelated precondition must NOT exempt a callable that then reads request.data raw.
test("analyzeSource flags an inline invalid-argument thrown for an unrelated precondition", () => {
  const src =
    'export const badPrecondition = onCall(opts, wrapCallableHandler("badPrecondition", async (request) => {\n' +
    '  if (!serverReady()) throw new HttpsError("invalid-argument", "server not ready");\n' +
    "  return request.data.foo;\n" +
    "}));";
  const bad = findCallable(analyzeSource("f.ts", src), "badPrecondition");
  assert.equal(bad.readsInput, true);
  assert.equal(bad.validated, false);
});

test("analyzeSource counts an inline invalid-argument tied to a payload-derived local", () => {
  const src =
    'export const goodInline = onCall(opts, wrapCallableHandler("goodInline", async (request) => {\n' +
    "  const scope = request.data.scope;\n" +
    '  if (typeof scope !== "string") { throw new HttpsError("invalid-argument", "scope must be a string"); }\n' +
    "  return scope;\n" +
    "}));";
  const ok = findCallable(analyzeSource("f.ts", src), "goodInline");
  assert.equal(ok.readsInput, true);
  assert.equal(ok.validated, true);
});

// R-S1 P2 (check-callable-validation.mjs:84) — a handler that destructures `data`
// off the request reads client input and must face the same validation gate.
test("analyzeSource detects a destructured payload read and flags it when unvalidated", () => {
  const src =
    'export const badDestructure = onCall(opts, wrapCallableHandler("badDestructure", async ({ data, auth }) => {\n' +
    "  return data.foo;\n" +
    "}));";
  const bad = findCallable(analyzeSource("f.ts", src), "badDestructure");
  assert.equal(bad.readsInput, true);
  assert.equal(bad.validated, false);
});

test("analyzeSource recognizes a validated, renamed destructured payload", () => {
  const src =
    'export const goodDestructure = onCall(opts, wrapCallableHandler("goodDestructure", async ({ data: payload }) => {\n' +
    '  if (typeof payload.x !== "string") throw new HttpsError("invalid-argument", "x is required");\n' +
    "  return payload.x;\n" +
    "}));";
  const ok = findCallable(analyzeSource("f.ts", src), "goodDestructure");
  assert.equal(ok.readsInput, true);
  assert.equal(ok.validated, true);
});

test("destructuredDataAliases picks up data (and renames) without matching metadata", () => {
  assert.deepEqual([...destructuredDataAliases("async ({ data, auth }) => {}")], ["data"]);
  assert.deepEqual([...destructuredDataAliases("async ({ data: payload }) => {}")], ["payload"]);
  assert.deepEqual([...destructuredDataAliases("async ({ metadata }) => {}")], []);
  assert.deepEqual([...destructuredDataAliases("async (request) => {}")], []);
});

test("hasPayloadTiedInvalidArg ties the inline exemption to a payload reference", () => {
  const tied =
    'const scope = request.data.scope;\n if (!scope) throw new HttpsError("invalid-argument", "scope required");';
  assert.equal(hasPayloadTiedInvalidArg(tied), true);
  const untied = 'if (!ready()) throw new HttpsError("invalid-argument", "not ready");\n return request.data.foo;';
  assert.equal(hasPayloadTiedInvalidArg(untied), false);
  // A destructured-alias reference in the guard counts as a payload tie.
  const aliasTied = 'if (!payload.x) throw new HttpsError("invalid-argument", "x required");';
  assert.equal(hasPayloadTiedInvalidArg(aliasTied, new Set(["payload"])), true);
});

test("controllingGuard captures the enclosing if condition for a braced throw", () => {
  const body = 'if (!scope) {\n  throw new HttpsError("invalid-argument", "x");\n}';
  assert.match(controllingGuard(body, body.indexOf("HttpsError")), /!scope/);
});
