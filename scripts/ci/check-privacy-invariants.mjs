#!/usr/bin/env node
/**
 * Privacy invariants gate (run-09: privacy / logging / metadata).
 *
 * Fail-closed, deterministic, dependency-free. Locks in the structural
 * invariants behind the run-09 findings so the whole class cannot silently
 * regress in a future refactor. Every invariant maps to a finding:
 *
 *   I1  Ephemeral PII/token collections MUST declare a Firestore TTL override
 *       (F-RR09-001 / F-RR09-007 — push queues + notification events must
 *       auto-expire; a missing override = unbounded retention of uid + tokens).
 *   I2  Every `ttl:true` override MUST have a code writer that stamps the field
 *       (a TTL index with no writer is dead config; a writer with no index is a
 *       silent retention leak). Keeps {writers} and {indexes} in sync.
 *   I3  No production Cloud Functions source imports the raw firebase-functions
 *       logger (F-RR09-002 — it bypasses the PII scrubber). Belt-and-suspenders
 *       for the eslint no-restricted-imports rule, in a portable gate.
 *   I4  The structured logger keeps its UID-path redaction (F-RR09-002).
 *   I5  Outbound push payload builders omit stable cross-processor correlators
 *       (F-RR09-008 — connection_id / paired_device_id / real display name must
 *       never ride to APNs/FCM).
 *
 * Extending this gate is intentionally a one-line edit: add a collection to
 * EPHEMERAL_PII_COLLECTIONS, a banned key to BANNED_PUSH_KEYS, etc.
 *
 * Usage:  node scripts/ci/check-privacy-invariants.mjs
 * Exit:   0 = all invariants hold; 1 = one or more violated; 2 = misconfigured.
 */

import { readFileSync, readdirSync, statSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

// Root defaults to the repo; PRIVACY_GATE_ROOT lets the self-test point the
// gate at a throwaway fixture tree (positive controls).
const REPO_ROOT = process.env.PRIVACY_GATE_ROOT
  ? process.env.PRIVACY_GATE_ROOT
  : join(dirname(fileURLToPath(import.meta.url)), "..", "..");
const FUNCTIONS_SRC = join(REPO_ROOT, "functions", "src");
const INDEXES_PATH = join(REPO_ROOT, "firestore.indexes.json");

/**
 * Root collections that persist a uid together with push tokens and/or
 * identifying metadata and therefore MUST auto-expire. Each requires a
 * `ttl:true` field override AND a writer that stamps the field (I1 + I2).
 */
const EPHEMERAL_PII_COLLECTIONS = [
  { collection: "voip_outbound", field: "expireAt", finding: "F-RR09-001" },
  { collection: "fcm_outbound", field: "expireAt", finding: "F-RR09-001" },
  { collection: "agent_notification_events", field: "expireAt", finding: "F-RR09-007" },
];

/** Keys that must never appear in an outbound APNs/FCM push payload (F-RR09-008). */
const BANNED_PUSH_KEYS = [
  "connectionId",
  "connection_id",
  "pairedDeviceId",
  "paired_device_id",
  "displayName",
  "display_name",
];

/** Push payload builders to scan for BANNED_PUSH_KEYS. */
const PUSH_PAYLOAD_BUILDERS = ["buildVoipApnsPayload", "buildFcmCallPayload"];

const failures = [];
const fail = (invariant, msg) => failures.push(`  ✗ [${invariant}] ${msg}`);
const ok = (invariant, msg) => console.log(`  ✓ [${invariant}] ${msg}`);

/** Recursively collect production .ts files under functions/src (excludes tests). */
function productionTsFiles(dir) {
  const out = [];
  for (const entry of readdirSync(dir)) {
    const full = join(dir, entry);
    if (statSync(full).isDirectory()) {
      if (entry === "__tests__" || entry === "node_modules") continue;
      out.push(...productionTsFiles(full));
    } else if (entry.endsWith(".ts") && !entry.endsWith(".test.ts") && !entry.endsWith(".d.ts")) {
      out.push(full);
    }
  }
  return out;
}

/**
 * True if `text` references a Firestore collection `name`, whether as a
 * double/single-quoted literal (`.collection("name")`) or a path segment inside
 * a template literal (`db.doc(`.../name/...`)`). Bounded by a path separator,
 * quote, or backtick so it doesn't match a substring of a larger identifier.
 */
function referencesCollection(text, name) {
  return new RegExp(`[/"'\`]${name.replace(/[.*+?^${}()|[\]\\]/g, "\\$&")}[/"'\`]`).test(text);
}

function readOrDie(path) {
  try {
    return readFileSync(path, "utf8");
  } catch (err) {
    console.error(`MISCONFIGURED: cannot read ${path}: ${err.message}`);
    process.exit(2);
  }
}

/** Extract a `export function NAME(...) { ... }` body via brace matching. */
function extractFunctionBody(source, name) {
  const sig = source.indexOf(`function ${name}`);
  if (sig === -1) return null;
  const open = source.indexOf("{", sig);
  if (open === -1) return null;
  let depth = 0;
  for (let i = open; i < source.length; i += 1) {
    const c = source[i];
    if (c === "{") depth += 1;
    else if (c === "}") {
      depth -= 1;
      if (depth === 0) return source.slice(open, i + 1);
    }
  }
  return null;
}

console.log("Privacy invariants gate (run-09)\n");

// --- Load Firestore TTL field overrides -------------------------------------
const indexesRaw = readOrDie(INDEXES_PATH);
let indexes;
try {
  indexes = JSON.parse(indexesRaw);
} catch (err) {
  console.error(`MISCONFIGURED: firestore.indexes.json is not valid JSON: ${err.message}`);
  process.exit(2);
}
const ttlOverrides = (indexes.fieldOverrides ?? []).filter((o) => o && o.ttl === true);
const ttlByCollection = new Map(ttlOverrides.map((o) => [o.collectionGroup, o.fieldPath]));

// --- Load production functions source ---------------------------------------
const prodFiles = productionTsFiles(FUNCTIONS_SRC).map((f) => ({ path: f, text: readFileSync(f, "utf8") }));
const allProdText = prodFiles.map((f) => f.text).join("\n");

// === I1: ephemeral PII collections must declare a TTL override ==============
for (const { collection, field, finding } of EPHEMERAL_PII_COLLECTIONS) {
  if (ttlByCollection.get(collection) === field) {
    ok("I1", `${collection}.${field} has a ttl:true override (${finding})`);
  } else {
    fail(
      "I1",
      `${collection} must have a {"collectionGroup":"${collection}","fieldPath":"${field}","ttl":true} field override in firestore.indexes.json (${finding}) — otherwise uid+tokens accumulate forever`,
    );
  }
}

// === I2: every ttl override must be backed by code ==========================
// Strict for the run-09 ephemeral PII collections (a missing writer there is a
// retention leak): require a single file that references the collection literal
// AND stamps the TTL field. Lighter for every OTHER pre-existing TTL collection
// (whose writers legitimately reference the collection via a shared constant):
// require only that the collection literal is referenced somewhere in
// functions/src, which catches a fully-orphaned (dead) TTL index.
const ephemeralCollections = new Set(EPHEMERAL_PII_COLLECTIONS.map((c) => c.collection));
for (const [collection, field] of ttlByCollection) {
  if (ephemeralCollections.has(collection)) {
    const writer = prodFiles.find(
      (f) => referencesCollection(f.text, collection) && new RegExp(`\\b${field}\\s*:`).test(f.text),
    );
    if (writer) {
      ok("I2", `${collection}.${field} TTL index has a run-09 writer (${writer.path.replace(REPO_ROOT + "/", "")})`);
    } else {
      fail(
        "I2",
        `${collection}.${field} has a ttl:true index but NO Cloud Functions writer stamps "${field}" — either remove the dead index or stamp the field on write`,
      );
    }
  } else if (referencesCollection(allProdText, collection)) {
    ok("I2", `${collection}.${field} TTL index is referenced by functions/src`);
  } else {
    fail(
      "I2",
      `${collection}.${field} has a ttl:true index but the collection "${collection}" is never referenced in functions/src — likely a dead/orphaned TTL index`,
    );
  }
}

// === I3: no raw firebase-functions/logger import in production source ========
const rawLoggerImporters = prodFiles.filter((f) =>
  /import\s[^;]*from\s+["']firebase-functions\/logger["']/.test(f.text),
);
if (rawLoggerImporters.length === 0) {
  ok("I3", "no production source imports the raw firebase-functions/logger (F-RR09-002)");
} else {
  for (const f of rawLoggerImporters) {
    fail(
      "I3",
      `${f.path.replace(REPO_ROOT + "/", "")} imports firebase-functions/logger — it bypasses the PII scrubber; use logInfo/logWarn/logError from ./logging.js (F-RR09-002)`,
    );
  }
}

// === I4: structured logger keeps UID-path redaction =========================
const loggingPath = join(FUNCTIONS_SRC, "logging.ts");
const loggingText = readOrDie(loggingPath);
if (/function\s+redactUidPaths\b/.test(loggingText) && /redactUidPaths\s*\(/.test(loggingText)) {
  ok("I4", "logging.ts retains redactUidPaths and applies it (F-RR09-002)");
} else {
  fail(
    "I4",
    "logging.ts must define and apply redactUidPaths() so UIDs embedded in path/message/error string values are redacted (F-RR09-002)",
  );
}

// === I5: push payload builders omit stable correlators ======================
const voipPushPath = join(FUNCTIONS_SRC, "voipPush.ts");
const voipPushText = readOrDie(voipPushPath);
for (const builder of PUSH_PAYLOAD_BUILDERS) {
  const body = extractFunctionBody(voipPushText, builder);
  if (body === null) {
    fail("I5", `voipPush.ts no longer defines ${builder}() — the push-payload-minimization invariant cannot be checked`);
    continue;
  }
  const offending = BANNED_PUSH_KEYS.filter((k) => new RegExp(`\\b${k}\\b`).test(body));
  if (offending.length === 0) {
    ok("I5", `${builder}() omits stable correlators (F-RR09-008)`);
  } else {
    fail(
      "I5",
      `${builder}() includes banned correlator key(s) [${offending.join(", ")}] — these must never ride to APNs/FCM (F-RR09-008)`,
    );
  }
}

// --- Verdict ----------------------------------------------------------------
console.log("");
if (failures.length > 0) {
  console.error(`Privacy invariants gate FAILED (${failures.length} violation${failures.length === 1 ? "" : "s"}):\n`);
  console.error(failures.join("\n"));
  console.error(
    "\nThese invariants protect run-09 (privacy/logging/metadata). See docs/security/PRIVACY_INVARIANTS.md.",
  );
  process.exit(1);
}
console.log("Privacy invariants gate PASSED — all run-09 structural invariants hold.");
process.exit(0);
