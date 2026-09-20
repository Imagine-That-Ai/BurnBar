/**
 * @fileoverview ActivityKit `liveactivity` APNs fan-out for Agent Watch.
 *
 * The iOS client already merges `liveActivityPushToken` / `liveActivitySessionId`
 * onto `users/{uid}/devices/{deviceId}`. This module is the missing reader:
 * Computer Use session/action headers (already written for metering) rebuild a
 * privacy-safe `ContentState` and push it through the existing APNs HTTP/2
 * sender (`pushToAPNs` + `pushWithResilience`).
 *
 * Payload contract matches `AgentWatchLiveActivityAttributes.ContentState`.
 * Relays/Firestore are untrusted — no secrets, hashes, pixels, or iroh
 * `approvalId`. Approve/Deny still require local unlock + the live iroh
 * request; this push is status/content only.
 */

import { getFirestore } from "firebase-admin/firestore";
import { onDocumentCreated, onDocumentWritten } from "firebase-functions/v2/firestore";
import { APNS_KEY_ID, APNS_KEY_P8, APNS_TEAM_ID, pushToAPNs, type SendResult } from "./apnsSender.js";
import { errorMessage, isRecord, isTimestampWithToMillis, stringValue } from "./guards.js";
import { logError, logInfo } from "./logging.js";
import { firestoreWithResilience } from "./resilienceHelpers.js";
import { FUNCTIONS_REGION } from "./runtimeOptions.js";

const LIVE_ACTIVITY_TOKEN_HEX_RE = /^[A-Fa-f0-9]{32,512}$/u;
const SESSION_ID_MAX = 160;

const HALT_END_REASONS = new Set([
  "user_halt",
  "panic_hotkey",
  "panic_phone_gesture",
  "panic_mac_lock",
  "panic_remote_config",
  "panic_accessibility_revoked",
]);

const MODE_APP_NAME: Record<string, string> = {
  agent_watch: "Agent Live",
  browser: "Browser",
  system: "System",
};

type LiveActivityEvent = "update" | "end";

/** Keys must match Swift `AgentWatchLiveActivityAttributes.ContentState`. */
interface LiveActivityContentState {
  appName: string;
  lastAction: string;
  actionsCount: number;
  approvalPending: boolean;
  elapsed: number;
  remoteRefreshEnabled: boolean;
}

interface LiveActivityChange {
  event: LiveActivityEvent;
  sessionId: string;
  state: LiveActivityContentState;
}

interface DeviceLiveActivityEndpoint {
  id: string;
  tokenHex: string;
}

type LiveActivityPushFn = (args: {
  deviceTokenHex: string;
  payload: Record<string, unknown>;
  documentId: string;
  pushType: "liveactivity";
}) => Promise<SendResult>;

function boundedSessionId(raw: unknown): string | undefined {
  const value = stringValue(raw);
  if (!value || value.length > SESSION_ID_MAX) return undefined;
  return value;
}

function isIosFamily(platform: string): boolean {
  const normalized = platform.trim().toLowerCase();
  return normalized === "ios" || normalized === "ipados" || normalized === "";
}

function appNameForMode(mode: unknown): string {
  const key = stringValue(mode);
  return (key && MODE_APP_NAME[key]) || "Agent Live";
}

function lastActionForEndReason(endReason: string | undefined): string {
  if (!endReason) return "Watching Mac";
  if (HALT_END_REASONS.has(endReason)) return "Halted";
  return "Session ended";
}

function lastActionForStatus(status: string | undefined): string {
  switch (status) {
    case "awaiting_approval":
      return "Approval pending";
    case "denied":
    case "rejected":
      return "Denied";
    case "error":
      return "Error";
    case "executed":
      return "Action done";
    default:
      return "Watching Mac";
  }
}

function nonNegativeInt(raw: unknown): number {
  return typeof raw === "number" && Number.isFinite(raw) && raw >= 0 ? Math.floor(raw) : 0;
}

function elapsedSeconds(startedAt: unknown, nowMs: number): number {
  if (!isTimestampWithToMillis(startedAt)) return 0;
  return Math.max(0, Math.floor((nowMs - startedAt.toMillis()) / 1000));
}

function hasEnded(data: Record<string, unknown>): boolean {
  return Boolean(stringValue(data.endReason) || data.endedAt);
}

/**
 * Session start/end/halt. Metering-only updates (quota markers) do not push.
 */
export function liveActivityChangeFromSession(args: {
  sessionId: string;
  before?: Record<string, unknown>;
  after?: Record<string, unknown>;
  nowMs?: number;
}): LiveActivityChange | undefined {
  const sessionId = boundedSessionId(args.sessionId);
  const after = args.after;
  if (!sessionId || !after) return undefined;
  const nowMs = args.nowMs ?? Date.now();
  const ended = hasEnded(after);
  const wasEnded = args.before ? hasEnded(args.before) : false;
  if (ended && wasEnded) return undefined;
  if (!ended && args.before) return undefined;

  const endReason = stringValue(after.endReason);
  const actionCount = nonNegativeInt(after.actionCount);
  return {
    event: ended ? "end" : "update",
    sessionId,
    state: {
      appName: appNameForMode(after.mode),
      lastAction: ended ? lastActionForEndReason(endReason) : "Watching Mac",
      actionsCount: actionCount,
      approvalPending: false,
      elapsed: elapsedSeconds(after.startedAt, nowMs),
      remoteRefreshEnabled: true,
    },
  };
}

/**
 * Action headers. `awaiting_approval` is the only server-visible pending bit;
 * the iroh `approvalId` is not on this document and is never invented.
 */
export function liveActivityChangeFromAction(args: {
  action: Record<string, unknown>;
  session?: Record<string, unknown>;
  nowMs?: number;
}): LiveActivityChange | undefined {
  const sessionId = boundedSessionId(args.action.sessionId);
  if (!sessionId) return undefined;
  const nowMs = args.nowMs ?? Date.now();
  const status = stringValue(args.action.status);
  const entryIndex = nonNegativeInt(args.action.entryIndex);
  const sessionCount = args.session ? nonNegativeInt(args.session.actionCount) : 0;
  const ended = args.session ? hasEnded(args.session) : false;
  return {
    event: ended ? "end" : "update",
    sessionId,
    state: {
      appName: appNameForMode(args.session?.mode),
      lastAction: ended
        ? lastActionForEndReason(stringValue(args.session?.endReason))
        : lastActionForStatus(status),
      actionsCount: Math.max(sessionCount, entryIndex + 1),
      approvalPending: !ended && status === "awaiting_approval",
      elapsed: elapsedSeconds(args.session?.startedAt, nowMs),
      remoteRefreshEnabled: true,
    },
  };
}

/**
 * Apple ActivityKit APNs body. `content-state` is a full replacement.
 * `pendingApprovalId` is omitted so Approve/Deny stay disabled until iroh.
 */
export function buildLiveActivityApsPayload(args: {
  event: LiveActivityEvent;
  state: LiveActivityContentState;
  timestampSeconds?: number;
}): Record<string, unknown> {
  const timestamp = args.timestampSeconds ?? Math.floor(Date.now() / 1000);
  return {
    aps: {
      timestamp,
      event: args.event,
      "content-state": {
        appName: args.state.appName,
        lastAction: args.state.lastAction,
        actionsCount: args.state.actionsCount,
        approvalPending: args.state.approvalPending,
        elapsed: args.state.elapsed,
        remoteRefreshEnabled: args.state.remoteRefreshEnabled,
      },
    },
  };
}

export function selectLiveActivityDevices(
  devices: ReadonlyArray<{ id: string; data: Record<string, unknown> }>,
  sessionId: string,
): DeviceLiveActivityEndpoint[] {
  const wanted = boundedSessionId(sessionId);
  if (!wanted) return [];
  const selected: DeviceLiveActivityEndpoint[] = [];
  for (const device of devices) {
    const tokenHex = stringValue(device.data.liveActivityPushToken);
    const boundSession = boundedSessionId(device.data.liveActivitySessionId);
    const platform = stringValue(device.data.platform) ?? "";
    if (!tokenHex || !LIVE_ACTIVITY_TOKEN_HEX_RE.test(tokenHex)) continue;
    if (boundSession !== wanted) continue;
    if (!isIosFamily(platform)) continue;
    selected.push({ id: device.id, tokenHex });
  }
  return selected;
}

export async function fanoutLiveActivityUpdate(args: {
  uid: string;
  change: LiveActivityChange;
  firestore?: FirebaseFirestore.Firestore;
  push?: LiveActivityPushFn;
  nowMs?: number;
}): Promise<{ sent: number; skipped: number; failed: number; rejected: number }> {
  const firestore = args.firestore ?? getFirestore();
  const push = args.push ?? ((pushArgs) => pushToAPNs(pushArgs));
  const payload = buildLiveActivityApsPayload({
    event: args.change.event,
    state: args.change.state,
    timestampSeconds: Math.floor((args.nowMs ?? Date.now()) / 1000),
  });

  // Narrow at the server: an agent action fires this trigger for every action
  // document, so reading the whole device collection bills N reads per action.
  // `selectLiveActivityDevices` stays the filter of record (token shape and
  // platform still have to hold).
  const snapshot = await firestoreWithResilience("liveactivity.devices", () =>
    firestore
      .collection("users")
      .doc(args.uid)
      .collection("devices")
      .where("liveActivitySessionId", "==", args.change.sessionId)
      .get(),
  );
  const devices = selectLiveActivityDevices(
    snapshot.docs.map((doc) => ({ id: doc.id, data: isRecord(doc.data()) ? doc.data() : {} })),
    args.change.sessionId,
  );

  let sent = 0;
  let skipped = 0;
  let failed = 0;
  let rejected = 0;
  if (devices.length === 0) {
    skipped += 1;
    return { sent, skipped, failed, rejected };
  }

  for (const device of devices) {
    try {
      const result = await push({
        deviceTokenHex: device.tokenHex,
        payload,
        documentId: `${args.uid}:${device.id}:${args.change.sessionId}`,
        pushType: "liveactivity",
      });
      if (result.status === "sent") {
        sent += 1;
      } else if (result.status === "rejected") {
        rejected += 1;
        if (result.apnsStatusCode === 410) {
          await deviceRefClearToken(firestore, args.uid, device.id);
        }
      } else {
        failed += 1;
        logError({
          event: "live_activity_apns_retry",
          reason: result.reason ?? "retry",
          apns_status: result.apnsStatusCode ?? null,
        });
      }
    } catch (err) {
      failed += 1;
      logError({
        event: "live_activity_apns_failed",
        error: errorMessage(err),
      });
    }
  }

  logInfo({
    event: "live_activity_apns_fanout",
    push_event: args.change.event,
    sent,
    skipped,
    failed,
    rejected,
  });
  return { sent, skipped, failed, rejected };
}

async function deviceRefClearToken(
  firestore: FirebaseFirestore.Firestore,
  uid: string,
  deviceId: string,
): Promise<void> {
  await firestore
    .doc(`users/${uid}/devices/${deviceId}`)
    .set(
      {
        liveActivityPushToken: null,
        liveActivitySessionId: null,
        updated_at_millis: Date.now(),
      },
      { merge: true },
    )
    .catch(() => undefined);
}

export const onComputerUseSessionLiveActivity = onDocumentWritten(
  {
    document: "users/{uid}/computer_use_sessions/{sessionId}",
    region: FUNCTIONS_REGION,
    memory: "256MiB",
    timeoutSeconds: 60,
    secrets: [APNS_KEY_ID, APNS_TEAM_ID, APNS_KEY_P8],
  },
  async (event) => {
    const uid = stringValue(event.params.uid);
    const sessionId = stringValue(event.params.sessionId);
    if (!uid || !sessionId) return;
    const after = event.data?.after.exists ? event.data.after.data() : undefined;
    const before = event.data?.before.exists ? event.data.before.data() : undefined;
    const change = liveActivityChangeFromSession({
      sessionId,
      before: isRecord(before) ? before : undefined,
      after: isRecord(after) ? after : undefined,
    });
    if (!change) return;
    await fanoutLiveActivityUpdate({ uid, change });
  },
);

export const onComputerUseActionLiveActivity = onDocumentCreated(
  {
    document: "users/{uid}/computer_use_actions/{actionId}",
    region: FUNCTIONS_REGION,
    memory: "256MiB",
    timeoutSeconds: 60,
    secrets: [APNS_KEY_ID, APNS_TEAM_ID, APNS_KEY_P8],
  },
  async (event) => {
    const uid = stringValue(event.params.uid);
    const snapshot = event.data;
    if (!uid || !snapshot) return;
    const action = snapshot.data();
    if (!isRecord(action)) return;
    const sessionId = boundedSessionId(action.sessionId);
    const sessionSnap = sessionId
      ? await firestoreWithResilience("liveactivity.session", () =>
          getFirestore().doc(`users/${uid}/computer_use_sessions/${sessionId}`).get(),
        )
      : undefined;
    const sessionData = sessionSnap?.data();
    const change = liveActivityChangeFromAction({
      action,
      session: isRecord(sessionData) ? sessionData : undefined,
    });
    if (!change) return;
    await fanoutLiveActivityUpdate({ uid, change });
  },
);
