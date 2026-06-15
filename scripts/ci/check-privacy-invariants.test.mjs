#!/usr/bin/env node
/**
 * Self-test for scripts/ci/check-privacy-invariants.mjs.
 *
 * Builds throwaway fixture trees and asserts the gate's exit codes for a clean
 * tree vs. each deliberately-broken invariant — positive controls that prove the
 * gate actually catches regressions (not just passes vacuously). Every case maps
 * to a run-09 finding the gate must keep closed. No network; self-cleaning.
 *
 * Run:  node scripts/ci/check-privacy-invariants.test.mjs
 * Exit: 0 = all self-test cases passed; 1 = the gate misbehaved.
 */
import { execFileSync } from "node:child_process";
import { mkdtempSync, mkdirSync, writeFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const GATE = join(dirname(fileURLToPath(import.meta.url)), "check-privacy-invariants.mjs");
const roots = [];
process.on("exit", () => roots.forEach((d) => rmSync(d, { recursive: true, force: true })));

// --- Minimal "good" fixture tree (all invariants hold) ----------------------
const GOOD_INDEXES = {
  indexes: [],
  fieldOverrides: [
    { collectionGroup: "voip_outbound", fieldPath: "expireAt", ttl: true, indexes: [] },
    { collectionGroup: "fcm_outbound", fieldPath: "expireAt", ttl: true, indexes: [] },
    { collectionGroup: "agent_notification_events", fieldPath: "expireAt", ttl: true, indexes: [] },
  ],
};
const GOOD_VOIPPUSH = `
export function buildVoipApnsPayload(args) {
  return { aps: { "content-available": 1 }, type: "media_incoming_call", callId: args.callId, correlationId: args.correlationId, isVideo: args.isVideo };
}
export function buildFcmCallPayload(args) {
  return { type: "media_incoming_call", caller_name: "Incoming call", feature: "voiceCall", call_id: args.callId, correlation_id: args.correlationId };
}
const w = db.collection("voip_outbound").add({ uid, expireAt: x });
const f = db.collection("fcm_outbound").add({ uid, expireAt: x });
`;
const GOOD_AGENTNOTIF = `const EVENT_COLLECTION = "agent_notification_events";
const e = { expireAt: Timestamp.fromMillis(n + TTL) };`;
const GOOD_LOGGING = `function redactUidPaths(v){return v;} function scrubString(v){return redactUidPaths(v);}`;

/** Write a fixture tree under a fresh temp dir; `mut` may mutate the files map. */
function buildTree(mut = (f) => f) {
  const root = mkdtempSync(join(tmpdir(), "privgate-"));
  roots.push(root);
  const files = mut({
    "firestore.indexes.json": JSON.stringify(GOOD_INDEXES, null, 2),
    "functions/src/voipPush.ts": GOOD_VOIPPUSH,
    "functions/src/agentNotifications.ts": GOOD_AGENTNOTIF,
    "functions/src/logging.ts": GOOD_LOGGING,
  });
  for (const [rel, content] of Object.entries(files)) {
    if (content === null) continue;
    const full = join(root, rel);
    mkdirSync(dirname(full), { recursive: true });
    writeFileSync(full, content);
  }
  return root;
}

/** Run the gate against a fixture root; return its exit code. */
function runGate(root) {
  try {
    execFileSync("node", [GATE], { env: { ...process.env, PRIVACY_GATE_ROOT: root }, stdio: "pipe" });
    return 0;
  } catch (err) {
    return err.status ?? 1;
  }
}

let passed = 0;
let failed = 0;
function expect(label, root, wantExit) {
  const got = runGate(root);
  if (got === wantExit) {
    console.log(`  ✓ ${label} (exit ${got})`);
    passed += 1;
  } else {
    console.error(`  ✗ ${label}: expected exit ${wantExit}, got ${got}`);
    failed += 1;
  }
}

console.log("Self-test: check-privacy-invariants.mjs\n");

// Positive control: a clean tree passes.
expect("clean tree passes", buildTree(), 0);

// I1: an ephemeral PII collection missing its TTL override must FAIL.
expect(
  "I1 — fcm_outbound TTL override removed fails",
  buildTree((f) => {
    const idx = JSON.parse(f["firestore.indexes.json"]);
    idx.fieldOverrides = idx.fieldOverrides.filter((o) => o.collectionGroup !== "fcm_outbound");
    f["firestore.indexes.json"] = JSON.stringify(idx);
    return f;
  }),
  1,
);

// I3: a raw firebase-functions/logger import must FAIL.
expect(
  "I3 — raw firebase-functions/logger import fails",
  buildTree((f) => {
    f["functions/src/agentNotifications.ts"] = `import * as logger from "firebase-functions/logger";\n` + f["functions/src/agentNotifications.ts"];
    return f;
  }),
  1,
);

// I4: removing the UID-path redaction must FAIL.
expect(
  "I4 — redactUidPaths removed fails",
  buildTree((f) => {
    f["functions/src/logging.ts"] = `function scrubString(v){return v;}`;
    return f;
  }),
  1,
);

// I5: re-adding a stable correlator to a push payload must FAIL.
expect(
  "I5 — connection_id back in APNs payload fails",
  buildTree((f) => {
    f["functions/src/voipPush.ts"] = f["functions/src/voipPush.ts"].replace(
      'callId: args.callId, correlationId: args.correlationId',
      'callId: args.callId, connection_id: args.connectionId, correlationId: args.correlationId',
    );
    return f;
  }),
  1,
);

// Misconfiguration: invalid indexes JSON must exit 2 (fail-closed, not crash to 0).
expect(
  "invalid firestore.indexes.json exits 2",
  buildTree((f) => {
    f["firestore.indexes.json"] = "{ not valid json";
    return f;
  }),
  2,
);

console.log(`\n${failed === 0 ? "PASS" : "FAIL"}: ${passed} passed, ${failed} failed`);
process.exit(failed === 0 ? 0 : 1);
