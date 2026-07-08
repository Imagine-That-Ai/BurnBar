#!/usr/bin/env node
/**
 * Wave-5 WS3 — structural + byte-identity + coverage gate for the platform-neutral
 * budget-enforcement contract vectors.
 *
 * The canonical fixture lives at tests/fixtures/budget-enforcement/. Every platform test
 * target consumes a byte-identical copy (OpenBurnBarCore test bundle on Apple; Android
 * src/test/resources for the JUnit gate). This Linux leg pins every committed copy present
 * AND byte-identical so a silent drift OR a deleted copy fails CI, then structurally
 * validates the vectors and asserts the coverage matrix — so a platform can never quietly
 * drop a scope, a behavior, or a fail-closed case. Exits non-zero on any failure.
 *
 * The behavioral OPEN (running the vectors through each gate) lives in the platform suites:
 * BudgetGateContractVectorTests (OpenBurnBarCore, Apple) today; the Android JUnit consumer
 * in a follow-up. This script is the cheap fail-closed drift + coverage tripwire.
 */
import { createHash } from "node:crypto";
import { existsSync, readFileSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";

// Repo root is computed from this file's location; the self-test overrides it via
// BUDGET_FIXTURE_REPO_ROOT to point at a temp fixture tree.
const REPO = process.env.BUDGET_FIXTURE_REPO_ROOT
  ? resolve(process.env.BUDGET_FIXTURE_REPO_ROOT)
  : resolve(dirname(fileURLToPath(import.meta.url)), "..", "..");

let failures = 0;
const fail = (msg) => {
  console.error(`  FAIL ${msg}`);
  failures += 1;
};
const ok = (msg) => console.log(`  ok   ${msg}`);

function requireByteIdenticalCopies(label, copies) {
  const shas = new Set();
  let missing = false;
  for (const rel of copies) {
    const abs = resolve(REPO, rel);
    if (!existsSync(abs)) {
      fail(`${label}: missing committed copy ${rel}`);
      missing = true;
      continue;
    }
    shas.add(createHash("sha256").update(readFileSync(abs)).digest("hex"));
  }
  if (missing) return null;
  if (shas.size !== 1) {
    fail(`${label}: ${copies.length} copies are not byte-identical (sha256 set: ${[...shas].join(", ")})`);
    return null;
  }
  ok(`${label}: ${copies.length} byte-identical copies present`);
  return JSON.parse(readFileSync(resolve(REPO, copies[0]), "utf8"));
}

// ---- Byte-identity: canonical + Apple Core copy + Android copy --------------

const BUDGET_COPIES = [
  "tests/fixtures/budget-enforcement/budget-enforcement-vectors.json",
  "OpenBurnBarCore/Tests/OpenBurnBarCoreTests/Fixtures/budget-enforcement-vectors.json",
  "android/app/src/test/resources/budget-enforcement/budget-enforcement-vectors.json",
];

const suite = requireByteIdenticalCopies("budget-enforcement-vectors", BUDGET_COPIES);

// ---- Structural validation --------------------------------------------------

const SCOPES = ["credential", "project", "global", "organization"];
const PERIODS = ["day", "week", "month", "allTime"];
const BEHAVIORS = ["warnThenBlock", "hardBlock", "warnOnly", "hardBlockWithFallback"];
const BILLING = ["perUsage", "subscription", "unknown"];
const DECISIONS = ["allow", "warn", "block", "paused"];

if (suite) {
  if (suite.schemaVersion !== 1) fail(`schemaVersion must be 1, got ${suite.schemaVersion}`);
  if (!Array.isArray(suite.vectors) || suite.vectors.length === 0) {
    fail("vectors[] must be a non-empty array");
  } else {
    ok(`${suite.vectors.length} vectors`);
  }

  const ids = new Set();
  const seenScopes = new Set();
  const seenBehaviors = new Set();
  const seenDecisions = new Set();
  let failClosedBlock = false;
  let failClosedWarn = false;
  let fallbackResolves = false;
  let subscriptionShortCircuit = false;

  for (const v of suite.vectors ?? []) {
    const at = `vector "${v.id ?? "<no id>"}"`;
    if (!v.id) fail(`${at}: missing id`);
    else if (ids.has(v.id)) fail(`${at}: duplicate id`);
    else ids.add(v.id);

    if (!Array.isArray(v.rules)) fail(`${at}: rules[] missing`);
    for (const r of v.rules ?? []) {
      if (!r.id) fail(`${at}: a rule has no id`);
      if (!SCOPES.includes(r.scope)) fail(`${at}: bad scope ${r.scope}`);
      if (!PERIODS.includes(r.period)) fail(`${at}: bad period ${r.period}`);
      if (!BEHAVIORS.includes(r.behavior)) fail(`${at}: bad behavior ${r.behavior}`);
      if (typeof r.amountUSD !== "number") fail(`${at}: rule ${r.id} amountUSD not a number`);
      if (!Array.isArray(r.fallbackCredentialIDs)) fail(`${at}: rule ${r.id} fallbackCredentialIDs not an array`);
      seenScopes.add(r.scope);
      seenBehaviors.add(r.behavior);
    }

    const req = v.request ?? {};
    if (!req.providerID || !req.slotID) fail(`${at}: request needs providerID + slotID`);
    if (!BILLING.includes(req.billingMode)) fail(`${at}: bad billingMode ${req.billingMode}`);
    if (typeof req.estimatedCost !== "number") fail(`${at}: request.estimatedCost not a number`);

    const led = v.ledger ?? {};
    if (typeof led.spend !== "object" || led.spend === null) fail(`${at}: ledger.spend must be an object`);
    if (!Array.isArray(led.unreadable)) fail(`${at}: ledger.unreadable must be an array`);
    if (!led.reference) fail(`${at}: ledger.reference (ISO date) required`);

    const exp = v.expected ?? {};
    if (!DECISIONS.includes(exp.decision)) fail(`${at}: bad expected.decision ${exp.decision}`);
    seenDecisions.add(exp.decision);

    // Property tagging for the coverage matrix.
    const unreadable = new Set(led.unreadable ?? []);
    const behaviorsHit = new Set((v.rules ?? []).map((r) => r.behavior));
    if (unreadable.size > 0 && exp.decision === "block") failClosedBlock = true;
    if (unreadable.size > 0 && exp.decision === "warn" && behaviorsHit.has("warnOnly")) failClosedWarn = true;
    if (exp.decision === "block" && exp.fallbackCredentialID) fallbackResolves = true;
    if (req.billingMode === "subscription" && exp.decision === "allow") subscriptionShortCircuit = true;
  }

  // ---- Coverage matrix (the whole point: omission fails the build) ----------
  for (const s of SCOPES) {
    if (seenScopes.has(s)) ok(`scope covered: ${s}`);
    else fail(`no vector exercises scope "${s}"`);
  }
  for (const b of BEHAVIORS) {
    if (seenBehaviors.has(b)) ok(`behavior covered: ${b}`);
    else fail(`no vector exercises behavior "${b}"`);
  }
  for (const d of DECISIONS) {
    if (seenDecisions.has(d)) ok(`decision covered: ${d}`);
    else fail(`no vector expects decision "${d}"`);
  }
  if (failClosedBlock) ok("fail-closed-to-block covered"); else fail("no fail-closed (unreadable -> block) vector");
  if (failClosedWarn) ok("fail-closed-warnOnly-to-warn covered"); else fail("no fail-closed warnOnly (unreadable -> warn) vector");
  if (fallbackResolves) ok("fallback-resolution covered"); else fail("no fallback-resolving vector");
  if (subscriptionShortCircuit) ok("subscription short-circuit covered"); else fail("no subscription-short-circuit vector");
}

// ---- Entitlement vectors: byte-identity + minimal structure ----------------

const ENT_COPIES = [
  "tests/fixtures/budget-enforcement/entitlement-vectors.json",
  "OpenBurnBarCore/Tests/OpenBurnBarCoreTests/Fixtures/entitlement-vectors.json",
];
if (existsSync(resolve(REPO, ENT_COPIES[0]))) {
  const ent = requireByteIdenticalCopies("entitlement-vectors", ENT_COPIES);
  if (ent && (!Array.isArray(ent.vectors) || ent.vectors.length === 0)) {
    fail("entitlement-vectors: vectors[] must be a non-empty array");
  } else if (ent) {
    ok(`entitlement-vectors: ${ent.vectors.length} vectors`);
  }
}

if (failures > 0) {
  console.error(`\nbudget-enforcement fixture gate: ${failures} failure(s)`);
  process.exit(1);
}
console.log("\nbudget-enforcement fixture gate: all checks passed");
