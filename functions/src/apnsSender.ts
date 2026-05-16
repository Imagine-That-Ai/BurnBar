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
import { Timestamp } from "firebase-admin/firestore";
import { defineSecret, defineString } from "firebase-functions/params";
import { onDocumentCreated } from "firebase-functions/v2/firestore";

const APNS_KEY_ID = defineSecret("APNS_KEY_ID");
const APNS_TEAM_ID = defineSecret("APNS_TEAM_ID");
const APNS_KEY_P8 = defineSecret("APNS_KEY_P8");
const APNS_VOIP_TOPIC = defineString("APNS_VOIP_TOPIC", {
  default: "com.openburnbar.mobile.voip",
  description:
    "APNs topic for VoIP pushes. Must match the bundle id + .voip suffix.",
});
const APNS_HOST = defineString("APNS_HOST", {
  default: "https://api.push.apple.com",
  description:
    "APNs HTTP/2 host. Override to https://api.sandbox.push.apple.com for the development environment.",
});

const JWT_LIFETIME_MS = 50 * 60 * 1000; // Apple recommends < 60 min

interface CachedJWT {
  token: string;
  expiresAt: number;
}

let cachedJWT: CachedJWT | undefined;

function base64UrlEncode(input: Buffer | string): string {
  const buf = typeof input === "string" ? Buffer.from(input, "utf8") : input;
  return buf
    .toString("base64")
    .replace(/=+$/, "")
    .replace(/\+/g, "-")
    .replace(/\//g, "_");
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
    throw new Error(
      "APNS_KEY_ID, APNS_TEAM_ID, and APNS_KEY_P8 must be configured"
    );
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

/**
 * Push the given payload to APNs. Returns a structured result the
 * Firestore handler uses to update the source document. Pure function
 * so unit tests can mock `http2Connect` indirection if needed.
 */
export async function pushToAPNs(args: {
  deviceTokenHex: string;
  payload: Record<string, unknown>;
  documentId: string;
  topicOverride?: string;
  hostOverride?: string;
}): Promise<SendResult> {
  const url = new URL(args.hostOverride ?? APNS_HOST.value());
  const topic = args.topicOverride ?? APNS_VOIP_TOPIC.value();
  const jwt = mintJWT();

  return new Promise<SendResult>((resolve) => {
    let session: ClientHttp2Session | null = null;
    try {
      session = http2Connect(url.origin);
    } catch (err) {
      resolve({
        status: "retry",
        reason: `http2 connect: ${(err as Error).message}`,
      });
      return;
    }

    session.on("error", (err) => {
      resolve({ status: "retry", reason: `session error: ${err.message}` });
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
      // 429, 5xx → retry.
      resolve({ status: "retry", apnsStatusCode: responseStatus, reason });
    });
    req.on("error", (err) => {
      session?.close();
      resolve({
        status: "retry",
        apnsStatusCode: responseStatus || undefined,
        reason: err.message,
      });
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
    region: "us-central1",
    secrets: [APNS_KEY_ID, APNS_TEAM_ID, APNS_KEY_P8],
  },
  async (event) => {
    const data = event.data?.data();
    if (!data) return;
    if (data.status && data.status !== "pending") return;
    const deviceToken = data.voipDeviceToken as string | undefined;
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
      payload: (data.payload as Record<string, unknown>) ?? {},
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
          retryAt: Timestamp.fromMillis(Date.now() + 30_000),
          attemptCount: (data.attemptCount ?? 0) + 1,
        });
        return;
    }
  }
);
