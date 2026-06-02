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
 * Idempotency: Firestore delivery is claimed with a transactional lease before
 * APNs I/O starts. Duplicate Eventarc deliveries and scheduler races see the
 * `sending` lease and do not send a second push.
 */

import { createSign, randomUUID } from "node:crypto";
import { connect as http2Connect, type ClientHttp2Session } from "node:http2";
import { Timestamp, getFirestore, type Firestore } from "firebase-admin/firestore";
import { defineSecret, defineString } from "firebase-functions/params";
import { onDocumentCreated } from "firebase-functions/v2/firestore";
import { onSchedule } from "firebase-functions/v2/scheduler";
import {
  claimPendingPush,
  collectRetryablePushRefs,
  finishClaimedPush,
  nextPushRetryAt,
  pushWithResilience,
} from "./resilienceHelpers.js";

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
    // Generate a fresh UUID per request; duplicate Firestore/Eventarc work is
    // deduped by the transactional `sending` lease before this I/O starts.
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
 * Retry policy: transient failures leave the document with `status: "pending"`
 * and an exponential `retryAt`. `retryPendingVoIPOutbound` picks due retries
 * and expired leases back up.
 */
export const sendVoIPOutbound = onDocumentCreated(
  {
    document: "voip_outbound/{docId}",
    region: "us-central1",
    secrets: [APNS_KEY_ID, APNS_TEAM_ID, APNS_KEY_P8],
  },
  async (event) => {
    if (!event.data) return;
    await processVoIPOutboundRef(event.data.ref, event.params.docId);
  },
);

export async function processVoIPOutboundRef(
  ref: FirebaseFirestore.DocumentReference,
  documentId = ref.id,
): Promise<"sent" | "rejected" | "retry" | "skipped"> {
  const claim = await claimPendingPush(ref);
  if (!claim) return "skipped";
  const data = claim.data;
  if (!isRecord(data)) return "skipped";

  const deviceToken = stringValue(data.voipDeviceToken);
  if (!deviceToken) {
    await finishClaimedPush(ref, claim.leaseId, {
      status: "rejected",
      reason: "missing voipDeviceToken",
      rejectedAt: Timestamp.now(),
    });
    return "rejected";
  }

  const result = await pushToAPNs({
    deviceTokenHex: deviceToken,
    payload: isRecord(data.payload) ? data.payload : {},
    documentId,
  });

  switch (result.status) {
    case "sent":
      await finishClaimedPush(ref, claim.leaseId, {
        status: "sent",
        deliveredAt: Timestamp.now(),
        apnsStatusCode: result.apnsStatusCode ?? 200,
        retryAt: null,
        lastFailureReason: null,
      });
      return "sent";
    case "rejected":
      await finishClaimedPush(ref, claim.leaseId, {
        status: "rejected",
        rejectedAt: Timestamp.now(),
        apnsStatusCode: result.apnsStatusCode ?? null,
        reason: result.reason ?? null,
        retryAt: null,
      });
      return "rejected";
    case "retry":
      await finishClaimedPush(ref, claim.leaseId, {
        status: "pending",
        lastFailureReason: result.reason ?? null,
        retryAt: nextPushRetryAt(Date.now(), claim.attemptCount),
      });
      return "retry";
  }
}

export async function retryPendingVoIPPushes(
  firestore: Firestore = getFirestore(),
  limit = 50,
): Promise<number> {
  const refs = await collectRetryablePushRefs(firestore, "voip_outbound", { limit });
  let processed = 0;
  for (const ref of refs) {
    const result = await processVoIPOutboundRef(ref, ref.id);
    if (result !== "skipped") processed += 1;
  }
  return processed;
}

export const retryPendingVoIPOutbound = onSchedule(
  {
    schedule: "every 1 minutes",
    region: "us-central1",
    secrets: [APNS_KEY_ID, APNS_TEAM_ID, APNS_KEY_P8],
  },
  async () => {
    await retryPendingVoIPPushes();
  },
);
