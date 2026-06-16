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

const GATE = join(
  dirname(fileURLToPath(import.meta.url)),
  "check-privacy-invariants.mjs",
);
const roots = [];
process.on("exit", () =>
  roots.forEach((d) => rmSync(d, { recursive: true, force: true })),
);

// --- Minimal "good" fixture tree (all invariants hold) ----------------------
const GOOD_INDEXES = {
  indexes: [],
  fieldOverrides: [
    {
      collectionGroup: "voip_outbound",
      fieldPath: "expireAt",
      ttl: true,
      indexes: [],
    },
    {
      collectionGroup: "fcm_outbound",
      fieldPath: "expireAt",
      ttl: true,
      indexes: [],
    },
    {
      collectionGroup: "agent_notification_events",
      fieldPath: "expireAt",
      ttl: true,
      indexes: [],
    },
  ],
};
// Inline-typed signatures mirror the real voipPush.ts: the param destructure
// type contains braces, so these fixtures exercise extractFunctionBody's
// param-skip — the exact path whose absence hid a false-negative before review.
const GOOD_VOIPPUSH = `
export function buildVoipApnsPayload(args: { callId: string; isVideo: boolean; correlationId: string }): Record<string, unknown> {
  return { aps: { "content-available": 1 }, type: "media_incoming_call", callId: args.callId, correlationId: args.correlationId, isVideo: args.isVideo };
}
export function buildFcmCallPayload(args: { callId: string; isVideo: boolean; correlationId: string }): Record<string, string> {
  return { type: "media_incoming_call", caller_name: "Incoming call", feature: "voiceCall", call_id: args.callId, correlation_id: args.correlationId };
}
const w = db.collection("voip_outbound").add({ uid, expireAt: x });
const f = db.collection("fcm_outbound").add({ uid, expireAt: x });
`;
const GOOD_AGENTNOTIF = `const EVENT_COLLECTION = "agent_notification_events";
const e = { expireAt: Timestamp.fromMillis(n + TTL) };
export function buildFcmMessage(args: { event: { id: string; runtime: string; providerLabel: string; preview: string; replyEnabled: boolean }; device: { fcmToken?: string; platform: string } }) {
  const data = {
    type: "agent_reply",
    event_id: args.event.id,
    runtime: args.event.runtime,
    title: args.event.providerLabel,
    preview: args.event.preview,
    reply_enabled: args.event.replyEnabled ? "true" : "false",
  };
  const base = {
    token: args.device.fcmToken ?? "",
    data,
    android: { priority: "high", collapseKey: "agent-reply", ttl: 600000 },
  };
  if (args.device.platform === "android") return base;
  return {
    token: base.token,
    data: base.data,
    android: base.android,
    notification: { title: data.title, body: data.preview },
    apns: { payload: { aps: { category: "AGENT_REPLY", sound: "default" } }, headers: { "apns-push-type": "alert", "apns-priority": "10" } },
  };
}`;
const GOOD_LOGGING = `function redactUidPaths(v){return v;} function scrubString(v){return redactUidPaths(v);}`;
// Minimal account-deletion fixture: routes through logWarn, never logs document_id
// or a raw storage_prefix, and keeps \`${uid}\` out of log arguments.
const GOOD_ACCOUNT_DELETION = `
import { logWarn } from "./logging.js";
function safeWarn(user_id_hash, msg, err, extra) {
  logWarn({ event: "account_deletion_warning", user_id_hash, message: msg, error: String(err), ...extra });
}
export async function eraseUserCloudData(db, uid, options) {
  safeWarn(uid.slice(0, 8), "Failed to destroy provider credential secret", new Error("boom"), { account_id_hash: "abc", collection: "provider_account_secret_refs" });
  for (const prefix of [\`users/\${uid}/\`, \`avatars/\${uid}\`]) {
    await options.deleteStorageObjects(prefix).catch((err) =>
      safeWarn(uid.slice(0, 8), "Failed to delete Cloud Storage objects", err, { storage_prefix_kind: prefix.startsWith("avatars/") ? "avatars" : "users" })
    );
  }
}
`;

/** Write a fixture tree under a fresh temp dir; `mut` may mutate the files map. */
function buildTree(mut = (f) => f) {
  const root = mkdtempSync(join(tmpdir(), "privgate-"));
  roots.push(root);
  const files = mut({
    "firestore.indexes.json": JSON.stringify(GOOD_INDEXES, null, 2),
    "functions/src/voipPush.ts": GOOD_VOIPPUSH,
    "functions/src/agentNotifications.ts": GOOD_AGENTNOTIF,
    "functions/src/logging.ts": GOOD_LOGGING,
    "functions/src/accountDeletion.ts": GOOD_ACCOUNT_DELETION,
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
    execFileSync("node", [GATE], {
      env: { ...process.env, PRIVACY_GATE_ROOT: root },
      stdio: "pipe",
    });
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
    idx.fieldOverrides = idx.fieldOverrides.filter(
      (o) => o.collectionGroup !== "fcm_outbound",
    );
    f["firestore.indexes.json"] = JSON.stringify(idx);
    return f;
  }),
  1,
);

// I3: a raw firebase-functions/logger import must FAIL.
expect(
  "I3 — raw firebase-functions/logger import fails",
  buildTree((f) => {
    f["functions/src/agentNotifications.ts"] =
      `import * as logger from "firebase-functions/logger";\n` +
      f["functions/src/agentNotifications.ts"];
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

// I5: re-adding a stable correlator to a push payload must FAIL. Critically,
// this injects into the BODY of an inline-typed builder — with the pre-review
// extractFunctionBody (which grabbed the param TYPE) the gate would have missed
// it, so this case is a standing regression guard for that false-negative.
expect(
  "I5 — connection_id back in APNs payload body fails",
  buildTree((f) => {
    f["functions/src/voipPush.ts"] = f["functions/src/voipPush.ts"].replace(
      "callId: args.callId, correlationId: args.correlationId",
      "callId: args.callId, connection_id: args.connectionId, correlationId: args.correlationId",
    );
    return f;
  }),
  1,
);

// I5: a banned key in the PARAM TYPE alone (not forwarded to the payload) must
// NOT trip the gate — proves the gate inspects the payload body, not the params.
expect(
  "I5 — connectionId only in the param type still passes",
  buildTree((f) => {
    f["functions/src/voipPush.ts"] = f["functions/src/voipPush.ts"].replace(
      "args: { callId: string; isVideo: boolean; correlationId: string }): Record<string, unknown>",
      "args: { callId: string; isVideo: boolean; correlationId: string; connectionId?: string }): Record<string, unknown>",
    );
    return f;
  }),
  0,
);

// I5: an object spread in a payload builder can forward a banned key past the
// literal check, so it must FAIL.
expect(
  "I5 — object spread in payload builder fails",
  buildTree((f) => {
    f["functions/src/voipPush.ts"] = f["functions/src/voipPush.ts"].replace(
      'aps: { "content-available": 1 }, type: "media_incoming_call", callId: args.callId, correlationId: args.correlationId, isVideo: args.isVideo',
      '...args, type: "media_incoming_call"',
    );
    return f;
  }),
  1,
);

// I7: a raw console.warn in accountDeletion.ts must FAIL.
expect(
  "I7 — raw console.warn in accountDeletion.ts fails",
  buildTree((f) => {
    f["functions/src/accountDeletion.ts"] =
      `console.warn("leaked uid", uid);\n` + f["functions/src/accountDeletion.ts"];
    return f;
  }),
  1,
);

// I7: logging a document_id (which embeds the full UID) must FAIL.
expect(
  "I7 — document_id in accountDeletion.ts logWarn fails",
  buildTree((f) => {
    f["functions/src/accountDeletion.ts"] = f["functions/src/accountDeletion.ts"].replace(
      'account_id_hash: "abc"',
      'document_id: doc.id',
    );
    return f;
  }),
  1,
);

// I7: a raw storage_prefix field (carries `users/${uid}/`) must FAIL.
expect(
  "I7 — storage_prefix in accountDeletion.ts logWarn fails",
  buildTree((f) => {
    f["functions/src/accountDeletion.ts"] = f["functions/src/accountDeletion.ts"].replace(
      'storage_prefix_kind: prefix.startsWith("avatars/") ? "avatars" : "users"',
      'storage_prefix: prefix',
    );
    return f;
  }),
  1,
);

// I7: \`${uid}\` inside a logWarn argument must FAIL.
expect(
  "I7 — ${uid} interpolation in accountDeletion.ts logWarn fails",
  buildTree((f) => {
    f["functions/src/accountDeletion.ts"] = f["functions/src/accountDeletion.ts"].replace(
      'message: msg',
      'message: `failed for ${uid}`',
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

// Misconfiguration: a missing functions/src must exit 2 (clean, not a stack trace).
expect(
  "missing functions/src exits 2",
  buildTree((f) => {
    f["functions/src/voipPush.ts"] = null;
    f["functions/src/agentNotifications.ts"] = null;
    f["functions/src/logging.ts"] = null;
    return f;
  }),
  2,
);

console.log(
  `\n${failed === 0 ? "PASS" : "FAIL"}: ${passed} passed, ${failed} failed`,
);
process.exit(failed === 0 ? 0 : 1);
