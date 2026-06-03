import { errorMessage, isRecord, stringValue } from "./guards.js";
/**
 * @fileoverview Mercury Phase 5 APNs sender.
 *
 * Risk-2 fix: `triggerVoIPCall` writes a `voip_outbound` document; this
 * file's Firestore trigger reads each pending document and pushes via
 * APNs HTTP/2. Uses an APNs Auth Key (`.p8`) + signed ES256 JWT —
 * standard pattern documented at
 * https://developer.apple.com/documentation/usernotifications/establishing_a_token-based_connection_to_apns.
 *
 * Lifecycle of a `voip_outbound` document:
 *   created → status: "pending"
 *   sent successfully → status: "sent", deliveredAt: Timestamp
 *   transient failure (5xx, network) → status: "pending" with retryAt
 *   permanent failure (410 BadDeviceToken etc.) → status: "rejected"
 *
 * Idempotency: APNs `apns-id` header is the Firestore document id, so
 * Apple coalesces duplicate sends if a retry fires before the previous
 * Firestore commit lands.
 */

import { createSign, randomUUID } from "node:crypto";
import { connect as http2Connect, type ClientHttp2Session } from "node:http2";
import { Timestamp, getFirestore } from "firebase-admin/firestore";
import type { QueryDocumentSnapshot } from "firebase-admin/firestore";
import { defineSecret, defineString } from "firebase-functions/params";
import { onDocumentCreated } from "firebase-functions/v2/firestore";
import { onSchedule } from "firebase-functions/v2/scheduler";
import * as logger from "firebase-functions/logger";
import { pushWithResilience } from "./resilienceHelpers.js";
import { FUNCTIONS_REGION } from "./runtimeOptions.js";

const APNS_KEY_ID = defineSecret("APNS_KEY_ID");
const APNS_TEAM_ID = defineSecret("APNS_TEAM_ID");
const APNS_KEY_P8 = defineSecret("APNS_KEY_P8");
const APNS_VOIP_TOPIC = defineString("APNS_VOIP_TOPIC", {
  default: "com.openburnbar.mobile.voip",
  description: "APNs topic for VoIP pushes. Must match the bundle id + .voip suffix.",
});
const APNS_HOST = defineString("APNS_HOST", {
  default: "https://api.push.apple.com",
  description: "APNs HTTP/2 host. Override to https://api.sandbox.push.apple.com for the development environment.",
});

const JWT_LIFETIME_MS = 50 * 60 * 1000; // Apple recommends < 60 min

interface CachedJWT {
  token: string;
  expiresAt: number;
}

let cachedJWT: CachedJWT | undefined;

function base64UrlEncode(input: Buffer | string): string {
  const buf = typeof input === "string" ? Buffer.from(input, "utf8") : input;
  return buf.toString("base64").replace(/=+$/, "").replace(/\+/g, "-").replace(/\//g, "_");
}

function mintJWT(): string {
  const now = Date.now();
  if (cachedJWT && cachedJWT.expiresAt > now + 60_000) {
    return cachedJWT.token;
  }

  const keyId = APNS_KEY_ID.value().trim();
  const teamId = APNS_TEAM_ID.value().trim();
  const keyP8 = APNS_KEY_P8.value();
  if (!keyId || !teamId || !keyP8) {
    throw new Error("APNS_KEY_ID, APNS_TEAM_ID, and APNS_KEY_P8 must be configured");
  }

  const header = {
    alg: "ES256",
    kid: keyId,
    typ: "JWT",
  };
  const claims = {
    iss: teamId,
    iat: Math.floor(now / 1000),
  };
  const headerB64 = base64UrlEncode(JSON.stringify(header));
  const claimsB64 = base64UrlEncode(JSON.stringify(claims));
  const signingInput = `${headerB64}.${claimsB64}`;

  const signer = createSign("SHA256");
  signer.update(signingInput);
  signer.end();
  const signature = signer.sign({
    key: keyP8,
    dsaEncoding: "ieee-p1363",
  });
  const sigB64 = base64UrlEncode(signature);

  const token = `${signingInput}.${sigB64}`;
  cachedJWT = { token, expiresAt: now + JWT_LIFETIME_MS };
  return token;
}

export interface SendResult {
  status: "sent" | "rejected" | "retry";
  apnsStatusCode?: number;
  reason?: string;
}

/** Thrown for transient APNs outcomes so pushWithResilience can retry; mapped to SendResult at boundary. */
export class ApnsRetryableError extends Error {
  constructor(
    message: string,
    readonly apnsStatusCode?: number,
  ) {
    super(message);
    this.name = "ApnsRetryableError";
  }
}

/**
 * Push the given payload to APNs. Returns a structured result the
 * Firestore handler uses to update the source document.
 */
export async function pushToAPNs(args: {
  deviceTokenHex: string;
  payload: Record<string, unknown>;
  documentId: string;
  topicOverride?: string;
  hostOverride?: string;
}): Promise<SendResult> {
  try {
    return await pushWithResilience("apns.voip", () => sendVoipPush(args));
  } catch (err) {
    if (err instanceof ApnsRetryableError) {
      return {
        status: "retry",
        apnsStatusCode: err.apnsStatusCode,
        reason: err.message,
      };
    }
    return { status: "retry", reason: errorMessage(err) };
  }
}

async function sendVoipPush(args: {
  deviceTokenHex: string;
  payload: Record<string, unknown>;
  documentId: string;
  topicOverride?: string;
  hostOverride?: string;
}): Promise<SendResult> {
  const url = new URL(args.hostOverride ?? APNS_HOST.value());
  const topic = args.topicOverride ?? APNS_VOIP_TOPIC.value();
  const jwt = mintJWT();

  return new Promise<SendResult>((resolve, reject) => {
    let session: ClientHttp2Session | null = null;
    try {
      session = http2Connect(url.origin);
    } catch (err) {
      reject(new ApnsRetryableError(`http2 connect: ${errorMessage(err)}`));
      return;
    }

    session.on("error", (err) => {
      reject(new ApnsRetryableError(`session error: ${err.message}`));
    });

    // Apple's apns-id MUST be a canonical UUID (`xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx`)
    // or Apple returns 400 BadMessageId. The Firestore docId is *not* a
    // UUID — passing it raw bricked every push during the smoke test.
    // Generate a fresh UUID per request; idempotency against duplicate
    // Eventarc fires is already handled by the Firestore status guard
    // (`if (data.status !== "pending") return;`) so we don't need the
    // apns-id to be deterministic for dedupe.
    const apnsId = randomUUID();
    const req = session.request({
      ":method": "POST",
      ":path": `/3/device/${args.deviceTokenHex}`,
      "apns-topic": topic,
      "apns-push-type": "voip",
      "apns-id": apnsId,
      "apns-priority": "10",
      "apns-expiration": "0",
      authorization: `bearer ${jwt}`,
      "content-type": "application/json",
    });

    let responseStatus = 0;
    let bodyChunks = "";
    req.on("response", (headers) => {
      responseStatus = Number(headers[":status"] ?? 0);
    });
    req.on("data", (chunk) => {
      bodyChunks += chunk.toString("utf8");
    });
    req.on("end", () => {
      session?.close();
      if (responseStatus === 200) {
        resolve({ status: "sent", apnsStatusCode: 200 });
        return;
      }
      // Apple sends a JSON body { reason: "..." } on every failure.
      let reason: string | undefined;
      try {
        const parsed = bodyChunks ? JSON.parse(bodyChunks) : undefined;
        reason = parsed?.reason;
      } catch {
        reason = bodyChunks.slice(0, 256);
      }
      if (responseStatus === 410 || responseStatus === 400) {
        // 410 BadDeviceToken / 400 BadCertificateEnvironment etc.
        resolve({ status: "rejected", apnsStatusCode: responseStatus, reason });
        return;
      }
      // 429, 5xx → retry (throw so pushWithResilience can apply policy).
      reject(new ApnsRetryableError(reason ?? `apns http ${responseStatus}`, responseStatus));
    });
    req.on("error", (err) => {
      session?.close();
      reject(new ApnsRetryableError(err.message, responseStatus || undefined));
    });
    req.setEncoding("utf8");
    req.end(JSON.stringify(args.payload));
  });
}

/**
 * Firestore trigger — fires for each new `voip_outbound` document
 * written by `triggerVoIPCall`. Pushes via APNs and updates the source
 * document with the outcome.
 *
 * Retry policy: transient failures leave the document with
 * `status: "pending"` and `retryAt = now + 30 s`. A scheduled function
 * (`retryStuckVoIPPushes`) — left to a follow-up commit — picks them
 * back up. Permanent failures are sealed with `status: "rejected"` so
 * dashboards can detect token rot.
 */
export const sendVoIPOutbound = onDocumentCreated(
  {
    document: "voip_outbound/{docId}",
    region: FUNCTIONS_REGION,
    secrets: [APNS_KEY_ID, APNS_TEAM_ID, APNS_KEY_P8],
  },
  async (event) => {
    const data = event.data?.data();
    if (!isRecord(data)) return;
    if (data.status && data.status !== "pending") return;
    const deviceToken = stringValue(data.voipDeviceToken);
    if (!deviceToken) {
      await event.data?.ref.update({
        status: "rejected",
        reason: "missing voipDeviceToken",
        rejectedAt: Timestamp.now(),
      });
      return;
    }

    const result = await pushToAPNs({
      deviceTokenHex: deviceToken,
      payload: isRecord(data.payload) ? data.payload : {},
      documentId: event.params.docId,
    });

    switch (result.status) {
      case "sent":
        await event.data?.ref.update({
          status: "sent",
          deliveredAt: Timestamp.now(),
          apnsStatusCode: result.apnsStatusCode ?? 200,
        });
        return;
      case "rejected":
        await event.data?.ref.update({
          status: "rejected",
          rejectedAt: Timestamp.now(),
          apnsStatusCode: result.apnsStatusCode ?? null,
          reason: result.reason ?? null,
        });
        return;
      case "retry":
        await event.data?.ref.update({
          status: "pending",
          lastAttemptAt: Timestamp.now(),
          lastFailureReason: result.reason ?? null,
          retryAt: Timestamp.fromMillis(Date.now() + RETRY_BACKOFF_BASE_MS),
          attemptCount: (typeof data.attemptCount === "number" ? data.attemptCount : 0) + 1,
        });
        return;
    }
  },
);

// ---------------------------------------------------------------------------
// Stuck-push retry sweeper (Risk-A2)
//
// The `sendVoIPOutbound` Eventarc trigger only fires once, on document
// creation. When that single push hits a transient APNs blip it leaves the
// document `status: "pending"` with a future `retryAt`, but nothing ever fires
// again — so remote VoIP wake silently never lands. `retryStuckVoIPPushes`
// runs every minute, finds those due-but-pending documents, and re-pushes them
// with exponential backoff until they either deliver or exhaust their budget.
// ---------------------------------------------------------------------------

/** Backoff base for transient retries (matches `sendVoIPOutbound`'s first retry). */
const RETRY_BACKOFF_BASE_MS = 30_000;
/** Hard ceiling on a single backoff interval so a wedged token retries hourly-ish, not yearly. */
const RETRY_BACKOFF_MAX_MS = 15 * 60_000;
/** After this many attempts a still-failing push is sealed `rejected` so dashboards see token rot. */
export const MAX_VOIP_RETRY_ATTEMPTS = 8;
/** Max documents handled per sweep tick — bounds Firestore writes + APNs fan-out per invocation. */
const SWEEP_BATCH_LIMIT = 50;

/**
 * Exponential backoff for the Nth attempt (1-based): 30s, 60s, 120s, … capped
 * at {@link RETRY_BACKOFF_MAX_MS}. `attempt` is the count *after* incrementing
 * for the failure we just observed.
 */
export function nextVoIPRetryDelayMs(attempt: number): number {
  const exponent = Math.max(0, attempt - 1);
  const raw = RETRY_BACKOFF_BASE_MS * 2 ** exponent;
  return Math.min(RETRY_BACKOFF_MAX_MS, raw);
}

/** Outcome of processing a single stuck document — surfaced for tests + logging. */
export type StuckPushOutcome = "sent" | "rejected" | "rescheduled" | "skipped";

type VoIPPushFn = (args: {
  deviceTokenHex: string;
  payload: Record<string, unknown>;
  documentId: string;
}) => Promise<SendResult>;

/**
 * Re-push a single due `voip_outbound` document and commit its next state.
 *
 * Reuses the exact field names + push shape from `sendVoIPOutbound`:
 *   - success → `status: "sent"`, `deliveredAt`, `apnsStatusCode`.
 *   - permanent reject (410/400) OR `attemptCount >= MAX_VOIP_RETRY_ATTEMPTS`
 *     → `status: "rejected"`, `rejectedAt`, `reason`.
 *   - transient retry → `status: "pending"`, bumped `attemptCount`, exponential
 *     `retryAt`, `lastAttemptAt`, `lastFailureReason`.
 *
 * Double-processing guard: only acts when the snapshot's status is still
 * `"pending"`; a doc another tick already advanced is left untouched.
 */
export async function processStuckVoIPPush(
  snapshot: QueryDocumentSnapshot,
  push: VoIPPushFn,
  now: Date = new Date(),
): Promise<StuckPushOutcome> {
  const data = snapshot.data();
  if (!isRecord(data)) return "skipped";
  // Guard against double-processing: a concurrent tick or the original trigger
  // may already have advanced this document past "pending".
  if (data.status !== "pending") return "skipped";

  const deviceToken = stringValue(data.voipDeviceToken);
  const priorAttempts = typeof data.attemptCount === "number" ? data.attemptCount : 0;

  if (!deviceToken) {
    await snapshot.ref.update({
      status: "rejected",
      rejectedAt: Timestamp.fromDate(now),
      reason: "missing voipDeviceToken",
    });
    return "rejected";
  }

  const result = await push({
    deviceTokenHex: deviceToken,
    payload: isRecord(data.payload) ? data.payload : {},
    // apns-id idempotency keys off the Firestore doc id (Apple coalesces dupes).
    documentId: snapshot.id,
  });

  switch (result.status) {
    case "sent":
      await snapshot.ref.update({
        status: "sent",
        deliveredAt: Timestamp.fromDate(now),
        apnsStatusCode: result.apnsStatusCode ?? 200,
      });
      return "sent";
    case "rejected":
      await snapshot.ref.update({
        status: "rejected",
        rejectedAt: Timestamp.fromDate(now),
        apnsStatusCode: result.apnsStatusCode ?? null,
        reason: result.reason ?? null,
      });
      return "rejected";
    case "retry": {
      const attemptCount = priorAttempts + 1;
      // Budget exhausted: seal it so token rot is visible rather than retrying forever.
      if (attemptCount >= MAX_VOIP_RETRY_ATTEMPTS) {
        await snapshot.ref.update({
          status: "rejected",
          rejectedAt: Timestamp.fromDate(now),
          attemptCount,
          apnsStatusCode: result.apnsStatusCode ?? null,
          reason: result.reason ?? `exhausted ${MAX_VOIP_RETRY_ATTEMPTS} retry attempts`,
        });
        return "rejected";
      }
      await snapshot.ref.update({
        status: "pending",
        attemptCount,
        lastAttemptAt: Timestamp.fromDate(now),
        lastFailureReason: result.reason ?? null,
        retryAt: Timestamp.fromMillis(now.getTime() + nextVoIPRetryDelayMs(attemptCount)),
      });
      return "rescheduled";
    }
  }
}

/**
 * Query due-and-pending `voip_outbound` documents across every subcollection
 * and re-push each one. Returns a per-outcome tally for structured logging.
 */
export async function sweepStuckVoIPPushes(
  db: ReturnType<typeof getFirestore>,
  push: VoIPPushFn,
  now: Date = new Date(),
): Promise<Record<StuckPushOutcome, number>> {
  const snapshot = await db
    .collectionGroup("voip_outbound")
    .where("status", "==", "pending")
    .where("retryAt", "<=", Timestamp.fromDate(now))
    .orderBy("retryAt", "asc")
    .limit(SWEEP_BATCH_LIMIT)
    .get();

  const tally: Record<StuckPushOutcome, number> = { sent: 0, rejected: 0, rescheduled: 0, skipped: 0 };
  for (const doc of snapshot.docs) {
    try {
      const outcome = await processStuckVoIPPush(doc, push, now);
      tally[outcome] += 1;
    } catch (err) {
      tally.skipped += 1;
      logger.error("retryStuckVoIPPushes: failed to process document", {
        documentPath: doc.ref.path,
        error: errorMessage(err),
      });
    }
  }
  return tally;
}

/**
 * Scheduled sweeper — re-pushes `voip_outbound` documents left `pending` after a
 * transient APNs failure once their `retryAt` falls due. Mirrors the onSchedule
 * option shape used by the iroh / Computer-Use monitoring rollups.
 */
export const retryStuckVoIPPushes = onSchedule(
  {
    schedule: "every 1 minutes",
    region: FUNCTIONS_REGION,
    secrets: [APNS_KEY_ID, APNS_TEAM_ID, APNS_KEY_P8],
  },
  async () => {
    const tally = await sweepStuckVoIPPushes(getFirestore(), (args) => pushToAPNs(args));
    if (tally.sent || tally.rejected || tally.rescheduled || tally.skipped) {
      logger.info("retryStuckVoIPPushes swept stuck VoIP pushes", tally);
    }
  },
);
