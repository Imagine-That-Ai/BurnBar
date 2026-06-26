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
const IOS_COREDEVICE_SAMPLE = [
  "01234567",
  "89AB",
  "CDEF",
  "0123",
  "456789ABCDEF",
].join("-");
const ANDROID_SERIAL_SAMPLE = ["TEST", "12345678"].join("");
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
    {
      collectionGroup: "credential_transfers",
      fieldPath: "expiresAt",
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
const GOOD_CREDENTIAL_TRANSFER =
  "const ref = db.doc(`credential_transfers/${id}`); const doc = { expiresAt: Timestamp.fromMillis(Date.now() + 86400000) };";
const GOOD_UID_REDACTOR = `function redactUidPaths(v){
  let result = v;
  result = result.replace(/\\busers\\/([A-Za-z0-9_-]{9,})/g, (_m, id) => "users/" + id.slice(0, 8) + "...");
  result = result.replace(/\\bworkspace-([A-Za-z0-9_-]{9,})/g, (_m, id) => "workspace-" + id.slice(0, 8) + "...");
  return result;
}`;
const GOOD_LOGGING = `${GOOD_UID_REDACTOR} function scrubString(v){return redactUidPaths(v);}`;

/** Write a fixture tree under a fresh temp dir; `mut` may mutate the files map. */
function buildTree(mut = (f) => f) {
  const root = mkdtempSync(join(tmpdir(), "privgate-"));
  roots.push(root);
  const files = mut({
    "firestore.indexes.json": JSON.stringify(GOOD_INDEXES, null, 2),
    "functions/src/voipPush.ts": GOOD_VOIPPUSH,
    "functions/src/agentNotifications.ts": GOOD_AGENTNOTIF,
    "functions/src/credentialTransfer.ts": GOOD_CREDENTIAL_TRANSFER,
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

expect(
  "I1 — credential_transfers TTL override removed fails",
  buildTree((f) => {
    const idx = JSON.parse(f["firestore.indexes.json"]);
    idx.fieldOverrides = idx.fieldOverrides.filter(
      (o) => o.collectionGroup !== "credential_transfers",
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

expect(
  "I4 — redactUidPaths only mentioned in a comment fails",
  buildTree((f) => {
    f["functions/src/logging.ts"] =
      `${GOOD_UID_REDACTOR} function scrubString(v){ /* redactUidPaths(v); */ return v; }`;
    return f;
  }),
  1,
);

expect(
  "I4 — no-op redactUidPaths implementation fails",
  buildTree((f) => {
    f["functions/src/logging.ts"] =
      `function redactUidPaths(v){ return v; } function scrubString(v){ return redactUidPaths(v); }`;
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

expect(
  "I5 — quoted banned APNs payload key fails",
  buildTree((f) => {
    f["functions/src/voipPush.ts"] = f["functions/src/voipPush.ts"].replace(
      "callId: args.callId, correlationId: args.correlationId",
      'callId: args.callId, "connection_id": args.connectionId, correlationId: args.correlationId',
    );
    return f;
  }),
  1,
);

expect(
  "I5 — computed banned FCM payload key fails",
  buildTree((f) => {
    f["functions/src/voipPush.ts"] = f["functions/src/voipPush.ts"].replace(
      "call_id: args.callId, correlation_id: args.correlationId",
      'call_id: args.callId, ["connection_id"]: args.connectionId, correlation_id: args.correlationId',
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

expect(
  "I5 — braced return type still scans executable body",
  buildTree((f) => {
    f["functions/src/voipPush.ts"] = f["functions/src/voipPush.ts"].replace(
      "buildFcmCallPayload(args: { callId: string; isVideo: boolean; correlationId: string }): Record<string, string>",
      "buildFcmCallPayload(args: { callId: string; isVideo: boolean; correlationId: string }): { payload: Record<string, string> }",
    );
    return f;
  }),
  0,
);

expect(
  "I5 — banned key after braced return type fails",
  buildTree((f) => {
    f["functions/src/voipPush.ts"] = f["functions/src/voipPush.ts"]
      .replace(
        "buildFcmCallPayload(args: { callId: string; isVideo: boolean; correlationId: string }): Record<string, string>",
        "buildFcmCallPayload(args: { callId: string; isVideo: boolean; correlationId: string }): { payload: Record<string, string> }",
      )
      .replace(
        "call_id: args.callId, correlation_id: args.correlationId",
        "call_id: args.callId, connection_id: args.connectionId, correlation_id: args.correlationId",
      );
    return f;
  }),
  1,
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

expect(
  "I5 — whitespace object spread in payload builder fails",
  buildTree((f) => {
    f["functions/src/voipPush.ts"] = f["functions/src/voipPush.ts"].replace(
      'aps: { "content-available": 1 }, type: "media_incoming_call", callId: args.callId, correlationId: args.correlationId, isVideo: args.isVideo',
      '... args, type: "media_incoming_call"',
    );
    return f;
  }),
  1,
);

expect(
  "I5 — object spread only in a comment still passes",
  buildTree((f) => {
    f["functions/src/voipPush.ts"] = f["functions/src/voipPush.ts"].replace(
      "return { aps:",
      "/* return { ...args }; */\n  return { aps:",
    );
    return f;
  }),
  0,
);

// I7: personal physical-device identifiers must not be committed to public
// docs/scripts/tests. The samples are assembled above so this self-test source
// does not itself carry a real-looking device token.
expect(
  "I7 — physical iOS device id in docs fails",
  buildTree((f) => {
    f["docs/local-device.md"] =
      `Physical iPhone ${IOS_COREDEVICE_SAMPLE} passed local validation.`;
    return f;
  }),
  1,
);

expect(
  "I7 — physical Android serial in docs fails",
  buildTree((f) => {
    f["docs/local-device.md"] =
      `Samsung Android ${ANDROID_SERIAL_SAMPLE} passed local validation.`;
    return f;
  }),
  1,
);

expect(
  "I7 — device placeholders in docs pass",
  buildTree((f) => {
    f["docs/local-device.md"] =
      "Physical iPhone <IOS_DEVICE_ID> and Android <ANDROID_SERIAL> passed local validation.";
    return f;
  }),
  0,
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
