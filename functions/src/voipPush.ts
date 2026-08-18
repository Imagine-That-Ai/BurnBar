/**
 * @fileoverview Mercury Phase 5 — VoIP push fan-out helpers.
 *
 * `triggerVoIPCall` lives in `callables/voipPush.ts`. This module owns
 * request parsing, entitlement checks, and push-channel resolution shared
 * with unit tests (`scripts/test-fcm-android.mjs`).
 *
 * Schema for the callable request:
 *   {
 *     callId: string
 *     connectionId: string
 *     pairedDeviceId: string
 *     displayName: string
 *     isVideo: boolean
 *     voipDeviceToken?: string
 *     androidDeviceId?: string
 *   }
 */

import { randomUUID } from "node:crypto";

import { getFirestore } from "firebase-admin/firestore";
import { isRecord, isTimestampWithToMillis, stringField } from "./guards.js";

const MEDIA_ENTITLEMENT_DOC_ID = "hosted_media_sync";

/**
 * Fresh, single-push correlation id (T-PRV-01 / T-PRV-07). Push payloads use
 * this instead of stable routing ids; Android resolves any required call route
 * from an owner-scoped, short-lived Firestore context after receiving the push.
 * Because this value rotates per push, it cannot be used to link a device
 * across call sessions; the device still dedupes duplicate fan-outs of the SAME
 * push via the document id / `correlationId` echoed back.
 */
export function ephemeralCallCorrelationId(): string {
  return randomUUID();
}
const CLOUD_PRO_ENTITLEMENT_DOC_ID = "burnbar_pro_max";
const CLOUD_PRO_PRODUCT_IDS = new Set([
  "com.openburnbar.proMax.v2.monthly",
  "com.openburnbar.proMax.monthly",
  "com.openburnbar.proMax.annual",
  "com.openburnbar.proMax.bundle.monthly",
]);

interface TriggerRequest {
  callId: string;
  connectionId: string;
  pairedDeviceId: string;
  displayName: string;
  isVideo: boolean;
  voipDeviceToken?: string;
  androidDeviceId?: string;
}

/** Generic, non-identifying caller label sent in every push (T-PRV-01). */
const GENERIC_CALLER_DISPLAY_NAME = "Incoming call";

/** TTL for queued push fan-out docs; matched by the Firestore `expireAt` TTL index. */
export const VOIP_OUTBOUND_TTL_MS = 15 * 60 * 1000;

/**
 * Stamp the fields the receiver checks before it acts on a push, identically on
 * both transports: the uid the call was minted for, and when the replay window
 * closes. Both are omitted rather than invented when the caller has neither.
 */
function stampPushRecipient(
  payload: Record<string, unknown>,
  args: { uid?: string; expiresAtMillis?: number },
): void {
  if (args.uid) payload.uid = args.uid;
  if (typeof args.expiresAtMillis === "number") {
    payload.expires_at_millis = String(args.expiresAtMillis);
  }
}

/**
 * Build the APNs VoIP push payload (T-PRV-01 / T-PRV-07). It deliberately carries
 * NO cleartext displayName and NO stable correlators (connectionId /
 * pairedDeviceId) — those previously rode to APNs (a third-party push processor)
 * and let it link a device across sessions / learn the caller. Only opaque
 * routing fields remain: the per-call `callId` the device already holds and a
 * fresh ephemeral `correlationId`.
 */
export function buildVoipApnsPayload(args: {
  callId: string;
  isVideo: boolean;
  correlationId: string;
  uid?: string;
  expiresAtMillis?: number;
}): Record<string, unknown> {
  const payload: Record<string, unknown> = {
    aps: { "content-available": 1 },
    type: "media_incoming_call",
    callId: args.callId,
    correlationId: args.correlationId,
    isVideo: args.isVideo,
  };
  stampPushRecipient(payload, args);
  return payload;
}

/**
 * Build the Android FCM data payload (T-PRV-01 / T-PRV-07). Android's
 * background receiver resolves the paired Mac connection id from the
 * owner-scoped call context keyed by the ephemeral `correlationId`, so FCM
 * stays free of stable cross-processor correlators and real display names.
 */
export function buildFcmCallPayload(args: {
  callId: string;
  isVideo: boolean;
  correlationId: string;
  uid?: string;
  expiresAtMillis?: number;
}): Record<string, string> {
  const payload: Record<string, string> = {
    type: "media_incoming_call",
    caller_name: GENERIC_CALLER_DISPLAY_NAME,
    caller_initial: pushCallerInitial(GENERIC_CALLER_DISPLAY_NAME),
    feature: args.isVideo ? "videoCall" : "voiceCall",
    call_id: args.callId,
    correlation_id: args.correlationId,
  };
  stampPushRecipient(payload, args);
  return payload;
}

export const PUSH_DISPLAY_NAME_MAX_CHARS = 40;

export function sanitizePushDisplayName(raw: string): string {
  let s = raw.replace(/[\u0000-\u001f\u200b-\u200d\u202a-\u202e\ufeff]/gu, " ");
  s = s.replace(/\s+/gu, " ");
  s = s.trim();
  const chars = Array.from(s);
  if (chars.length > PUSH_DISPLAY_NAME_MAX_CHARS) {
    return chars.slice(0, PUSH_DISPLAY_NAME_MAX_CHARS).join("");
  }
  return s;
}

export function pushCallerInitial(name: string): string {
  const chars = Array.from(name.trim());
  return chars.length > 0 ? chars[0].toUpperCase() : "";
}

function isValidRoutingId(id: string, maxLen = 160): boolean {
  if (id.length > maxLen) return false;
  if (/[\u0000-\u001f\u202a-\u202e]/u.test(id)) return false;
  return true;
}

export function parseTriggerRequest(raw: unknown): TriggerRequest | undefined {
  if (!isRecord(raw)) return undefined;
  const callId = stringField(raw, "callId");
  const connectionId = stringField(raw, "connectionId");
  const pairedDeviceId = stringField(raw, "pairedDeviceId");
  const displayName = typeof raw.displayName === "string" ? sanitizePushDisplayName(raw.displayName) : undefined;
  if (!callId || !connectionId || !pairedDeviceId || !displayName) return undefined;

  if (!isValidRoutingId(callId) || !isValidRoutingId(connectionId) || !isValidRoutingId(pairedDeviceId)) {
    return undefined;
  }

  return {
    callId,
    connectionId,
    pairedDeviceId,
    displayName: sanitizePushDisplayName(displayName),
    isVideo: raw.isVideo === true,
    voipDeviceToken: stringField(raw, "voipDeviceToken"),
    androidDeviceId: stringField(raw, "androidDeviceId"),
  };
}

interface ResolvedFanOut {
  apnsToken?: string;
  androidDeviceId?: string;
  fcmToken?: string;
}

/**
 * Pick the freshest push channel for the paired client.
 */
export async function resolveFanOut(args: {
  uid: string;
  pairedDeviceId: string;
  firestore?: FirebaseFirestore.Firestore;
}): Promise<ResolvedFanOut> {
  const firestore = args.firestore ?? getFirestore();
  const deviceId = args.pairedDeviceId?.trim() ?? "";
  if (!deviceId) {
    return {};
  }
  const snap = await firestore.doc(`users/${args.uid}/devices/${deviceId}`).get();
  if (!snap.exists) {
    return {};
  }
  const data = snap.data();
  const apnsToken = isRecord(data)
    ? (stringField(data, "voipDeviceToken") ?? stringField(data, "voip_token"))?.trim()
    : undefined;
  const fcmToken = isRecord(data) ? stringField(data, "fcm_token")?.trim() : undefined;
  const platform = isRecord(data) ? stringField(data, "platform")?.trim().toLowerCase() : undefined;
  if (platform === "android" || (fcmToken && !apnsToken)) {
    return {
      androidDeviceId: deviceId,
      fcmToken,
    };
  }
  if (apnsToken) {
    return { apnsToken };
  }
  if (fcmToken) {
    return {
      androidDeviceId: deviceId,
      fcmToken,
    };
  }
  return {};
}

export async function macHasActiveMediaEntitlement(
  uid: string,
  firestore: FirebaseFirestore.Firestore = getFirestore(),
): Promise<boolean> {
  const [media, pro] = await Promise.all([
    firestore.doc(`users/${uid}/entitlements/${MEDIA_ENTITLEMENT_DOC_ID}`).get(),
    firestore.doc(`users/${uid}/entitlements/${CLOUD_PRO_ENTITLEMENT_DOC_ID}`).get(),
  ]);
  if (media.exists && activeEntitlement(media.data())) {
    return true;
  }
  if (pro.exists && activeEntitlement(pro.data(), CLOUD_PRO_PRODUCT_IDS)) {
    return true;
  }
  return false;
}

function activeEntitlement(data: FirebaseFirestore.DocumentData | undefined, allowedProductIDs?: Set<string>): boolean {
  const entitlement = data ?? {};
  if (entitlement.active !== true) return false;
  if (allowedProductIDs) {
    const productID = typeof entitlement.productID === "string" ? entitlement.productID : "";
    if (!allowedProductIDs.has(productID)) return false;
  }
  const expireAt = entitlement.expireAt;
  if (!isTimestampWithToMillis(expireAt)) return false;
  return expireAt.toMillis() > Date.now();
}
